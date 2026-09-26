mod actions;
mod app;
mod assets;
mod cli;
mod devices;
mod storage;
mod system;
mod theme;
mod ui;
mod units;

use gpui_kit::component::{Root, TitleBar};
use gpui_kit::{AppContext as _, Bounds, WindowBounds, WindowOptions, px, size};

use crate::app::AppShell;
use crate::assets::AppAssets;
use crate::cli::LaunchOptions;

fn main() {
    let launch = LaunchOptions::from_args();
    gpui_kit::application()
        .with_assets(AppAssets)
        .run(move |cx| {
            gpui_kit::init(cx);
            actions::init(cx);

            let preferred = size(px(1180.), px(800.));
            let window_size = cx
                .primary_display()
                .map(|display| {
                    let screen = display.bounds().size;
                    size(
                        preferred.width.min(screen.width * 0.92),
                        preferred.height.min(screen.height * 0.92),
                    )
                })
                .unwrap_or(preferred);
            let bounds = Bounds::centered(None, window_size, cx);
            let options = WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                window_min_size: Some(size(px(720.), px(480.))),
                ..TitleBar::window_options()
            };

            cx.spawn(async move |cx| {
                cx.open_window(options, |window, cx| {
                    if let Err(err) = theme::init(window, cx) {
                        eprintln!("procmon: falling back to default theme: {err:#}");
                    }
                    let shell = cx.new(|cx| AppShell::new(&launch, window, cx));
                    cx.new(|cx| Root::new(shell, window, cx))
                })
                .expect("failed to open main window");
            })
            .detach();
        });
}
