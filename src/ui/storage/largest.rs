use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{ActiveTheme, IconName, Sizable, h_flex, v_flex};
use gpui_kit::{
    AnyElement, Context, InteractiveElement, IntoElement, ParentElement,
    StatefulInteractiveElement, Styled, div, prelude::FluentBuilder as _, px,
};

use super::browse::Browse;
use super::{StoragePage, category_tint};

impl StoragePage {
    pub(super) fn render_largest(&self, browse: &Browse, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let (muted, hover_bg, selected_bg, radius) = (
            theme.muted_foreground,
            theme.muted,
            theme.table_active,
            theme.radius,
        );
        if browse.largest.is_empty() {
            return div()
                .text_sm()
                .text_color(muted)
                .child("No files found.")
                .into_any_element();
        }
        let tree = &browse.tree;
        let root = tree.root_path();
        let rows = browse.largest.iter().enumerate().map(|(ix, &id)| {
            let node = tree.node(id);
            let path = tree.path_of(id);
            let folder = node
                .parent
                .and_then(|parent| tree.path_of(parent))
                .map(|dir| match dir.strip_prefix(root) {
                    Ok(relative) if relative.as_os_str().is_empty() => "/".to_string(),
                    Ok(relative) => relative.display().to_string(),
                    Err(_) => dir.display().to_string(),
                })
                .unwrap_or_default();
            h_flex()
                .id(("largest", ix))
                .gap_3()
                .px_2()
                .py_1()
                .rounded(radius)
                .cursor_pointer()
                .hover(move |row| row.bg(hover_bg))
                .when(browse.selected == Some(id), |row| row.bg(selected_bg))
                .on_click(cx.listener(move |this, _, _, cx| this.focus_node(id, cx)))
                .child(
                    div()
                        .size_2()
                        .flex_shrink_0()
                        .rounded_full()
                        .bg(category_tint(node.category).strong()),
                )
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .child(div().text_sm().truncate().child(node.name.to_string()))
                        .child(div().text_xs().truncate().text_color(muted).child(folder)),
                )
                .child(
                    div()
                        .w(px(72.))
                        .text_right()
                        .text_sm()
                        .child(node.size.decimal().to_string()),
                )
                .children(path.map(|path| {
                    h_flex()
                        .child(
                            Button::new(("largest-reveal", ix))
                                .icon(IconName::FolderOpen)
                                .xsmall()
                                .ghost()
                                .tooltip("Reveal in Finder")
                                .on_click(move |_, _, cx| {
                                    cx.stop_propagation();
                                    cx.reveal_path(&path);
                                }),
                        )
                        .child(
                            Button::new(("largest-trash", ix))
                                .icon(IconName::Delete)
                                .xsmall()
                                .ghost()
                                .tooltip("Move to Trash")
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    cx.stop_propagation();
                                    this.confirm_trash(id, window, cx);
                                })),
                        )
                }))
        });
        v_flex().gap_0p5().children(rows).into_any_element()
    }
}
