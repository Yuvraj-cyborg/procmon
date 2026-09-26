use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::sidebar::{Sidebar, SidebarGroup, SidebarMenu, SidebarMenuItem};
use gpui_kit::component::{
    ActiveTheme, Icon, IconName, Root, Sizable, Theme, TitleBar, h_flex, v_flex,
};
use gpui_kit::{
    AnyView, AppContext as _, Context, Entity, FocusHandle, InteractiveElement, IntoElement,
    ParentElement, Pixels, Render, SharedString, Styled, Subscription, Window, div,
    prelude::FluentBuilder as _, px,
};

use crate::actions::{
    CloseWindow, Refresh, ShowActivity, ShowDevices, ShowMemory, ShowStorage, ToggleSidebar,
};
use crate::cli::LaunchOptions;
use crate::settings::{Settings, ThemePreference};
use crate::system::Monitor;
use crate::theme;
use crate::ui::activity::ActivityPage;
use crate::ui::devices::DevicesPage;
use crate::ui::memory::MemoryPage;
use crate::ui::storage::StoragePage;

/// A top-level destination in the sidebar.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Page {
    Memory,
    Activity,
    Storage,
    Devices,
}

impl Page {
    pub const ALL: [Page; 4] = [Page::Memory, Page::Activity, Page::Storage, Page::Devices];

    pub fn title(self) -> &'static str {
        match self {
            Page::Memory => "Memory",
            Page::Activity => "Activity",
            Page::Storage => "Storage",
            Page::Devices => "Devices",
        }
    }

    pub fn subtitle(self) -> &'static str {
        match self {
            Page::Memory => "RAM, swap and the processes holding it",
            Page::Activity => "CPU load, blocked threads and noisy processes",
            Page::Storage => "Volumes and what is taking up space",
            Page::Devices => "Connected hardware and loaded drivers",
        }
    }

    pub fn icon(self) -> Icon {
        match self {
            Page::Memory => Icon::new(IconName::MemoryStick),
            Page::Activity => Icon::new(IconName::Cpu),
            Page::Storage => Icon::new(IconName::HardDrive),
            Page::Devices => Icon::new(gpui_kit::assets::IconName::Usb),
        }
    }
}

impl std::str::FromStr for Page {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Page::ALL
            .into_iter()
            .find(|page| page.title().eq_ignore_ascii_case(s))
            .ok_or_else(|| {
                let names: Vec<_> = Page::ALL.iter().map(|p| p.title().to_lowercase()).collect();
                format!("unknown page `{s}`, expected one of: {}", names.join(", "))
            })
    }
}

/// Below this window width the sidebar shrinks to icons unless the user
/// has explicitly expanded it.
const SIDEBAR_BREAKPOINT: Pixels = px(900.);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SidebarMode {
    /// Follow the window width.
    Auto,
    Expanded,
    Collapsed,
}

pub struct AppShell {
    page: Page,
    views: PageViews,
    sidebar: SidebarMode,
    focus_handle: FocusHandle,
    _appearance: Subscription,
}

struct PageViews {
    memory: Entity<MemoryPage>,
    activity: Entity<ActivityPage>,
    storage: Entity<StoragePage>,
    devices: Entity<DevicesPage>,
}

impl PageViews {
    fn get(&self, page: Page) -> AnyView {
        match page {
            Page::Memory => self.memory.clone().into(),
            Page::Activity => self.activity.clone().into(),
            Page::Storage => self.storage.clone().into(),
            Page::Devices => self.devices.clone().into(),
        }
    }
}

impl AppShell {
    pub fn new(options: &LaunchOptions, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let monitor = cx.new(Monitor::new);
        let focus_handle = cx.focus_handle();
        // Keyboard shortcuts dispatch along the focus path, so the shell must be
        // on it even before the user clicks anything.
        window.focus(&focus_handle, cx);
        let appearance = cx.observe_window_appearance(window, |_, window, cx| {
            if Settings::get(cx).theme == ThemePreference::System {
                Theme::sync_system_appearance(Some(window), cx);
            }
        });
        Self {
            page: options.initial_page(),
            views: PageViews {
                memory: cx.new(|cx| MemoryPage::new(monitor.clone(), window, cx)),
                activity: cx.new(|cx| ActivityPage::new(monitor.clone(), window, cx)),
                storage: cx.new(|cx| StoragePage::new(options.scan.clone(), window, cx)),
                devices: cx.new(|cx| DevicesPage::new(window, cx)),
            },
            sidebar: SidebarMode::Auto,
            focus_handle,
            _appearance: appearance,
        }
    }

    fn sidebar_collapsed(&self, window: &Window) -> bool {
        match self.sidebar {
            SidebarMode::Auto => window.viewport_size().width < SIDEBAR_BREAKPOINT,
            SidebarMode::Expanded => false,
            SidebarMode::Collapsed => true,
        }
    }

    fn toggle_sidebar(&mut self, window: &Window, cx: &mut Context<Self>) {
        self.sidebar = if self.sidebar_collapsed(window) {
            SidebarMode::Expanded
        } else {
            SidebarMode::Collapsed
        };
        cx.notify();
    }

    fn cycle_theme(window: &mut Window, cx: &mut Context<Self>) {
        let next = Settings::get(cx).theme.next();
        Settings::update(cx, |settings| settings.theme = next);
        theme::apply(next, window, cx);
    }

    fn refresh_page(&mut self, cx: &mut Context<Self>) {
        match self.page {
            Page::Storage => self.views.storage.update(cx, |page, cx| page.rescan(cx)),
            Page::Devices => self.views.devices.update(cx, |page, cx| page.refresh(cx)),
            // Memory and Activity update live every second.
            Page::Memory | Page::Activity => {}
        }
    }

    fn navigate(&mut self, page: Page, cx: &mut Context<Self>) {
        if self.page != page {
            self.page = page;
            cx.notify();
        }
    }

    fn render_sidebar(&self, window: &Window, cx: &mut Context<Self>) -> impl IntoElement {
        let collapsed = self.sidebar_collapsed(window);
        let items = Page::ALL.map(|page| {
            SidebarMenuItem::new(page.title())
                .icon(page.icon())
                .active(self.page == page)
                .on_click(cx.listener(move |this, _, _, cx| this.navigate(page, cx)))
        });
        let preference = Settings::get(cx).theme;
        let theme_icon = match preference {
            ThemePreference::System => Icon::new(gpui_kit::assets::IconName::Monitor),
            ThemePreference::Light => Icon::new(IconName::Sun),
            ThemePreference::Dark => Icon::new(IconName::Moon),
        };
        Sidebar::new("nav")
            .collapsed(collapsed)
            .w_56()
            .child(SidebarGroup::new("Monitor").child(SidebarMenu::new().children(items)))
            .footer(
                Button::new("theme")
                    .icon(theme_icon)
                    .ghost()
                    .small()
                    .when(!collapsed, |button| {
                        button.label(format!("Theme: {}", preference.label()))
                    })
                    .tooltip("Switch between system, light and dark")
                    .on_click(cx.listener(|_, _, window, cx| Self::cycle_theme(window, cx))),
            )
    }
}

impl Render for AppShell {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let title: SharedString = format!("Procmon — {}", self.page.title()).into();
        v_flex()
            .size_full()
            .track_focus(&self.focus_handle)
            .on_action(cx.listener(|this, _: &ShowMemory, _, cx| this.navigate(Page::Memory, cx)))
            .on_action(
                cx.listener(|this, _: &ShowActivity, _, cx| this.navigate(Page::Activity, cx)),
            )
            .on_action(cx.listener(|this, _: &ShowStorage, _, cx| this.navigate(Page::Storage, cx)))
            .on_action(cx.listener(|this, _: &ShowDevices, _, cx| this.navigate(Page::Devices, cx)))
            .on_action(cx.listener(|this, _: &Refresh, _, cx| this.refresh_page(cx)))
            .on_action(
                cx.listener(|this, _: &ToggleSidebar, window, cx| this.toggle_sidebar(window, cx)),
            )
            .on_action(|_: &CloseWindow, window, _| window.remove_window())
            .bg(theme.background)
            .text_color(theme.foreground)
            .child(
                TitleBar::new().child(
                    h_flex()
                        .w_full()
                        .justify_center()
                        .text_sm()
                        .text_color(theme.muted_foreground)
                        .child(title),
                ),
            )
            .child(
                h_flex()
                    .flex_1()
                    .min_h_0()
                    .items_stretch()
                    .child(self.render_sidebar(window, cx))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .h_full()
                            .child(self.views.get(self.page)),
                    ),
            )
            .children(Root::render_dialog_layer(window, cx))
            .children(Root::render_notification_layer(window, cx))
    }
}
