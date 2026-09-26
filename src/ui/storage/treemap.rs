use std::sync::Arc;

use gpui_kit::component::ActiveTheme;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement, IntoElement, ParentElement,
    StatefulInteractiveElement, Styled, canvas, div, prelude::FluentBuilder as _, px, size,
};

use super::{StoragePage, category_tint};
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

        div()
            .relative()
            .size_full()
            .child(measure)
            .children(
                children
                    .into_iter()
                    .zip(rects)
                    .filter(|(_, r)| r.w >= 1.0 && r.h >= 1.0)
                    .map(|(id, rect)| self.render_tile(tree, id, rect, cx)),
            )
            .into_any_element()
    }

    fn render_tile(
        &self,
        tree: &Arc<FileTree>,
        id: NodeId,
        rect: Rect,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = cx.theme();
        let dark = theme.is_dark();
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
                .on_click(cx.listener(move |this, _, _, cx| this.navigate(id, cx)));

        if nested {
            let inner = Rect::new(GAP, HEADER, r.w - 2.0 * GAP, r.h - HEADER - GAP);
            let children: Vec<NodeId> = node.children.iter().copied().take(MAX_SUBTILES).collect();
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
                    .map(|(child, rect)| self.render_subtile(tree, id, child, rect, cx)),
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

    /// A tile inside a nested folder. Clicking opens the child if it is a
    /// folder, otherwise the folder that contains it.
    fn render_subtile(
        &self,
        tree: &Arc<FileTree>,
        parent: NodeId,
        id: NodeId,
        rect: Rect,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = cx.theme();
        let node = tree.node(id);
        let r = rect.inset(GAP / 2.0);
        let target = if node.is_container() { id } else { parent };
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
            .on_click(cx.listener(move |this, _, _, cx| {
                cx.stop_propagation();
                this.navigate(target, cx)
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
