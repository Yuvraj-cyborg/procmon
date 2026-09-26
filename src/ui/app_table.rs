use std::cmp::Ordering;

use gpui_kit::component::table::{Column, ColumnSort, TableDelegate, TableState};
use gpui_kit::component::{ActiveTheme, h_flex};
use gpui_kit::{App, Context, IntoElement, ParentElement, SharedString, Styled, Window, div, px};

use crate::system::query::ProcessQuery;
use crate::system::snapshot::{AppUsage, Snapshot, group_by_app};
use crate::theme::Tint;
use crate::ui::widgets::Meter;
use crate::units::Bytes;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AppColumn {
    Name,
    Memory,
    Share,
    Processes,
    Threads,
    Cpu,
}

impl AppColumn {
    const ALL: [AppColumn; 6] = [
        AppColumn::Name,
        AppColumn::Memory,
        AppColumn::Share,
        AppColumn::Processes,
        AppColumn::Threads,
        AppColumn::Cpu,
    ];

    fn title(self) -> &'static str {
        match self {
            AppColumn::Name => "App",
            AppColumn::Memory => "Memory",
            AppColumn::Share => "Share of RAM",
            AppColumn::Processes => "Processes",
            AppColumn::Threads => "Threads",
            AppColumn::Cpu => "CPU",
        }
    }

    fn width(self) -> f32 {
        match self {
            AppColumn::Name => 240.,
            AppColumn::Share => 160.,
            _ => 100.,
        }
    }

    fn compare(self, a: &AppUsage, b: &AppUsage) -> Ordering {
        match self {
            AppColumn::Name => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
            AppColumn::Memory | AppColumn::Share => a.memory.cmp(&b.memory),
            AppColumn::Processes => a.processes.cmp(&b.processes),
            AppColumn::Threads => a.threads.cmp(&b.threads),
            AppColumn::Cpu => a.cpu.get().total_cmp(&b.cpu.get()),
        }
    }

    fn text(self, app: &AppUsage) -> SharedString {
        match self {
            AppColumn::Name => return app.name.clone(),
            AppColumn::Memory => app.memory.binary().to_string(),
            AppColumn::Share => String::new(),
            AppColumn::Processes => app.processes.to_string(),
            AppColumn::Threads => app.threads.to_string(),
            AppColumn::Cpu => app.cpu.to_string(),
        }
        .into()
    }
}

/// [`TableDelegate`] showing memory per application instead of per process.
pub struct AppTable {
    apps: Vec<AppUsage>,
    query: ProcessQuery,
    rows: Vec<AppUsage>,
    sort: (AppColumn, ColumnSort),
    total_memory: Bytes,
}

impl AppTable {
    pub fn new() -> Self {
        Self {
            apps: Vec::new(),
            query: ProcessQuery::default(),
            rows: Vec::new(),
            sort: (AppColumn::Memory, ColumnSort::Descending),
            total_memory: Bytes::ZERO,
        }
    }

    pub fn update(&mut self, snapshot: &Snapshot) {
        self.apps = group_by_app(&snapshot.processes);
        self.total_memory = snapshot.memory.total;
        self.rebuild();
    }

    pub fn set_query(&mut self, query: ProcessQuery) {
        self.query = query;
        self.rebuild();
    }

    fn rebuild(&mut self) {
        self.rows = self
            .apps
            .iter()
            .filter(|app| self.query.matches_app(app))
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

impl TableDelegate for AppTable {
    fn columns_count(&self, _: &App) -> usize {
        AppColumn::ALL.len()
    }

    fn rows_count(&self, _: &App) -> usize {
        self.rows.len()
    }

    fn column(&self, col_ix: usize, _: &App) -> Column {
        let column = AppColumn::ALL[col_ix];
        let mut spec = Column::new(column.title(), column.title())
            .width(px(column.width()))
            .sortable();
        if column == self.sort.0 {
            spec = spec.sort(self.sort.1);
        }
        match column {
            AppColumn::Name => spec.fixed_left(),
            AppColumn::Share => spec,
            _ => spec.text_right(),
        }
    }

    fn perform_sort(
        &mut self,
        col_ix: usize,
        sort: ColumnSort,
        _: &mut Window,
        _: &mut Context<TableState<Self>>,
    ) {
        self.sort = (AppColumn::ALL[col_ix], sort);
        self.apply_sort();
    }

    fn render_td(
        &mut self,
        row_ix: usize,
        col_ix: usize,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) -> impl IntoElement {
        let column = AppColumn::ALL[col_ix];
        let Some(app) = self.rows.get(row_ix) else {
            return div().into_any_element();
        };
        match column {
            AppColumn::Share => {
                let share = app.memory.ratio_of(self.total_memory);
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
            AppColumn::Name => div().truncate().child(column.text(app)).into_any_element(),
            _ => div()
                .w_full()
                .text_right()
                .child(column.text(app))
                .into_any_element(),
        }
    }

    fn cell_text(&self, row_ix: usize, col_ix: usize, _: &App) -> String {
        self.rows
            .get(row_ix)
            .map(|app| AppColumn::ALL[col_ix].text(app).to_string())
            .unwrap_or_default()
    }
}
