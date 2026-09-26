use gpui_kit::component::sidebar::{Sidebar, SidebarGroup, SidebarMenu, SidebarMenuItem};
use gpui_kit::component::{ActiveTheme, Icon, IconName, Root, TitleBar, h_flex, v_flex};
use gpui_kit::{
    AnyView, AppContext as _, Context, Entity, FocusHandle, InteractiveElement, IntoElement,
    ParentElement, Render, SharedString, Styled, Window, div,
};

use crate::actions::{
    CloseWindow, Refresh, ShowActivity, ShowDevices, ShowMemory, ShowStorage, ToggleSidebar,
};
use crate::cli::LaunchOptions;
use crate::system::Monitor;
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

pub struct AppShell {
    page: Page,
    views: PageViews,
    sidebar_collapsed: bool,
    focus_handle: FocusHandle,
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
        Self {
            page: options.initial_page(),
            views: PageViews {
                memory: cx.new(|cx| MemoryPage::new(monitor.clone(), window, cx)),
                activity: cx.new(|cx| ActivityPage::new(monitor.clone(), window, cx)),
                storage: cx.new(|cx| StoragePage::new(options.scan.clone(), window, cx)),
                devices: cx.new(|cx| DevicesPage::new(window, cx)),
            },
            sidebar_collapsed: false,
            focus_handle,
        }
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

    fn render_sidebar(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let items = Page::ALL.map(|page| {
            SidebarMenuItem::new(page.title())
                .icon(page.icon())
                .active(self.page == page)
                .on_click(cx.listener(move |this, _, _, cx| this.navigate(page, cx)))
        });
        Sidebar::new("nav")
            .collapsed(self.sidebar_collapsed)
            .w_56()
            .child(SidebarGroup::new("Monitor").child(SidebarMenu::new().children(items)))
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
            .on_action(cx.listener(|this, _: &ToggleSidebar, _, cx| {
                this.sidebar_collapsed = !this.sidebar_collapsed;
                cx.notify();
            }))
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
                    .child(self.render_sidebar(cx))
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
