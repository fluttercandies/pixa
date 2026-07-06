use crate::image_format::{sniff_image_format, wbmp_dimensions, RuntimeImageFormat};
use crate::{RuntimeError, RuntimeResult};
use std::io::Read;

/// Encoded image format identified by the lightweight metadata parser.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ImageMetadataFormat {
    Jpeg,
    Png,
    Gif,
    Webp,
    Bmp,
    Wbmp,
    Ico,
    Tiff,
    Pnm,
    Qoi,
    Tga,
    Dds,
    Hdr,
    Farbfeld,
    Pcx,
    Sgi,
    Xbm,
    Xpm,
}

/// Image metadata parsed from encoded headers without full pixel decode.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ImageMetadata {
    pub width: u32,
    pub height: u32,
    pub format: ImageMetadataFormat,
    pub progressive: bool,
    pub animated: bool,
}

/// Parses image dimensions and simple format traits from encoded headers.
pub fn image_metadata(bytes: &[u8]) -> RuntimeResult<ImageMetadata> {
    let Some(format) = sniff_image_format(bytes) else {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "unsupported image metadata format",
        ));
    };

    match format {
        RuntimeImageFormat::Jpeg => jpeg_metadata(bytes),
        RuntimeImageFormat::Png => png_metadata(bytes),
        RuntimeImageFormat::Gif => gif_metadata(bytes),
        RuntimeImageFormat::Webp => webp_metadata(bytes),
        RuntimeImageFormat::Bmp => bmp_metadata(bytes),
        RuntimeImageFormat::Ico => ico_metadata(bytes),
        RuntimeImageFormat::Wbmp => wbmp_metadata(bytes),
        _ => decoder_metadata(format, bytes),
    }
}

fn decoder_metadata(format: RuntimeImageFormat, bytes: &[u8]) -> RuntimeResult<ImageMetadata> {
    let (width, height) = format.dimensions(bytes)?;
    image_metadata_dimensions(width, height, metadata_format(format), false, false)
}

fn metadata_format(format: RuntimeImageFormat) -> ImageMetadataFormat {
    match format {
        RuntimeImageFormat::Jpeg => ImageMetadataFormat::Jpeg,
        RuntimeImageFormat::Png => ImageMetadataFormat::Png,
        RuntimeImageFormat::Gif => ImageMetadataFormat::Gif,
        RuntimeImageFormat::Webp => ImageMetadataFormat::Webp,
        RuntimeImageFormat::Bmp => ImageMetadataFormat::Bmp,
        RuntimeImageFormat::Wbmp => ImageMetadataFormat::Wbmp,
        RuntimeImageFormat::Ico => ImageMetadataFormat::Ico,
        RuntimeImageFormat::Tiff => ImageMetadataFormat::Tiff,
        RuntimeImageFormat::Pnm => ImageMetadataFormat::Pnm,
        RuntimeImageFormat::Qoi => ImageMetadataFormat::Qoi,
        RuntimeImageFormat::Tga => ImageMetadataFormat::Tga,
        RuntimeImageFormat::Dds => ImageMetadataFormat::Dds,
        RuntimeImageFormat::Hdr => ImageMetadataFormat::Hdr,
        RuntimeImageFormat::Farbfeld => ImageMetadataFormat::Farbfeld,
        RuntimeImageFormat::Pcx => ImageMetadataFormat::Pcx,
        RuntimeImageFormat::Sgi => ImageMetadataFormat::Sgi,
        RuntimeImageFormat::Xbm => ImageMetadataFormat::Xbm,
        RuntimeImageFormat::Xpm => ImageMetadataFormat::Xpm,
    }
}

fn jpeg_metadata(bytes: &[u8]) -> RuntimeResult<ImageMetadata> {
    let mut offset = 2_usize;
    while offset + 4 <= bytes.len() {
        if bytes[offset] != 0xff {
            return Err(RuntimeError::new("metadata", false, "invalid JPEG marker"));
        }
        while offset < bytes.len() && bytes[offset] == 0xff {
            offset += 1;
        }
        if offset >= bytes.len() {
            break;
        }
        let marker = bytes[offset];
        offset += 1;
        if marker == 0xda || marker == 0xd9 {
            break;
        }
        if is_standalone_marker(marker) {
            continue;
        }
        if offset + 2 > bytes.len() {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "truncated JPEG segment",
            ));
        }
        let segment_len = u16::from_be_bytes([bytes[offset], bytes[offset + 1]]) as usize;
        if segment_len < 2 {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "invalid JPEG segment length",
            ));
        }
        let data_start = offset + 2;
        let data_end = data_start.saturating_add(segment_len - 2);
        if data_end > bytes.len() {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "truncated JPEG segment data",
            ));
        }
        if is_jpeg_sof_marker(marker) {
            if data_start + 5 > data_end {
                return Err(RuntimeError::new(
                    "metadata",
                    false,
                    "truncated JPEG SOF segment",
                ));
            }
            let height = u16::from_be_bytes([bytes[data_start + 1], bytes[data_start + 2]]) as u32;
            let width = u16::from_be_bytes([bytes[data_start + 3], bytes[data_start + 4]]) as u32;
            return image_metadata_dimensions(
                width,
                height,
                ImageMetadataFormat::Jpeg,
                is_progressive_jpeg_sof_marker(marker),
                false,
            );
        }
        offset = data_end;
    }
    Err(RuntimeError::new(
        "metadata",
        false,
        "missing JPEG dimensions",
    ))
}

fn png_metadata(bytes: &[u8]) -> RuntimeResult<ImageMetadata> {
    if bytes.len() < 24 || bytes.get(12..16) != Some(b"IHDR") {
        return Err(RuntimeError::new("metadata", false, "truncated PNG IHDR"));
    }
    let width = u32::from_be_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]);
    let height = u32::from_be_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]);
    image_metadata_dimensions(width, height, ImageMetadataFormat::Png, false, false)
}

fn gif_metadata(bytes: &[u8]) -> RuntimeResult<ImageMetadata> {
    if bytes.len() < 10 {
        return Err(RuntimeError::new("metadata", false, "truncated GIF header"));
    }
    let width = u16::from_le_bytes([bytes[6], bytes[7]]) as u32;
    let height = u16::from_le_bytes([bytes[8], bytes[9]]) as u32;
    image_metadata_dimensions(width, height, ImageMetadataFormat::Gif, false, false)
}

fn webp_metadata(bytes: &[u8]) -> RuntimeResult<ImageMetadata> {
    let mut offset = 12_usize;
    while offset + 8 <= bytes.len() {
        let chunk = &bytes[offset..offset + 4];
        let chunk_len = u32::from_le_bytes([
            bytes[offset + 4],
            bytes[offset + 5],
            bytes[offset + 6],
            bytes[offset + 7],
        ]) as usize;
        let data_start = offset + 8;
        let data_end = data_start
            .checked_add(chunk_len)
            .ok_or_else(|| RuntimeError::new("metadata", false, "WebP chunk range overflows"))?;
        if data_end > bytes.len() {
            return Err(RuntimeError::new("metadata", false, "truncated WebP chunk"));
        }
        let data = &bytes[data_start..data_end];
        match chunk {
            b"VP8X" => return webp_vp8x_metadata(data),
            b"VP8 " => return webp_vp8_metadata(data),
            b"VP8L" => return webp_vp8l_metadata(data),
            _ => {}
        }
        offset = data_end + (chunk_len & 1);
    }
    Err(RuntimeError::new(
        "metadata",
        false,
        "missing WebP dimensions",
    ))
}

fn webp_vp8x_metadata(data: &[u8]) -> RuntimeResult<ImageMetadata> {
    if data.len() < 10 {
        return Err(RuntimeError::new("metadata", false, "truncated WebP VP8X"));
    }
    let width = read_u24_le(data, 4)? + 1;
    let height = read_u24_le(data, 7)? + 1;
    image_metadata_dimensions(
        width,
        height,
        ImageMetadataFormat::Webp,
        false,
        data[0] & 0x02 != 0,
    )
}

fn webp_vp8_metadata(data: &[u8]) -> RuntimeResult<ImageMetadata> {
    if data.len() < 10 || data.get(3..6) != Some(&[0x9d, 0x01, 0x2a]) {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "truncated WebP VP8 frame header",
        ));
    }
    let raw_width = u16::from_le_bytes([data[6], data[7]]) & 0x3fff;
    let raw_height = u16::from_le_bytes([data[8], data[9]]) & 0x3fff;
    image_metadata_dimensions(
        u32::from(raw_width),
        u32::from(raw_height),
        ImageMetadataFormat::Webp,
        false,
        false,
    )
}

fn webp_vp8l_metadata(data: &[u8]) -> RuntimeResult<ImageMetadata> {
    if data.len() < 5 || data[0] != 0x2f {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "truncated WebP VP8L frame header",
        ));
    }
    let width = 1 + (((u32::from(data[2]) & 0x3f) << 8) | u32::from(data[1]));
    let height = 1
        + (((u32::from(data[4]) & 0x0f) << 10)
            | (u32::from(data[3]) << 2)
            | ((u32::from(data[2]) & 0xc0) >> 6));
    image_metadata_dimensions(width, height, ImageMetadataFormat::Webp, false, false)
}

fn bmp_metadata(bytes: &[u8]) -> RuntimeResult<ImageMetadata> {
    if bytes.len() < 26 {
        return Err(RuntimeError::new("metadata", false, "truncated BMP header"));
    }
    let dib_size = u32::from_le_bytes([bytes[14], bytes[15], bytes[16], bytes[17]]);
    if dib_size == 12 {
        let width = u16::from_le_bytes([bytes[18], bytes[19]]) as u32;
        let height = u16::from_le_bytes([bytes[20], bytes[21]]) as u32;
        return image_metadata_dimensions(width, height, ImageMetadataFormat::Bmp, false, false);
    }
    if dib_size < 40 || bytes.len() < 26 {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "unsupported BMP DIB header",
        ));
    }
    let width = i32::from_le_bytes([bytes[18], bytes[19], bytes[20], bytes[21]]);
    let height = i32::from_le_bytes([bytes[22], bytes[23], bytes[24], bytes[25]]);
    if width <= 0 || height == 0 || height == i32::MIN {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "invalid BMP dimensions",
        ));
    }
    image_metadata_dimensions(
        width as u32,
        height.unsigned_abs(),
        ImageMetadataFormat::Bmp,
        false,
        false,
    )
}

fn wbmp_metadata(bytes: &[u8]) -> RuntimeResult<ImageMetadata> {
    let (width, height, _) = wbmp_dimensions(bytes)?;
    image_metadata_dimensions(width, height, ImageMetadataFormat::Wbmp, false, false)
}

fn ico_metadata(bytes: &[u8]) -> RuntimeResult<ImageMetadata> {
    if bytes.len() < 6 {
        return Err(RuntimeError::new("metadata", false, "truncated ICO header"));
    }
    let reserved = u16::from_le_bytes([bytes[0], bytes[1]]);
    let icon_type = u16::from_le_bytes([bytes[2], bytes[3]]);
    let count = u16::from_le_bytes([bytes[4], bytes[5]]) as usize;
    if reserved != 0 || icon_type != 1 || count == 0 {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "unsupported ICO header",
        ));
    }
    let directory_len = count
        .checked_mul(16)
        .and_then(|len| len.checked_add(6))
        .ok_or_else(|| RuntimeError::new("metadata", false, "ICO directory length overflows"))?;
    if bytes.len() < directory_len {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "truncated ICO directory",
        ));
    }
    let mut best: Option<(u32, u32, u64)> = None;
    for index in 0..count {
        let offset = 6 + index * 16;
        let width = ico_dimension(bytes[offset]);
        let height = ico_dimension(bytes[offset + 1]);
        let bytes_in_resource = u32::from_le_bytes([
            bytes[offset + 8],
            bytes[offset + 9],
            bytes[offset + 10],
            bytes[offset + 11],
        ]);
        let image_offset = u32::from_le_bytes([
            bytes[offset + 12],
            bytes[offset + 13],
            bytes[offset + 14],
            bytes[offset + 15],
        ]);
        if bytes_in_resource == 0 || image_offset < directory_len as u32 {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "invalid ICO directory entry",
            ));
        }
        let area = u64::from(width) * u64::from(height);
        if best.is_none_or(|(_, _, best_area)| area > best_area) {
            best = Some((width, height, area));
        }
    }
    let Some((width, height, _)) = best else {
        return Err(RuntimeError::new("metadata", false, "missing ICO entries"));
    };
    image_metadata_dimensions(width, height, ImageMetadataFormat::Ico, false, false)
}

fn ico_dimension(value: u8) -> u32 {
    if value == 0 {
        256
    } else {
        u32::from(value)
    }
}

fn image_metadata_dimensions(
    width: u32,
    height: u32,
    format: ImageMetadataFormat,
    progressive: bool,
    animated: bool,
) -> RuntimeResult<ImageMetadata> {
    if width == 0 || height == 0 {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "image dimensions must be greater than zero",
        ));
    }
    Ok(ImageMetadata {
        width,
        height,
        format,
        progressive,
        animated,
    })
}

fn is_jpeg_sof_marker(marker: u8) -> bool {
    matches!(
        marker,
        0xc0 | 0xc1 | 0xc2 | 0xc3 | 0xc5 | 0xc6 | 0xc7 | 0xc9 | 0xca | 0xcb | 0xcd | 0xce | 0xcf
    )
}

fn is_progressive_jpeg_sof_marker(marker: u8) -> bool {
    matches!(marker, 0xc2 | 0xc6 | 0xca | 0xce)
}

fn read_u24_le(bytes: &[u8], offset: usize) -> RuntimeResult<u32> {
    if offset + 3 > bytes.len() {
        return Err(RuntimeError::new("metadata", false, "truncated u24"));
    }
    Ok(u32::from(bytes[offset])
        | (u32::from(bytes[offset + 1]) << 8)
        | (u32::from(bytes[offset + 2]) << 16))
}

/// Parses JPEG EXIF orientation from APP1/TIFF metadata.
pub fn jpeg_exif_orientation(bytes: &[u8]) -> RuntimeResult<Option<u16>> {
    if !bytes.starts_with(&[0xff, 0xd8]) {
        return Ok(None);
    }

    let mut offset = 2_usize;
    while offset + 4 <= bytes.len() {
        if bytes[offset] != 0xff {
            return Ok(None);
        }
        while offset < bytes.len() && bytes[offset] == 0xff {
            offset += 1;
        }
        if offset >= bytes.len() {
            return Ok(None);
        }
        let marker = bytes[offset];
        offset += 1;
        if marker == 0xda || marker == 0xd9 {
            return Ok(None);
        }
        if offset + 2 > bytes.len() {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "truncated JPEG segment",
            ));
        }
        let segment_len = u16::from_be_bytes([bytes[offset], bytes[offset + 1]]) as usize;
        if segment_len < 2 {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "invalid JPEG segment length",
            ));
        }
        let data_start = offset + 2;
        let data_end = data_start.saturating_add(segment_len - 2);
        if data_end > bytes.len() {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "truncated JPEG segment data",
            ));
        }
        if marker == 0xe1 {
            let segment = &bytes[data_start..data_end];
            if segment.starts_with(b"Exif\0\0") {
                return parse_tiff_orientation(&segment[6..]);
            }
        }
        offset = data_end;
    }
    Ok(None)
}

/// Extracts an embedded JPEG EXIF thumbnail from an in-memory JPEG.
pub fn jpeg_exif_thumbnail(bytes: &[u8]) -> RuntimeResult<Option<Vec<u8>>> {
    if !bytes.starts_with(&[0xff, 0xd8]) {
        return Ok(None);
    }

    let mut offset = 2_usize;
    while offset + 4 <= bytes.len() {
        if bytes[offset] != 0xff {
            return Ok(None);
        }
        while offset < bytes.len() && bytes[offset] == 0xff {
            offset += 1;
        }
        if offset >= bytes.len() {
            return Ok(None);
        }
        let marker = bytes[offset];
        offset += 1;
        if marker == 0xda || marker == 0xd9 {
            return Ok(None);
        }
        if offset + 2 > bytes.len() {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "truncated JPEG segment",
            ));
        }
        let segment_len = u16::from_be_bytes([bytes[offset], bytes[offset + 1]]) as usize;
        if segment_len < 2 {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "invalid JPEG segment length",
            ));
        }
        let data_start = offset + 2;
        let data_end = data_start.saturating_add(segment_len - 2);
        if data_end > bytes.len() {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "truncated JPEG segment data",
            ));
        }
        if marker == 0xe1 {
            if let Some(thumbnail) = exif_thumbnail_from_segment(&bytes[data_start..data_end])? {
                return Ok(Some(thumbnail));
            }
        }
        offset = data_end;
    }
    Ok(None)
}

/// Extracts an embedded JPEG EXIF thumbnail while reading only JPEG metadata segments.
pub fn jpeg_exif_thumbnail_from_reader(reader: &mut impl Read) -> RuntimeResult<Option<Vec<u8>>> {
    let mut soi = [0_u8; 2];
    if reader.read_exact(&mut soi).is_err() {
        return Ok(None);
    }
    if soi != [0xff, 0xd8] {
        return Ok(None);
    }

    loop {
        let marker = match read_jpeg_marker(reader)? {
            Some(marker) => marker,
            None => return Ok(None),
        };
        if marker == 0xda || marker == 0xd9 {
            return Ok(None);
        }
        if is_standalone_marker(marker) {
            continue;
        }
        let mut len_bytes = [0_u8; 2];
        reader
            .read_exact(&mut len_bytes)
            .map_err(|_| RuntimeError::new("metadata", false, "truncated JPEG segment length"))?;
        let segment_len = u16::from_be_bytes(len_bytes) as usize;
        if segment_len < 2 {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "invalid JPEG segment length",
            ));
        }
        let payload_len = segment_len - 2;
        if marker == 0xe1 {
            let mut segment = vec![0_u8; payload_len];
            reader
                .read_exact(&mut segment)
                .map_err(|_| RuntimeError::new("metadata", false, "truncated JPEG APP1 segment"))?;
            if let Some(thumbnail) = exif_thumbnail_from_segment(&segment)? {
                return Ok(Some(thumbnail));
            }
            continue;
        }
        skip_exact(reader, payload_len)?;
    }
}

fn parse_tiff_orientation(tiff: &[u8]) -> RuntimeResult<Option<u16>> {
    if tiff.len() < 8 {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "truncated EXIF TIFF header",
        ));
    }
    let endian = match &tiff[0..2] {
        b"II" => Endian::Little,
        b"MM" => Endian::Big,
        _ => {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "invalid EXIF byte order",
            ))
        }
    };
    if read_u16(tiff, 2, endian)? != 42 {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "invalid EXIF TIFF marker",
        ));
    }
    let ifd_offset = read_u32(tiff, 4, endian)? as usize;
    if ifd_offset + 2 > tiff.len() {
        return Err(RuntimeError::new("metadata", false, "truncated EXIF IFD"));
    }
    let entry_count = read_u16(tiff, ifd_offset, endian)? as usize;
    let entries_start = ifd_offset + 2;
    for index in 0..entry_count {
        let entry = entries_start + index.saturating_mul(12);
        if entry + 12 > tiff.len() {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "truncated EXIF IFD entry",
            ));
        }
        let tag = read_u16(tiff, entry, endian)?;
        if tag != 0x0112 {
            continue;
        }
        let value_type = read_u16(tiff, entry + 2, endian)?;
        let count = read_u32(tiff, entry + 4, endian)?;
        if value_type != 3 || count != 1 {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "invalid EXIF orientation entry",
            ));
        }
        let orientation = read_u16(tiff, entry + 8, endian)?;
        if !(1..=8).contains(&orientation) {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "EXIF orientation is out of range",
            ));
        }
        return Ok(Some(orientation));
    }
    Ok(None)
}

fn exif_thumbnail_from_segment(segment: &[u8]) -> RuntimeResult<Option<Vec<u8>>> {
    if !segment.starts_with(b"Exif\0\0") {
        return Ok(None);
    }
    parse_tiff_thumbnail(&segment[6..])
}

fn parse_tiff_thumbnail(tiff: &[u8]) -> RuntimeResult<Option<Vec<u8>>> {
    let (endian, ifd0_offset) = parse_tiff_header(tiff)?;
    let ifd1_offset = next_ifd_offset(tiff, ifd0_offset, endian)?;
    if ifd1_offset == 0 {
        return Ok(None);
    }
    let entry_count = read_ifd_entry_count(tiff, ifd1_offset, endian, "EXIF thumbnail IFD")?;
    let entries_start = ifd1_offset + 2;
    let mut thumbnail_offset: Option<usize> = None;
    let mut thumbnail_length: Option<usize> = None;
    for index in 0..entry_count {
        let entry = entries_start + index.saturating_mul(12);
        if entry + 12 > tiff.len() {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "truncated EXIF thumbnail IFD entry",
            ));
        }
        let tag = read_u16(tiff, entry, endian)?;
        match tag {
            0x0201 => thumbnail_offset = Some(read_ifd_u32_value(tiff, entry, endian)? as usize),
            0x0202 => thumbnail_length = Some(read_ifd_u32_value(tiff, entry, endian)? as usize),
            _ => {}
        }
    }
    let (Some(offset), Some(length)) = (thumbnail_offset, thumbnail_length) else {
        return Ok(None);
    };
    if length == 0 {
        return Ok(None);
    }
    let end = offset
        .checked_add(length)
        .ok_or_else(|| RuntimeError::new("metadata", false, "EXIF thumbnail range overflows"))?;
    if end > tiff.len() {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "EXIF thumbnail range exceeds APP1 segment",
        ));
    }
    let thumbnail = &tiff[offset..end];
    if !thumbnail.starts_with(&[0xff, 0xd8]) {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "EXIF thumbnail is not a JPEG payload",
        ));
    }
    Ok(Some(thumbnail.to_vec()))
}

fn parse_tiff_header(tiff: &[u8]) -> RuntimeResult<(Endian, usize)> {
    if tiff.len() < 8 {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "truncated EXIF TIFF header",
        ));
    }
    let endian = match &tiff[0..2] {
        b"II" => Endian::Little,
        b"MM" => Endian::Big,
        _ => {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "invalid EXIF byte order",
            ))
        }
    };
    if read_u16(tiff, 2, endian)? != 42 {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "invalid EXIF TIFF marker",
        ));
    }
    Ok((endian, read_u32(tiff, 4, endian)? as usize))
}

fn next_ifd_offset(tiff: &[u8], ifd_offset: usize, endian: Endian) -> RuntimeResult<usize> {
    let entry_count = read_ifd_entry_count(tiff, ifd_offset, endian, "EXIF IFD")?;
    let next_offset_position = ifd_offset
        .checked_add(2)
        .and_then(|value| value.checked_add(entry_count.saturating_mul(12)))
        .ok_or_else(|| RuntimeError::new("metadata", false, "EXIF IFD range overflows"))?;
    if next_offset_position + 4 > tiff.len() {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "truncated EXIF next IFD offset",
        ));
    }
    Ok(read_u32(tiff, next_offset_position, endian)? as usize)
}

fn read_ifd_entry_count(
    tiff: &[u8],
    ifd_offset: usize,
    endian: Endian,
    label: &'static str,
) -> RuntimeResult<usize> {
    if ifd_offset + 2 > tiff.len() {
        return Err(RuntimeError::new(
            "metadata",
            false,
            format!("truncated {label}"),
        ));
    }
    Ok(read_u16(tiff, ifd_offset, endian)? as usize)
}

fn read_ifd_u32_value(tiff: &[u8], entry: usize, endian: Endian) -> RuntimeResult<u32> {
    let value_type = read_u16(tiff, entry + 2, endian)?;
    let count = read_u32(tiff, entry + 4, endian)?;
    if value_type != 4 || count != 1 {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "invalid EXIF thumbnail pointer entry",
        ));
    }
    read_u32(tiff, entry + 8, endian)
}

fn read_jpeg_marker(reader: &mut impl Read) -> RuntimeResult<Option<u8>> {
    let mut byte = [0_u8; 1];
    loop {
        match reader.read_exact(&mut byte) {
            Ok(()) if byte[0] == 0xff => break,
            Ok(()) => continue,
            Err(_) => return Ok(None),
        }
    }
    loop {
        reader
            .read_exact(&mut byte)
            .map_err(|_| RuntimeError::new("metadata", false, "truncated JPEG marker"))?;
        if byte[0] != 0xff {
            return Ok(Some(byte[0]));
        }
    }
}

fn is_standalone_marker(marker: u8) -> bool {
    marker == 0x01 || (0xd0..=0xd7).contains(&marker)
}

fn skip_exact(reader: &mut impl Read, mut bytes: usize) -> RuntimeResult<()> {
    let mut buffer = [0_u8; 1024];
    while bytes > 0 {
        let count = bytes.min(buffer.len());
        reader
            .read_exact(&mut buffer[..count])
            .map_err(|_| RuntimeError::new("metadata", false, "truncated JPEG segment data"))?;
        bytes -= count;
    }
    Ok(())
}

#[derive(Clone, Copy)]
enum Endian {
    Little,
    Big,
}

fn read_u16(bytes: &[u8], offset: usize, endian: Endian) -> RuntimeResult<u16> {
    if offset + 2 > bytes.len() {
        return Err(RuntimeError::new("metadata", false, "truncated EXIF u16"));
    }
    let raw = [bytes[offset], bytes[offset + 1]];
    Ok(match endian {
        Endian::Little => u16::from_le_bytes(raw),
        Endian::Big => u16::from_be_bytes(raw),
    })
}

fn read_u32(bytes: &[u8], offset: usize, endian: Endian) -> RuntimeResult<u32> {
    if offset + 4 > bytes.len() {
        return Err(RuntimeError::new("metadata", false, "truncated EXIF u32"));
    }
    let raw = [
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ];
    Ok(match endian {
        Endian::Little => u32::from_le_bytes(raw),
        Endian::Big => u32::from_be_bytes(raw),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::ImageEncoder;

    #[test]
    fn parses_little_endian_jpeg_orientation() {
        let bytes = jpeg_with_orientation(6);

        assert_eq!(jpeg_exif_orientation(&bytes).unwrap(), Some(6));
    }

    #[test]
    fn rejects_out_of_range_orientation() {
        let bytes = jpeg_with_orientation(9);

        assert!(jpeg_exif_orientation(&bytes).is_err());
    }

    #[test]
    fn extracts_embedded_exif_jpeg_thumbnail() {
        let thumbnail = vec![0xff, 0xd8, 0xff, 0xd9];
        let bytes = jpeg_with_thumbnail(&thumbnail);

        assert_eq!(jpeg_exif_thumbnail(&bytes).unwrap(), Some(thumbnail));
    }

    #[test]
    fn streams_embedded_exif_jpeg_thumbnail_without_full_image_read() {
        let thumbnail = vec![0xff, 0xd8, 0xff, 0xd9];
        let bytes = jpeg_with_thumbnail(&thumbnail);
        let mut cursor = std::io::Cursor::new(bytes);

        assert_eq!(
            jpeg_exif_thumbnail_from_reader(&mut cursor).unwrap(),
            Some(thumbnail)
        );
    }

    #[test]
    fn probes_baseline_jpeg_dimensions() {
        let metadata = image_metadata(&jpeg_with_sof(0xc0, 4096, 2048)).unwrap();

        assert_eq!(metadata.width, 4096);
        assert_eq!(metadata.height, 2048);
        assert_eq!(metadata.format, ImageMetadataFormat::Jpeg);
        assert!(!metadata.progressive);
    }

    #[test]
    fn probes_progressive_jpeg_dimensions() {
        let metadata = image_metadata(&jpeg_with_sof(0xc2, 3000, 2000)).unwrap();

        assert_eq!(metadata.width, 3000);
        assert_eq!(metadata.height, 2000);
        assert_eq!(metadata.format, ImageMetadataFormat::Jpeg);
        assert!(metadata.progressive);
    }

    #[test]
    fn probes_png_gif_and_webp_dimensions_without_full_decode() {
        let png = image_metadata(&png_header(320, 240)).unwrap();
        let gif = image_metadata(&gif_header(640, 480)).unwrap();
        let webp = image_metadata(&webp_vp8x_header(1024, 768, true)).unwrap();

        assert_eq!(
            (png.width, png.height, png.format),
            (320, 240, ImageMetadataFormat::Png)
        );
        assert_eq!(
            (gif.width, gif.height, gif.format),
            (640, 480, ImageMetadataFormat::Gif)
        );
        assert_eq!(
            (webp.width, webp.height, webp.format, webp.animated),
            (1024, 768, ImageMetadataFormat::Webp, true)
        );
    }

    #[test]
    fn probes_bmp_dimensions_without_full_decode() {
        let bottom_up = image_metadata(&bmp_info_header(800, 600)).unwrap();
        let top_down = image_metadata(&bmp_info_header(320, -240)).unwrap();

        assert_eq!(
            (bottom_up.width, bottom_up.height, bottom_up.format),
            (800, 600, ImageMetadataFormat::Bmp)
        );
        assert_eq!(
            (top_down.width, top_down.height, top_down.format),
            (320, 240, ImageMetadataFormat::Bmp)
        );
    }

    #[test]
    fn probes_wbmp_dimensions_without_full_decode() {
        let metadata = image_metadata(&wbmp_image(17, 9)).unwrap();

        assert_eq!(
            (metadata.width, metadata.height, metadata.format),
            (17, 9, ImageMetadataFormat::Wbmp)
        );
    }

    #[test]
    fn probes_largest_ico_entry_without_full_decode() {
        let metadata = image_metadata(&ico_header(&[(16, 16), (0, 0), (48, 32)])).unwrap();

        assert_eq!(
            (metadata.width, metadata.height, metadata.format),
            (256, 256, ImageMetadataFormat::Ico)
        );
    }

    #[test]
    fn probes_additional_image_crate_and_extras_dimensions() {
        let fixtures: &[(Vec<u8>, ImageMetadataFormat)] = &[
            (tiff_rgba_1x1(), ImageMetadataFormat::Tiff),
            (pnm_rgb_1x1(), ImageMetadataFormat::Pnm),
            (qoi_rgba_1x1(), ImageMetadataFormat::Qoi),
            (tga_rgb_1x1(), ImageMetadataFormat::Tga),
            (dds_dxt1_4x4(), ImageMetadataFormat::Dds),
            (hdr_rgb_1x1(), ImageMetadataFormat::Hdr),
            (farbfeld_rgba_1x1(), ImageMetadataFormat::Farbfeld),
            (pcx_rgb_1x1(), ImageMetadataFormat::Pcx),
            (sgi_rgb_1x1(), ImageMetadataFormat::Sgi),
            (xbm_1x1(), ImageMetadataFormat::Xbm),
            (xpm_1x1(), ImageMetadataFormat::Xpm),
        ];

        for (bytes, format) in fixtures {
            let metadata = image_metadata(bytes).expect("metadata should parse");
            let expected_size = if *format == ImageMetadataFormat::Dds {
                (4, 4)
            } else {
                (1, 1)
            };
            assert_eq!(
                (metadata.width, metadata.height, metadata.format),
                (expected_size.0, expected_size.1, *format)
            );
        }
    }

    fn jpeg_with_orientation(orientation: u16) -> Vec<u8> {
        let mut exif = Vec::<u8>::new();
        exif.extend_from_slice(b"Exif\0\0");
        exif.extend_from_slice(b"II");
        exif.extend_from_slice(&42_u16.to_le_bytes());
        exif.extend_from_slice(&8_u32.to_le_bytes());
        exif.extend_from_slice(&1_u16.to_le_bytes());
        exif.extend_from_slice(&0x0112_u16.to_le_bytes());
        exif.extend_from_slice(&3_u16.to_le_bytes());
        exif.extend_from_slice(&1_u32.to_le_bytes());
        exif.extend_from_slice(&orientation.to_le_bytes());
        exif.extend_from_slice(&0_u16.to_le_bytes());
        exif.extend_from_slice(&0_u32.to_le_bytes());

        let segment_len = (exif.len() + 2) as u16;
        let mut jpeg = vec![0xff, 0xd8, 0xff, 0xe1];
        jpeg.extend_from_slice(&segment_len.to_be_bytes());
        jpeg.extend_from_slice(&exif);
        jpeg.extend_from_slice(&[0xff, 0xd9]);
        jpeg
    }

    fn jpeg_with_thumbnail(thumbnail: &[u8]) -> Vec<u8> {
        let thumbnail_offset = 44_u32;
        let mut tiff = Vec::<u8>::new();
        tiff.extend_from_slice(b"II");
        tiff.extend_from_slice(&42_u16.to_le_bytes());
        tiff.extend_from_slice(&8_u32.to_le_bytes());
        tiff.extend_from_slice(&0_u16.to_le_bytes());
        tiff.extend_from_slice(&14_u32.to_le_bytes());
        tiff.extend_from_slice(&2_u16.to_le_bytes());
        tiff.extend_from_slice(&0x0201_u16.to_le_bytes());
        tiff.extend_from_slice(&4_u16.to_le_bytes());
        tiff.extend_from_slice(&1_u32.to_le_bytes());
        tiff.extend_from_slice(&thumbnail_offset.to_le_bytes());
        tiff.extend_from_slice(&0x0202_u16.to_le_bytes());
        tiff.extend_from_slice(&4_u16.to_le_bytes());
        tiff.extend_from_slice(&1_u32.to_le_bytes());
        tiff.extend_from_slice(&(thumbnail.len() as u32).to_le_bytes());
        tiff.extend_from_slice(&0_u32.to_le_bytes());
        tiff.extend_from_slice(thumbnail);

        let mut exif = Vec::<u8>::new();
        exif.extend_from_slice(b"Exif\0\0");
        exif.extend_from_slice(&tiff);
        let segment_len = (exif.len() + 2) as u16;
        let mut jpeg = vec![0xff, 0xd8, 0xff, 0xe1];
        jpeg.extend_from_slice(&segment_len.to_be_bytes());
        jpeg.extend_from_slice(&exif);
        jpeg.extend_from_slice(&[0xff, 0xda, 0x00, 0x02, 0xff, 0xd9]);
        jpeg
    }

    fn jpeg_with_sof(marker: u8, width: u16, height: u16) -> Vec<u8> {
        let mut jpeg = vec![0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00];
        jpeg.extend_from_slice(&[0xff, marker, 0x00, 0x11, 0x08]);
        jpeg.extend_from_slice(&height.to_be_bytes());
        jpeg.extend_from_slice(&width.to_be_bytes());
        jpeg.extend_from_slice(&[0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
        jpeg.extend_from_slice(&[0xff, 0xda, 0x00, 0x02]);
        jpeg
    }

    fn png_header(width: u32, height: u32) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"\x89PNG\r\n\x1a\n");
        bytes.extend_from_slice(&13_u32.to_be_bytes());
        bytes.extend_from_slice(b"IHDR");
        bytes.extend_from_slice(&width.to_be_bytes());
        bytes.extend_from_slice(&height.to_be_bytes());
        bytes.extend_from_slice(&[8, 6, 0, 0, 0]);
        bytes
    }

    fn pnm_rgb_1x1() -> Vec<u8> {
        let mut bytes = b"P6\n1 1\n255\n".to_vec();
        bytes.extend_from_slice(&[255, 0, 0]);
        bytes
    }

    fn tiff_rgba_1x1() -> Vec<u8> {
        let mut cursor = std::io::Cursor::new(Vec::new());
        image::codecs::tiff::TiffEncoder::new(&mut cursor)
            .write_image(&[255, 0, 0, 255], 1, 1, image::ExtendedColorType::Rgba8)
            .expect("test TIFF should encode");
        cursor.into_inner()
    }

    fn qoi_rgba_1x1() -> Vec<u8> {
        let mut bytes = Vec::new();
        image::codecs::qoi::QoiEncoder::new(&mut bytes)
            .write_image(&[255, 0, 0, 255], 1, 1, image::ExtendedColorType::Rgba8)
            .expect("test QOI should encode");
        bytes
    }

    fn tga_rgb_1x1() -> Vec<u8> {
        let mut bytes = vec![0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&[24, 0x20, 0, 0, 255]);
        bytes
    }

    fn dds_dxt1_4x4() -> Vec<u8> {
        let mut bytes = b"DDS ".to_vec();
        bytes.extend_from_slice(&124_u32.to_le_bytes());
        bytes.extend_from_slice(&0x0002_1007_u32.to_le_bytes());
        bytes.extend_from_slice(&4_u32.to_le_bytes());
        bytes.extend_from_slice(&4_u32.to_le_bytes());
        bytes.extend_from_slice(&8_u32.to_le_bytes());
        bytes.extend_from_slice(&0_u32.to_le_bytes());
        bytes.extend_from_slice(&0_u32.to_le_bytes());
        bytes.extend_from_slice(&[0; 44]);
        bytes.extend_from_slice(&32_u32.to_le_bytes());
        bytes.extend_from_slice(&4_u32.to_le_bytes());
        bytes.extend_from_slice(b"DXT1");
        bytes.extend_from_slice(&[0; 20]);
        bytes.extend_from_slice(&0x1000_u32.to_le_bytes());
        bytes.extend_from_slice(&[0; 16]);
        bytes.extend_from_slice(&[0x00, 0xf8, 0x00, 0x00, 0, 0, 0, 0]);
        bytes
    }

    fn hdr_rgb_1x1() -> Vec<u8> {
        let mut bytes = Vec::new();
        image::codecs::hdr::HdrEncoder::new(&mut bytes)
            .encode(&[image::Rgb([1.0, 0.0, 0.0])], 1, 1)
            .expect("test HDR should encode");
        bytes
    }

    fn farbfeld_rgba_1x1() -> Vec<u8> {
        let mut bytes = b"farbfeld".to_vec();
        bytes.extend_from_slice(&1_u32.to_be_bytes());
        bytes.extend_from_slice(&1_u32.to_be_bytes());
        bytes.extend_from_slice(&[0xff, 0xff, 0, 0, 0, 0, 0xff, 0xff]);
        bytes
    }

    fn pcx_rgb_1x1() -> Vec<u8> {
        let mut bytes = vec![0_u8; 128];
        bytes[0] = 0x0a;
        bytes[1] = 5;
        bytes[2] = 1;
        bytes[3] = 8;
        bytes[8..10].copy_from_slice(&0_u16.to_le_bytes());
        bytes[10..12].copy_from_slice(&0_u16.to_le_bytes());
        bytes[12..14].copy_from_slice(&72_u16.to_le_bytes());
        bytes[14..16].copy_from_slice(&72_u16.to_le_bytes());
        bytes[65] = 3;
        bytes[66..68].copy_from_slice(&1_u16.to_le_bytes());
        bytes[68..70].copy_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&[0xc1, 0xff, 0, 0]);
        bytes
    }

    fn sgi_rgb_1x1() -> Vec<u8> {
        let mut bytes = vec![0_u8; 512];
        bytes[0..2].copy_from_slice(&0x01da_u16.to_be_bytes());
        bytes[2] = 0;
        bytes[3] = 1;
        bytes[4..6].copy_from_slice(&3_u16.to_be_bytes());
        bytes[6..8].copy_from_slice(&1_u16.to_be_bytes());
        bytes[8..10].copy_from_slice(&1_u16.to_be_bytes());
        bytes[10..12].copy_from_slice(&3_u16.to_be_bytes());
        bytes[16..20].copy_from_slice(&255_u32.to_be_bytes());
        bytes.extend_from_slice(&[255, 0, 0]);
        bytes
    }

    fn xbm_1x1() -> Vec<u8> {
        b"#define test_width 1\n#define test_height 1\nstatic unsigned char test_bits[] = { 0x01 };\n"
            .to_vec()
    }

    fn xpm_1x1() -> Vec<u8> {
        b"/* XPM */\nstatic char *xpm[] = {\n\"1 1 1 1\",\n\"a c #ff0000\",\n\"a\"\n};\n".to_vec()
    }

    fn gif_header(width: u16, height: u16) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"GIF89a");
        bytes.extend_from_slice(&width.to_le_bytes());
        bytes.extend_from_slice(&height.to_le_bytes());
        bytes
    }

    fn webp_vp8x_header(width: u32, height: u32, animated: bool) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&18_u32.to_le_bytes());
        bytes.extend_from_slice(b"WEBPVP8X");
        bytes.extend_from_slice(&10_u32.to_le_bytes());
        bytes.push(if animated { 0x02 } else { 0x00 });
        bytes.extend_from_slice(&[0, 0, 0]);
        push_u24_le(&mut bytes, width - 1);
        push_u24_le(&mut bytes, height - 1);
        bytes
    }

    fn ico_header(entries: &[(u8, u8)]) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&0_u16.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        let mut data_offset = 6 + entries.len() as u32 * 16;
        for &(width, height) in entries {
            bytes.push(width);
            bytes.push(height);
            bytes.push(0);
            bytes.push(0);
            bytes.extend_from_slice(&1_u16.to_le_bytes());
            bytes.extend_from_slice(&32_u16.to_le_bytes());
            bytes.extend_from_slice(&1_u32.to_le_bytes());
            bytes.extend_from_slice(&data_offset.to_le_bytes());
            data_offset += 1;
        }
        bytes.resize(data_offset as usize, 0);
        bytes
    }

    fn push_u24_le(bytes: &mut Vec<u8>, value: u32) {
        bytes.push((value & 0xff) as u8);
        bytes.push(((value >> 8) & 0xff) as u8);
        bytes.push(((value >> 16) & 0xff) as u8);
    }

    fn bmp_info_header(width: i32, height: i32) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"BM");
        bytes.extend_from_slice(&54_u32.to_le_bytes());
        bytes.extend_from_slice(&[0; 4]);
        bytes.extend_from_slice(&54_u32.to_le_bytes());
        bytes.extend_from_slice(&40_u32.to_le_bytes());
        bytes.extend_from_slice(&width.to_le_bytes());
        bytes.extend_from_slice(&height.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&24_u16.to_le_bytes());
        bytes
    }

    fn wbmp_image(width: u32, height: u32) -> Vec<u8> {
        let row_bytes = width.div_ceil(8);
        let mut bytes = vec![0, 0];
        push_wbmp_multi_byte_integer(&mut bytes, width);
        push_wbmp_multi_byte_integer(&mut bytes, height);
        bytes.resize(bytes.len() + (row_bytes * height) as usize, 0);
        bytes
    }

    fn push_wbmp_multi_byte_integer(bytes: &mut Vec<u8>, mut value: u32) {
        let mut stack = [0_u8; 5];
        let mut len = 1_usize;
        stack[4] = (value & 0x7f) as u8;
        value >>= 7;
        while value != 0 {
            len += 1;
            stack[5 - len] = ((value & 0x7f) as u8) | 0x80;
            value >>= 7;
        }
        bytes.extend_from_slice(&stack[5 - len..]);
    }
}
