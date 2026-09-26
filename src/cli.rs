use std::path::PathBuf;

use crate::app::Page;

/// Command-line options: `--page <name>` and `--scan <path>`.
#[derive(Debug, Default)]
pub struct LaunchOptions {
    page: Option<Page>,
    pub scan: Option<PathBuf>,
}

impl LaunchOptions {
    pub fn from_args() -> Self {
        let mut options = Self::default();
        let mut args = std::env::args().skip(1);
        while let Some(arg) = args.next() {
            match (arg.as_str(), args.next()) {
                ("--page", Some(name)) => match name.parse() {
                    Ok(page) => options.page = Some(page),
                    Err(err) => eprintln!("procmon: {err}"),
                },
                ("--scan", Some(path)) => options.scan = Some(PathBuf::from(path)),
                (flag, _) => eprintln!("procmon: ignoring unexpected argument `{flag}`"),
            }
        }
        options
    }

    pub fn initial_page(&self) -> Page {
        match (self.page, &self.scan) {
            (Some(page), _) => page,
            (None, Some(_)) => Page::Storage,
            (None, None) => Page::Memory,
        }
    }
}
