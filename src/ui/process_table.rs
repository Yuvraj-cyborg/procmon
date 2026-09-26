use std::cmp::Ordering;
use std::rc::Rc;
use std::sync::Arc;

use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::component::table::{Column, ColumnSort, TableDelegate, TableState};
use gpui_kit::component::{ActiveTheme, IconName, h_flex};
use gpui_kit::{
    App, ClickEvent, Context, Div, InteractiveElement, IntoElement, ParentElement, SharedString,
    Stateful, StatefulInteractiveElement, Styled, Window, div, prelude::FluentBuilder as _, px,
};

use crate::system::network::NetworkRates;
use crate::system::query::ProcessQuery;
use crate::system::snapshot::{ProcessInfo, Snapshot};
use crate::theme::Tint;
use crate::ui::process_detail;
use crate::ui::widgets::Meter;
use crate::units::{Bytes, Pid, Rate, compact_duration};

/// A column a process table can show. Each variant knows how to title,
/// size, sort and render itself, so pages just pick a list of columns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcessColumn {
    Name,
    Pid,
    Memory,
    MemoryShare,
    Cpu,
    Threads,
    DiskRead,
    DiskWrite,
    Syscalls,
    ContextSwitches,
    Wakeups,
    NetIn,
    NetOut,
    Packets,
    Uptime,
}

impl ProcessColumn {
    fn key(self) -> &'static str {
        match self {
            Self::Name => "name",
            Self::Pid => "pid",
            Self::Memory => "memory",
            Self::MemoryShare => "memory_share",
            Self::Cpu => "cpu",
            Self::Threads => "threads",
            Self::DiskRead => "disk_read",
            Self::DiskWrite => "disk_write",
            Self::Syscalls => "syscalls",
            Self::ContextSwitches => "csw",
            Self::Wakeups => "wakeups",
            Self::NetIn => "net_in",
            Self::NetOut => "net_out",
            Self::Packets => "packets",
            Self::Uptime => "uptime",
        }
    }

    fn title(self) -> &'static str {
        match self {
            Self::Name => "Process",
            Self::Pid => "PID",
            Self::Memory => "Memory",
            Self::MemoryShare => "Share of RAM",
            Self::Cpu => "CPU",
            Self::Threads => "Threads",
            Self::DiskRead => "Disk read",
            Self::DiskWrite => "Disk write",
            Self::Syscalls => "Syscalls",
            Self::ContextSwitches => "Ctx switches",
            Self::Wakeups => "Wakeups",
            Self::NetIn => "Received",
            Self::NetOut => "Sent",
            Self::Packets => "Packets",
            Self::Uptime => "Running for",
        }
    }

    fn width(self) -> f32 {
        match self {
            Self::Name => 240.,
            Self::MemoryShare => 160.,
            Self::Pid | Self::Threads => 80.,
            _ => 110.,
        }
    }

    fn is_numeric(self) -> bool {
        !matches!(self, Self::Name | Self::MemoryShare)
    }

    fn compare(self, a: &ProcessInfo, b: &ProcessInfo) -> Ordering {
        fn rate(p: &ProcessInfo, f: fn(&crate::system::snapshot::ActivityRates) -> Rate) -> f64 {
            p.activity.as_ref().map_or(-1.0, |a| f(a).per_sec())
        }
        fn net(p: &ProcessInfo, f: fn(&NetworkRates) -> f64) -> f64 {
            p.network.as_ref().map_or(-1.0, f)
        }
        match self {
            Self::Name => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
            Self::Pid => a.pid.cmp(&b.pid),
            Self::Memory | Self::MemoryShare => a.memory.cmp(&b.memory),
            Self::Cpu => a.cpu.get().total_cmp(&b.cpu.get()),
            Self::Threads => a.threads.cmp(&b.threads),
            Self::DiskRead => a.disk_read.cmp(&b.disk_read),
            Self::DiskWrite => a.disk_write.cmp(&b.disk_write),
            Self::Syscalls => rate(a, |r| r.syscalls).total_cmp(&rate(b, |r| r.syscalls)),
            Self::ContextSwitches => {
                rate(a, |r| r.context_switches).total_cmp(&rate(b, |r| r.context_switches))
            }
            Self::Wakeups => rate(a, |r| r.idle_wakeups).total_cmp(&rate(b, |r| r.idle_wakeups)),
            Self::NetIn => net(a, |n| n.received.0.get() as f64)
                .total_cmp(&net(b, |n| n.received.0.get() as f64)),
            Self::NetOut => {
                net(a, |n| n.sent.0.get() as f64).total_cmp(&net(b, |n| n.sent.0.get() as f64))
            }
            Self::Packets => {
                net(a, |n| n.packets.per_sec()).total_cmp(&net(b, |n| n.packets.per_sec()))
            }
            Self::Uptime => a.run_time.cmp(&b.run_time),
        }
    }

    fn text(self, p: &ProcessInfo) -> SharedString {
        let rate = |f: fn(&crate::system::snapshot::ActivityRates) -> Rate| {
            p.activity
                .as_ref()
                .map_or_else(|| "—".to_string(), |a| f(a).to_string())
        };
        match self {
            Self::Name => return p.name.clone(),
            Self::Pid => p.pid.to_string(),
            Self::Memory => p.memory.binary().to_string(),
            Self::MemoryShare => String::new(),
            Self::Cpu => p.cpu.to_string(),
            Self::Threads => p.threads.map_or_else(|| "—".into(), |t| t.to_string()),
            Self::DiskRead => p.disk_read.to_string(),
            Self::DiskWrite => p.disk_write.to_string(),
            Self::Syscalls => rate(|r| r.syscalls),
            Self::ContextSwitches => rate(|r| r.context_switches),
            Self::Wakeups => rate(|r| r.idle_wakeups),
            Self::NetIn => p
                .network
                .map_or_else(|| "—".into(), |n| n.received.to_string()),
            Self::NetOut => p.network.map_or_else(|| "—".into(), |n| n.sent.to_string()),
            Self::Packets => p
                .network
                .map_or_else(|| "—".into(), |n| n.packets.to_string()),
            Self::Uptime => compact_duration(p.run_time),
        }
        .into()
    }
}

/// Called to open the detail view for a process.
type InspectHandler = Rc<dyn Fn(Pid, SharedString, &mut Window, &mut App)>;

/// [`TableDelegate`] listing processes from the latest [`Snapshot`].
pub struct ProcessTable {
    columns: Vec<ProcessColumn>,
    /// Latest snapshot, kept so a new query can re-filter without waiting
    /// for the next sample.
    snapshot: Option<Arc<Snapshot>>,
    query: ProcessQuery,
    rows: Vec<ProcessInfo>,
    sort: (ProcessColumn, ColumnSort),
    total_memory: Bytes,
    selected: Option<Pid>,
    on_inspect: Option<InspectHandler>,
}

impl ProcessTable {
    pub fn new(columns: Vec<ProcessColumn>, sort_by: ProcessColumn) -> Self {
        Self {
            columns,
            snapshot: None,
            query: ProcessQuery::default(),
            rows: Vec::new(),
            sort: (sort_by, ColumnSort::Descending),
            total_memory: Bytes::ZERO,
            selected: None,
            on_inspect: None,
        }
    }

    /// Double-clicking a row or choosing "Inspect" calls `handler`.
    pub fn on_inspect(
        mut self,
        handler: impl Fn(Pid, SharedString, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_inspect = Some(Rc::new(handler));
        self
    }

    pub fn update(&mut self, snapshot: &Arc<Snapshot>) {
        self.snapshot = Some(snapshot.clone());
        self.rebuild();
    }

    pub fn set_query(&mut self, query: ProcessQuery) {
        self.query = query;
        self.rebuild();
    }

    fn rebuild(&mut self) {
        let Some(snapshot) = &self.snapshot else {
            return;
        };
        self.total_memory = snapshot.memory.total;
        self.rows = snapshot
            .processes
            .iter()
            .filter(|p| self.query.matches_process(p))
            .cloned()
            .collect();
        self.apply_sort();
    }

    fn apply_sort(&mut self) {
        let (column, direction) = self.sort;
        match direction {
            ColumnSort::Ascending => self.rows.sort_by(|a, b| column.compare(a, b)),
            ColumnSort::Descending | ColumnSort::Default => {
                self.rows.sort_by(|a, b| column.compare(b, a))
            }
        }
    }
}

impl TableDelegate for ProcessTable {
    fn columns_count(&self, _: &App) -> usize {
        self.columns.len()
    }

    fn rows_count(&self, _: &App) -> usize {
        self.rows.len()
    }

    fn column(&self, col_ix: usize, _: &App) -> Column {
        let column = self.columns[col_ix];
        let mut spec = Column::new(column.key(), column.title())
            .width(px(column.width()))
            .sortable();
        if column == self.sort.0 {
            spec = spec.sort(self.sort.1);
        }
        if column.is_numeric() {
            spec = spec.text_right();
        }
        if column == ProcessColumn::Name {
            spec = spec.fixed_left();
        }
        spec
    }

    fn perform_sort(
        &mut self,
        col_ix: usize,
        sort: ColumnSort,
        _: &mut Window,
        _: &mut Context<TableState<Self>>,
    ) {
        self.sort = (self.columns[col_ix], sort);
        self.apply_sort();
    }

    fn render_tr(
        &mut self,
        row_ix: usize,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) -> Stateful<Div> {
        let row = self.rows.get(row_ix).map(|p| (p.pid, p.name.clone()));
        let pid = row.as_ref().map(|(pid, _)| *pid);
        let selected = pid.is_some() && pid == self.selected;
        let inspect = self.on_inspect.clone();
        div()
            .id(("process-row", row_ix))
            .when(selected, |row| row.bg(cx.theme().table_active))
            .on_click(cx.listener(move |table, event: &ClickEvent, window, cx| {
                table.delegate_mut().selected = pid;
                if event.click_count() >= 2
                    && let (Some((pid, name)), Some(inspect)) = (&row, &inspect)
                {
                    inspect(*pid, name.clone(), window, cx);
                }
                cx.notify();
            }))
    }

    fn context_menu(
        &mut self,
        row_ix: usize,
        menu: PopupMenu,
        _: &mut Window,
        _: &mut Context<TableState<Self>>,
    ) -> PopupMenu {
        let Some(process) = self.rows.get(row_ix) else {
            return menu;
        };
        let (pid, name) = (process.pid, process.name.clone());
        let (quit_name, kill_name) = (name.clone(), name.clone());
        menu.when_some(self.on_inspect.clone(), |menu, inspect| {
            menu.item(
                PopupMenuItem::new("Inspect")
                    .icon(IconName::Info)
                    .on_click(move |_, window, cx| inspect(pid, name.clone(), window, cx)),
            )
            .separator()
        })
        .item(
            PopupMenuItem::new("Quit")
                .on_click(move |_, window, cx| process_detail::quit(pid, &quit_name, window, cx)),
        )
        .item(
            PopupMenuItem::new("Force Quit…").on_click(move |_, window, cx| {
                process_detail::confirm_force_quit(pid, kill_name.clone(), window, cx)
            }),
        )
    }

    fn render_td(
        &mut self,
        row_ix: usize,
        col_ix: usize,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) -> impl IntoElement {
        let column = self.columns[col_ix];
        let Some(process) = self.rows.get(row_ix) else {
            return div().into_any_element();
        };
        match column {
            ProcessColumn::MemoryShare => {
                let share = process.memory.ratio_of(self.total_memory);
                h_flex()
                    .size_full()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .child(Meter::single(share, Tint::Blue.strong()).height(px(6.))),
                    )
                    .child(
                        div()
                            .w(px(40.))
                            .text_right()
                            .text_color(cx.theme().muted_foreground)
                            .child(share.percent().to_string()),
                    )
                    .into_any_element()
            }
            ProcessColumn::Name => div()
                .truncate()
                .when(process.activity.is_none(), |d| {
                    d.text_color(cx.theme().muted_foreground)
                })
                .child(column.text(process))
                .into_any_element(),
            _ => div()
                .w_full()
                .text_right()
                .child(column.text(process))
                .into_any_element(),
        }
    }

    fn cell_text(&self, row_ix: usize, col_ix: usize, _: &App) -> String {
        self.rows
            .get(row_ix)
            .map(|p| self.columns[col_ix].text(p).to_string())
            .unwrap_or_default()
    }
}
