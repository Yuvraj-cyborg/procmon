use gpui_kit::component::v_flex;
use gpui_kit::{Context, IntoElement, ParentElement, Render, Styled, Window};

use crate::app::Page;
use crate::ui::widgets::PageHeader;

/// Stand-in view for pages that are not implemented yet.
pub struct Placeholder {
    page: Page,
}

impl Placeholder {
    pub fn new(page: Page) -> Self {
        Self { page }
    }
}

impl Render for Placeholder {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .size_full()
            .p_8()
            .child(PageHeader::new(self.page.title(), self.page.subtitle()))
    }
}
