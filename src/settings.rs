//! User preferences persisted as JSON between launches.

use std::path::PathBuf;
use std::{fs, io};

use gpui_kit::{App, Global};
use serde::{Deserialize, Serialize};

use crate::gpu::BenchRecord;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThemePreference {
    #[default]
    System,
    Light,
    Dark,
}

impl ThemePreference {
    pub fn next(self) -> Self {
        match self {
            ThemePreference::System => ThemePreference::Light,
            ThemePreference::Light => ThemePreference::Dark,
            ThemePreference::Dark => ThemePreference::System,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            ThemePreference::System => "System",
            ThemePreference::Light => "Light",
            ThemePreference::Dark => "Dark",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub theme: ThemePreference,
    pub group_by_app: bool,
    /// Finished GPU benchmarks, newest first.
    pub benchmarks: Vec<BenchRecord>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            theme: ThemePreference::System,
            group_by_app: true,
            benchmarks: Vec::new(),
        }
    }
}

impl Global for Settings {}

impl Settings {
    /// Loads saved settings, falling back to defaults when the file is
    /// missing or unreadable (a corrupt file must never stop the app).
    pub fn load() -> Self {
        settings_path()
            .and_then(|path| fs::read_to_string(path).ok())
            .and_then(|json| serde_json::from_str(&json).ok())
            .unwrap_or_default()
    }

    fn save(&self) -> io::Result<()> {
        let path = settings_path()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no home directory"))?;
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let json = serde_json::to_string_pretty(self).map_err(io::Error::other)?;
        fs::write(path, json)
    }

    pub fn get(cx: &App) -> &Self {
        cx.global::<Self>()
    }

    /// Applies `change` to the global settings and persists the result.
    pub fn update(cx: &mut App, change: impl FnOnce(&mut Self)) {
        let settings = cx.global_mut::<Self>();
        change(settings);
        if let Err(err) = settings.save() {
            eprintln!("procmon: could not save settings: {err}");
        }
    }
}

fn settings_path() -> Option<PathBuf> {
    if cfg!(windows) {
        let app_data = PathBuf::from(std::env::var_os("APPDATA")?);
        return Some(app_data.join("Procmon").join("settings.json"));
    }
    let home = PathBuf::from(std::env::var_os("HOME")?);
    let dir = if cfg!(target_os = "macos") {
        home.join("Library/Application Support/Procmon")
    } else {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".config"))
            .join("procmon")
    };
    Some(dir.join("settings.json"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_fields_fall_back_to_defaults() {
        let settings: Settings = serde_json::from_str(r#"{"theme":"dark"}"#).unwrap();
        assert_eq!(settings.theme, ThemePreference::Dark);
        assert!(settings.group_by_app);
    }

    #[test]
    fn theme_cycles_through_all_modes() {
        let start = ThemePreference::System;
        assert_eq!(start.next().next().next(), start);
    }
}
