//! Application-wide actions, their keyboard shortcuts and the menu bar.

use gpui_kit::{App, KeyBinding, Menu, MenuItem, SystemMenuType};

gpui_kit::actions!(
    procmon,
    [
        Quit,
        CloseWindow,
        ShowMemory,
        ShowActivity,
        ShowStorage,
        ShowDevices,
        Refresh,
        ToggleSidebar,
        FocusSearch,
    ]
);

pub fn init(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("cmd-q", Quit, None),
        KeyBinding::new("cmd-w", CloseWindow, None),
        KeyBinding::new("cmd-1", ShowMemory, None),
        KeyBinding::new("cmd-2", ShowActivity, None),
        KeyBinding::new("cmd-3", ShowStorage, None),
        KeyBinding::new("cmd-4", ShowDevices, None),
        KeyBinding::new("cmd-r", Refresh, None),
        KeyBinding::new("cmd-\\", ToggleSidebar, None),
        KeyBinding::new("cmd-f", FocusSearch, None),
    ]);
    cx.on_action(|_: &Quit, cx| cx.quit());
    // A single-window utility: closing the window means quitting.
    cx.on_window_closed(|cx, _| {
        if cx.windows().is_empty() {
            cx.quit();
        }
    })
    .detach();
    cx.set_menus([
        Menu::new("Procmon").items([
            MenuItem::os_submenu("Services", SystemMenuType::Services),
            MenuItem::separator(),
            MenuItem::action("Quit Procmon", Quit),
        ]),
        Menu::new("View").items([
            MenuItem::action("Memory", ShowMemory),
            MenuItem::action("Activity", ShowActivity),
            MenuItem::action("Storage", ShowStorage),
            MenuItem::action("Devices", ShowDevices),
            MenuItem::separator(),
            MenuItem::action("Refresh", Refresh),
            MenuItem::action("Find", FocusSearch),
            MenuItem::action("Toggle Sidebar", ToggleSidebar),
        ]),
        Menu::new("Window").items([MenuItem::action("Close Window", CloseWindow)]),
    ]);
}
