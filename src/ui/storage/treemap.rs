use std::sync::Arc;

use gpui_kit::component::ActiveTheme;
use gpui_kit::component::menu::{ContextMenuExt as _, PopupMenuItem};
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement, IntoElement, ParentElement,
    StatefulInteractiveElement, Styled, canvas, div, prelude::FluentBuilder as _, px, size,
};

use super::{ScanState, StoragePage, category_tint};
use crate::storage::treemap::{Rect, squarify};
use crate::storage::{FileTree, NodeId};

/// Tiles beyond this many are too small to see; they would only cost layout time.
const MAX_TILES: usize = 150;
const MAX_SUBTILES: usize = 60;
/// Space between neighbouring tiles.
const GAP: f32 = 3.0;
/// Height of the name strip on folders that show their contents.
const HEADER: f32 = 20.0;
/// Folders at least this large (in px) reveal a second level of tiles.
const NEST_MIN_W: f32 = 120.0;
const NEST_MIN_H: f32 = 80.0;
/// Tiles at least this large get a name and size label.
const LABEL_MIN_W: f32 = 56.0;
const LABEL_MIN_H: f32 = 30.0;

impl StoragePage {
    pub(super) fn render_treemap(
        &self,
        tree: &Arc<FileTree>,
        current: NodeId,
        selected: Option<NodeId>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let area = self
            .treemap_bounds
            .get()
            .map(|b| b.size)
            .unwrap_or(size(px(800.), px(420.)));
        let bounds = Rect::new(0.0, 0.0, f32::from(area.width), f32::from(area.height));
        let children: Vec<NodeId> = tree
            .node(current)
            .children
            .iter()
            .copied()
            .take(MAX_TILES)
            .collect();
        let rects = layout(tree, &children, bounds);

        let cell = self.treemap_bounds.clone();
        let view = cx.entity().downgrade();
        let measure = canvas(
            move |measured, _, cx| {
                let resized = cell.get().map(|b| b.size) != Some(measured.size);
                cell.set(Some(measured));
                if resized {
                    cx.defer(move |cx| {
                        view.update(cx, |_, cx| cx.notify()).ok();
                    });
                }
            },
            |_, _, _, _| {},
        )
        .absolute()
        .size_full();

        let menu_view = cx.entity().downgrade();
        div()
            .id("treemap")
            .relative()
            .size_full()
            .context_menu(move |menu, _, cx| {
                let Some(view) = menu_view.upgrade() else {
                    return menu;
                };
                let Some((id, is_folder, path)) = view.read(cx).hovered_target() else {
                    return menu;
                };
                let (open_view, trash_view) = (view.clone(), view);
                menu.when(is_folder, |menu| {
                    menu.item(PopupMenuItem::new("Open").on_click(move |_, _, cx| {
                        open_view.update(cx, |this, cx| this.focus_node(id, cx));
                    }))
                })
                .when_some(path, |menu, path| {
                    menu.item(
                        PopupMenuItem::new("Reveal in Finder")
                            .on_click(move |_, _, cx| cx.reveal_path(&path)),
                    )
                    .separator()
                    .item(
                        PopupMenuItem::new("Move to Trash…").on_click(move |_, window, cx| {
                            trash_view.update(cx, |this, cx| this.confirm_trash(id, window, cx));
                        }),
                    )
                })
            })
            .child(measure)
            .children(
                children
                    .into_iter()
                    .zip(rects)
                    .filter(|(_, r)| r.w >= 1.0 && r.h >= 1.0)
                    .map(|(id, rect)| self.render_tile(tree, id, rect, selected, cx)),
            )
            .into_any_element()
    }

    fn render_tile(
        &self,
        tree: &Arc<FileTree>,
        id: NodeId,
        rect: Rect,
        selected: Option<NodeId>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = cx.theme();
        let dark = theme.is_dark();
        let ring = theme.ring;
        let node = tree.node(id);
        let r = rect.inset(GAP / 2.0);
        let nested = node.is_container() && r.w >= NEST_MIN_W && r.h >= NEST_MIN_H;
        let fill = if nested {
            theme.muted
        } else {
            category_tint(node.category).fill(dark)
        };

        let tile =
            div()
                .id(("tile", id.as_usize()))
                .absolute()
                .left(px(r.x))
                .top(px(r.y))
                .w(px(r.w))
                .h(px(r.h))
                .rounded(px(6.))
                .overflow_hidden()
                .bg(fill)
                .border_1()
                .border_color(theme.border)
                .hover(|style| style.border_color(theme.ring))
                .cursor_pointer()
                .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                    this.hover(hovered.then_some(id), cx)
                }))
                .when(selected == Some(id), |tile| {
                    tile.border_2().border_color(ring)
                })
                .on_click(cx.listener(move |this, _, _, cx| this.focus_node(id, cx)));

        if nested {
            let inner = Rect::new(GAP, HEADER, r.w - 2.0 * GAP, r.h - HEADER - GAP);
            let children: Vec<NodeId> = tree
                .node(skip_single_folders(tree, id))
                .children
                .iter()
                .copied()
                .take(MAX_SUBTILES)
                .collect();
            let rects = layout(tree, &children, inner);
            tile.child(
                label(node.name.to_string(), node.size, r.w, cx)
                    .px_2()
                    .h(px(HEADER)),
            )
            .children(
                children
                    .into_iter()
                    .zip(rects)
                    .filter(|(_, r)| r.w >= 1.0 && r.h >= 1.0)
                    .map(|(child, rect)| self.render_subtile(tree, child, rect, selected, cx)),
            )
            .into_any_element()
        } else {
            tile.when(r.w >= LABEL_MIN_W && r.h >= LABEL_MIN_H, |tile| {
                tile.p_1p5().child(
                    label(node.name.to_string(), node.size, r.w, cx)
                        .flex_col()
                        .items_start(),
                )
            })
            .into_any_element()
        }
    }

    /// A tile inside a nested folder. Clicking opens the child folder, or
    /// opens the containing folder with the file selected.
    fn render_subtile(
        &self,
        tree: &Arc<FileTree>,
        id: NodeId,
        rect: Rect,
        selected: Option<NodeId>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = cx.theme();
        let ring = theme.ring;
        let node = tree.node(id);
        let r = rect.inset(GAP / 2.0);
        div()
            .id(("subtile", id.as_usize()))
            .absolute()
            .left(px(r.x))
            .top(px(r.y))
            .w(px(r.w))
            .h(px(r.h))
            .rounded(px(4.))
            .overflow_hidden()
            .bg(category_tint(node.category).fill(theme.is_dark()))
            .hover(|style| style.bg(category_tint(node.category).strong().opacity(0.35)))
            .on_hover(
                cx.listener(move |this, hovered: &bool, _, cx| {
                    this.hover(hovered.then_some(id), cx)
                }),
            )
            .when(selected == Some(id), |tile| {
                tile.border_2().border_color(ring)
            })
            .on_click(cx.listener(move |this, _, _, cx| {
                cx.stop_propagation();
                this.focus_node(id, cx)
            }))
            .when(r.w >= LABEL_MIN_W && r.h >= LABEL_MIN_H, |tile| {
                tile.p_1().child(
                    label(node.name.to_string(), node.size, r.w, cx)
                        .flex_col()
                        .items_start(),
                )
            })
            .into_any_element()
    }
}

impl StoragePage {
    /// The tile under the pointer, for the right-click menu: its id, whether
    /// it is a folder, and its path (none for the root or synthetic nodes).
    fn hovered_target(&self) -> Option<(NodeId, bool, Option<std::path::PathBuf>)> {
        let ScanState::Ready(browse) = &self.state else {
            return None;
        };
        let id = browse.hovered?;
        let path = (id != NodeId::ROOT)
            .then(|| browse.tree.path_of(id))
            .flatten();
        Some((id, browse.tree.node(id).is_container(), path))
    }
}

/// Follows chains of folders that contain nothing but one folder (like
/// `Foo.app/Contents`), so nested tiles show what is actually inside.
fn skip_single_folders(tree: &FileTree, mut id: NodeId) -> NodeId {
    while let [only] = tree.node(id).children[..] {
        if !tree.node(only).is_container() {
            break;
        }
        id = only;
    }
    id
}

fn layout(tree: &FileTree, children: &[NodeId], bounds: Rect) -> Vec<Rect> {
    let weights: Vec<f64> = children
        .iter()
        .map(|c| tree.node(*c).size.get() as f64)
        .collect();
    squarify(&weights, bounds)
}

/// Name and size; the size moves beside the name on wide tiles.
fn label(
    name: String,
    size: crate::units::Bytes,
    width: f32,
    cx: &Context<StoragePage>,
) -> gpui_kit::Div {
    let theme = cx.theme();
    div()
        .flex()
        .gap_x_2()
        .items_center()
        .text_xs()
        .overflow_hidden()
        .child(
            div()
                .min_w_0()
                .truncate()
                .font_weight(FontWeight::MEDIUM)
                .text_color(theme.foreground)
                .child(name),
        )
        .when(width >= LABEL_MIN_W, |row| {
            row.child(
                div()
                    .flex_shrink_0()
                    .text_color(theme.muted_foreground)
                    .child(size.decimal().to_string()),
            )
        })
}
