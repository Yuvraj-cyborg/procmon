//! Recovery: deleted photos, videos and documents brought back from memory
//! cards, USB sticks, drives and disk images.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use gpui_kit::assets::IconName as Lucide;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::dialog::DialogButtonProps;
use gpui_kit::component::notification::Notification;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::switch::Switch;
use gpui_kit::component::tag::Tag;
use gpui_kit::component::{
    ActiveTheme, Icon, IconName, Selectable as _, Sizable, WindowExt, h_flex, v_flex,
};
use gpui_kit::{
    AnyElement, App, AppContext as _, ClickEvent, Context, ImageSource, InteractiveElement,
    IntoElement, ObjectFit, ParentElement, PathPromptOptions, Render, RenderImage, SharedString,
    StatefulInteractiveElement, Styled, StyledImage as _, Task, Window, div, img,
    prelude::FluentBuilder as _, px,
};

use crate::app::Page;
use crate::recovery::{
    self, AccessError, ByteSource, Condition, Disk, DiskKind, ExportProgress, FoundFile, Kind,
    Origin, RawDevice, RecoveryScan, Stage,
};
use crate::theme::Tint;
use crate::ui::widgets::{Card, Meter, PageHeader, page_body, page_scroll};
use crate::units::Bytes;

/// Tiles shown before "Show more"; each holds a decoded thumbnail.
const PAGE_SIZE: usize = 240;
const THUMBNAIL: u32 = 200;

pub struct RecoveryPage {
    disks: Vec<Disk>,
    state: State,
    /// Shown above the disk list, e.g. why a disk couldn't be opened.
    notice: Option<SharedString>,
}

enum State {
    Choosing,
    Opening { name: SharedString, _task: Task<()> },
    Session(Box<Session>),
}

struct Session {
    name: SharedString,
    /// The disk being read, so recovered files never land on it.
    disk: Option<String>,
    scan: Arc<RecoveryScan>,
    files: Vec<FoundFile>,
    started: Instant,
    /// How long the scan ran, once it has stopped.
    took: Option<Duration>,
    running: bool,
    failure: Option<SharedString>,
    filter: Option<Kind>,
    hide_small: bool,
    shown: usize,
    selected: HashSet<usize>,
    thumbnails: HashMap<usize, Option<Arc<RenderImage>>>,
    queue: VecDeque<usize>,
    decoding: bool,
    export: Option<Arc<ExportProgress>>,
    _scan: Task<()>,
    _ticker: Task<()>,
}

impl Session {
    fn visible(&self) -> Vec<&FoundFile> {
        self.files
            .iter()
            .filter(|f| self.filter.is_none_or(|kind| f.kind == kind))
            .filter(|f| !self.hide_small || !is_tiny(f))
            .collect()
    }

    fn selected_files(&self) -> Vec<FoundFile> {
        self.files
            .iter()
            .filter(|f| self.selected.contains(&f.id))
            .cloned()
            .collect()
    }
}

/// Small files found by content are mostly icons and thumbnail caches; ones
/// a folder still names were put there by someone, so they always show.
fn is_tiny(file: &FoundFile) -> bool {
    file.origin == Origin::Contents && file.size().0 < 16 * 1024
}

impl RecoveryPage {
    /// `recover` names a disk or disk image to start searching right away.
    pub fn new(recover: Option<PathBuf>, _: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut page = Self {
            disks: recovery::list(),
            state: State::Choosing,
            notice: None,
        };
        if let Some(path) = recover {
            match page.disks.iter().find(|disk| disk.path == path).cloned() {
                Some(disk) => page.open_disk(disk, cx),
                None => page.open_path(path, cx),
            }
        }
        page
    }

    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        if matches!(self.state, State::Choosing) {
            self.disks = recovery::list();
            cx.notify();
        }
    }

    fn session(&mut self) -> Option<&mut Session> {
        match &mut self.state {
            State::Session(session) => Some(session),
            _ => None,
        }
    }

    fn open_disk(&mut self, disk: Disk, cx: &mut Context<Self>) {
        self.notice = None;
        let name: SharedString = disk.name.clone().into();
        let task = cx.spawn({
            let name = name.clone();
            async move |this, cx| {
                let target = disk.clone();
                let opened = cx.background_spawn(async move { recovery::open(&target) }).await;
                this.update(cx, |this, cx| match opened {
                    Ok(device) => this.start(name, Some(disk.id.clone()), Arc::new(device), cx),
                    Err(err) => {
                        this.state = State::Choosing;
                        this.notice = Some(match err {
                            AccessError::Cancelled => "Procmon needs an administrator's password to read the disk directly. Nothing was changed.".into(),
                            other => other.to_string().into(),
                        });
                        cx.notify();
                    }
                })
                .ok();
            }
        });
        self.state = State::Opening { name, _task: task };
        cx.notify();
    }

    fn open_image(&mut self, cx: &mut Context<Self>) {
        let picked = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Scan".into()),
        });
        cx.spawn(async move |this, cx| {
            let Ok(Ok(Some(mut paths))) = picked.await else {
                return;
            };
            let Some(path) = paths.pop() else { return };
            this.update(cx, |this, cx| this.open_path(path, cx)).ok();
        })
        .detach();
    }

    /// Opens a disk image, or a disk this user may already read.
    fn open_path(&mut self, path: PathBuf, cx: &mut Context<Self>) {
        let name: SharedString = path
            .file_name()
            .map_or_else(
                || path.display().to_string(),
                |n| n.to_string_lossy().into_owned(),
            )
            .into();
        cx.spawn(async move |this, cx| {
            let opened = cx
                .background_spawn(async move { RawDevice::open(&path) })
                .await;
            this.update(cx, |this, cx| match opened {
                Ok(device) => this.start(name, None, Arc::new(device), cx),
                Err(err) => {
                    this.notice = Some(format!("Couldn't open {name}: {err}").into());
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
    }

    fn start(
        &mut self,
        name: SharedString,
        disk: Option<String>,
        source: Arc<dyn ByteSource>,
        cx: &mut Context<Self>,
    ) {
        let scan = Arc::new(RecoveryScan::new(source));
        let task = cx.spawn({
            let scan = scan.clone();
            async move |this, cx| {
                let runner = scan.clone();
                let result = cx.background_spawn(async move { runner.run() }).await;
                this.update(cx, |this, cx| {
                    this.collect(cx);
                    if let Some(session) = this.session() {
                        session.running = false;
                        session.took = Some(session.started.elapsed());
                        session.failure = result.err().map(|err| err.to_string().into());
                    }
                    cx.notify();
                })
                .ok();
            }
        });
        let ticker = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(400))
                    .await;
                if this.update(cx, |this, cx| this.collect(cx)).is_err() {
                    break;
                }
            }
        });
        self.state = State::Session(Box::new(Session {
            name,
            disk,
            scan,
            files: Vec::new(),
            started: Instant::now(),
            took: None,
            running: true,
            failure: None,
            filter: None,
            hide_small: true,
            shown: PAGE_SIZE,
            selected: HashSet::new(),
            thumbnails: HashMap::new(),
            queue: VecDeque::new(),
            decoding: false,
            export: None,
            _scan: task,
            _ticker: ticker,
        }));
        cx.notify();
    }

    /// Takes files the scan found since the last look.
    fn collect(&mut self, cx: &mut Context<Self>) {
        if let Some(session) = self.session() {
            session.files.extend(session.scan.collect());
            cx.notify();
        }
    }

    fn stop(&mut self, cx: &mut Context<Self>) {
        if let Some(session) = self.session() {
            session.scan.progress().cancel();
        }
        cx.notify();
    }

    fn leave(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let State::Session(session) = &self.state {
            session.scan.progress().cancel();
            // Thumbnails live in the GPU's texture atlas until dropped.
            for image in session.thumbnails.values().flatten() {
                window.drop_image(image.clone()).ok();
            }
        }
        self.state = State::Choosing;
        self.disks = recovery::list();
        cx.notify();
    }

    /// Decodes queued thumbnails a few at a time on a worker thread.
    fn pump_thumbnails(&mut self, cx: &mut Context<Self>) {
        let Some(session) = self.session() else {
            return;
        };
        if session.decoding || session.queue.is_empty() {
            return;
        }
        let ids: Vec<usize> = (0..6).filter_map(|_| session.queue.pop_front()).collect();
        let batch: Vec<FoundFile> = session
            .files
            .iter()
            .filter(|f| ids.contains(&f.id))
            .cloned()
            .collect();
        let source = session.scan.source().clone();
        session.decoding = true;
        cx.spawn(async move |this, cx| {
            let decoded = cx
                .background_spawn(async move {
                    batch
                        .into_iter()
                        .map(|file| {
                            let preview = recovery::thumbnail(&file, source.as_ref(), THUMBNAIL);
                            let facts = preview.as_ref().map(|p| (p.pixels, p.date));
                            let image = preview.map(|p| {
                                Arc::new(RenderImage::new(vec![image::Frame::new(p.image)]))
                            });
                            (file.id, image, facts)
                        })
                        .collect::<Vec<_>>()
                })
                .await;
            this.update(cx, |this, cx| {
                if let Some(session) = this.session() {
                    for (id, image, facts) in decoded {
                        if let (Some((pixels, date)), Some(file)) =
                            (facts, session.files.iter_mut().find(|f| f.id == id))
                        {
                            file.details.pixels = file.details.pixels.or(pixels);
                            file.date = file.date.or(date);
                        }
                        session.thumbnails.insert(id, image);
                    }
                    session.decoding = false;
                }
                this.pump_thumbnails(cx);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn recover(&mut self, files: Vec<FoundFile>, window: &mut Window, cx: &mut Context<Self>) {
        if files.is_empty() {
            return;
        }
        let picked = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Recover Here".into()),
        });
        cx.spawn_in(window, async move |this, cx| {
            let Ok(Ok(Some(mut paths))) = picked.await else {
                return;
            };
            let Some(folder) = paths.pop() else { return };
            this.update_in(cx, |this, window, cx| {
                this.export_to(files, folder, window, cx)
            })
            .ok();
        })
        .detach();
    }

    fn export_to(
        &mut self,
        files: Vec<FoundFile>,
        folder: PathBuf,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(session) = self.session() else {
            return;
        };
        // Writing to the disk being recovered would overwrite the very files
        // still waiting to be saved.
        if session.disk.is_some() && recovery::holding(&folder) == session.disk {
            window.open_alert_dialog(cx, |dialog, _, _| {
                dialog
                    .title("Choose a folder on another disk")
                    .description("Saving onto the disk you are recovering from can overwrite the files you are trying to get back.")
                    .button_props(DialogButtonProps::default().ok_text("OK"))
            });
            return;
        }
        let progress = Arc::new(ExportProgress::default());
        session.export = Some(progress.clone());
        let source = session.scan.source().clone();
        let name = session.name.to_string();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    recovery::export(&files, source.as_ref(), &name, &folder, &progress)
                })
                .await;
            this.update_in(cx, |this, window, cx| {
                if let Some(session) = this.session() {
                    session.export = None;
                }
                let note = match result {
                    Ok(report) => {
                        cx.reveal_path(&report.folder);
                        let mut text = format!(
                            "Recovered {} ({}) to {}.",
                            count(report.saved, "file"),
                            report.bytes.decimal(),
                            report.folder.display()
                        );
                        if report.unreadable.0 > 0 {
                            text.push_str(&format!(
                                " {} couldn't be read and were saved as blanks.",
                                report.unreadable.decimal()
                            ));
                        }
                        if report.failures.is_empty() {
                            Notification::success(text)
                        } else {
                            Notification::warning(format!(
                                "{text} {} failed: {}",
                                count(report.failures.len(), "file"),
                                report.failures.join("; ")
                            ))
                        }
                    }
                    Err(err) => Notification::error(format!("Couldn't recover: {err}")),
                };
                window.push_notification(note, cx);
                cx.notify();
            })
            .ok();
        })
        .detach();
        cx.notify();
    }

    fn preview(&mut self, id: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(session) = self.session() else {
            return;
        };
        let Some(file) = session.files.iter().find(|f| f.id == id).cloned() else {
            return;
        };
        let source = session.scan.source().clone();
        let page = cx.entity().downgrade();
        let view = cx.new(|cx| FoundPreview::new(file.clone(), source, page, cx));
        window.open_sheet(cx, move |sheet, _, _| {
            sheet
                .title(file.display_name())
                .size(px(480.))
                .child(view.clone())
        });
    }

    fn render_choosing(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let muted = cx.theme().muted_foreground;
        let groups = [
            (
                DiskKind::External,
                "Memory cards and drives",
                "Where recovery works best. Plug in the card or drive the files were on.",
            ),
            (DiskKind::Image, "Disk images", "Images attached as disks."),
            (
                DiskKind::Internal,
                "This computer",
                "Deleted files on an internal SSD rarely come back: the drive erases freed space soon after. Hard disks often still have them.",
            ),
        ];
        let elevated = recovery::is_elevated();
        v_flex()
            .gap_4()
            .child(
                div()
                    .text_sm()
                    .text_color(muted)
                    .child("Procmon reads the disk without changing anything on it, finds deleted photos, videos and documents, and copies the ones you choose to another disk."),
            )
            .when(!elevated, |col| {
                col.child(
                    Card::new().child(
                        h_flex()
                            .gap_3()
                            .flex_wrap()
                            .child(Icon::new(IconName::TriangleAlert).text_color(Tint::Orange.strong()))
                            .child(div().flex_1().min_w(px(240.)).text_sm().child("Windows only lets administrators read disks directly. Disk images work without it."))
                            .child(
                                Button::new("elevate")
                                    .label("Restart as Administrator")
                                    .small()
                                    .primary()
                                    .on_click(|_, _, cx| {
                                        if recovery::relaunch_elevated() {
                                            cx.quit();
                                        }
                                    }),
                            ),
                    ),
                )
            })
            .children(self.notice.clone().map(|notice| {
                h_flex()
                    .gap_2()
                    .text_sm()
                    .child(Icon::new(IconName::Info).text_color(Tint::Orange.strong()))
                    .child(notice)
            }))
            .children(groups.into_iter().filter_map(|(kind, title, detail)| {
                let disks: Vec<Disk> = self.disks.iter().filter(|d| d.kind == kind).cloned().collect();
                (!disks.is_empty() || kind == DiskKind::External).then(|| {
                    Card::new()
                        .title(title)
                        .child(div().text_xs().text_color(muted).child(detail))
                        .when(disks.is_empty(), |card| {
                            card.child(div().text_sm().text_color(muted).child("Nothing plugged in. Insert a card or drive, then press Refresh."))
                        })
                        .children(disks.into_iter().map(|disk| self.disk_row(disk, cx)))
                        .into_any_element()
                })
            }))
            .into_any_element()
    }

    fn disk_row(&self, disk: Disk, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let icon = match disk.kind {
            DiskKind::External => Icon::new(Lucide::Usb),
            DiskKind::Image => Icon::new(Lucide::FileArchive),
            DiskKind::Internal => Icon::new(IconName::HardDrive),
        };
        let internal = disk.kind == DiskKind::Internal;
        let id: SharedString = disk.id.clone().into();
        h_flex()
            .gap_3()
            .py_1p5()
            .child(icon.text_color(theme.muted_foreground))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .child(div().text_sm().truncate().child(disk.name.clone()))
                    .child(
                        div()
                            .text_xs()
                            .truncate()
                            .text_color(theme.muted_foreground)
                            .child(disk.summary()),
                    ),
            )
            .child(
                Button::new(id)
                    .label("Scan")
                    .small()
                    .map(|b| if internal { b.ghost() } else { b.primary() })
                    .on_click(cx.listener(move |this, _, _, cx| this.open_disk(disk.clone(), cx))),
            )
            .into_any_element()
    }

    fn render_session(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme().clone();
        let Some(session) = self.session() else {
            return div().into_any_element();
        };
        let progress = session.scan.progress();
        let (scanned, total) = (progress.scanned(), progress.total());
        let fraction = scanned.ratio_of(total);
        let elapsed = session
            .took
            .unwrap_or_else(|| session.started.elapsed())
            .as_secs_f64();
        let status: String = match (session.running, progress.stage()) {
            (true, Stage::Opening | Stage::Directories) => {
                "Reading folders for deleted files…".into()
            }
            (true, _) => {
                let speed = if elapsed > 2.0 {
                    scanned.0 as f64 / elapsed
                } else {
                    0.0
                };
                let left = if speed > 0.0 {
                    format!(
                        " · about {} left",
                        eta((total.0 - scanned.0.min(total.0)) as f64 / speed)
                    )
                } else {
                    String::new()
                };
                format!(
                    "Searching {} of {} · {}/s{left}",
                    scanned.decimal(),
                    total.decimal(),
                    Bytes(speed as u64).decimal()
                )
            }
            (false, Stage::Finished) => format!("Finished in {}", eta(elapsed)),
            (false, _) => "Stopped".into(),
        };
        let unreadable = progress.unreadable();
        let failure = session.failure.clone();
        let file_systems = session.scan.file_systems();
        let total_found = session.files.len();
        let counts: Vec<(Kind, usize)> = Kind::ALL
            .into_iter()
            .map(|kind| {
                (
                    kind,
                    session.files.iter().filter(|f| f.kind == kind).count(),
                )
            })
            .filter(|(_, n)| *n > 0)
            .collect();
        let (filter, hide_small, running) = (session.filter, session.hide_small, session.running);
        let visible_count;
        let tiles: Vec<FoundFile>;
        let more;
        {
            let visible = session.visible();
            visible_count = visible.len();
            more = visible.len().saturating_sub(session.shown);
            tiles = visible.into_iter().take(session.shown).cloned().collect();
        }
        for file in &tiles {
            if recovery::has_preview(file.format)
                && !session.thumbnails.contains_key(&file.id)
                && !session.queue.contains(&file.id)
            {
                session.queue.push_back(file.id);
            }
        }
        let selected = session.selected.clone();
        let thumbnails = session.thumbnails.clone();
        let export = session.export.clone();
        let chosen = session.selected_files();
        self.pump_thumbnails(cx);

        let filter_button = |id: &'static str, label: String, kind: Option<Kind>| {
            Button::new(id)
                .label(label)
                .small()
                .ghost()
                .selected(filter == kind)
                .on_click(cx.listener(move |this, _, _, cx| {
                    if let Some(session) = this.session() {
                        session.filter = kind;
                        session.shown = PAGE_SIZE;
                    }
                    cx.notify();
                }))
        };
        let mut filters = vec![filter_button("all", format!("All {total_found}"), None)];
        for (kind, count) in &counts {
            let id = match kind {
                Kind::Photo => "photos",
                Kind::Video => "videos",
                Kind::Audio => "audio",
                Kind::Document => "documents",
                Kind::Other => "other",
            };
            filters.push(filter_button(
                id,
                format!("{} {count}", kind.label()),
                Some(*kind),
            ));
        }

        v_flex()
            .gap_4()
            .child(
                Card::new()
                    .child(
                        h_flex()
                            .gap_3()
                            .flex_wrap()
                            .child(div().flex_1().min_w(px(240.)).text_sm().child(status))
                            .when(running, |row| {
                                row.child(
                                    Button::new("stop-scan")
                                        .label("Stop")
                                        .small()
                                        .outline()
                                        .on_click(cx.listener(|this, _, _, cx| this.stop(cx))),
                                )
                            }),
                    )
                    .when(running, |card| {
                        card.child(Meter::single(fraction, theme.primary).height(px(6.)))
                    })
                    .child(
                        div().text_xs().text_color(theme.muted_foreground).child(
                            [
                                (!file_systems.is_empty()).then(|| {
                                    format!("Read the {} folders", file_systems.join(" and "))
                                }),
                                (unreadable.0 > 0).then(|| {
                                    format!(
                                        "{} couldn't be read — the disk may be failing",
                                        unreadable.decimal()
                                    )
                                }),
                            ]
                            .into_iter()
                            .flatten()
                            .collect::<Vec<_>>()
                            .join(" · "),
                        ),
                    )
                    .children(failure.map(|message| {
                        div()
                            .text_sm()
                            .text_color(Tint::Red.strong())
                            .child(message)
                    })),
            )
            .child(
                h_flex()
                    .gap_1()
                    .flex_wrap()
                    .children(filters)
                    .child(div().flex_1())
                    .child(
                        Switch::new("hide-small")
                            .label("Hide small files")
                            .checked(hide_small)
                            .small()
                            .on_click(cx.listener(|this, checked: &bool, _, cx| {
                                if let Some(session) = this.session() {
                                    session.hide_small = *checked;
                                }
                                cx.notify();
                            })),
                    ),
            )
            .map(|col| {
                if tiles.is_empty() {
                    col.child(
                        v_flex()
                            .items_center()
                            .gap_2()
                            .py_12()
                            .text_sm()
                            .text_color(theme.muted_foreground)
                            .child(if running {
                                "Nothing yet. Files appear here as they are found."
                            } else if total_found > 0 {
                                "Nothing matches. Small files are hidden."
                            } else {
                                "Nothing recoverable was found."
                            }),
                    )
                } else {
                    col.child(
                        h_flex()
                            .flex_wrap()
                            .gap_3()
                            .children(tiles.iter().map(|file| {
                                tile(
                                    file,
                                    selected.contains(&file.id),
                                    thumbnails.get(&file.id).cloned().flatten(),
                                    cx,
                                )
                            })),
                    )
                }
            })
            .when(more > 0, |col| {
                col.child(
                    h_flex().justify_center().child(
                        Button::new("more")
                            .label(format!(
                                "Show {} more of {visible_count}",
                                more.min(PAGE_SIZE)
                            ))
                            .small()
                            .outline()
                            .on_click(cx.listener(|this, _, _, cx| {
                                if let Some(session) = this.session() {
                                    session.shown += PAGE_SIZE;
                                }
                                cx.notify();
                            })),
                    ),
                )
            })
            .when(!chosen.is_empty() || export.is_some(), |col| {
                let size: Bytes = chosen.iter().map(FoundFile::size).sum();
                col.child(
                    Card::new().child(
                        h_flex()
                            .gap_3()
                            .flex_wrap()
                            .child(div().flex_1().text_sm().child(match &export {
                                Some(progress) => format!(
                                    "Recovering… {} of {} files · {} copied",
                                    progress.files(),
                                    chosen.len().max(progress.files()),
                                    progress.bytes().decimal()
                                ),
                                None => format!(
                                    "{} selected · {}",
                                    count(chosen.len(), "file"),
                                    size.decimal()
                                ),
                            }))
                            .when(export.is_none(), |row| {
                                row.child(
                                    Button::new("clear")
                                        .label("Clear")
                                        .small()
                                        .ghost()
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            if let Some(session) = this.session() {
                                                session.selected.clear();
                                            }
                                            cx.notify();
                                        })),
                                )
                                .child(
                                    Button::new("recover")
                                        .label("Recover…")
                                        .icon(Icon::new(Lucide::Download))
                                        .small()
                                        .primary()
                                        .on_click(cx.listener(move |this, _, window, cx| {
                                            let files = this
                                                .session()
                                                .map(|s| s.selected_files())
                                                .unwrap_or_default();
                                            this.recover(files, window, cx);
                                        })),
                                )
                            }),
                    ),
                )
            })
            .into_any_element()
    }
}

fn count(n: usize, noun: &str) -> String {
    if n == 1 {
        format!("1 {noun}")
    } else {
        format!("{n} {noun}s")
    }
}

fn eta(seconds: f64) -> String {
    let s = seconds.max(0.0).round() as u64;
    match s {
        0..60 => format!("{s}s"),
        60..3600 => format!("{}m {}s", s / 60, s % 60),
        _ => format!("{}h {}m", s / 3600, s / 60 % 60),
    }
}

fn kind_icon(kind: Kind) -> Icon {
    match kind {
        Kind::Photo => Icon::new(Lucide::Image),
        Kind::Video => Icon::new(Lucide::Film),
        Kind::Audio => Icon::new(Lucide::Music),
        Kind::Document => Icon::new(IconName::FileText),
        Kind::Other => Icon::new(IconName::File),
    }
}

/// One found file: thumbnail or icon, name, size, and how intact it is.
fn tile(
    file: &FoundFile,
    selected: bool,
    thumbnail: Option<Arc<RenderImage>>,
    cx: &mut Context<RecoveryPage>,
) -> AnyElement {
    let theme = cx.theme();
    let id = file.id;
    let detail = [
        Some(file.size().decimal().to_string()),
        file.details.summary(),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join(" · ");
    let badge = match file.condition {
        Condition::Good => None,
        Condition::Damaged => Some(Tag::warning().child("May be incomplete")),
        Condition::Overwritten => Some(Tag::danger().child("Overwritten")),
    };
    v_flex()
        .id(("found", id))
        .w(px(156.))
        .gap_1()
        .p_1p5()
        .rounded(theme.radius_lg)
        .border_2()
        .border_color(if selected {
            theme.primary
        } else {
            gpui_kit::transparent_black()
        })
        .cursor_pointer()
        .hover(|tile| tile.bg(theme.muted.opacity(0.5)))
        .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
            if event.click_count() >= 2 {
                this.preview(id, window, cx);
                return;
            }
            if let Some(session) = this.session()
                && !session.selected.remove(&id)
            {
                session.selected.insert(id);
            }
            cx.notify();
        }))
        .child(
            div()
                .w_full()
                .h(px(112.))
                .rounded(theme.radius)
                .overflow_hidden()
                .bg(theme.muted)
                .flex()
                .items_center()
                .justify_center()
                .map(|area| match thumbnail {
                    Some(image) => area.child(
                        img(ImageSource::Render(image))
                            .size_full()
                            .object_fit(ObjectFit::Cover),
                    ),
                    None => area.child(
                        kind_icon(file.kind)
                            .large()
                            .text_color(theme.muted_foreground),
                    ),
                }),
        )
        .child(
            h_flex()
                .gap_1()
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_xs()
                        .truncate()
                        .child(file.display_name()),
                )
                .when(file.origin == Origin::Directory, |row| {
                    row.child(
                        Icon::new(IconName::Check)
                            .xsmall()
                            .text_color(Tint::Green.strong()),
                    )
                }),
        )
        .child(
            div()
                .text_xs()
                .truncate()
                .text_color(theme.muted_foreground)
                .child(detail),
        )
        .children(badge.map(|tag| tag.small().outline().rounded_full()))
        .into_any_element()
}

/// A larger look at one file, with everything known about it.
struct FoundPreview {
    file: FoundFile,
    image: Option<Arc<RenderImage>>,
    loading: bool,
    page: gpui_kit::WeakEntity<RecoveryPage>,
}

impl FoundPreview {
    fn new(
        file: FoundFile,
        source: Arc<dyn ByteSource>,
        page: gpui_kit::WeakEntity<RecoveryPage>,
        cx: &mut Context<Self>,
    ) -> Self {
        let loading = recovery::has_preview(file.format);
        if loading {
            let target = file.clone();
            cx.spawn(async move |this, cx| {
                let image = cx
                    .background_spawn(async move {
                        recovery::thumbnail(&target, source.as_ref(), 900)
                            .map(|p| Arc::new(RenderImage::new(vec![image::Frame::new(p.image)])))
                    })
                    .await;
                this.update(cx, |this, cx| {
                    this.image = image;
                    this.loading = false;
                    cx.notify();
                })
                .ok();
            })
            .detach();
        }
        Self {
            file,
            image: None,
            loading,
            page,
        }
    }
}

impl Render for FoundPreview {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let file = &self.file;
        let facts: Vec<(&str, String)> = [
            Some(("Size", file.size().decimal().to_string())),
            file.format.map(|f| ("Format", f.label().to_string())),
            file.details.summary().map(|s| ("Details", s)),
            file.date.map(|d| ("Date", d.to_string())),
            file.folder.clone().map(|f| ("Was in", f)),
            Some((
                "Found",
                match file.origin {
                    Origin::Directory => "In a folder, with its name".to_string(),
                    Origin::Contents => format!("By its contents, at byte {}", file.offset()),
                },
            )),
            Some((
                "Condition",
                match file.condition {
                    Condition::Good => "Looks complete",
                    Condition::Damaged => "May be cut short or partly damaged",
                    Condition::Overwritten => "Its space was reused; little of it is left",
                }
                .to_string(),
            )),
        ]
        .into_iter()
        .flatten()
        .collect();
        let target = file.clone();
        let page = self.page.clone();
        v_flex()
            .gap_4()
            .child(
                div()
                    .w_full()
                    .h(px(300.))
                    .rounded(theme.radius_lg)
                    .overflow_hidden()
                    .bg(theme.muted)
                    .flex()
                    .items_center()
                    .justify_center()
                    .map(|area| match (&self.image, self.loading) {
                        (Some(image), _) => area.child(
                            img(ImageSource::Render(image.clone()))
                                .size_full()
                                .object_fit(ObjectFit::Contain),
                        ),
                        (None, true) => area.child(Spinner::new()),
                        (None, false) => area.child(
                            v_flex()
                                .items_center()
                                .gap_2()
                                .child(
                                    kind_icon(file.kind)
                                        .large()
                                        .text_color(theme.muted_foreground),
                                )
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(theme.muted_foreground)
                                        .child("No preview here; recover it to open it."),
                                ),
                        ),
                    }),
            )
            .child(
                v_flex()
                    .gap_1p5()
                    .children(facts.into_iter().map(|(label, value)| {
                        h_flex()
                            .gap_3()
                            .text_sm()
                            .child(
                                div()
                                    .w(px(90.))
                                    .text_color(theme.muted_foreground)
                                    .child(label),
                            )
                            .child(div().flex_1().min_w_0().child(value))
                    })),
            )
            .child(
                Button::new("recover-one")
                    .label("Recover…")
                    .icon(Icon::new(Lucide::Download))
                    .primary()
                    .on_click(move |_, window, cx: &mut App| {
                        page.update(cx, |page, cx| {
                            page.recover(vec![target.clone()], window, cx)
                        })
                        .ok();
                    }),
            )
    }
}

impl Render for RecoveryPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let in_session = matches!(self.state, State::Session(_));
        let mut header = PageHeader::new(Page::Recovery.title(), Page::Recovery.subtitle());
        if in_session {
            header = header.action(
                Button::new("back")
                    .label("Choose another disk")
                    .icon(IconName::ArrowLeft)
                    .small()
                    .ghost()
                    .on_click(cx.listener(|this, _, window, cx| this.leave(window, cx))),
            );
        } else {
            header = header
                .action(
                    Button::new("refresh-disks")
                        .label("Refresh")
                        .icon(Icon::new(Lucide::RefreshCw))
                        .small()
                        .outline()
                        .on_click(cx.listener(|this, _, _, cx| this.refresh(cx))),
                )
                .action(
                    Button::new("open-image")
                        .label("Open disk image…")
                        .icon(IconName::FolderOpen)
                        .small()
                        .outline()
                        .on_click(cx.listener(|this, _, _, cx| this.open_image(cx))),
                );
        }
        let body = match &self.state {
            State::Choosing => self.render_choosing(cx),
            State::Opening { name, .. } => v_flex()
                .items_center()
                .gap_3()
                .py_12()
                .child(Spinner::new().large().color(cx.theme().primary))
                .child(div().text_sm().child(format!("Opening {name}…")))
                .child(
                    div()
                        .text_xs()
                        .text_color(cx.theme().muted_foreground)
                        .child(
                            "Your system may ask for an administrator's password to read the disk.",
                        ),
                )
                .into_any_element(),
            State::Session(_) => self.render_session(cx),
        };
        let title_suffix = match &self.state {
            State::Session(session) => Some(session.name.clone()),
            _ => None,
        };
        page_scroll("recovery-page").child(
            page_body()
                .child(header)
                .children(title_suffix.map(|name| {
                    div()
                        .text_sm()
                        .text_color(cx.theme().muted_foreground)
                        .child(format!("Scanning {name}"))
                }))
                .child(body),
        )
    }
}
