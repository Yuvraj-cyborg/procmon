//! Side sheet with live details for one process, including every thread's
//! run state — the place to look when something is stuck.

use std::path::PathBuf;

use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::dialog::DialogButtonProps;
use gpui_kit::component::notification::Notification;
use gpui_kit::component::{ActiveTheme, IconName, Sizable, WindowExt, h_flex, v_flex};
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, Hsla, IntoElement, ParentElement, Render,
    SharedString, Styled, Subscription, Window, div, prelude::FluentBuilder as _, px,
};

use crate::system::control::{self, Signal};
use crate::system::snapshot::ProcessInfo;
use crate::system::{Monitor, ThreadRunState, ThreadSample, executable_path, inspect_threads};
use crate::theme::Tint;
use crate::ui::widgets::Stat;
use crate::units::{Pid, compact_duration};

pub struct ProcessDetail {
    pid: Pid,
    name: SharedString,
    monitor: Entity<Monitor>,
    executable: Option<PathBuf>,
    threads: Option<Vec<ThreadSample>>,
    _observer: Subscription,
}

impl ProcessDetail {
    /// Opens the detail sheet for `pid` on the right-hand side of the window.
    pub fn open(
        pid: Pid,
        name: SharedString,
        monitor: Entity<Monitor>,
        window: &mut Window,
        cx: &mut App,
    ) {
        let view = cx.new(|cx| Self::new(pid, name.clone(), monitor, cx));
        window.open_sheet(cx, move |sheet, _, _| {
            sheet.title(name.clone()).size(px(440.)).child(view.clone())
        });
    }

    fn new(pid: Pid, name: SharedString, monitor: Entity<Monitor>, cx: &mut Context<Self>) -> Self {
        let observer = cx.observe(&monitor, |this, _, cx| {
            this.threads = inspect_threads(this.pid);
            cx.notify();
        });
        Self {
            pid,
            name,
            executable: executable_path(pid),
            threads: inspect_threads(pid),
            monitor,
            _observer: observer,
        }
    }

    fn render_identity(&self, cx: &App) -> AnyElement {
        let muted = cx.theme().muted_foreground;
        v_flex()
            .gap_1()
            .child(
                div()
                    .text_sm()
                    .text_color(muted)
                    .child(format!("PID {}", self.pid)),
            )
            .when_some(self.executable.clone(), |col, path| {
                col.child(
                    h_flex()
                        .gap_2()
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .text_xs()
                                .text_color(muted)
                                .truncate()
                                .child(path.display().to_string()),
                        )
                        .child(
                            Button::new("reveal-exe")
                                .icon(IconName::FolderOpen)
                                .xsmall()
                                .ghost()
                                .tooltip("Reveal executable in Finder")
                                .on_click(move |_, _, cx| cx.reveal_path(&path)),
                        ),
                )
            })
            .into_any_element()
    }

    fn render_stats(process: &ProcessInfo) -> AnyElement {
        let dash = || "—".to_string();
        let activity = process.activity;
        let network = process.network;
        let stats = [
            Stat::new("Memory", process.memory.binary().to_string()),
            Stat::new("CPU", process.cpu.to_string()),
            Stat::new("Running for", compact_duration(process.run_time)),
            Stat::new("Disk", process.disk_read.to_string())
                .hint(format!("{} written", process.disk_write)),
            Stat::new(
                "Network",
                network.map_or_else(dash, |n| n.received.to_string()),
            )
            .hint(network.map_or_else(dash, |n| format!("{} sent", n.sent))),
            Stat::new(
                "Syscalls",
                activity.map_or_else(dash, |a| a.syscalls.to_string()),
            )
            .hint(
                activity.map_or_else(dash, |a| format!("{} context switches", a.context_switches)),
            ),
            Stat::new(
                "Wakeups",
                activity.map_or_else(dash, |a| a.idle_wakeups.to_string()),
            )
            .hint(activity.map_or_else(dash, |a| format!("{} IPC messages", a.mach_messages))),
        ];
        h_flex()
            .flex_wrap()
            .gap_x_8()
            .gap_y_4()
            .children(stats.into_iter().map(|stat| div().w(px(160.)).child(stat)))
            .into_any_element()
    }

    fn render_threads(&self, cx: &App) -> AnyElement {
        let muted = cx.theme().muted_foreground;
        let Some(threads) = &self.threads else {
            return div()
                .text_sm()
                .text_color(muted)
                .child("Thread details need permission — run Procmon with sudo to inspect system processes.")
                .into_any_element();
        };
        let mut threads = threads.clone();
        threads.sort_by(|a, b| {
            a.state
                .cmp(&b.state)
                .then(b.cpu.get().total_cmp(&a.cpu.get()))
        });

        let count = |state: ThreadRunState| threads.iter().filter(|t| t.state == state).count();
        let summary = [
            ThreadRunState::Running,
            ThreadRunState::Waiting,
            ThreadRunState::Uninterruptible,
            ThreadRunState::Stopped,
        ]
        .into_iter()
        .filter_map(|state| {
            let n = count(state);
            (n > 0).then(|| format!("{n} {}", state.label().to_lowercase()))
        })
        .collect::<Vec<_>>()
        .join(" · ");

        v_flex()
            .gap_2()
            .child(
                h_flex()
                    .justify_between()
                    .child(
                        div()
                            .text_sm()
                            .font_weight(gpui_kit::FontWeight::MEDIUM)
                            .child(format!("Threads ({})", threads.len())),
                    )
                    .child(div().text_xs().text_color(muted).child(summary)),
            )
            .child(
                v_flex()
                    .gap_0p5()
                    .children(threads.iter().map(|thread| thread_row(thread, cx))),
            )
            .into_any_element()
    }

    fn render_actions(&self, cx: &mut Context<Self>) -> AnyElement {
        let (pid, name) = (self.pid, self.name.clone());
        let force_name = name.clone();
        h_flex()
            .gap_2()
            .child(
                Button::new("quit-process")
                    .label("Quit")
                    .small()
                    .outline()
                    .on_click(move |_, window, cx| quit(pid, &name, window, cx)),
            )
            .child(
                Button::new("force-quit-process")
                    .label("Force Quit")
                    .small()
                    .danger()
                    .on_click(move |_, window, cx| {
                        confirm_force_quit(pid, force_name.clone(), window, cx)
                    }),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child("Quit asks politely; Force Quit cannot be ignored."),
            )
            .into_any_element()
    }
}

fn state_color(state: ThreadRunState, cx: &App) -> Hsla {
    match state {
        ThreadRunState::Running => Tint::Green.strong(),
        ThreadRunState::Uninterruptible => Tint::Orange.strong(),
        ThreadRunState::Stopped | ThreadRunState::Halted => Tint::Red.strong(),
        ThreadRunState::Waiting | ThreadRunState::Unknown => {
            cx.theme().muted_foreground.opacity(0.5)
        }
    }
}

fn thread_row(thread: &ThreadSample, cx: &App) -> AnyElement {
    let muted = cx.theme().muted_foreground;
    let name = thread
        .name
        .clone()
        .unwrap_or_else(|| format!("thread {}", thread.id));
    h_flex()
        .gap_2()
        .py_1()
        .text_sm()
        .child(
            div()
                .size_2()
                .rounded_full()
                .bg(state_color(thread.state, cx)),
        )
        .child(div().flex_1().min_w_0().truncate().child(name))
        .child(
            div()
                .w(px(64.))
                .text_xs()
                .text_color(muted)
                .child(thread.state.label()),
        )
        .child(
            div()
                .w(px(48.))
                .text_right()
                .text_xs()
                .child(thread.cpu.percent().to_string()),
        )
        .into_any_element()
}

/// Sends `SIGTERM` and reports the outcome as a notification.
pub fn quit(pid: Pid, name: &SharedString, window: &mut Window, cx: &mut App) {
    let note = match control::send(pid, Signal::Terminate) {
        Ok(()) => Notification::success(format!("Asked {name} to quit.")),
        Err(err) => Notification::error(format!("Couldn't quit {name}: {err}.")),
    };
    window.push_notification(note, cx);
}

/// Asks for confirmation, then sends `SIGKILL`.
pub fn confirm_force_quit(pid: Pid, name: SharedString, window: &mut Window, cx: &mut App) {
    window.open_alert_dialog(cx, move |dialog, _, _| {
        let name = name.clone();
        dialog
            .title(format!("Force quit {name}?"))
            .description("It stops immediately. Any unsaved work in it will be lost.")
            .button_props(
                DialogButtonProps::default()
                    .ok_text("Force Quit")
                    .ok_variant(ButtonVariant::Danger)
                    .show_cancel(true),
            )
            .on_ok(move |_, window, cx| {
                let note = match control::send(pid, Signal::Kill) {
                    Ok(()) => Notification::success(format!("{name} was force quit.")),
                    Err(err) => Notification::error(format!("Couldn't force quit {name}: {err}.")),
                };
                window.push_notification(note, cx);
                true
            })
    });
}

impl Render for ProcessDetail {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let process = self
            .monitor
            .read(cx)
            .latest()
            .and_then(|s| s.processes.iter().find(|p| p.pid == self.pid).cloned());
        v_flex()
            .gap_5()
            .pb_4()
            .child(self.render_identity(cx))
            .map(|col| match &process {
                Some(process) => col
                    .child(Self::render_stats(process))
                    .child(self.render_actions(cx))
                    .child(self.render_threads(cx)),
                None => col.child(
                    div()
                        .text_sm()
                        .text_color(cx.theme().muted_foreground)
                        .child("This process has exited."),
                ),
            })
    }
}
