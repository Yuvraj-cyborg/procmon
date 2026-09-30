mod browse;
mod largest;
mod treemap;

use std::cell::Cell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gpui_kit::component::breadcrumb::{Breadcrumb, BreadcrumbItem};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{ActiveTheme, Icon, IconName, Selectable as _, Sizable, h_flex, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, Bounds, Context, IntoElement, ParentElement, PathPromptOptions,
    Pixels, Render, SharedString, Styled, Task, Window, div, prelude::FluentBuilder as _, px,
};

use crate::app::Page;
use crate::storage::{self, Category, FileTree, NodeId, ScanError, ScanProgress, Volume};
use crate::theme::Tint;
use crate::ui::widgets::{Card, Meter, PageHeader, page_body, page_scroll};
use browse::{Browse, BrowseMode};

pub struct StoragePage {
    volumes: Vec<Volume>,
    state: ScanState,
    /// Size of the treemap area in the last frame; drives the layout aspect ratio.
    treemap_bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
}

enum ScanState {
    Idle,
    Scanning {
        root: PathBuf,
        progress: Arc<ScanProgress>,
        _scan: Task<()>,
        _ticker: Task<()>,
    },
    Ready(Browse),
    Failed {
        root: PathBuf,
        message: SharedString,
    },
}

impl StoragePage {
    pub fn new(scan: Option<PathBuf>, _: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut page = Self {
            volumes: storage::list_volumes(),
            state: ScanState::Idle,
            treemap_bounds: Rc::default(),
        };
        if let Some(root) = scan {
            page.start_scan(root, cx);
        }
        page
    }

    fn start_scan(&mut self, root: PathBuf, cx: &mut Context<Self>) {
        self.cancel_scan();
        let progress = Arc::new(ScanProgress::default());
        let scan = cx.spawn({
            let progress = progress.clone();
            let root = root.clone();
            async move |this, cx| {
                let scan_root = root.clone();
                let result = cx
                    .background_spawn(async move { storage::scan(&scan_root, &progress) })
                    .await;
                this.update(cx, |this, cx| this.finish_scan(root, result, cx))
                    .ok();
            }
        });
        let ticker = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(250))
                    .await;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        });
        self.state = ScanState::Scanning {
            root,
            progress,
            _scan: scan,
            _ticker: ticker,
        };
        cx.notify();
    }

    /// Scans the last root again, if there is one.
    pub fn rescan(&mut self, cx: &mut Context<Self>) {
        let root = match &self.state {
            ScanState::Ready(browse) => browse.tree.root_path().to_path_buf(),
            ScanState::Failed { root, .. } => root.clone(),
            ScanState::Idle | ScanState::Scanning { .. } => return,
        };
        self.start_scan(root, cx);
    }

    fn cancel_scan(&mut self) {
        if let ScanState::Scanning { progress, .. } = &self.state {
            progress.cancel();
        }
    }

    fn finish_scan(
        &mut self,
        root: PathBuf,
        result: Result<FileTree, ScanError>,
        cx: &mut Context<Self>,
    ) {
        self.state = match result {
            Ok(tree) => ScanState::Ready(Browse::new(tree)),
            Err(ScanError::Cancelled) => ScanState::Idle,
            Err(err) => ScanState::Failed {
                root,
                message: err.to_string().into(),
            },
        };
        self.volumes = storage::list_volumes();
        cx.notify();
    }

    fn choose_folder(&mut self, cx: &mut Context<Self>) {
        let picked = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Scan".into()),
        });
        cx.spawn(async move |this, cx| {
            if let Ok(Ok(Some(mut paths))) = picked.await
                && let Some(path) = paths.pop()
            {
                this.update(cx, |this, cx| this.start_scan(path, cx)).ok();
            }
        })
        .detach();
    }

    fn render_volumes(&self, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme();
        h_flex()
            .flex_wrap()
            .gap_3()
            .children(self.volumes.iter().enumerate().map(|(ix, volume)| {
                let mount = volume.mount_point.clone();
                let used = volume.used().ratio_of(volume.total);
                let color = match used.get() {
                    u if u >= 0.9 => Tint::Red.strong(),
                    u if u >= 0.75 => Tint::Orange.strong(),
                    _ => theme.primary,
                };
                div().flex_1().min_w(px(240.)).max_w(px(420.)).child(
                    Card::new()
                        .child(
                            h_flex()
                                .gap_2()
                                .child(
                                    if volume.removable {
                                        Icon::new(gpui_kit::assets::IconName::Usb)
                                    } else {
                                        Icon::new(IconName::HardDrive)
                                    }
                                    .text_color(theme.muted_foreground),
                                )
                                .child(
                                    v_flex()
                                        .flex_1()
                                        .min_w_0()
                                        .child(
                                            div().text_sm().truncate().child(volume.name.clone()),
                                        )
                                        .child(
                                            div()
                                                .text_xs()
                                                .truncate()
                                                .text_color(theme.muted_foreground)
                                                .child(format!(
                                                    "{} · {}",
                                                    volume.mount_point.display(),
                                                    volume.file_system
                                                )),
                                        ),
                                )
                                .child(
                                    Button::new(("scan-volume", ix))
                                        .label("Scan")
                                        .small()
                                        .ghost()
                                        .on_click(cx.listener(move |this, _, _, cx| {
                                            this.start_scan(mount.clone(), cx)
                                        })),
                                ),
                        )
                        .child(Meter::single(used, color).height(px(6.)))
                        .child(
                            div()
                                .text_xs()
                                .text_color(theme.muted_foreground)
                                .child(format!(
                                    "{} used of {} · {} free",
                                    volume.used().decimal(),
                                    volume.total.decimal(),
                                    volume.available.decimal()
                                )),
                        ),
                )
            }))
            .into_any_element()
    }

    fn render_scan_area(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let muted = cx.theme().muted_foreground;
        match &self.state {
            ScanState::Idle => empty_state(
                "Pick a volume or folder",
                "Procmon measures every file and draws the result as boxes you can click into.",
                cx,
            ),
            ScanState::Failed { root, message } => empty_state(
                format!("Couldn't scan {}", root.display()),
                message.clone(),
                cx,
            ),
            ScanState::Scanning { root, progress, .. } => v_flex()
                .flex_1()
                .items_center()
                .justify_center()
                .gap_3()
                .child(Spinner::new().large().color(cx.theme().primary))
                .child(
                    div()
                        .text_sm()
                        .child(format!("Scanning {}", root.display())),
                )
                .child(div().text_xs().text_color(muted).child(format!(
                    "{} files · {}",
                    progress.files(),
                    progress.bytes().decimal()
                )))
                .child(
                    Button::new("cancel-scan")
                        .label("Cancel")
                        .small()
                        .outline()
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.cancel_scan();
                            this.state = ScanState::Idle;
                            cx.notify();
                        })),
                )
                .into_any_element(),
            ScanState::Ready(_) => self.render_browser(cx),
        }
    }

    fn render_browser(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let ScanState::Ready(browse) = &self.state else {
            unreachable!("render_browser called without a finished scan");
        };
        let muted = cx.theme().muted_foreground;
        let tree = browse.tree.clone();
        let unreadable = tree.unreadable;
        let header = self.render_browser_header(browse, cx);
        let body = match browse.mode {
            BrowseMode::Map => div()
                .flex_1()
                .min_h(px(280.))
                .child(self.render_treemap(&tree, browse.current, browse.selected, cx))
                .into_any_element(),
            BrowseMode::LargestFiles => self.render_largest(browse, cx),
        };
        let footer = self.render_browser_footer(browse, cx);
        v_flex()
            .flex_1()
            .min_h_0()
            .gap_3()
            .child(header)
            .child(body)
            .child(footer)
            .when(unreadable > 0, |col| {
                col.child(div().text_xs().text_color(muted).child(format!(
                    "{unreadable} folders were skipped because Procmon is not allowed to read them."
                )))
            })
            .into_any_element()
    }

    fn render_browser_header(&self, browse: &Browse, cx: &mut Context<Self>) -> AnyElement {
        let tree = &browse.tree;
        let current = browse.current;
        let crumbs = tree.lineage(current).into_iter().map(|id| {
            let label: SharedString = if id == NodeId::ROOT {
                tree.root_path()
                    .file_name()
                    .map_or_else(
                        || tree.root_path().display().to_string(),
                        |n| n.to_string_lossy().into_owned(),
                    )
                    .into()
            } else {
                tree.node(id).name.to_string().into()
            };
            BreadcrumbItem::new(label)
                .on_click(cx.listener(move |this, _, _, cx| this.focus_node(id, cx)))
        });
        let parent = tree.node(current).parent;
        let root = tree.root_path().to_path_buf();
        let mode = browse.mode;
        let mode_button = |id: &'static str, label: &'static str, target: BrowseMode| {
            Button::new(id)
                .label(label)
                .small()
                .ghost()
                .selected(mode == target)
                .on_click(cx.listener(move |this, _, _, cx| this.set_mode(target, cx)))
        };
        h_flex()
            .justify_between()
            .gap_2()
            .flex_wrap()
            .child(
                div()
                    .min_w_0()
                    .overflow_hidden()
                    .child(Breadcrumb::new().children(crumbs)),
            )
            .child(
                h_flex()
                    .gap_1()
                    .child(mode_button("mode-map", "Map", BrowseMode::Map))
                    .child(mode_button(
                        "mode-largest",
                        "Largest files",
                        BrowseMode::LargestFiles,
                    ))
                    .when_some(parent, |row, parent| {
                        row.child(
                            Button::new("up")
                                .icon(IconName::ArrowUp)
                                .small()
                                .ghost()
                                .tooltip("Up one level")
                                .on_click(
                                    cx.listener(move |this, _, _, cx| this.focus_node(parent, cx)),
                                ),
                        )
                    })
                    .child(
                        Button::new("rescan")
                            .icon(Icon::new(gpui_kit::assets::IconName::RefreshCw))
                            .small()
                            .ghost()
                            .tooltip("Scan again")
                            .on_click(
                                cx.listener(move |this, _, _, cx| {
                                    this.start_scan(root.clone(), cx)
                                }),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// Status line for the hovered item plus actions for the selection
    /// (or the open folder when nothing is selected).
    fn render_browser_footer(&self, browse: &Browse, cx: &mut Context<Self>) -> AnyElement {
        let tree = &browse.tree;
        let focus = tree.node(browse.hovered.unwrap_or(browse.target()));
        let status = format!(
            "{} · {} · {} files",
            focus.name,
            focus.size.decimal(),
            focus.files
        );
        let target = browse.target();
        let target_path = tree.path_of(target);
        let can_trash = target != NodeId::ROOT && target_path.is_some();
        h_flex()
            .justify_between()
            .gap_3()
            .flex_wrap()
            .child(
                div()
                    .flex_1()
                    .min_w(px(160.))
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .truncate()
                    .child(status),
            )
            .when(browse.mode == BrowseMode::Map, |row| row.child(legend(cx)))
            .child(
                h_flex()
                    .gap_1()
                    .when_some(target_path, |row, path| {
                        row.child(
                            Button::new("reveal")
                                .label("Show in Folder")
                                .small()
                                .ghost()
                                .on_click(move |_, _, cx| cx.reveal_path(&path)),
                        )
                    })
                    .when(can_trash, |row| {
                        row.child(
                            Button::new("trash")
                                .label("Move to Trash…")
                                .small()
                                .ghost()
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.confirm_trash(target, window, cx)
                                })),
                        )
                    }),
            )
            .into_any_element()
    }
}

fn empty_state(
    title: impl Into<SharedString>,
    detail: impl Into<SharedString>,
    cx: &Context<StoragePage>,
) -> AnyElement {
    v_flex()
        .flex_1()
        .items_center()
        .justify_center()
        .gap_2()
        .py_12()
        .child(
            Icon::new(gpui_kit::assets::IconName::ScanSearch)
                .large()
                .text_color(cx.theme().muted_foreground),
        )
        .child(div().text_sm().child(title.into()))
        .child(
            div()
                .max_w(px(360.))
                .text_center()
                .text_xs()
                .text_color(cx.theme().muted_foreground)
                .child(detail.into()),
        )
        .into_any_element()
}

pub(super) fn category_tint(category: Category) -> Tint {
    match category {
        Category::Folder => Tint::Blue,
        Category::Application => Tint::Purple,
        Category::Image => Tint::Pink,
        Category::Video => Tint::Red,
        Category::Audio => Tint::Yellow,
        Category::Archive => Tint::Orange,
        Category::Document => Tint::Green,
        Category::Code => Tint::Brown,
        Category::Remainder | Category::Other => Tint::Gray,
    }
}

fn legend(cx: &Context<StoragePage>) -> impl IntoElement {
    let muted = cx.theme().muted_foreground;
    h_flex()
        .gap_3()
        .flex_wrap()
        .children(Category::LEGEND.map(|category| {
            h_flex()
                .gap_1()
                .text_xs()
                .text_color(muted)
                .child(
                    div()
                        .size_2()
                        .rounded_full()
                        .bg(category_tint(category).strong()),
                )
                .child(category.label())
        }))
}

impl Render for StoragePage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let header = PageHeader::new(Page::Storage.title(), Page::Storage.subtitle())
            .action(
                Button::new("scan-home")
                    .label("Scan Home")
                    .icon(IconName::User)
                    .small()
                    .outline()
                    .on_click(cx.listener(|this, _, _, cx| {
                        if let Some(home) = std::env::var_os("HOME") {
                            this.start_scan(PathBuf::from(home), cx);
                        }
                    })),
            )
            .action(
                Button::new("choose-folder")
                    .label("Choose folder…")
                    .icon(IconName::FolderOpen)
                    .small()
                    .primary()
                    .on_click(cx.listener(|this, _, _, cx| this.choose_folder(cx))),
            );
        let volumes = self.render_volumes(cx);
        let scan_area = self.render_scan_area(cx);
        page_scroll("storage-page").child(
            page_body().child(header).child(volumes).child(
                div()
                    .flex_1()
                    .min_h(px(420.))
                    .flex()
                    .child(Card::new().grow().child(scan_area)),
            ),
        )
    }
}
