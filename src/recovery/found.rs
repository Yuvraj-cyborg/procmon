//! What recovery finds: files recognised by their contents or listed as
//! deleted in a directory, and where their bytes lie on the disk.

use std::fmt;
use std::time::Duration;

use crate::units::Bytes;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Kind {
    Photo,
    Video,
    Audio,
    Document,
    Other,
}

impl Kind {
    pub const ALL: [Kind; 5] = [Kind::Photo, Kind::Video, Kind::Audio, Kind::Document, Kind::Other];

    pub fn label(self) -> &'static str {
        match self {
            Kind::Photo => "Photos",
            Kind::Video => "Videos",
            Kind::Audio => "Audio",
            Kind::Document => "Documents",
            Kind::Other => "Other",
        }
    }

    /// "photo", "video", … for counts.
    pub fn noun(self) -> &'static str {
        match self {
            Kind::Photo => "photo",
            Kind::Video => "video",
            Kind::Audio => "audio file",
            Kind::Document => "document",
            Kind::Other => "other file",
        }
    }

    /// The kind a file name suggests, for directory entries.
    pub fn guess(name: &str) -> Kind {
        let ext = extension(name);
        if let Some(format) = Format::ALL.iter().find(|f| f.extensions().contains(&ext.as_str())) {
            return format.kind();
        }
        match ext.as_str() {
            "svg" | "psd" | "raw" | "ico" => Kind::Photo,
            "wmv" | "flv" | "mpg" | "mpeg" | "mts" | "m2ts" => Kind::Video,
            "flac" | "aac" | "ogg" | "aiff" | "aif" | "wma" | "opus" => Kind::Audio,
            "doc" | "xls" | "ppt" | "txt" | "rtf" | "odt" | "ods" | "odp" | "pages" | "numbers"
            | "key" | "csv" | "md" => Kind::Document,
            _ => Kind::Other,
        }
    }
}

/// Lowercased extension of a file name, without the dot.
pub fn extension(name: &str) -> String {
    name.rsplit_once('.')
        .map(|(_, ext)| ext.to_ascii_lowercase())
        .unwrap_or_default()
}

/// A format the carver can recognise and measure from its bytes alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Format {
    Jpeg,
    Png,
    Gif,
    Bmp,
    Webp,
    Heic,
    Avif,
    Tiff,
    Cr2,
    Cr3,
    Nef,
    Arw,
    Dng,
    Orf,
    Pef,
    Raf,
    Mp4,
    Mov,
    M4v,
    ThreeGp,
    Avi,
    Mkv,
    Webm,
    M4a,
    Mp3,
    Wav,
    Pdf,
    Docx,
    Xlsx,
    Pptx,
    Epub,
    Zip,
}

impl Format {
    pub const ALL: [Format; 32] = [
        Format::Jpeg,
        Format::Png,
        Format::Gif,
        Format::Bmp,
        Format::Webp,
        Format::Heic,
        Format::Avif,
        Format::Tiff,
        Format::Cr2,
        Format::Cr3,
        Format::Nef,
        Format::Arw,
        Format::Dng,
        Format::Orf,
        Format::Pef,
        Format::Raf,
        Format::Mp4,
        Format::Mov,
        Format::M4v,
        Format::ThreeGp,
        Format::Avi,
        Format::Mkv,
        Format::Webm,
        Format::M4a,
        Format::Mp3,
        Format::Wav,
        Format::Pdf,
        Format::Docx,
        Format::Xlsx,
        Format::Pptx,
        Format::Epub,
        Format::Zip,
    ];

    pub fn kind(self) -> Kind {
        use Format::*;
        match self {
            Jpeg | Png | Gif | Bmp | Webp | Heic | Avif | Tiff | Cr2 | Cr3 | Nef | Arw | Dng
            | Orf | Pef | Raf => Kind::Photo,
            Mp4 | Mov | M4v | ThreeGp | Avi | Mkv | Webm => Kind::Video,
            M4a | Mp3 | Wav => Kind::Audio,
            Pdf | Docx | Xlsx | Pptx | Epub | Zip => Kind::Document,
        }
    }

    pub fn extension(self) -> &'static str {
        self.extensions()[0]
    }

    /// Extensions a directory entry of this format may carry; the first is
    /// the one recovered copies get.
    pub fn extensions(self) -> &'static [&'static str] {
        use Format::*;
        match self {
            Jpeg => &["jpg", "jpeg", "jpe", "thm"],
            Png => &["png"],
            Gif => &["gif"],
            Bmp => &["bmp"],
            Webp => &["webp"],
            Heic => &["heic", "heif", "hif"],
            Avif => &["avif"],
            Tiff => &["tif", "tiff"],
            Cr2 => &["cr2"],
            Cr3 => &["cr3"],
            Nef => &["nef"],
            Arw => &["arw"],
            Dng => &["dng"],
            Orf => &["orf"],
            Pef => &["pef"],
            Raf => &["raf"],
            Mp4 => &["mp4"],
            Mov => &["mov"],
            M4v => &["m4v"],
            ThreeGp => &["3gp", "3g2"],
            Avi => &["avi"],
            Mkv => &["mkv", "mka"],
            Webm => &["webm"],
            M4a => &["m4a"],
            Mp3 => &["mp3"],
            Wav => &["wav"],
            Pdf => &["pdf"],
            Docx => &["docx"],
            Xlsx => &["xlsx"],
            Pptx => &["pptx"],
            Epub => &["epub"],
            Zip => &["zip"],
        }
    }

    pub fn label(self) -> &'static str {
        use Format::*;
        match self {
            Jpeg => "JPEG",
            Png => "PNG",
            Gif => "GIF",
            Bmp => "BMP",
            Webp => "WebP",
            Heic => "HEIC",
            Avif => "AVIF",
            Tiff => "TIFF",
            Cr2 | Cr3 => "Canon raw",
            Nef => "Nikon raw",
            Arw => "Sony raw",
            Dng => "DNG raw",
            Orf => "Olympus raw",
            Pef => "Pentax raw",
            Raf => "Fujifilm raw",
            Mp4 => "MP4",
            Mov => "QuickTime",
            M4v => "M4V",
            ThreeGp => "3GP",
            Avi => "AVI",
            Mkv => "Matroska",
            Webm => "WebM",
            M4a => "AAC audio",
            Mp3 => "MP3",
            Wav => "WAV",
            Pdf => "PDF",
            Docx => "Word",
            Xlsx => "Excel",
            Pptx => "PowerPoint",
            Epub => "EPUB",
            Zip => "ZIP archive",
        }
    }

    /// The format a file name suggests.
    pub fn for_name(name: &str) -> Option<Format> {
        let ext = extension(name);
        Format::ALL
            .into_iter()
            .find(|format| format.extensions().contains(&ext.as_str()))
    }
}

/// A run of bytes on the source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Extent {
    pub offset: u64,
    pub length: u64,
}

impl Extent {
    pub fn end(self) -> u64 {
        self.offset + self.length
    }
}

/// A calendar date and time as a camera or file system wrote it, in
/// whatever local time that device kept.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Timestamp {
    pub year: u16,
    pub month: u8,
    pub day: u8,
    pub hour: u8,
    pub minute: u8,
    pub second: u8,
}

impl Timestamp {
    pub fn new(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) -> Option<Self> {
        ((1..=12).contains(&month)
            && (1..=31).contains(&day)
            && hour < 24
            && minute < 60
            && second < 61)
            .then_some(Self {
                year,
                month,
                day,
                hour,
                minute,
                second,
            })
    }

    /// Seconds since 1970 in UTC, as a calendar date.
    pub fn from_unix(seconds: i64) -> Self {
        let days = seconds.div_euclid(86_400);
        let rest = seconds.rem_euclid(86_400);
        // Howard Hinnant's civil-from-days.
        let z = days + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z.rem_euclid(146_097);
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let day = doy - (153 * mp + 2) / 5 + 1;
        let month = if mp < 10 { mp + 3 } else { mp - 9 };
        let year = yoe + era * 400 + i64::from(month <= 2);
        Self {
            year: year.clamp(0, 9999) as u16,
            month: month as u8,
            day: day as u8,
            hour: (rest / 3600) as u8,
            minute: (rest / 60 % 60) as u8,
            second: (rest % 60) as u8,
        }
    }

    /// Seconds since 1970 if this were UTC.
    pub fn as_unix(self) -> i64 {
        let (year, month) = (i64::from(self.year), i64::from(self.month));
        let year = if month <= 2 { year - 1 } else { year };
        let era = year.div_euclid(400);
        let yoe = year.rem_euclid(400);
        let mp = (month + 9) % 12;
        let doy = (153 * mp + 2) / 5 + i64::from(self.day) - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        let days = era * 146_097 + doe - 719_468;
        days * 86_400
            + i64::from(self.hour) * 3600
            + i64::from(self.minute) * 60
            + i64::from(self.second)
    }
}

impl fmt::Display for Timestamp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{:04}-{:02}-{:02} {:02}:{:02}",
            self.year, self.month, self.day, self.hour, self.minute
        )
    }
}

/// Facts a parser or a preview learned about a file's contents.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Details {
    pub pixels: Option<(u32, u32)>,
    pub duration: Option<Duration>,
}

impl Details {
    pub fn summary(&self) -> Option<String> {
        let mut parts = Vec::new();
        if let Some((width, height)) = self.pixels.filter(|(w, h)| *w > 0 && *h > 0) {
            parts.push(format!("{width}×{height}"));
        }
        if let Some(duration) = self.duration.filter(|d| !d.is_zero()) {
            parts.push(media_length(duration));
        }
        (!parts.is_empty()).then(|| parts.join(" · "))
    }
}

/// Video and audio lengths, e.g. `0:42`, `1:02:05`.
pub fn media_length(duration: Duration) -> String {
    let total = duration.as_secs_f64().round() as u64;
    let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60);
    if hours > 0 {
        format!("{hours}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes}:{seconds:02}")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Origin {
    /// Recognised by its contents, wherever it lay.
    Contents,
    /// Listed as deleted in a FAT or exFAT directory, with its old name.
    Directory,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Condition {
    Good,
    /// Its structure broke off or never closed: it may be cut short.
    Damaged,
    /// Its space was reused after it was deleted, so little of it is left.
    Overwritten,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FoundFile {
    pub id: usize,
    /// `None` for a deleted directory entry whose contents are not a known format.
    pub format: Option<Format>,
    pub kind: Kind,
    pub extents: Vec<Extent>,
    /// The name it had, when a directory still remembers it.
    pub name: Option<String>,
    /// Where it was, from the root of its volume.
    pub folder: Option<String>,
    pub date: Option<Timestamp>,
    pub condition: Condition,
    pub details: Details,
    pub origin: Origin,
}

impl FoundFile {
    pub fn offset(&self) -> u64 {
        self.extents.first().map_or(0, |e| e.offset)
    }

    pub fn size(&self) -> Bytes {
        Bytes(self.extents.iter().map(|e| e.length).sum())
    }

    pub fn file_extension(&self) -> String {
        let named = self.name.as_deref().map(extension).unwrap_or_default();
        if named.is_empty() {
            self.format.map_or("bin", Format::extension).to_string()
        } else {
            named
        }
    }

    /// A name for the recovered copy: the old one, else the kind and a number.
    pub fn display_name(&self) -> String {
        if let Some(name) = self.name.as_ref().filter(|n| !n.is_empty()) {
            return name.clone();
        }
        let noun = match self.kind {
            Kind::Photo => "Photo",
            Kind::Video => "Video",
            Kind::Audio => "Audio",
            Kind::Document => "Document",
            Kind::Other => "File",
        };
        format!("{noun} {:05}.{}", self.id, self.file_extension())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unix_dates_round_trip() {
        let date = Timestamp::from_unix(1_721_000_000);
        assert_eq!(date, Timestamp::new(2024, 7, 14, 23, 33, 20).unwrap());
        assert_eq!(date.as_unix(), 1_721_000_000);
        assert_eq!(Timestamp::from_unix(0).to_string(), "1970-01-01 00:00");
    }

    #[test]
    fn names_fall_back_to_kind_and_number() {
        let mut file = FoundFile {
            id: 42,
            format: Some(Format::Jpeg),
            kind: Kind::Photo,
            extents: vec![Extent { offset: 512, length: 100 }],
            name: None,
            folder: None,
            date: None,
            condition: Condition::Good,
            details: Details::default(),
            origin: Origin::Contents,
        };
        assert_eq!(file.display_name(), "Photo 00042.jpg");
        file.name = Some("IMG_0001.JPG".into());
        assert_eq!(file.display_name(), "IMG_0001.JPG");
        assert_eq!(file.size(), Bytes(100));
    }

    #[test]
    fn kinds_come_from_names() {
        assert_eq!(Kind::guess("holiday.HEIC"), Kind::Photo);
        assert_eq!(Kind::guess("notes.txt"), Kind::Document);
        assert_eq!(Kind::guess("mystery"), Kind::Other);
        assert_eq!(Format::for_name("clip.MOV"), Some(Format::Mov));
    }
}
