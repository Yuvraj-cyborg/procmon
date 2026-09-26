use std::path::PathBuf;

use crate::app::Page;
use crate::units::Pid;

const USAGE: &str = "\
Usage: procmon [OPTIONS]

Options:
  --page <name>    Open on a page: memory, activity, storage or devices
  --scan <path>    Open Storage and start scanning <path>
  --inspect <pid>  Open the detail sheet for a process
  -h, --help       Print this help";

#[derive(Debug, Default)]
pub struct LaunchOptions {
    page: Option<Page>,
    pub scan: Option<PathBuf>,
    pub inspect: Option<Pid>,
}

impl LaunchOptions {
    pub fn from_args() -> Self {
        let mut options = Self::default();
        let mut args = std::env::args().skip(1);
        while let Some(arg) = args.next() {
            if matches!(arg.as_str(), "-h" | "--help") {
                println!("{USAGE}");
                std::process::exit(0);
            }
            match (arg.as_str(), args.next()) {
                ("--page", Some(name)) => match name.parse() {
                    Ok(page) => options.page = Some(page),
                    Err(err) => eprintln!("procmon: {err}"),
                },
                ("--scan", Some(path)) => options.scan = Some(PathBuf::from(path)),
                ("--inspect", Some(pid)) => match pid.parse() {
                    Ok(pid) => options.inspect = Some(Pid(pid)),
                    Err(_) => eprintln!("procmon: `{pid}` is not a process id"),
                },
                (flag, _) => eprintln!("procmon: ignoring unexpected argument `{flag}`\n\n{USAGE}"),
            }
        }
        options
    }

    pub fn initial_page(&self) -> Page {
        match (self.page, &self.scan, self.inspect) {
            (Some(page), _, _) => page,
            (None, Some(_), _) => Page::Storage,
            (None, None, Some(_)) => Page::Activity,
            (None, None, None) => Page::Memory,
        }
    }
}
