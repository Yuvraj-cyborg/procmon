use gpui_kit::component::sidebar::{Sidebar, SidebarGroup, SidebarMenu, SidebarMenuItem};
use gpui_kit::component::{ActiveTheme, Icon, IconName, Root, TitleBar, h_flex, v_flex};
use gpui_kit::{
    AnyView, AppContext as _, Context, IntoElement, ParentElement, Render, SharedString, Styled,
    Window, div,
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
}

struct PageViews {
    memory: AnyView,
    activity: AnyView,
    storage: AnyView,
    devices: AnyView,
}

impl PageViews {
    fn get(&self, page: Page) -> AnyView {
        match page {
            Page::Memory => self.memory.clone(),
            Page::Activity => self.activity.clone(),
            Page::Storage => self.storage.clone(),
            Page::Devices => self.devices.clone(),
        }
    }
}

impl AppShell {
    pub fn new(options: &LaunchOptions, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let monitor = cx.new(Monitor::new);
        Self {
            page: options.initial_page(),
            views: PageViews {
                memory: cx
                    .new(|cx| MemoryPage::new(monitor.clone(), window, cx))
                    .into(),
                activity: cx
                    .new(|cx| ActivityPage::new(monitor.clone(), window, cx))
                    .into(),
                storage: cx
                    .new(|cx| StoragePage::new(options.scan.clone(), window, cx))
                    .into(),
                devices: cx.new(|cx| DevicesPage::new(window, cx)).into(),
            },
            sidebar_collapsed: false,
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
