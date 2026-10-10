//! Small pictures of found photos, decoded with the image codecs the app
//! already carries. HEIC, raw files, videos and documents get an icon instead.

use image::{ImageFormat, RgbaImage};

use super::found::{Format, FoundFile, Timestamp};
use super::reader::ByteSource;

/// Photos larger than this are not decoded whole just for a thumbnail.
const DECODE_LIMIT: u64 = 40 << 20;

pub struct Preview {
    /// Pixels in BGRA order, as GPUI draws them.
    pub image: RgbaImage,
    pub pixels: Option<(u32, u32)>,
    /// When a camera took it, from EXIF.
    pub date: Option<Timestamp>,
}

pub fn has_preview(format: Option<Format>) -> bool {
    image_format(format).is_some()
}

fn image_format(format: Option<Format>) -> Option<ImageFormat> {
    Some(match format? {
        Format::Jpeg => ImageFormat::Jpeg,
        Format::Png => ImageFormat::Png,
        Format::Gif => ImageFormat::Gif,
        Format::Bmp => ImageFormat::Bmp,
        Format::Webp => ImageFormat::WebP,
        Format::Tiff => ImageFormat::Tiff,
        _ => return None,
    })
}

/// A picture of `file` at most `side` pixels on its longer side.
pub fn thumbnail(file: &FoundFile, source: &dyn ByteSource, side: u32) -> Option<Preview> {
    let format = image_format(file.format)?;
    // A JPEG's EXIF block usually carries a small copy of the photo, which
    // spares decoding every megapixel.
    let head = read(file, source, 0, 128 * 1024)?;
    let exif = (format == ImageFormat::Jpeg).then(|| exif(&head)).flatten().unwrap_or_default();
    if side <= 320
        && let Some(small) = &exif.thumbnail
        && let Ok(decoded) = image::load_from_memory_with_format(small, ImageFormat::Jpeg)
    {
        return Some(Preview {
            image: bgra(decoded.thumbnail(side, side).to_rgba8()),
            pixels: file.details.pixels,
            date: exif.date,
        });
    }
    if file.size().0 > DECODE_LIMIT {
        return None;
    }
    let bytes = read(file, source, 0, file.size().0 as usize)?;
    let decoded = image::load_from_memory_with_format(&bytes, format).ok()?;
    Some(Preview {
        pixels: Some((decoded.width(), decoded.height())),
        image: bgra(decoded.thumbnail(side, side).to_rgba8()),
        date: exif.date,
    })
}

/// `count` bytes from `position` within the file, across its extents.
/// Unreadable stretches read as zeros: a partly damaged photo still shows.
pub fn read(file: &FoundFile, source: &dyn ByteSource, position: u64, count: usize) -> Option<Vec<u8>> {
    let total = file.size().0;
    if position >= total {
        return None;
    }
    let count = count.min((total - position) as usize);
    let mut bytes = vec![0u8; count];
    let mut done = 0usize;
    let mut logical = 0u64;
    for extent in &file.extents {
        let wanted = position + done as u64;
        if done == count {
            break;
        }
        if wanted < logical + extent.length && wanted >= logical {
            let within = wanted - logical;
            let take = (count - done).min((extent.length - within) as usize);
            let slice = &mut bytes[done..done + take];
            let got = source.read_at(slice, extent.offset + within).unwrap_or(take);
            done += got;
            if got < take {
                break;
            }
        }
        logical += extent.length;
    }
    bytes.truncate(done);
    Some(bytes)
}

fn bgra(mut image: RgbaImage) -> RgbaImage {
    for pixel in image.pixels_mut() {
        pixel.0.swap(0, 2);
    }
    image
}

#[derive(Default)]
struct Exif {
    thumbnail: Option<Vec<u8>>,
    date: Option<Timestamp>,
}

/// The EXIF block in a JPEG's APP1 segment.
fn exif(jpeg: &[u8]) -> Option<Exif> {
    let mut position = 2;
    while position + 4 <= jpeg.len() && jpeg[position] == 0xFF {
        let marker = jpeg[position + 1];
        if matches!(marker, 0xDA | 0xD9) {
            break;
        }
        let length = usize::from(u16::from_be_bytes([jpeg[position + 2], jpeg[position + 3]]));
        if marker == 0xE1 && jpeg.get(position + 4..position + 10) == Some(b"Exif\0\0") {
            return parse_exif(jpeg.get(position + 10..position + 2 + length)?);
        }
        position += 2 + length;
    }
    None
}

/// EXIF is a small TIFF: the date sits in the EXIF sub-directory, the
/// thumbnail's offset and length in the second directory.
fn parse_exif(tiff: &[u8]) -> Option<Exif> {
    let little = match tiff.get(0..2)? {
        b"II" => true,
        b"MM" => false,
        _ => return None,
    };
    let u16_at = |offset: usize| -> Option<usize> {
        let bytes = [*tiff.get(offset)?, *tiff.get(offset + 1)?];
        Some(usize::from(if little { u16::from_le_bytes(bytes) } else { u16::from_be_bytes(bytes) }))
    };
    let u32_at = |offset: usize| -> Option<usize> {
        let bytes: [u8; 4] = tiff.get(offset..offset + 4)?.try_into().ok()?;
        Some((if little { u32::from_le_bytes(bytes) } else { u32::from_be_bytes(bytes) }) as usize)
    };
    // Tag value (offset field) for `tag` in the directory at `directory`.
    let find = |directory: usize, tag: usize| -> Option<(usize, usize)> {
        let count = u16_at(directory)?;
        (0..count.min(512)).find_map(|index| {
            let entry = directory + 2 + index * 12;
            (u16_at(entry)? == tag).then(|| Some((u32_at(entry + 4)?, u32_at(entry + 8)?))).flatten()
        })
    };
    let first = u32_at(4)?;
    let mut exif = Exif::default();
    if let Some((_, sub)) = find(first, 0x8769)
        && let Some((count, offset)) = find(sub, 0x9003)
        && let Some(text) = tiff.get(offset..offset + count.min(20))
    {
        exif.date = exif_date(&String::from_utf8_lossy(text));
    }
    let count = u16_at(first)?;
    let second = u32_at(first + 2 + count * 12)?;
    if second != 0
        && let (Some((_, offset)), Some((_, length))) = (find(second, 0x201), find(second, 0x202))
    {
        exif.thumbnail = tiff.get(offset..offset + length).map(<[u8]>::to_vec);
    }
    Some(exif)
}

/// EXIF writes dates as `2024:07:14 18:22:31`, in the camera's local time.
fn exif_date(text: &str) -> Option<Timestamp> {
    let numbers: Vec<u16> = text
        .split([':', ' '])
        .filter_map(|part| part.trim_matches('\0').parse().ok())
        .collect();
    let [year, month, day, hour, minute, second] = numbers[..] else { return None };
    Timestamp::new(year, month as u8, day as u8, hour as u8, minute as u8, second as u8)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_exif_dates() {
        assert_eq!(exif_date("2024:07:14 18:22:31"), Timestamp::new(2024, 7, 14, 18, 22, 31));
        assert_eq!(exif_date("    :  :     :  :  "), None);
    }
}
