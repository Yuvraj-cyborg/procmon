//! Navigation and file actions over a finished scan.

use std::sync::Arc;

use gpui_kit::component::WindowExt;
use gpui_kit::component::button::ButtonVariant;
use gpui_kit::component::dialog::DialogButtonProps;
use gpui_kit::component::notification::Notification;
use gpui_kit::{Context, Window};

use super::{ScanState, StoragePage};
use crate::storage::{self, FileTree, NodeId};

/// How many files the "Largest files" view lists.
const LARGEST_LIMIT: usize = 100;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum BrowseMode {
    Map,
    LargestFiles,
}

pub(super) struct Browse {
    pub tree: Arc<FileTree>,
    /// Folder shown in the treemap.
    pub current: NodeId,
    pub hovered: Option<NodeId>,
    /// File or folder that the footer actions apply to.
    pub selected: Option<NodeId>,
    pub mode: BrowseMode,
    pub largest: Vec<NodeId>,
}

impl Browse {
    pub fn new(tree: FileTree) -> Self {
        let largest = tree.largest_files(LARGEST_LIMIT);
        Self {
            tree: Arc::new(tree),
            current: NodeId::ROOT,
            hovered: None,
            selected: None,
            mode: BrowseMode::Map,
            largest,
        }
    }

    /// The node the footer actions act on: the selection, else the open folder.
    pub fn target(&self) -> NodeId {
        self.selected.unwrap_or(self.current)
    }
}

impl StoragePage {
    fn browse_mut(&mut self) -> Option<&mut Browse> {
        match &mut self.state {
            ScanState::Ready(browse) => Some(browse),
            _ => None,
        }
    }

    /// Shows `node` in the map: folders are opened, files are selected
    /// inside their folder.
    pub(super) fn focus_node(&mut self, node: NodeId, cx: &mut Context<Self>) {
        let Some(browse) = self.browse_mut() else {
            return;
        };
        let target = browse.tree.node(node);
        if target.is_container() {
            browse.current = node;
            browse.selected = None;
        } else {
            browse.current = target.parent.unwrap_or(NodeId::ROOT);
            browse.selected = Some(node);
        }
        browse.hovered = None;
        browse.mode = BrowseMode::Map;
        cx.notify();
    }

    pub(super) fn hover(&mut self, node: Option<NodeId>, cx: &mut Context<Self>) {
        if let Some(browse) = self.browse_mut()
            && browse.hovered != node
        {
            browse.hovered = node;
            cx.notify();
        }
    }

    pub(super) fn set_mode(&mut self, mode: BrowseMode, cx: &mut Context<Self>) {
        if let Some(browse) = self.browse_mut() {
            browse.mode = mode;
            cx.notify();
        }
    }

    /// Asks for confirmation, then moves `node` to the Trash.
    pub(super) fn confirm_trash(
        &mut self,
        node: NodeId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(browse) = self.browse_mut() else {
            return;
        };
        if node == NodeId::ROOT {
            return;
        }
        let Some(path) = browse.tree.path_of(node) else {
            return;
        };
        let item = browse.tree.node(node);
        let (name, size) = (item.name.to_string(), item.size);
        let view = cx.entity().downgrade();
        window.open_alert_dialog(cx, move |dialog, _, _| {
            let (path, name, view) = (path.clone(), name.clone(), view.clone());
            dialog
                .title(format!("Move “{name}” to the Trash?"))
                .description(format!(
                    "{} will be freed once you empty the Trash. You can put it back from Finder until then.",
                    size.decimal()
                ))
                .button_props(
                    DialogButtonProps::default()
                        .ok_text("Move to Trash")
                        .ok_variant(ButtonVariant::Danger)
                        .show_cancel(true),
                )
                .on_ok(move |_, window, cx| {
                    match storage::move_to_trash(&path) {
                        Ok(()) => {
                            view.update(cx, |this, cx| this.forget(node, cx)).ok();
                            window.push_notification(
                                Notification::success(format!("Moved {name} to the Trash.")),
                                cx,
                            );
                        }
                        Err(err) => window.push_notification(
                            Notification::error(format!("Couldn't move {name} to the Trash: {err}")),
                            cx,
                        ),
                    }
                    true
                })
        });
    }

    /// Drops a node that no longer exists on disk from the scan results.
    fn forget(&mut self, node: NodeId, cx: &mut Context<Self>) {
        let Some(browse) = self.browse_mut() else {
            return;
        };
        let parent = browse.tree.node(node).parent.unwrap_or(NodeId::ROOT);
        if browse.tree.lineage(browse.current).contains(&node) {
            browse.current = parent;
        }
        browse.selected = None;
        browse.hovered = None;
        let tree = Arc::make_mut(&mut browse.tree);
        tree.remove(node);
        browse.largest = tree.largest_files(LARGEST_LIMIT);
        self.volumes = storage::list_volumes();
        cx.notify();
    }
}
