//! Small presentational building blocks shared by every page.

use gpui_kit::component::{ActiveTheme, h_flex, v_flex};
use gpui_kit::{
    AnyElement, App, FontWeight, Hsla, IntoElement, ParentElement, RenderOnce, SharedString, Styled, Window,
    div, prelude::FluentBuilder as _, px, relative,
};

use crate::units::Ratio;

/// Page title + subtitle with optional trailing actions, Notion-style.
#[derive(IntoElement)]
pub struct PageHeader {
    title: SharedString,
    subtitle: SharedString,
    actions: Vec<AnyElement>,
}

impl PageHeader {
    pub fn new(title: impl Into<SharedString>, subtitle: impl Into<SharedString>) -> Self {
        Self {
            title: title.into(),
            subtitle: subtitle.into(),
            actions: Vec::new(),
        }
    }

    pub fn action(mut self, action: impl IntoElement) -> Self {
        self.actions.push(action.into_any_element());
        self
    }
}

impl RenderOnce for PageHeader {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        h_flex()
            .w_full()
            .items_end()
            .justify_between()
            .gap_4()
            .flex_wrap()
            .child(
                v_flex()
                    .gap_1()
                    .child(div().text_2xl().font_weight(FontWeight::SEMIBOLD).child(self.title))
                    .child(
                        div()
                            .text_sm()
                            .text_color(cx.theme().muted_foreground)
                            .child(self.subtitle),
                    ),
            )
            .child(h_flex().gap_2().children(self.actions))
    }
}

/// A bordered surface used to group related content.
#[derive(IntoElement)]
pub struct Card {
    title: Option<SharedString>,
    trailing: Option<AnyElement>,
    children: Vec<AnyElement>,
    grow: bool,
}

impl Card {
    pub fn new() -> Self {
        Self {
            title: None,
            trailing: None,
            children: Vec::new(),
            grow: false,
        }
    }

    pub fn title(mut self, title: impl Into<SharedString>) -> Self {
        self.title = Some(title.into());
        self
    }

    pub fn trailing(mut self, trailing: impl IntoElement) -> Self {
        self.trailing = Some(trailing.into_any_element());
        self
    }

    /// Let the card fill remaining space in a flex column.
    pub fn grow(mut self) -> Self {
        self.grow = true;
        self
    }
}

impl ParentElement for Card {
    fn extend(&mut self, elements: impl IntoIterator<Item = AnyElement>) {
        self.children.extend(elements);
    }
}

impl RenderOnce for Card {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.theme();
        v_flex()
            .min_w_0()
            .gap_3()
            .p_4()
            .rounded(theme.radius_lg)
            .border_1()
            .border_color(theme.border)
            .bg(theme.background)
            .when(self.grow, |this| this.flex_1().min_h_0())
            .when(self.title.is_some() || self.trailing.is_some(), |this| {
                this.child(
                    h_flex()
                        .justify_between()
                        .gap_2()
                        .children(self.title.map(|title| {
                            div()
                                .text_sm()
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(theme.muted_foreground)
                                .child(title)
                        }))
                        .children(self.trailing),
                )
            })
            .children(self.children)
    }
}

/// A headline number with a caption, e.g. "12.4 GB / used".
#[derive(IntoElement)]
pub struct Stat {
    label: SharedString,
    value: SharedString,
    hint: Option<SharedString>,
    dot: Option<Hsla>,
}

impl Stat {
    pub fn new(label: impl Into<SharedString>, value: impl Into<SharedString>) -> Self {
        Self {
            label: label.into(),
            value: value.into(),
            hint: None,
            dot: None,
        }
    }

    pub fn hint(mut self, hint: impl Into<SharedString>) -> Self {
        self.hint = Some(hint.into());
        self
    }

    pub fn dot(mut self, color: Hsla) -> Self {
        self.dot = Some(color);
        self
    }
}

impl RenderOnce for Stat {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let muted = cx.theme().muted_foreground;
        v_flex()
            .min_w(px(96.))
            .gap_0p5()
            .child(
                h_flex()
                    .gap_1p5()
                    .text_xs()
                    .text_color(muted)
                    .children(self.dot.map(|c| div().size_2().rounded_full().bg(c)))
                    .child(self.label),
            )
            .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).child(self.value))
            .children(
                self.hint
                    .map(|hint| div().text_xs().text_color(muted).child(hint)),
            )
    }
}

/// One coloured slice of a [`Meter`].
pub struct Segment {
    pub ratio: Ratio,
    pub color: Hsla,
}

/// A thin horizontal bar made of stacked segments; scales with its container.
#[derive(IntoElement)]
pub struct Meter {
    segments: Vec<Segment>,
    height: gpui_kit::Pixels,
}

impl Meter {
    pub fn new(segments: impl IntoIterator<Item = Segment>) -> Self {
        Self {
            segments: segments.into_iter().collect(),
            height: px(8.),
        }
    }

    pub fn single(ratio: Ratio, color: Hsla) -> Self {
        Self::new([Segment { ratio, color }])
    }

    pub fn height(mut self, height: gpui_kit::Pixels) -> Self {
        self.height = height;
        self
    }
}

impl RenderOnce for Meter {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        h_flex()
            .w_full()
            .h(self.height)
            .rounded_full()
            .overflow_hidden()
            .bg(cx.theme().muted)
            .children(
                self.segments
                    .into_iter()
                    .filter(|s| s.ratio.get() > 0.0)
                    .map(|s| div().h_full().w(relative(s.ratio.as_f32())).bg(s.color)),
            )
    }
}
