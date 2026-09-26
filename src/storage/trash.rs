use std::path::Path;

/// Moves `path` to the user's Trash, where Finder can put it back.
#[cfg(target_os = "macos")]
pub fn move_to_trash(path: &Path) -> Result<(), String> {
    use objc2_foundation::{NSFileManager, NSString, NSURL};

    let path = path
        .to_str()
        .ok_or_else(|| "the path is not valid UTF-8".to_string())?;
    let url = NSURL::fileURLWithPath(&NSString::from_str(path));
    NSFileManager::defaultManager()
        .trashItemAtURL_resultingItemURL_error(&url, None)
        .map_err(|err| err.localizedDescription().to_string())
}

#[cfg(not(target_os = "macos"))]
pub fn move_to_trash(_path: &Path) -> Result<(), String> {
    Err("moving to the Trash is only supported on macOS so far".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Leaves a file in the real Trash, so it only runs on request:
    /// `cargo test trashes_a_file -- --ignored`
    #[test]
    #[ignore]
    fn trashes_a_file() {
        let path = std::env::temp_dir().join(format!("procmon-trash-{}.txt", std::process::id()));
        std::fs::write(&path, b"bye").unwrap();
        move_to_trash(&path).unwrap();
        assert!(!path.exists());
    }
}
