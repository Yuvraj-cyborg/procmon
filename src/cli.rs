use std::path::PathBuf;

use crate::app::Page;
use crate::units::Pid;

const USAGE: &str = "\
Usage: procmon [OPTIONS]

Options:
  --page <name>      Open on a page: memory, activity, storage, devices,
                     graphics or recovery
  --scan <path>      Open Storage and start scanning <path>
  --recover <path>   Open Recovery and search a disk (e.g. /dev/sdb) or a
                     disk image for deleted files
  --inspect <pid>    Open the detail sheet for a process
  -h, --help         Print this help";

#[derive(Debug, Default)]
pub struct LaunchOptions {
    page: Option<Page>,
    pub scan: Option<PathBuf>,
    pub recover: Option<PathBuf>,
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
                ("--recover", Some(path)) => options.recover = Some(PathBuf::from(path)),
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
        match (self.page, &self.scan, &self.recover, self.inspect) {
            (Some(page), ..) => page,
            (None, Some(_), ..) => Page::Storage,
            (None, None, Some(_), _) => Page::Recovery,
            (None, None, None, Some(_)) => Page::Activity,
            (None, None, None, None) => Page::Memory,
        }
    }
}
