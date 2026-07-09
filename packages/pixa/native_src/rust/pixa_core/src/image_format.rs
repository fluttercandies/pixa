use crate::{RuntimeError, RuntimeResult};
use image::{DynamicImage, ImageDecoder, ImageDecoderRect, ImageFormat, ImageReader};
use std::io::{BufReader, Cursor};

/// Internal catalog of encoded raster formats Pixa can identify and route.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeImageFormat {
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

/// Stable capability flags for one encoded image format.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RuntimeImageFormatCapabilityFlags(u16);

impl RuntimeImageFormatCapabilityFlags {
    /// Runtime can identify the format from bounded magic/header bytes.
    pub const SNIFFING: Self = Self(0x0001);
    /// Runtime can return dimensions/traits without full application decode.
    pub const METADATA: Self = Self(0x0002);
    /// Flutter engine is the default display backend for this format.
    pub const ENGINE_DISPLAY: Self = Self(0x0004);
    /// Runtime RGBA backend can decode the format for static display handoff.
    pub const RUNTIME_DISPLAY: Self = Self(0x0008);
    /// Runtime processor input decode can use this format.
    pub const PROCESSOR_DECODE: Self = Self(0x0010);
    /// Format has an animated display mode in Pixa's supported surface.
    pub const ANIMATED: Self = Self(0x0020);
    /// Runtime display is selected automatically for ordinary display requests.
    pub const DEFAULT_RUNTIME_DISPLAY: Self = Self(0x0040);
    /// Decoder can read a bounded region/tile without full-frame pixel decode.
    pub const REGION_DECODE: Self = Self(0x0080);

    pub const fn bits(self) -> u16 {
        self.0
    }

    const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

/// Machine-readable runtime capability for one supported encoded image format.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RuntimeImageFormatCapability {
    pub format: RuntimeImageFormat,
    pub flags: RuntimeImageFormatCapabilityFlags,
}

type RuntimeImageDecodeFn =
    fn(&[u8], stage: &'static str, label: &'static str) -> RuntimeResult<DynamicImage>;
type RuntimeImageDimensionsFn = fn(&[u8]) -> RuntimeResult<(u32, u32)>;
type RuntimeImageRegionDecodeFn = fn(
    &[u8],
    RuntimeImageRegion,
    usize,
    stage: &'static str,
    label: &'static str,
) -> RuntimeResult<DynamicImage>;

/// Rectangle requested from a decoder that can avoid full-frame pixel decode.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct RuntimeImageRegion {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RuntimeImageDecodeProvider {
    id: &'static str,
    crate_name: &'static str,
}

#[derive(Clone, Copy)]
struct RuntimeImageDecodeBackend {
    id: &'static str,
    provider: &'static RuntimeImageDecodeProvider,
    decode: RuntimeImageDecodeFn,
    dimensions: RuntimeImageDimensionsFn,
    region_decode: Option<RuntimeImageRegionDecodeFn>,
}

impl std::fmt::Debug for RuntimeImageDecodeBackend {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RuntimeImageDecodeBackend")
            .field("id", &self.id)
            .field("provider", &self.provider.id)
            .field("provider_crate", &self.provider.crate_name)
            .field("region_decode", &self.region_decode.is_some())
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Copy, Debug)]
enum RuntimeDimensionsBackend {
    Decoder,
    Header(RuntimeImageDimensionsFn),
}

#[derive(Clone, Copy, Debug)]
struct RuntimeImageFormatDescriptor {
    format: RuntimeImageFormat,
    code: u8,
    format_id: &'static str,
    primary_mime_type: &'static str,
    label: &'static str,
    sniff: fn(&[u8]) -> bool,
    decode_backend: &'static RuntimeImageDecodeBackend,
    dimensions_backend: RuntimeDimensionsBackend,
    flags: RuntimeImageFormatCapabilityFlags,
}

impl RuntimeImageFormat {
    pub fn code(self) -> u8 {
        self.descriptor().code
    }

    pub fn format_id(self) -> &'static str {
        self.descriptor().format_id
    }

    pub fn primary_mime_type(self) -> &'static str {
        self.descriptor().primary_mime_type
    }

    pub(crate) fn decode(
        self,
        bytes: &[u8],
        stage: &'static str,
        label: &'static str,
    ) -> RuntimeResult<DynamicImage> {
        self.descriptor().decode_backend.decode(bytes, stage, label)
    }

    pub(crate) fn dimensions(self, bytes: &[u8]) -> RuntimeResult<(u32, u32)> {
        let descriptor = self.descriptor();
        match descriptor.dimensions_backend {
            RuntimeDimensionsBackend::Decoder => descriptor.decode_backend.dimensions(bytes),
            RuntimeDimensionsBackend::Header(dimensions) => dimensions(bytes),
        }
    }

    pub(crate) fn supports_region_decode(self) -> bool {
        self.descriptor().decode_backend.region_decode.is_some()
    }

    pub(crate) fn decode_region(
        self,
        bytes: &[u8],
        region: RuntimeImageRegion,
        max_region_bytes: usize,
        stage: &'static str,
        label: &'static str,
    ) -> RuntimeResult<Option<DynamicImage>> {
        let Some(region_decode) = self.descriptor().decode_backend.region_decode else {
            return Ok(None);
        };
        region_decode(bytes, region, max_region_bytes, stage, label).map(Some)
    }

    fn descriptor(self) -> &'static RuntimeImageFormatDescriptor {
        runtime_image_format_descriptors()
            .iter()
            .find(|descriptor| descriptor.format == self)
            .expect("every RuntimeImageFormat variant must have a descriptor")
    }
}

impl RuntimeImageDecodeBackend {
    fn decode(
        &self,
        bytes: &[u8],
        stage: &'static str,
        label: &'static str,
    ) -> RuntimeResult<DynamicImage> {
        (self.decode)(bytes, stage, label)
    }

    fn dimensions(&self, bytes: &[u8]) -> RuntimeResult<(u32, u32)> {
        (self.dimensions)(bytes)
    }
}

impl RuntimeImageFormatDescriptor {
    fn capability(self) -> RuntimeImageFormatCapability {
        RuntimeImageFormatCapability {
            format: self.format,
            flags: self.flags,
        }
    }
}

const COMMON: RuntimeImageFormatCapabilityFlags = RuntimeImageFormatCapabilityFlags::SNIFFING
    .union(RuntimeImageFormatCapabilityFlags::METADATA)
    .union(RuntimeImageFormatCapabilityFlags::ENGINE_DISPLAY)
    .union(RuntimeImageFormatCapabilityFlags::RUNTIME_DISPLAY)
    .union(RuntimeImageFormatCapabilityFlags::PROCESSOR_DECODE);
const ANIMATED: RuntimeImageFormatCapabilityFlags =
    COMMON.union(RuntimeImageFormatCapabilityFlags::ANIMATED);
const RUNTIME_ONLY: RuntimeImageFormatCapabilityFlags = RuntimeImageFormatCapabilityFlags::SNIFFING
    .union(RuntimeImageFormatCapabilityFlags::METADATA)
    .union(RuntimeImageFormatCapabilityFlags::RUNTIME_DISPLAY)
    .union(RuntimeImageFormatCapabilityFlags::PROCESSOR_DECODE)
    .union(RuntimeImageFormatCapabilityFlags::DEFAULT_RUNTIME_DISPLAY);
const DECODER_DIMENSIONS: RuntimeDimensionsBackend = RuntimeDimensionsBackend::Decoder;

static IMAGE_CRATE_PROVIDER: RuntimeImageDecodeProvider = RuntimeImageDecodeProvider {
    id: "image-crate",
    crate_name: "image",
};

static IMAGE_EXTRAS_PROVIDER: RuntimeImageDecodeProvider = RuntimeImageDecodeProvider {
    id: "image-extras",
    crate_name: "image_extras",
};

macro_rules! image_crate_backend {
    ($backend:ident, $decode:ident, $dimensions:ident, $id:expr, $format:expr) => {
        image_crate_backend!($backend, $decode, $dimensions, $id, $format, None);
    };
    ($backend:ident, $decode:ident, $dimensions:ident, $id:expr, $format:expr, $region_decode:expr) => {
        static $backend: RuntimeImageDecodeBackend = RuntimeImageDecodeBackend {
            id: $id,
            provider: &IMAGE_CRATE_PROVIDER,
            decode: $decode,
            dimensions: $dimensions,
            region_decode: $region_decode,
        };

        fn $decode(
            bytes: &[u8],
            stage: &'static str,
            label: &'static str,
        ) -> RuntimeResult<DynamicImage> {
            decode_image_crate($format, bytes, stage, label)
        }

        fn $dimensions(bytes: &[u8]) -> RuntimeResult<(u32, u32)> {
            image_crate_dimensions($format, bytes)
        }
    };
}

macro_rules! image_extras_backend {
    ($backend:ident, $decode:ident, $dimensions:ident, $id:expr, $decoder:path) => {
        static $backend: RuntimeImageDecodeBackend = RuntimeImageDecodeBackend {
            id: $id,
            provider: &IMAGE_EXTRAS_PROVIDER,
            decode: $decode,
            dimensions: $dimensions,
            region_decode: None,
        };

        fn $decode(
            bytes: &[u8],
            stage: &'static str,
            label: &'static str,
        ) -> RuntimeResult<DynamicImage> {
            decode_extra_decoder($decoder(BufReader::new(Cursor::new(bytes))), stage, label)
        }

        fn $dimensions(bytes: &[u8]) -> RuntimeResult<(u32, u32)> {
            extra_dimensions($decoder(BufReader::new(Cursor::new(bytes))))
        }
    };
}

image_crate_backend!(
    IMAGE_CRATE_JPEG_BACKEND,
    decode_image_crate_jpeg,
    dimensions_image_crate_jpeg,
    "image-crate/jpeg",
    ImageFormat::Jpeg
);
image_crate_backend!(
    IMAGE_CRATE_PNG_BACKEND,
    decode_image_crate_png,
    dimensions_image_crate_png,
    "image-crate/png",
    ImageFormat::Png,
    Some(decode_png_region_rows)
);
image_crate_backend!(
    IMAGE_CRATE_GIF_BACKEND,
    decode_image_crate_gif,
    dimensions_image_crate_gif,
    "image-crate/gif",
    ImageFormat::Gif
);
image_crate_backend!(
    IMAGE_CRATE_WEBP_BACKEND,
    decode_image_crate_webp,
    dimensions_image_crate_webp,
    "image-crate/webp",
    ImageFormat::WebP
);
image_crate_backend!(
    IMAGE_CRATE_BMP_BACKEND,
    decode_image_crate_bmp,
    dimensions_image_crate_bmp,
    "image-crate/bmp",
    ImageFormat::Bmp,
    Some(decode_image_crate_bmp_region)
);
image_crate_backend!(
    IMAGE_CRATE_ICO_BACKEND,
    decode_image_crate_ico,
    dimensions_image_crate_ico,
    "image-crate/ico",
    ImageFormat::Ico
);
image_crate_backend!(
    IMAGE_CRATE_TIFF_BACKEND,
    decode_image_crate_tiff,
    dimensions_image_crate_tiff,
    "image-crate/tiff",
    ImageFormat::Tiff
);
image_crate_backend!(
    IMAGE_CRATE_PNM_BACKEND,
    decode_image_crate_pnm,
    dimensions_image_crate_pnm,
    "image-crate/pnm",
    ImageFormat::Pnm
);
image_crate_backend!(
    IMAGE_CRATE_QOI_BACKEND,
    decode_image_crate_qoi,
    dimensions_image_crate_qoi,
    "image-crate/qoi",
    ImageFormat::Qoi
);
image_crate_backend!(
    IMAGE_CRATE_TGA_BACKEND,
    decode_image_crate_tga,
    dimensions_image_crate_tga,
    "image-crate/tga",
    ImageFormat::Tga
);
image_crate_backend!(
    IMAGE_CRATE_DDS_BACKEND,
    decode_image_crate_dds,
    dimensions_image_crate_dds,
    "image-crate/dds",
    ImageFormat::Dds
);
image_crate_backend!(
    IMAGE_CRATE_HDR_BACKEND,
    decode_image_crate_hdr,
    dimensions_image_crate_hdr,
    "image-crate/hdr",
    ImageFormat::Hdr
);
image_crate_backend!(
    IMAGE_CRATE_FARBFELD_BACKEND,
    decode_image_crate_farbfeld,
    dimensions_image_crate_farbfeld,
    "image-crate/farbfeld",
    ImageFormat::Farbfeld,
    Some(decode_image_crate_farbfeld_region)
);

image_extras_backend!(
    IMAGE_EXTRAS_WBMP_BACKEND,
    decode_image_extras_wbmp,
    dimensions_image_extras_wbmp,
    "image-extras/wbmp",
    image_extras::wbmp::WbmpDecoder::new
);
image_extras_backend!(
    IMAGE_EXTRAS_PCX_BACKEND,
    decode_image_extras_pcx,
    dimensions_image_extras_pcx,
    "image-extras/pcx",
    image_extras::pcx::PCXDecoder::new
);
image_extras_backend!(
    IMAGE_EXTRAS_SGI_BACKEND,
    decode_image_extras_sgi,
    dimensions_image_extras_sgi,
    "image-extras/sgi",
    image_extras::sgi::SgiDecoder::new
);
image_extras_backend!(
    IMAGE_EXTRAS_XBM_BACKEND,
    decode_image_extras_xbm,
    dimensions_image_extras_xbm,
    "image-extras/xbm",
    image_extras::xbm::XbmDecoder::new
);
image_extras_backend!(
    IMAGE_EXTRAS_XPM_BACKEND,
    decode_image_extras_xpm,
    dimensions_image_extras_xpm,
    "image-extras/xpm",
    image_extras::xpm::XpmDecoder::new
);

const RUNTIME_IMAGE_FORMAT_DESCRIPTORS: &[RuntimeImageFormatDescriptor] = &[
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Jpeg,
        code: 1,
        format_id: "jpeg",
        primary_mime_type: "image/jpeg",
        label: "JPEG",
        sniff: is_jpeg,
        decode_backend: &IMAGE_CRATE_JPEG_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: COMMON,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Png,
        code: 2,
        format_id: "png",
        primary_mime_type: "image/png",
        label: "PNG",
        sniff: is_png,
        decode_backend: &IMAGE_CRATE_PNG_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: COMMON.union(RuntimeImageFormatCapabilityFlags::REGION_DECODE),
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Gif,
        code: 3,
        format_id: "gif",
        primary_mime_type: "image/gif",
        label: "GIF",
        sniff: is_gif,
        decode_backend: &IMAGE_CRATE_GIF_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: ANIMATED,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Webp,
        code: 4,
        format_id: "webp",
        primary_mime_type: "image/webp",
        label: "WebP",
        sniff: is_webp,
        decode_backend: &IMAGE_CRATE_WEBP_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: ANIMATED,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Bmp,
        code: 5,
        format_id: "bmp",
        primary_mime_type: "image/bmp",
        label: "BMP",
        sniff: is_bmp,
        decode_backend: &IMAGE_CRATE_BMP_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: COMMON.union(RuntimeImageFormatCapabilityFlags::REGION_DECODE),
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Wbmp,
        code: 6,
        format_id: "wbmp",
        primary_mime_type: "image/vnd.wap.wbmp",
        label: "WBMP",
        sniff: is_wbmp,
        decode_backend: &IMAGE_EXTRAS_WBMP_BACKEND,
        dimensions_backend: RuntimeDimensionsBackend::Header(wbmp_header_dimensions),
        flags: COMMON,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Ico,
        code: 7,
        format_id: "ico",
        primary_mime_type: "image/x-icon",
        label: "ICO",
        sniff: is_ico,
        decode_backend: &IMAGE_CRATE_ICO_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: RUNTIME_ONLY,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Tiff,
        code: 8,
        format_id: "tiff",
        primary_mime_type: "image/tiff",
        label: "TIFF",
        sniff: is_tiff,
        decode_backend: &IMAGE_CRATE_TIFF_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: RUNTIME_ONLY,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Pnm,
        code: 9,
        format_id: "pnm",
        primary_mime_type: "image/x-portable-anymap",
        label: "PNM",
        sniff: is_pnm,
        decode_backend: &IMAGE_CRATE_PNM_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: RUNTIME_ONLY,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Qoi,
        code: 10,
        format_id: "qoi",
        primary_mime_type: "image/qoi",
        label: "QOI",
        sniff: is_qoi,
        decode_backend: &IMAGE_CRATE_QOI_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: RUNTIME_ONLY,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Tga,
        code: 11,
        format_id: "tga",
        primary_mime_type: "image/x-tga",
        label: "TGA",
        sniff: is_tga,
        decode_backend: &IMAGE_CRATE_TGA_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: RUNTIME_ONLY,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Dds,
        code: 12,
        format_id: "dds",
        primary_mime_type: "image/vnd.ms-dds",
        label: "DDS",
        sniff: is_dds,
        decode_backend: &IMAGE_CRATE_DDS_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: RUNTIME_ONLY,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Hdr,
        code: 13,
        format_id: "hdr",
        primary_mime_type: "image/vnd.radiance",
        label: "HDR",
        sniff: is_hdr,
        decode_backend: &IMAGE_CRATE_HDR_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: RUNTIME_ONLY,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Farbfeld,
        code: 14,
        format_id: "farbfeld",
        primary_mime_type: "image/x-farbfeld",
        label: "Farbfeld",
        sniff: is_farbfeld,
        decode_backend: &IMAGE_CRATE_FARBFELD_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: RUNTIME_ONLY.union(RuntimeImageFormatCapabilityFlags::REGION_DECODE),
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Pcx,
        code: 15,
        format_id: "pcx",
        primary_mime_type: "image/x-pcx",
        label: "PCX",
        sniff: is_pcx,
        decode_backend: &IMAGE_EXTRAS_PCX_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: RUNTIME_ONLY,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Sgi,
        code: 16,
        format_id: "sgi",
        primary_mime_type: "image/sgi",
        label: "SGI",
        sniff: is_sgi,
        decode_backend: &IMAGE_EXTRAS_SGI_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: RUNTIME_ONLY,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Xbm,
        code: 17,
        format_id: "xbm",
        primary_mime_type: "image/x-xbitmap",
        label: "XBM",
        sniff: is_xbm,
        decode_backend: &IMAGE_EXTRAS_XBM_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: RUNTIME_ONLY,
    },
    RuntimeImageFormatDescriptor {
        format: RuntimeImageFormat::Xpm,
        code: 18,
        format_id: "xpm",
        primary_mime_type: "image/x-xpixmap",
        label: "XPM",
        sniff: is_xpm,
        decode_backend: &IMAGE_EXTRAS_XPM_BACKEND,
        dimensions_backend: DECODER_DIMENSIONS,
        flags: RUNTIME_ONLY,
    },
];

fn runtime_image_format_descriptors() -> &'static [RuntimeImageFormatDescriptor] {
    RUNTIME_IMAGE_FORMAT_DESCRIPTORS
}

/// Runtime image format capability matrix for built-in providers.
pub fn runtime_image_format_capabilities() -> Vec<RuntimeImageFormatCapability> {
    runtime_image_format_descriptors()
        .iter()
        .map(|descriptor| descriptor.capability())
        .collect()
}

pub fn sniff_image_format(bytes: &[u8]) -> Option<RuntimeImageFormat> {
    runtime_image_format_descriptors()
        .iter()
        .find(|descriptor| (descriptor.sniff)(bytes))
        .map(|descriptor| descriptor.format)
}

#[allow(dead_code)]
pub(crate) fn runtime_image_format_label(format: RuntimeImageFormat) -> &'static str {
    format.descriptor().label
}

pub(crate) fn wbmp_dimensions(bytes: &[u8]) -> RuntimeResult<(u32, u32, usize)> {
    if bytes.len() < 5 {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "truncated WBMP header",
        ));
    }
    if bytes[0] != 0 || bytes[1] != 0 {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "unsupported WBMP type",
        ));
    }
    let (width, width_end) = read_wbmp_integer(bytes, 2)?;
    let (height, data_offset) = read_wbmp_integer(bytes, width_end)?;
    if width == 0 || height == 0 {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "invalid WBMP dimensions",
        ));
    }
    let row_bytes = width.div_ceil(8) as usize;
    let expected_len = row_bytes
        .checked_mul(height as usize)
        .and_then(|len| len.checked_add(data_offset))
        .ok_or_else(|| RuntimeError::new("metadata", false, "WBMP byte length overflows"))?;
    if bytes.len() != expected_len {
        return Err(RuntimeError::new(
            "metadata",
            false,
            "WBMP payload length does not match dimensions",
        ));
    }
    Ok((width, height, data_offset))
}

fn wbmp_header_dimensions(bytes: &[u8]) -> RuntimeResult<(u32, u32)> {
    let (width, height, _) = wbmp_dimensions(bytes)?;
    Ok((width, height))
}

fn decode_image_crate(
    format: ImageFormat,
    bytes: &[u8],
    stage: &'static str,
    label: &'static str,
) -> RuntimeResult<DynamicImage> {
    image::load_from_memory_with_format(bytes, format).map_err(|error| {
        RuntimeError::new(stage, false, format!("failed to decode {label}: {error}"))
    })
}

fn image_crate_dimensions(format: ImageFormat, bytes: &[u8]) -> RuntimeResult<(u32, u32)> {
    ImageReader::with_format(Cursor::new(bytes), format)
        .into_dimensions()
        .map_err(|error| {
            RuntimeError::new(
                "metadata",
                false,
                format!("failed to parse image dimensions: {error}"),
            )
        })
}

fn decode_png_region_rows(
    bytes: &[u8],
    region: RuntimeImageRegion,
    max_region_bytes: usize,
    stage: &'static str,
    label: &'static str,
) -> RuntimeResult<DynamicImage> {
    let mut decoder = png::Decoder::new(BufReader::new(Cursor::new(bytes)));
    decoder.set_transformations(png::Transformations::EXPAND);
    let mut reader = decoder.read_info().map_err(|error| {
        RuntimeError::new(
            stage,
            false,
            format!("failed to initialize {label} decoder: {error}"),
        )
    })?;
    let (image_width, image_height, interlaced, animated) = {
        let info = reader.info();
        (
            info.width,
            info.height,
            info.interlaced,
            info.animation_control.is_some(),
        )
    };
    if animated {
        return Err(RuntimeError::new(
            stage,
            false,
            "animated PNG region decode is unsupported",
        ));
    }
    if interlaced {
        return Err(RuntimeError::new(
            stage,
            false,
            "interlaced PNG region decode is unsupported",
        ));
    }
    validate_region_bounds(region, image_width, image_height, stage)?;
    let full_row_pitch = png_output_line_size(&reader, image_width, stage)?;
    let x_offset = png_output_line_size(&reader, region.x, stage)?;
    let region_row_pitch = png_output_line_size(&reader, region.width, stage)?;
    let region_row_end = x_offset
        .checked_add(region_row_pitch)
        .ok_or_else(|| RuntimeError::new(stage, false, "PNG region row offset overflows"))?;
    if region_row_end > full_row_pitch {
        return Err(RuntimeError::new(
            stage,
            false,
            "PNG region row exceeds decoded row bounds",
        ));
    }
    let region_len = region_row_pitch
        .checked_mul(region.height as usize)
        .ok_or_else(|| RuntimeError::new(stage, false, "PNG region byte length overflows"))?;
    if region_len > max_region_bytes {
        return Err(RuntimeError::new(
            stage,
            false,
            format!("tile region decoded bytes exceed limit ({region_len}>{max_region_bytes})"),
        ));
    }
    let (png_color_type, bit_depth) = reader.output_color_type();
    let color_type = png_output_color_type(png_color_type, bit_depth, stage)?;
    let mut row = vec![0_u8; full_row_pitch];
    let mut region_bytes = Vec::with_capacity(region_len);
    let y_end = region
        .y
        .checked_add(region.height)
        .ok_or_else(|| RuntimeError::new(stage, false, "PNG region y range overflows"))?;
    let mut row_index = 0_u32;
    while reader
        .read_row(&mut row)
        .map_err(|error| {
            RuntimeError::new(stage, false, format!("failed to decode {label}: {error}"))
        })?
        .is_some()
    {
        if row_index >= region.y && row_index < y_end {
            region_bytes.extend_from_slice(&row[x_offset..region_row_end]);
        }
        row_index = row_index
            .checked_add(1)
            .ok_or_else(|| RuntimeError::new(stage, false, "PNG row index overflows"))?;
        if row_index >= y_end {
            break;
        }
    }
    if region_bytes.len() != region_len {
        return Err(RuntimeError::new(
            stage,
            false,
            "PNG decoder ended before requested region was complete",
        ));
    }
    if bit_depth == png::BitDepth::Sixteen {
        convert_png_region_to_native_endian(&mut region_bytes, stage)?;
    }
    dynamic_image_from_region(region_bytes, region.width, region.height, color_type, stage)
}

fn decode_image_crate_bmp_region(
    bytes: &[u8],
    region: RuntimeImageRegion,
    max_region_bytes: usize,
    stage: &'static str,
    label: &'static str,
) -> RuntimeResult<DynamicImage> {
    let mut decoder = image::codecs::bmp::BmpDecoder::new(Cursor::new(bytes)).map_err(|error| {
        RuntimeError::new(
            stage,
            false,
            format!("failed to initialize {label} decoder: {error}"),
        )
    })?;
    let color_type = decoder.color_type();
    let row_pitch = checked_region_row_pitch(region.width, color_type.bytes_per_pixel(), stage)?;
    let region_len = row_pitch
        .checked_mul(region.height as usize)
        .ok_or_else(|| RuntimeError::new(stage, false, "tile region byte length overflows"))?;
    if region_len > max_region_bytes {
        return Err(RuntimeError::new(
            stage,
            false,
            format!("tile region decoded bytes exceed limit ({region_len}>{max_region_bytes})"),
        ));
    }
    let mut region_bytes = vec![0_u8; region_len];
    decoder
        .read_rect(
            region.x,
            region.y,
            region.width,
            region.height,
            &mut region_bytes,
            row_pitch,
        )
        .map_err(|error| {
            RuntimeError::new(stage, false, format!("failed to decode {label}: {error}"))
        })?;
    dynamic_image_from_region(region_bytes, region.width, region.height, color_type, stage)
}

fn decode_image_crate_farbfeld_region(
    bytes: &[u8],
    region: RuntimeImageRegion,
    max_region_bytes: usize,
    stage: &'static str,
    label: &'static str,
) -> RuntimeResult<DynamicImage> {
    let mut decoder =
        image::codecs::farbfeld::FarbfeldDecoder::new(Cursor::new(bytes)).map_err(|error| {
            RuntimeError::new(
                stage,
                false,
                format!("failed to initialize {label} decoder: {error}"),
            )
        })?;
    let color_type = decoder.color_type();
    let row_pitch = checked_region_row_pitch(region.width, color_type.bytes_per_pixel(), stage)?;
    let region_len = row_pitch
        .checked_mul(region.height as usize)
        .ok_or_else(|| RuntimeError::new(stage, false, "tile region byte length overflows"))?;
    if region_len > max_region_bytes {
        return Err(RuntimeError::new(
            stage,
            false,
            format!("tile region decoded bytes exceed limit ({region_len}>{max_region_bytes})"),
        ));
    }
    let mut region_bytes = vec![0_u8; region_len];
    decoder
        .read_rect(
            region.x,
            region.y,
            region.width,
            region.height,
            &mut region_bytes,
            row_pitch,
        )
        .map_err(|error| {
            RuntimeError::new(stage, false, format!("failed to decode {label}: {error}"))
        })?;
    dynamic_image_from_region(region_bytes, region.width, region.height, color_type, stage)
}

fn checked_region_row_pitch(
    width: u32,
    bytes_per_pixel: u8,
    stage: &'static str,
) -> RuntimeResult<usize> {
    (width as usize)
        .checked_mul(usize::from(bytes_per_pixel))
        .ok_or_else(|| RuntimeError::new(stage, false, "tile row pitch overflows"))
}

fn validate_region_bounds(
    region: RuntimeImageRegion,
    image_width: u32,
    image_height: u32,
    stage: &'static str,
) -> RuntimeResult<()> {
    let x_end = region
        .x
        .checked_add(region.width)
        .ok_or_else(|| RuntimeError::new(stage, false, "region x range overflows"))?;
    let y_end = region
        .y
        .checked_add(region.height)
        .ok_or_else(|| RuntimeError::new(stage, false, "region y range overflows"))?;
    if region.width == 0
        || region.height == 0
        || region.x >= image_width
        || region.y >= image_height
        || x_end > image_width
        || y_end > image_height
    {
        return Err(RuntimeError::new(
            stage,
            false,
            "region is outside image bounds",
        ));
    }
    Ok(())
}

fn png_output_line_size<R: std::io::BufRead + std::io::Seek>(
    reader: &png::Reader<R>,
    width: u32,
    stage: &'static str,
) -> RuntimeResult<usize> {
    reader
        .output_line_size(width)
        .ok_or_else(|| RuntimeError::new(stage, false, "PNG row byte length overflows"))
}

fn png_output_color_type(
    color_type: png::ColorType,
    bit_depth: png::BitDepth,
    stage: &'static str,
) -> RuntimeResult<image::ColorType> {
    match (color_type, bit_depth) {
        (png::ColorType::Grayscale, png::BitDepth::Eight) => Ok(image::ColorType::L8),
        (png::ColorType::Grayscale, png::BitDepth::Sixteen) => Ok(image::ColorType::L16),
        (png::ColorType::GrayscaleAlpha, png::BitDepth::Eight) => Ok(image::ColorType::La8),
        (png::ColorType::GrayscaleAlpha, png::BitDepth::Sixteen) => Ok(image::ColorType::La16),
        (png::ColorType::Rgb, png::BitDepth::Eight) => Ok(image::ColorType::Rgb8),
        (png::ColorType::Rgb, png::BitDepth::Sixteen) => Ok(image::ColorType::Rgb16),
        (png::ColorType::Rgba, png::BitDepth::Eight) => Ok(image::ColorType::Rgba8),
        (png::ColorType::Rgba, png::BitDepth::Sixteen) => Ok(image::ColorType::Rgba16),
        (other_color, other_depth) => Err(RuntimeError::new(
            stage,
            false,
            format!("unsupported PNG region color type: {other_color:?}/{other_depth:?}"),
        )),
    }
}

fn convert_png_region_to_native_endian(
    region: &mut [u8],
    stage: &'static str,
) -> RuntimeResult<()> {
    let mut chunks = region.chunks_exact_mut(2);
    for chunk in &mut chunks {
        let value = u16::from_be_bytes([chunk[0], chunk[1]]);
        chunk.copy_from_slice(&value.to_ne_bytes());
    }
    if !chunks.into_remainder().is_empty() {
        return Err(RuntimeError::new(
            stage,
            false,
            "invalid PNG 16-bit region byte alignment",
        ));
    }
    Ok(())
}

fn dynamic_image_from_region(
    region: Vec<u8>,
    width: u32,
    height: u32,
    color_type: image::ColorType,
    stage: &'static str,
) -> RuntimeResult<DynamicImage> {
    match color_type {
        image::ColorType::L8 => image::GrayImage::from_raw(width, height, region)
            .map(DynamicImage::ImageLuma8)
            .ok_or_else(|| RuntimeError::new(stage, false, "invalid L8 tile region buffer")),
        image::ColorType::L16 => u16_image_from_region::<image::Luma<u16>>(
            region,
            width,
            height,
            DynamicImage::ImageLuma16,
            "L16",
            stage,
        ),
        image::ColorType::La8 => {
            image::ImageBuffer::<image::LumaA<u8>, Vec<u8>>::from_raw(width, height, region)
                .map(DynamicImage::ImageLumaA8)
                .ok_or_else(|| RuntimeError::new(stage, false, "invalid LA8 tile region buffer"))
        }
        image::ColorType::La16 => u16_image_from_region::<image::LumaA<u16>>(
            region,
            width,
            height,
            DynamicImage::ImageLumaA16,
            "LA16",
            stage,
        ),
        image::ColorType::Rgb8 => image::RgbImage::from_raw(width, height, region)
            .map(DynamicImage::ImageRgb8)
            .ok_or_else(|| RuntimeError::new(stage, false, "invalid RGB tile region buffer")),
        image::ColorType::Rgb16 => u16_image_from_region::<image::Rgb<u16>>(
            region,
            width,
            height,
            DynamicImage::ImageRgb16,
            "RGB16",
            stage,
        ),
        image::ColorType::Rgba8 => image::RgbaImage::from_raw(width, height, region)
            .map(DynamicImage::ImageRgba8)
            .ok_or_else(|| RuntimeError::new(stage, false, "invalid RGBA tile region buffer")),
        image::ColorType::Rgba16 => u16_image_from_region::<image::Rgba<u16>>(
            region,
            width,
            height,
            DynamicImage::ImageRgba16,
            "RGBA16",
            stage,
        ),
        other => Err(RuntimeError::new(
            stage,
            false,
            format!("unsupported tile region color type: {other:?}"),
        )),
    }
}

fn u16_image_from_region<P>(
    region: Vec<u8>,
    width: u32,
    height: u32,
    wrap: fn(image::ImageBuffer<P, Vec<u16>>) -> DynamicImage,
    label: &'static str,
    stage: &'static str,
) -> RuntimeResult<DynamicImage>
where
    P: image::Pixel<Subpixel = u16> + 'static,
{
    let mut pixels = Vec::with_capacity(region.len() / 2);
    let mut chunks = region.chunks_exact(2);
    for chunk in &mut chunks {
        pixels.push(u16::from_ne_bytes([chunk[0], chunk[1]]));
    }
    if !chunks.remainder().is_empty() {
        return Err(RuntimeError::new(
            stage,
            false,
            format!("invalid {label} tile region byte alignment"),
        ));
    }
    image::ImageBuffer::<P, Vec<u16>>::from_raw(width, height, pixels)
        .map(wrap)
        .ok_or_else(|| {
            RuntimeError::new(stage, false, format!("invalid {label} tile region buffer"))
        })
}

fn decode_extra_decoder<D>(
    decoder: Result<D, image::ImageError>,
    stage: &'static str,
    label: &'static str,
) -> RuntimeResult<DynamicImage>
where
    D: ImageDecoder,
{
    let decoder = decoder.map_err(|error| {
        RuntimeError::new(
            stage,
            false,
            format!("failed to initialize {label} decoder: {error}"),
        )
    })?;
    DynamicImage::from_decoder(decoder).map_err(|error| {
        RuntimeError::new(stage, false, format!("failed to decode {label}: {error}"))
    })
}

fn extra_dimensions<D>(decoder: Result<D, image::ImageError>) -> RuntimeResult<(u32, u32)>
where
    D: ImageDecoder,
{
    let decoder = decoder.map_err(|error| {
        RuntimeError::new(
            "metadata",
            false,
            format!("failed to initialize image metadata decoder: {error}"),
        )
    })?;
    Ok(decoder.dimensions())
}

fn is_jpeg(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0xff, 0xd8, 0xff])
}

fn is_png(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
}

fn is_gif(bytes: &[u8]) -> bool {
    bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a")
}

fn is_webp(bytes: &[u8]) -> bool {
    bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP"
}

fn is_bmp(bytes: &[u8]) -> bool {
    bytes.starts_with(b"BM")
}

fn is_ico(bytes: &[u8]) -> bool {
    bytes.len() >= 6
        && bytes[0] == 0
        && bytes[1] == 0
        && bytes[2] == 1
        && bytes[3] == 0
        && (bytes[4] != 0 || bytes[5] != 0)
}

fn is_wbmp(bytes: &[u8]) -> bool {
    wbmp_dimensions(bytes).is_ok()
}

fn is_tiff(bytes: &[u8]) -> bool {
    bytes.starts_with(b"MM\0*") || bytes.starts_with(b"II*\0")
}

fn is_dds(bytes: &[u8]) -> bool {
    bytes.starts_with(b"DDS ")
}

fn is_hdr(bytes: &[u8]) -> bool {
    bytes.starts_with(b"#?RADIANCE")
}

fn is_qoi(bytes: &[u8]) -> bool {
    bytes.starts_with(b"qoif")
}

fn is_pnm(bytes: &[u8]) -> bool {
    bytes.len() >= 3
        && bytes[0] == b'P'
        && (b'1'..=b'7').contains(&bytes[1])
        && is_ascii_whitespace(bytes[2])
}

fn is_farbfeld(bytes: &[u8]) -> bool {
    bytes.starts_with(b"farbfeld")
}

fn is_tga(bytes: &[u8]) -> bool {
    if bytes.len() < 18 {
        return false;
    }
    let color_map_type = bytes[1];
    let image_type = bytes[2];
    let width = u16::from_le_bytes([bytes[12], bytes[13]]);
    let height = u16::from_le_bytes([bytes[14], bytes[15]]);
    let pixel_depth = bytes[16];
    let valid_image_type = matches!(image_type, 1 | 2 | 3 | 9 | 10 | 11);
    let valid_depth = matches!(pixel_depth, 8 | 15 | 16 | 24 | 32);
    color_map_type <= 1 && valid_image_type && width > 0 && height > 0 && valid_depth
}

fn is_pcx(bytes: &[u8]) -> bool {
    bytes.len() >= 4
        && bytes[0] == 0x0a
        && matches!(bytes[1], 0 | 2 | 3 | 4 | 5)
        && bytes[2] == 1
        && matches!(bytes[3], 1 | 2 | 4 | 8)
}

fn is_sgi(bytes: &[u8]) -> bool {
    bytes.len() >= 4
        && bytes[0] == 0x01
        && bytes[1] == 0xda
        && matches!(bytes[2], 0 | 1)
        && matches!(bytes[3], 1 | 2)
}

fn is_xbm(bytes: &[u8]) -> bool {
    bytes.starts_with(b"#define ") && bytes.windows(7).any(|window| window == b"_bits[]")
}

fn is_xpm(bytes: &[u8]) -> bool {
    bytes.starts_with(b"/* XPM */")
}

fn is_ascii_whitespace(value: u8) -> bool {
    matches!(value, b'\t' | b'\n' | b'\r' | b' ')
}

fn read_wbmp_integer(bytes: &[u8], offset: usize) -> RuntimeResult<(u32, usize)> {
    let mut value = 0_u32;
    let mut index = offset;
    let mut read = 0_usize;
    while index < bytes.len() {
        let byte = bytes[index];
        index += 1;
        read += 1;
        if read > 5 {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "WBMP integer is too long",
            ));
        }
        value = value
            .checked_shl(7)
            .and_then(|shifted| shifted.checked_add(u32::from(byte & 0x7f)))
            .ok_or_else(|| RuntimeError::new("metadata", false, "WBMP integer overflows"))?;
        if byte & 0x80 == 0 {
            return Ok((value, index));
        }
    }
    Err(RuntimeError::new(
        "metadata",
        false,
        "truncated WBMP integer",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_table_defines_stable_format_order_and_codes() {
        let formats: Vec<RuntimeImageFormat> = runtime_image_format_descriptors()
            .iter()
            .map(|descriptor| descriptor.format)
            .collect();

        assert_eq!(
            formats,
            vec![
                RuntimeImageFormat::Jpeg,
                RuntimeImageFormat::Png,
                RuntimeImageFormat::Gif,
                RuntimeImageFormat::Webp,
                RuntimeImageFormat::Bmp,
                RuntimeImageFormat::Wbmp,
                RuntimeImageFormat::Ico,
                RuntimeImageFormat::Tiff,
                RuntimeImageFormat::Pnm,
                RuntimeImageFormat::Qoi,
                RuntimeImageFormat::Tga,
                RuntimeImageFormat::Dds,
                RuntimeImageFormat::Hdr,
                RuntimeImageFormat::Farbfeld,
                RuntimeImageFormat::Pcx,
                RuntimeImageFormat::Sgi,
                RuntimeImageFormat::Xbm,
                RuntimeImageFormat::Xpm,
            ]
        );
        let codes: Vec<u8> = formats.iter().map(|format| format.code()).collect();
        assert_eq!(codes, (1_u8..=18).collect::<Vec<u8>>());
    }

    #[test]
    fn descriptor_table_is_the_format_routing_source() {
        let descriptors = runtime_image_format_descriptors();
        let mut seen_codes = std::collections::BTreeSet::new();
        let mut seen_format_ids = std::collections::BTreeSet::new();
        let mut seen_mime_types = std::collections::BTreeSet::new();

        for descriptor in descriptors {
            assert_eq!(descriptor.format.code(), descriptor.code);
            assert_eq!(descriptor.format.format_id(), descriptor.format_id);
            assert_eq!(
                descriptor.format.primary_mime_type(),
                descriptor.primary_mime_type
            );
            assert!(seen_codes.insert(descriptor.code));
            assert!(seen_format_ids.insert(descriptor.format_id));
            assert!(seen_mime_types.insert(descriptor.primary_mime_type));
            assert!(!descriptor.label.is_empty());
            assert!(!descriptor.format_id.is_empty());
            assert!(descriptor.primary_mime_type.starts_with("image/"));
            assert!(!descriptor.decode_backend.id.is_empty());
        }
    }

    #[test]
    fn decoder_backends_are_explicit_adapters() {
        let mut seen_backend_ids = std::collections::BTreeSet::new();
        let mut backend_counts_by_provider = std::collections::BTreeMap::new();
        let mut region_decode_backends = 0;

        for descriptor in runtime_image_format_descriptors() {
            let backend = descriptor.decode_backend;
            assert!(
                seen_backend_ids.insert(backend.id),
                "duplicate runtime image decoder backend {}",
                backend.id
            );
            if backend.region_decode.is_some() {
                region_decode_backends += 1;
            }
            assert!(!backend.provider.id.is_empty());
            assert!(!backend.provider.crate_name.is_empty());
            assert!(backend.id.starts_with(backend.provider.id));
            *backend_counts_by_provider
                .entry(backend.provider.id)
                .or_insert(0) += 1;
        }
        assert_eq!(backend_counts_by_provider["image-crate"], 13);
        assert_eq!(backend_counts_by_provider["image-extras"], 5);
        assert_eq!(region_decode_backends, 3);
        assert!(RuntimeImageFormat::Png.supports_region_decode());
        assert!(RuntimeImageFormat::Bmp.supports_region_decode());
        assert!(RuntimeImageFormat::Farbfeld.supports_region_decode());
        assert!(!RuntimeImageFormat::Jpeg.supports_region_decode());
    }

    #[test]
    fn capabilities_are_projected_from_format_descriptors() {
        let descriptors = runtime_image_format_descriptors();
        let capabilities = runtime_image_format_capabilities();

        assert_eq!(capabilities.len(), descriptors.len());
        for (descriptor, capability) in descriptors.iter().zip(capabilities.iter().copied()) {
            assert_eq!(capability, descriptor.capability());
        }
        let bmp = capabilities
            .iter()
            .find(|capability| capability.format == RuntimeImageFormat::Bmp)
            .expect("BMP capability should exist");
        assert_ne!(
            bmp.flags.bits() & RuntimeImageFormatCapabilityFlags::REGION_DECODE.bits(),
            0
        );
        let png = capabilities
            .iter()
            .find(|capability| capability.format == RuntimeImageFormat::Png)
            .expect("PNG capability should exist");
        assert_ne!(
            png.flags.bits() & RuntimeImageFormatCapabilityFlags::REGION_DECODE.bits(),
            0
        );
        let farbfeld = capabilities
            .iter()
            .find(|capability| capability.format == RuntimeImageFormat::Farbfeld)
            .expect("Farbfeld capability should exist");
        assert_ne!(
            farbfeld.flags.bits() & RuntimeImageFormatCapabilityFlags::REGION_DECODE.bits(),
            0
        );
    }

    #[test]
    fn extras_formats_use_extras_decoder_backend() {
        for format in [
            RuntimeImageFormat::Wbmp,
            RuntimeImageFormat::Pcx,
            RuntimeImageFormat::Sgi,
            RuntimeImageFormat::Xbm,
            RuntimeImageFormat::Xpm,
        ] {
            assert_eq!(
                format.descriptor().decode_backend.provider.id,
                "image-extras"
            );
        }
    }

    #[test]
    fn custom_header_dimensions_are_descriptor_level_hooks() {
        let descriptor = RuntimeImageFormat::Wbmp.descriptor();
        assert!(matches!(
            descriptor.dimensions_backend,
            RuntimeDimensionsBackend::Header(_)
        ));
    }
}
