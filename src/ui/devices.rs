use std::time::Duration;

use gpui_kit::assets::IconName as Lucide;
use gpui_kit::component::button::Button;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::switch::Switch;
use gpui_kit::component::tag::Tag;
use gpui_kit::component::{ActiveTheme, Icon, IconName, Sizable, h_flex, v_flex};
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Hsla, IntoElement, ParentElement, Render,
    SharedString, Styled, Task, Window, div, prelude::FluentBuilder as _, px,
};

use crate::app::Page;
use crate::devices::{self, Device, DeviceClass, DeviceStatus, Driver, Inventory};
use crate::theme::Tint;
use crate::ui::widgets::{Card, PageHeader, Stat, page_body, page_scroll};

/// Hardware changes are rare; re-probing more often only burns CPU.
const REFRESH_INTERVAL: Duration = Duration::from_secs(30);
/// Not-connected devices listed per class before collapsing into a count.
const ABSENT_SHOWN: usize = 2;

pub struct DevicesPage {
    inventory: Option<Inventory>,
    loading: bool,
    show_apple_drivers: bool,
    _poller: Task<()>,
}

impl DevicesPage {
    pub fn new(_: &mut Window, cx: &mut Context<Self>) -> Self {
        let poller = cx.spawn(async move |this, cx| {
            loop {
                if this.update(cx, |this, cx| this.refresh(cx)).is_err() {
                    break;
                }
                cx.background_executor().timer(REFRESH_INTERVAL).await;
            }
        });
        Self {
            inventory: None,
            loading: false,
            show_apple_drivers: false,
            _poller: poller,
        }
    }

    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        if self.loading {
            return;
        }
        self.loading = true;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let inventory = cx.background_spawn(async { devices::collect() }).await;
            this.update(cx, |this, cx| {
                this.inventory = Some(inventory);
                this.loading = false;
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn render_summary(&self, inventory: &Inventory, cx: &App) -> AnyElement {
        let connected = inventory
            .devices
            .iter()
            .filter(|d| d.status == DeviceStatus::Connected)
            .count();
        let running = inventory
            .drivers
            .iter()
            .filter(|d| d.state.is_healthy())
            .count();
        let third_party = inventory
            .drivers
            .iter()
            .filter(|d| d.is_third_party())
            .count();
        let problems = problem_count(inventory);
        Card::new()
            .child(
                h_flex()
                    .flex_wrap()
                    .gap_x_10()
                    .gap_y_3()
                    .child(Stat::new("Connected devices", connected.to_string()))
                    .child(
                        Stat::new("Drivers running", running.to_string())
                            .hint(format!("{third_party} third-party")),
                    )
                    .child(
                        Stat::new("Problems", problems.to_string()).dot(if problems == 0 {
                            Tint::Green.strong()
                        } else {
                            Tint::Red.strong()
                        }),
                    ),
            )
            .when(!inventory.errors.is_empty(), |card| {
                card.child(
                    div()
                        .text_xs()
                        .text_color(cx.theme().muted_foreground)
                        .child(format!(
                            "Some probes failed: {}",
                            inventory.errors.join("; ")
                        )),
                )
            })
            .into_any_element()
    }

    fn render_problems(&self, inventory: &Inventory, cx: &App) -> Option<AnyElement> {
        let faulty = inventory
            .devices
            .iter()
            .filter(|d| d.status == DeviceStatus::Faulty)
            .map(|d| device_row(d, cx));
        let drivers = inventory
            .drivers
            .iter()
            .filter(|d| !d.state.is_healthy())
            .map(|d| driver_row(d, cx));
        let rows: Vec<AnyElement> = faulty.chain(drivers).collect();
        (!rows.is_empty()).then(|| {
            Card::new()
                .title("Needs attention")
                .child(v_flex().gap_1().children(rows))
                .into_any_element()
        })
    }

    /// One card per device class, busiest first. Remembered-but-absent devices
    /// (paired headphones, old network services) are capped so they don't
    /// bury what is actually plugged in.
    fn render_devices(&self, inventory: &Inventory, cx: &App) -> AnyElement {
        let muted = cx.theme().muted_foreground;
        let mut groups: Vec<(DeviceClass, Vec<&Device>)> = DeviceClass::ALL
            .into_iter()
            .map(|class| {
                let devices = inventory
                    .devices
                    .iter()
                    .filter(|d| d.class == class)
                    .collect();
                (class, devices)
            })
            .filter(|(_, devices): &(_, Vec<&Device>)| !devices.is_empty())
            .collect();
        let present = |devices: &[&Device]| {
            devices
                .iter()
                .filter(|d| d.status != DeviceStatus::Available)
                .count()
        };
        groups.sort_by_key(|(_, devices)| std::cmp::Reverse(present(devices)));

        h_flex()
            .flex_wrap()
            .items_start()
            .gap_4()
            .children(groups.into_iter().map(|(class, devices)| {
                let present_count = present(&devices);
                let absent: Vec<&Device> = devices
                    .iter()
                    .copied()
                    .filter(|d| d.status == DeviceStatus::Available)
                    .collect();
                let hidden = absent.len().saturating_sub(ABSENT_SHOWN);
                let rows = devices
                    .iter()
                    .filter(|d| d.status != DeviceStatus::Available)
                    .chain(absent.iter().take(ABSENT_SHOWN))
                    .map(|d| device_row(d, cx));
                div().flex_1().min_w(px(300.)).child(
                    Card::new()
                        .title(class.label())
                        .trailing(
                            h_flex()
                                .gap_1()
                                .text_xs()
                                .text_color(muted)
                                .child(class_icon(class).small())
                                .child(format!("{present_count} of {}", devices.len())),
                        )
                        .child(v_flex().gap_0p5().children(rows))
                        .when(hidden > 0, |card| {
                            card.child(
                                div()
                                    .text_xs()
                                    .text_color(muted)
                                    .child(format!("and {hidden} more not connected")),
                            )
                        }),
                )
            }))
            .into_any_element()
    }

    fn render_drivers(&self, inventory: &Inventory, cx: &mut Context<Self>) -> AnyElement {
        let show_apple = self.show_apple_drivers;
        let mut drivers: Vec<&Driver> = inventory
            .drivers
            .iter()
            .filter(|d| show_apple || d.is_third_party())
            .collect();
        drivers.sort_by(|a, b| {
            (a.state.is_healthy(), !a.is_third_party(), a.display_name()).cmp(&(
                b.state.is_healthy(),
                !b.is_third_party(),
                b.display_name(),
            ))
        });
        let muted = cx.theme().muted_foreground;
        Card::new()
            .title("Drivers & extensions")
            .trailing(
                Switch::new("show-apple-drivers")
                    .label("Include Apple")
                    .checked(show_apple)
                    .small()
                    .on_click(cx.listener(|this, checked: &bool, _, cx| {
                        this.show_apple_drivers = *checked;
                        cx.notify();
                    })),
            )
            .map(|card| {
                if drivers.is_empty() {
                    card.child(
                        div()
                            .text_sm()
                            .text_color(muted)
                            .child("No third-party drivers are loaded."),
                    )
                } else {
                    card.child(
                        v_flex()
                            .gap_0p5()
                            .children(drivers.into_iter().map(|d| driver_row(d, cx))),
                    )
                }
            })
            .into_any_element()
    }
}

fn problem_count(inventory: &Inventory) -> usize {
    inventory
        .devices
        .iter()
        .filter(|d| d.status == DeviceStatus::Faulty)
        .count()
        + inventory
            .drivers
            .iter()
            .filter(|d| !d.state.is_healthy())
            .count()
}

fn class_icon(class: DeviceClass) -> Icon {
    match class {
        DeviceClass::Usb => Icon::new(Lucide::Usb),
        DeviceClass::Thunderbolt => Icon::new(Lucide::Cable),
        DeviceClass::Bluetooth => Icon::new(Lucide::Bluetooth),
        DeviceClass::Display => Icon::new(Lucide::Monitor),
        DeviceClass::Audio => Icon::new(Lucide::AudioLines),
        DeviceClass::Camera => Icon::new(Lucide::Camera),
        DeviceClass::Network => Icon::new(Lucide::EthernetPort),
        DeviceClass::Storage => Icon::new(IconName::HardDrive),
    }
}

fn status_color(status: DeviceStatus, cx: &App) -> Hsla {
    match status {
        DeviceStatus::Connected => Tint::Green.strong(),
        DeviceStatus::Available => cx.theme().muted_foreground.opacity(0.5),
        DeviceStatus::Faulty => Tint::Red.strong(),
    }
}

fn row(
    icon: Icon,
    title: impl Into<SharedString>,
    detail: impl Into<SharedString>,
    trailing: impl IntoElement,
    dimmed: bool,
    cx: &App,
) -> AnyElement {
    let theme = cx.theme();
    h_flex()
        .gap_3()
        .py_1p5()
        .px_1()
        .when(dimmed, |row| row.opacity(0.6))
        .child(icon.small().text_color(theme.muted_foreground))
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .child(div().text_sm().truncate().child(title.into()))
                .child(
                    div()
                        .text_xs()
                        .truncate()
                        .text_color(theme.muted_foreground)
                        .child(detail.into()),
                ),
        )
        .child(trailing)
        .into_any_element()
}

fn device_row(device: &Device, cx: &App) -> AnyElement {
    let mut detail = device.facts.join(" · ");
    if let Some(driver) = &device.driver {
        if !detail.is_empty() {
            detail.push_str(" · ");
        }
        detail.push_str(&format!("driver {driver}"));
    }
    let color = status_color(device.status, cx);
    row(
        class_icon(device.class),
        device.name.clone(),
        detail,
        h_flex()
            .gap_1p5()
            .text_xs()
            .text_color(cx.theme().muted_foreground)
            .child(div().size_2().rounded_full().bg(color))
            .child(device.status.label()),
        device.status == DeviceStatus::Available,
        cx,
    )
}

fn driver_row(driver: &Driver, cx: &App) -> AnyElement {
    let mut detail = driver.kind.label().to_string();
    if driver.name.is_some() {
        detail.push_str(&format!(" · {}", driver.bundle_id));
    }
    if let Some(version) = &driver.version {
        detail.push_str(&format!(" · v{version}"));
    }
    let tag = if driver.state.is_healthy() {
        Tag::success()
    } else {
        Tag::warning()
    };
    row(
        Icon::new(Lucide::Puzzle),
        driver.display_name().to_string(),
        detail,
        tag.outline()
            .small()
            .rounded_full()
            .child(driver.state.label().to_string()),
        false,
        cx,
    )
}

impl Render for DevicesPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let header = PageHeader::new(Page::Devices.title(), Page::Devices.subtitle()).action(
            Button::new("refresh-devices")
                .label("Refresh")
                .icon(Icon::new(Lucide::RefreshCw))
                .small()
                .outline()
                .loading(self.loading)
                .on_click(cx.listener(|this, _, _, cx| this.refresh(cx))),
        );
        let Some(inventory) = self.inventory.clone() else {
            return v_flex()
                .size_full()
                .p_8()
                .gap_8()
                .child(header)
                .child(
                    h_flex()
                        .gap_2()
                        .text_sm()
                        .text_color(cx.theme().muted_foreground)
                        .child(Spinner::new())
                        .child("Asking the system for connected hardware…"),
                )
                .into_any_element();
        };
        page_scroll("devices-page")
            .child(
                page_body()
                    .child(header)
                    .child(self.render_summary(&inventory, cx))
                    .children(self.render_problems(&inventory, cx))
                    .child(self.render_devices(&inventory, cx))
                    .child(self.render_drivers(&inventory, cx)),
            )
            .into_any_element()
    }
}
