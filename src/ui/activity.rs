use gpui_kit::assets::IconName as Lucide;
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::component::table::{DataTable, TableState};
use gpui_kit::component::tag::Tag;
use gpui_kit::component::{ActiveTheme, Icon, IconName, Sizable, h_flex, v_flex};
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, Hsla, InteractiveElement, IntoElement,
    ParentElement, Render, SharedString, StatefulInteractiveElement, Styled, Subscription, Window,
    div, prelude::FluentBuilder as _, px, relative,
};

use crate::app::Page;
use crate::system::Monitor;
use crate::system::query::ProcessQuery;
use crate::system::snapshot::{
    CpuStats, NoiseReason, ProbeCoverage, ProcessInfo, Snapshot, ThreadAlert, ThreadAlertKind,
};
use crate::theme::Tint;
use crate::ui::process_detail::ProcessDetail;
use crate::ui::process_table::{ProcessColumn, ProcessTable};
use crate::ui::widgets::{Card, PageHeader, Sparkline, Stat, page_body, page_scroll, search_field};
use crate::units::{Pid, Ratio, compact_duration};

/// At most this many rows in the "Needs attention" card.
const ATTENTION_LIMIT: usize = 8;

pub struct ActivityPage {
    monitor: Entity<Monitor>,
    table: Entity<TableState<ProcessTable>>,
    search: Entity<InputState>,
    _subscriptions: [Subscription; 2],
}

impl ActivityPage {
    pub fn new(monitor: Entity<Monitor>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let columns = vec![
            ProcessColumn::Name,
            ProcessColumn::Cpu,
            ProcessColumn::Syscalls,
            ProcessColumn::ContextSwitches,
            ProcessColumn::Wakeups,
            ProcessColumn::NetIn,
            ProcessColumn::NetOut,
            ProcessColumn::Packets,
            ProcessColumn::DiskRead,
            ProcessColumn::DiskWrite,
            ProcessColumn::Threads,
            ProcessColumn::Pid,
        ];
        let table = cx.new(|cx| {
            TableState::new(
                ProcessTable::new(columns, ProcessColumn::Cpu).on_inspect({
                    let monitor = monitor.clone();
                    move |pid, name, window, cx| {
                        ProcessDetail::open(pid, name, monitor.clone(), window, cx)
                    }
                }),
                window,
                cx,
            )
            .col_movable(false)
            .row_selectable(false)
        });
        let observer = cx.observe(&monitor, |this, monitor, cx| {
            if let Some(snapshot) = monitor.read(cx).latest() {
                this.table.update(cx, |table, cx| {
                    table.delegate_mut().update(&snapshot);
                    cx.notify();
                });
            }
            cx.notify();
        });
        let search = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("Filter by name or PID")
                .clean_on_escape()
        });
        let filter = cx.subscribe(&search, |this, search, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                let query = ProcessQuery::parse(&search.read(cx).value());
                this.table.update(cx, |table, cx| {
                    table.delegate_mut().set_query(query);
                    cx.notify();
                });
            }
        });
        Self {
            monitor,
            table,
            search,
            _subscriptions: [observer, filter],
        }
    }

    pub fn focus_search(&self, window: &mut Window, cx: &mut Context<Self>) {
        self.search
            .update(cx, |search, cx| search.focus(window, cx));
    }

    fn render_cpu(&self, cpu: &CpuStats, cx: &Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let history = self.monitor.read(cx).cpu_history();
        Card::new()
            .title("Processor")
            .trailing(
                div()
                    .text_sm()
                    .text_color(theme.muted_foreground)
                    .child(format!(
                        "Load {:.2} · {:.2} · {:.2}",
                        cpu.load.one, cpu.load.five, cpu.load.fifteen
                    )),
            )
            .child(
                h_flex()
                    .flex_wrap()
                    .gap_6()
                    .items_end()
                    .child(
                        Stat::new("Total", cpu.total.percent().to_string())
                            .hint(format!("{} cores", cpu.cores.len())),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(200.))
                            .h(px(56.))
                            .child(Sparkline::new(
                                history.iter(),
                                history.capacity(),
                                theme.primary,
                            )),
                    ),
            )
            .child(
                h_flex().flex_wrap().gap_1p5().children(
                    cpu.cores
                        .iter()
                        .map(|load| core_bar(*load, theme.muted, load_color(*load))),
                ),
            )
            .into_any_element()
    }

    fn render_attention(&self, snapshot: &Snapshot, cx: &Context<Self>) -> AnyElement {
        let muted = cx.theme().muted_foreground;
        let mut noisy: Vec<(&ProcessInfo, Vec<NoiseReason>)> = snapshot
            .processes
            .iter()
            .filter_map(|p| {
                let reasons = p.noise_reasons();
                (!reasons.is_empty()).then_some((p, reasons))
            })
            .collect();
        noisy.sort_by(|(a, _), (b, _)| b.intensity().total_cmp(&a.intensity()));

        let rows: Vec<AnyElement> = snapshot
            .thread_alerts
            .iter()
            .map(|alert| thread_alert_row(alert, cx))
            .chain(noisy.iter().map(|(p, reasons)| noisy_row(p, reasons, cx)))
            .enumerate()
            .map(|(ix, row)| row.into_element(ix, &self.monitor, cx))
            .take(ATTENTION_LIMIT)
            .collect();
        let issue_count = snapshot.thread_alerts.len() + noisy.len();

        Card::new()
            .title("Needs attention")
            .trailing(
                div()
                    .text_xs()
                    .text_color(muted)
                    .child(coverage_note(snapshot.coverage)),
            )
            .map(|card| {
                if rows.is_empty() {
                    card.child(
                        h_flex()
                            .gap_2()
                            .py_2()
                            .text_sm()
                            .text_color(muted)
                            .child(
                                Icon::new(IconName::CircleCheck).text_color(Tint::Green.strong()),
                            )
                            .child("No blocked threads or processes flooding the kernel."),
                    )
                } else {
                    card.child(v_flex().gap_1().children(rows)).when(
                        issue_count > ATTENTION_LIMIT,
                        |card| {
                            card.child(
                                div()
                                    .text_xs()
                                    .text_color(muted)
                                    .child(format!("and {} more", issue_count - ATTENTION_LIMIT)),
                            )
                        },
                    )
                }
            })
            .into_any_element()
    }
}

fn core_bar(load: Ratio, track: Hsla, fill: Hsla) -> impl IntoElement {
    v_flex()
        .w(px(22.))
        .h(px(44.))
        .rounded(px(4.))
        .overflow_hidden()
        .bg(track)
        .justify_end()
        .child(div().w_full().h(relative(load.as_f32())).bg(fill))
}

fn load_color(load: Ratio) -> Hsla {
    match load.get() {
        l if l >= 0.85 => Tint::Red.strong(),
        l if l >= 0.6 => Tint::Orange.strong(),
        _ => Tint::Blue.strong(),
    }
}

fn coverage_note(coverage: ProbeCoverage) -> SharedString {
    if coverage.denied == 0 {
        "All processes inspected".into()
    } else {
        format!("{} root processes hidden (needs sudo)", coverage.denied).into()
    }
}

/// One line in the "Needs attention" card; clicking it opens the process.
struct AttentionRow {
    pid: Pid,
    process: SharedString,
    icon: Icon,
    accent: Hsla,
    detail: SharedString,
    tag: Tag,
}

impl AttentionRow {
    fn into_element(self, ix: usize, monitor: &Entity<Monitor>, cx: &App) -> AnyElement {
        let AttentionRow {
            pid,
            process,
            icon,
            accent,
            detail,
            tag,
        } = self;
        let title: SharedString = format!("{process} ({pid})").into();
        let monitor = monitor.clone();
        let hover_bg = cx.theme().muted;
        h_flex()
            .id(("attention", ix))
            .cursor_pointer()
            .on_click(move |_, window, cx| {
                ProcessDetail::open(pid, process.clone(), monitor.clone(), window, cx)
            })
            .gap_3()
            .px_2()
            .py_1p5()
            .rounded(cx.theme().radius)
            .hover(move |row| row.bg(hover_bg))
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_center()
                    .size_7()
                    .rounded_full()
                    .bg(accent.opacity(0.14))
                    .child(icon.small().text_color(accent)),
            )
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .child(div().text_sm().truncate().child(title))
                    .child(
                        div()
                            .text_xs()
                            .truncate()
                            .text_color(cx.theme().muted_foreground)
                            .child(detail),
                    ),
            )
            .child(tag.small().rounded_full())
            .into_any_element()
    }
}

fn thread_alert_row(alert: &ThreadAlert, _: &App) -> AttentionRow {
    let (icon, tint, tag) = match alert.kind {
        ThreadAlertKind::Blocked => (Lucide::Hourglass, Tint::Orange, Tag::warning()),
        ThreadAlertKind::Stopped => (Lucide::Pause, Tint::Gray, Tag::secondary()),
        ThreadAlertKind::Spinning { .. } => (Lucide::Flame, Tint::Red, Tag::danger()),
    };
    let thread = alert
        .thread_name
        .clone()
        .unwrap_or_else(|| format!("thread {}", alert.thread).into());
    let what = match alert.kind {
        ThreadAlertKind::Blocked => "in uninterruptible wait".to_string(),
        ThreadAlertKind::Stopped => "suspended".to_string(),
        ThreadAlertKind::Spinning { cpu } => format!("at {} of a core", cpu.percent()),
    };
    AttentionRow {
        pid: alert.pid,
        process: alert.process.clone(),
        icon: Icon::new(icon),
        accent: tint.strong(),
        detail: format!("{thread} {what} for {}", compact_duration(alert.duration)).into(),
        tag: tag.child(alert.kind.label()),
    }
}

fn noisy_row(process: &ProcessInfo, reasons: &[NoiseReason], _: &App) -> AttentionRow {
    let activity = process.activity.unwrap_or_default();
    let mut detail = format!(
        "{} syscalls · {} switches · {} IPC · {} wakeups",
        activity.syscalls, activity.context_switches, activity.mach_messages, activity.idle_wakeups
    );
    if let Some(network) = process.network {
        detail.push_str(&format!(" · {} packets", network.packets));
    }
    let label = reasons.first().map_or("Noisy", |reason| reason.label());
    AttentionRow {
        pid: process.pid,
        process: process.name.clone(),
        icon: Icon::new(Lucide::Zap),
        accent: Tint::Purple.strong(),
        detail: detail.into(),
        tag: Tag::info().child(label),
    }
}

impl Render for ActivityPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let header = PageHeader::new(Page::Activity.title(), Page::Activity.subtitle());
        let Some(snapshot) = self.monitor.read(cx).latest() else {
            return v_flex().size_full().p_8().child(header).into_any_element();
        };
        page_scroll("activity-page")
            .child(
                page_body()
                    .child(header)
                    .child(self.render_cpu(&snapshot.cpu, cx))
                    .child(self.render_attention(&snapshot, cx))
                    .child(
                        div().flex_1().min_h(px(380.)).flex().child(
                            Card::new()
                                .grow()
                                .title("Processes by CPU")
                                .trailing(search_field(&self.search))
                                .child(
                                    div()
                                        .flex_1()
                                        .min_h_0()
                                        .child(DataTable::new(&self.table).bordered(false).small()),
                                ),
                        ),
                    ),
            )
            .into_any_element()
    }
}
