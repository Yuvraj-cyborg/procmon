use gpui_kit::component::switch::Switch;
use gpui_kit::component::table::{DataTable, TableState};
use gpui_kit::component::tag::Tag;
use gpui_kit::component::{ActiveTheme, Sizable, h_flex, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, Context, Entity, IntoElement, ParentElement, Render, Styled,
    Subscription, Window, div, px,
};

use crate::app::Page;
use crate::settings::Settings;
use crate::system::Monitor;
use crate::system::snapshot::{MemoryPressure, MemoryStats};
use crate::theme::Tint;
use crate::ui::app_table::AppTable;
use crate::ui::process_table::{ProcessColumn, ProcessTable};
use crate::ui::widgets::{
    Card, Meter, PageHeader, Segment, Sparkline, Stat, page_body, page_scroll,
};

pub struct MemoryPage {
    monitor: Entity<Monitor>,
    table: Entity<TableState<ProcessTable>>,
    app_table: Entity<TableState<AppTable>>,
    group_by_app: bool,
    _observer: Subscription,
}

impl MemoryPage {
    pub fn new(monitor: Entity<Monitor>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let columns = vec![
            ProcessColumn::Name,
            ProcessColumn::Memory,
            ProcessColumn::MemoryShare,
            ProcessColumn::Threads,
            ProcessColumn::Cpu,
            ProcessColumn::Pid,
            ProcessColumn::Uptime,
        ];
        let table = cx.new(|cx| {
            TableState::new(
                ProcessTable::new(columns, ProcessColumn::Memory),
                window,
                cx,
            )
            .col_movable(false)
        });
        let app_table =
            cx.new(|cx| TableState::new(AppTable::new(), window, cx).col_movable(false));
        let observer = cx.observe(&monitor, |this, monitor, cx| {
            if let Some(snapshot) = monitor.read(cx).latest() {
                // Only the visible table needs fresh rows.
                if this.group_by_app {
                    this.app_table.update(cx, |table, cx| {
                        table.delegate_mut().update(&snapshot);
                        cx.notify();
                    });
                } else {
                    this.table.update(cx, |table, cx| {
                        table.delegate_mut().update(&snapshot);
                        cx.notify();
                    });
                }
            }
            cx.notify();
        });
        Self {
            monitor,
            table,
            app_table,
            group_by_app: Settings::get(cx).group_by_app,
            _observer: observer,
        }
    }

    fn pressure_tag(pressure: MemoryPressure) -> Tag {
        let tag = match pressure {
            MemoryPressure::Normal => Tag::success(),
            MemoryPressure::Warning => Tag::warning(),
            MemoryPressure::Critical => Tag::danger(),
            MemoryPressure::Unknown => Tag::secondary(),
        };
        tag.outline()
            .rounded_full()
            .small()
            .child(format!("Pressure · {}", pressure.label()))
    }

    fn render_overview(&self, memory: &MemoryStats, cx: &Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let total = memory.total;
        let mut segments = Vec::new();
        let mut stats = Vec::new();
        if let Some(b) = memory.breakdown {
            for (label, bytes, tint) in [
                ("App", b.app, Tint::Blue),
                ("Wired", b.wired, Tint::Orange),
                ("Compressed", b.compressed, Tint::Purple),
                ("Cached files", b.cached, Tint::Green),
            ] {
                segments.push(Segment {
                    ratio: bytes.ratio_of(total),
                    color: tint.strong(),
                });
                stats.push(Stat::new(label, bytes.binary().to_string()).dot(tint.strong()));
            }
        } else {
            segments.push(Segment {
                ratio: memory.used.ratio_of(total),
                color: Tint::Blue.strong(),
            });
            stats
                .push(Stat::new("Used", memory.used.binary().to_string()).dot(Tint::Blue.strong()));
        }
        stats.push(Stat::new(
            "Available",
            memory.available.binary().to_string(),
        ));
        stats.push(
            Stat::new("Swap", memory.swap_used.binary().to_string())
                .hint(format!("of {}", memory.swap_total.binary())),
        );

        let history = self.monitor.read(cx).memory_history();
        Card::new()
            .title("Physical memory")
            .trailing(
                div()
                    .text_sm()
                    .text_color(theme.muted_foreground)
                    .child(format!(
                        "{} of {} used · {}",
                        memory.used.binary(),
                        total.binary(),
                        memory.used.ratio_of(total).percent(),
                    )),
            )
            .child(Meter::new(segments).height(px(10.)))
            .child(h_flex().flex_wrap().gap_x_8().gap_y_3().children(stats))
            .child(
                v_flex()
                    .gap_1()
                    .child(
                        div()
                            .text_xs()
                            .text_color(theme.muted_foreground)
                            .child("Used, last two minutes"),
                    )
                    .child(div().h(px(48.)).w_full().child(Sparkline::new(
                        history.iter(),
                        history.capacity(),
                        theme.primary,
                    ))),
            )
            .into_any_element()
    }
}

impl Render for MemoryPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let snapshot = self.monitor.read(cx).latest();
        let header = PageHeader::new(Page::Memory.title(), Page::Memory.subtitle());
        let Some(snapshot) = snapshot else {
            return v_flex().size_full().p_8().child(header).into_any_element();
        };
        let memory = snapshot.memory;
        let process_count = snapshot.processes.len();
        page_scroll("memory-page")
            .child(
                page_body()
                    .child(header.action(Self::pressure_tag(memory.pressure)))
                    .child(self.render_overview(&memory, cx))
                    .child(
                        div()
                            .flex_1()
                            .min_h(px(380.))
                            .flex()
                            .child(self.render_consumers(process_count, cx)),
                    ),
            )
            .into_any_element()
    }
}

impl MemoryPage {
    fn render_consumers(&self, process_count: usize, cx: &mut Context<Self>) -> AnyElement {
        let table = if self.group_by_app {
            DataTable::new(&self.app_table)
                .bordered(false)
                .small()
                .into_any_element()
        } else {
            DataTable::new(&self.table)
                .bordered(false)
                .small()
                .into_any_element()
        };
        Card::new()
            .grow()
            .title("Who is using memory")
            .trailing(
                h_flex()
                    .gap_4()
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child(format!("{process_count} processes"))
                    .child(
                        Switch::new("group-by-app")
                            .label("Group by app")
                            .checked(self.group_by_app)
                            .small()
                            .on_click(cx.listener(|this, checked: &bool, _, cx| {
                                this.set_group_by_app(*checked, cx)
                            })),
                    ),
            )
            .child(div().flex_1().min_h_0().child(table))
            .into_any_element()
    }

    fn set_group_by_app(&mut self, group: bool, cx: &mut Context<Self>) {
        self.group_by_app = group;
        Settings::update(cx, |settings| settings.group_by_app = group);
        if let Some(snapshot) = self.monitor.read(cx).latest() {
            self.app_table
                .update(cx, |table, _| table.delegate_mut().update(&snapshot));
            self.table
                .update(cx, |table, _| table.delegate_mut().update(&snapshot));
        }
        cx.notify();
    }
}
