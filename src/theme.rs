use std::rc::Rc;

use anyhow::Context as _;
use gpui_kit::component::{Theme, ThemeSet};
use gpui_kit::{App, Hsla, Rgba, Window, rgb};

const THEME_JSON: &str = include_str!("../assets/themes/procmon.json");

/// Installs the Procmon light/dark palettes and follows the system appearance.
pub fn init(window: &mut Window, cx: &mut App) -> anyhow::Result<()> {
    let set: ThemeSet = serde_json::from_str(THEME_JSON).context("parsing bundled theme")?;
    {
        let theme = Theme::global_mut(cx);
        for config in set.themes {
            if config.mode.is_dark() {
                theme.dark_theme = Rc::new(config);
            } else {
                theme.light_theme = Rc::new(config);
            }
        }
    }
    Theme::sync_system_appearance(Some(window), cx);
    Ok(())
}

/// A soft categorical colour, used for treemap tiles, legends and tags.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Tint {
    Blue,
    Green,
    Orange,
    Purple,
    Pink,
    Yellow,
    Red,
    Brown,
    Gray,
}

impl Tint {
    pub const CYCLE: [Tint; 8] = [
        Tint::Blue,
        Tint::Green,
        Tint::Orange,
        Tint::Purple,
        Tint::Pink,
        Tint::Yellow,
        Tint::Red,
        Tint::Brown,
    ];

    /// Pastel fill, readable with the theme foreground on top.
    pub fn fill(self, dark: bool) -> Hsla {
        let hex = match (self, dark) {
            (Tint::Blue, false) => 0xDCE8F5,
            (Tint::Green, false) => 0xDCEEDF,
            (Tint::Orange, false) => 0xFAE3CF,
            (Tint::Purple, false) => 0xE9E0F3,
            (Tint::Pink, false) => 0xF6E0EA,
            (Tint::Yellow, false) => 0xFBEFCB,
            (Tint::Red, false) => 0xFBE0DD,
            (Tint::Brown, false) => 0xEEE3DA,
            (Tint::Gray, false) => 0xEDECE9,
            (Tint::Blue, true) => 0x243447,
            (Tint::Green, true) => 0x243B31,
            (Tint::Orange, true) => 0x46301F,
            (Tint::Purple, true) => 0x362B47,
            (Tint::Pink, true) => 0x44283A,
            (Tint::Yellow, true) => 0x453A1C,
            (Tint::Red, true) => 0x4A2725,
            (Tint::Brown, true) => 0x3B2F27,
            (Tint::Gray, true) => 0x2C2C2B,
        };
        rgb(hex).into()
    }

    /// Saturated variant for strokes, dots and bar fills.
    pub fn strong(self) -> Hsla {
        let hex: Rgba = rgb(match self {
            Tint::Blue => 0x529CCA,
            Tint::Green => 0x4DAB9A,
            Tint::Orange => 0xE38A4F,
            Tint::Purple => 0x9A6DD7,
            Tint::Pink => 0xD66A9E,
            Tint::Yellow => 0xD9A441,
            Tint::Red => 0xE0645C,
            Tint::Brown => 0xA27763,
            Tint::Gray => 0x9B9A97,
        });
        hex.into()
    }
}
