use super::{
    abi_struct_is_compatible, bytes_from_ptr, bytes_to_str, set_plugin_output_mime,
    PixaPluginHostApiV1, PixaPluginModuleApiV1, PixaPluginOutputV1, PixaPluginProcessRequestV1,
};
use image::{imageops::FilterType, ImageEncoder};
use pixa_core::BoundedBytesWriter;
use std::ffi::{c_char, c_int, c_uchar, c_void, CStr};
use std::io::Cursor;
use std::ptr;
use std::sync::OnceLock;

const OUTPUT_MIME: &[u8] = b"image/png";
const TJINIT_DECOMPRESS: c_int = 1;
const TJPARAM_SUBSAMP: c_int = 4;
const TJPARAM_JPEGWIDTH: c_int = 5;
const TJPARAM_JPEGHEIGHT: c_int = 6;
const TJPARAM_PROGRESSIVE: c_int = 12;
const TJPARAM_LOSSLESS: c_int = 15;
const TJPARAM_MAXMEMORY: c_int = 23;
const TJPF_RGBA: c_int = 7;
const FULL_FRAME_WORKING_BYTES_PER_PIXEL: u64 = 16;
const MEBIBYTE: usize = 1024 * 1024;

static HOST_API: OnceLock<PixaPluginHostApiV1> = OnceLock::new();

#[repr(C)]
#[derive(Clone, Copy)]
struct TjRegion {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TjScalingFactor {
    num: c_int,
    denom: c_int,
}

type TjHandle = *mut c_void;

unsafe extern "C" {
    fn tj3Init(init_type: c_int) -> TjHandle;
    fn tj3Destroy(handle: TjHandle);
    fn tj3GetErrorStr(handle: TjHandle) -> *mut c_char;
    fn tj3Get(handle: TjHandle, param: c_int) -> c_int;
    fn tj3Set(handle: TjHandle, param: c_int, value: c_int) -> c_int;
    fn tj3DecompressHeader(handle: TjHandle, jpeg_buf: *const c_uchar, jpeg_size: usize) -> c_int;
    fn tj3GetScalingFactors(count: *mut c_int) -> *mut TjScalingFactor;
    fn tj3SetScalingFactor(handle: TjHandle, scaling_factor: TjScalingFactor) -> c_int;
    fn tj3SetCroppingRegion(handle: TjHandle, cropping_region: TjRegion) -> c_int;
    fn tj3Decompress8(
        handle: TjHandle,
        jpeg_buf: *const c_uchar,
        jpeg_size: usize,
        dst_buf: *mut c_uchar,
        pitch: c_int,
        pixel_format: c_int,
    ) -> c_int;
}

struct TurboHandle(TjHandle);

impl TurboHandle {
    fn new_decompressor() -> Result<Self, i32> {
        let handle = unsafe { tj3Init(TJINIT_DECOMPRESS) };
        if handle.is_null() {
            Err(-20)
        } else {
            Ok(Self(handle))
        }
    }

    fn as_ptr(&self) -> TjHandle {
        self.0
    }

    fn status(&self, status: c_int, code: i32) -> Result<(), i32> {
        if status == 0 {
            Ok(())
        } else {
            let _message = self.error_message();
            Err(code)
        }
    }

    fn error_message(&self) -> Option<String> {
        let ptr = unsafe { tj3GetErrorStr(self.0) };
        if ptr.is_null() {
            return None;
        }
        unsafe { CStr::from_ptr(ptr) }
            .to_str()
            .ok()
            .map(str::to_string)
    }
}

impl Drop for TurboHandle {
    fn drop(&mut self) {
        unsafe { tj3Destroy(self.0) };
    }
}

#[derive(Clone, Copy, Debug)]
struct TileSpec {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    decoded_width: u32,
    decoded_height: u32,
    filter: FilterType,
}

#[derive(Clone, Copy, Debug)]
struct ScaledTileGeometry {
    factor: TjScalingFactor,
    crop_x: u32,
    crop_y: u32,
    crop_width: u32,
    crop_height: u32,
    tile_offset_x: u32,
    tile_offset_y: u32,
    tile_width: u32,
    tile_height: u32,
}

#[allow(private_interfaces)]
#[no_mangle]
pub unsafe extern "C" fn pixa_jpeg_turbo_processor_plugin_init(
    host: *const PixaPluginHostApiV1,
    module: *mut PixaPluginModuleApiV1,
) -> i32 {
    if host.is_null() || module.is_null() {
        return -1;
    }
    let host_api = unsafe { *host };
    if !abi_struct_is_compatible::<PixaPluginHostApiV1>(host_api.abi_version, host_api.struct_size)
        || host_api.buffer_alloc.is_none()
        || host_api.buffer_data.is_none()
        || host_api.buffer_free.is_none()
    {
        return -2;
    }
    let module_api = unsafe { &*module };
    if !abi_struct_is_compatible::<PixaPluginModuleApiV1>(
        module_api.abi_version,
        module_api.struct_size,
    ) {
        return -2;
    }
    let _ = HOST_API.set(host_api);
    unsafe {
        (*module).process = Some(process_jpeg_tile);
    }
    0
}

unsafe extern "C" fn process_jpeg_tile(
    request: *const PixaPluginProcessRequestV1,
    output: *mut PixaPluginOutputV1,
) -> i32 {
    if request.is_null() || output.is_null() {
        return -1;
    }
    let request = unsafe { &*request };
    let output = unsafe { &mut *output };
    if !abi_struct_is_compatible::<PixaPluginProcessRequestV1>(
        request.abi_version,
        request.struct_size,
    ) || !abi_struct_is_compatible::<PixaPluginOutputV1>(output.abi_version, output.struct_size)
    {
        return -2;
    }
    let Some(operation) = (unsafe { bytes_to_str(request.operation_ptr, request.operation_len) })
    else {
        return -2;
    };
    if !operation.eq_ignore_ascii_case("tile:jpeg") {
        return -3;
    }
    let Some(format_id) = (unsafe { bytes_to_str(request.format_id_ptr, request.format_id_len) })
    else {
        return -4;
    };
    if !format_id.eq_ignore_ascii_case("jpeg") {
        return -5;
    }
    let Some(descriptor) =
        (unsafe { bytes_to_str(request.descriptor_ptr, request.descriptor_len) })
    else {
        return -6;
    };
    let Some(input) = (unsafe { bytes_from_ptr(request.bytes_ptr, request.bytes_len) }) else {
        return -7;
    };
    let spec = match parse_tile_spec(descriptor) {
        Some(spec) => spec,
        None => return -8,
    };
    let png = match decode_tile_to_png(
        input,
        spec,
        request.max_decoded_pixels,
        request.max_output_bytes,
    ) {
        Ok(bytes) => bytes,
        Err(code) => return code,
    };
    copy_output_to_host_buffer(&png, output, request.max_output_bytes)
}

fn decode_tile_to_png(
    input: &[u8],
    spec: TileSpec,
    max_decoded_pixels: u64,
    max_output_bytes: usize,
) -> Result<Vec<u8>, i32> {
    validate_tile_spec(spec)?;
    let handle = TurboHandle::new_decompressor()?;
    handle.status(
        unsafe { tj3DecompressHeader(handle.as_ptr(), input.as_ptr(), input.len()) },
        -30,
    )?;
    let width = checked_header_dimension(handle.as_ptr(), TJPARAM_JPEGWIDTH)?;
    let height = checked_header_dimension(handle.as_ptr(), TJPARAM_JPEGHEIGHT)?;
    validate_bounds(spec, width, height)?;

    let allocation_pixel_budget =
        rgba_allocation_pixel_budget(max_decoded_pixels, max_output_bytes)?;
    validate_pixel_budget(
        spec.decoded_width,
        spec.decoded_height,
        allocation_pixel_budget,
    )?;
    if unsafe { tj3Get(handle.as_ptr(), TJPARAM_LOSSLESS) } != 0 {
        return Err(-31);
    }
    if unsafe { tj3Get(handle.as_ptr(), TJPARAM_PROGRESSIVE) } != 0 {
        validate_full_frame_working_set(width, height, max_decoded_pixels, max_output_bytes)?;
        let max_memory_mb = max_output_bytes / MEBIBYTE;
        if max_memory_mb == 0 {
            return Err(-37);
        }
        handle.status(
            unsafe {
                tj3Set(
                    handle.as_ptr(),
                    TJPARAM_MAXMEMORY,
                    c_int::try_from(max_memory_mb).map_err(|_| -37)?,
                )
            },
            -37,
        )?;
    }
    let subsamp = unsafe { tj3Get(handle.as_ptr(), TJPARAM_SUBSAMP) };
    let (mcu_width, _) = mcu_size(subsamp).ok_or(-32)?;
    let geometry = select_scaled_tile_geometry(spec, mcu_width, allocation_pixel_budget)?;
    handle.status(
        unsafe { tj3SetScalingFactor(handle.as_ptr(), geometry.factor) },
        -33,
    )?;
    let crop_pixels = pixel_count(geometry.crop_width, geometry.crop_height)?;
    let raw_len = crop_pixels.checked_mul(4).ok_or(-38)?;
    let raw_len = usize::try_from(raw_len).map_err(|_| -39)?;
    let mut pixels = vec![0_u8; raw_len];
    let pitch = i32::try_from(u64::from(geometry.crop_width) * 4).map_err(|_| -40)?;
    let region = TjRegion {
        x: i32::try_from(geometry.crop_x).map_err(|_| -41)?,
        y: i32::try_from(geometry.crop_y).map_err(|_| -42)?,
        w: i32::try_from(geometry.crop_width).map_err(|_| -43)?,
        h: i32::try_from(geometry.crop_height).map_err(|_| -44)?,
    };
    handle.status(
        unsafe { tj3SetCroppingRegion(handle.as_ptr(), region) },
        -45,
    )?;
    handle.status(
        unsafe {
            tj3Decompress8(
                handle.as_ptr(),
                input.as_ptr(),
                input.len(),
                pixels.as_mut_ptr(),
                pitch,
                TJPF_RGBA,
            )
        },
        -46,
    )?;

    let crop =
        image::RgbaImage::from_raw(geometry.crop_width, geometry.crop_height, pixels).ok_or(-47)?;
    let exact_tile = if geometry.tile_offset_x == 0
        && geometry.tile_offset_y == 0
        && geometry.tile_width == geometry.crop_width
        && geometry.tile_height == geometry.crop_height
    {
        crop
    } else {
        image::imageops::crop_imm(
            &crop,
            geometry.tile_offset_x,
            geometry.tile_offset_y,
            geometry.tile_width,
            geometry.tile_height,
        )
        .to_image()
    };
    let mut image = image::DynamicImage::ImageRgba8(exact_tile);
    if geometry.tile_width != spec.decoded_width || geometry.tile_height != spec.decoded_height {
        image = image.resize_exact(spec.decoded_width, spec.decoded_height, spec.filter);
    }
    encode_png(image, max_output_bytes)
}

fn copy_output_to_host_buffer(
    bytes: &[u8],
    output: &mut PixaPluginOutputV1,
    max_output_bytes: usize,
) -> i32 {
    if bytes.len() > max_output_bytes {
        return -60;
    }
    let Some(host) = HOST_API.get() else {
        return -61;
    };
    let Some(buffer_alloc) = host.buffer_alloc else {
        return -62;
    };
    let Some(buffer_data) = host.buffer_data else {
        return -63;
    };
    let Some(buffer_free) = host.buffer_free else {
        return -64;
    };
    let handle = unsafe { buffer_alloc(bytes.len()) };
    if handle.is_null() {
        return -65;
    }
    let data = unsafe { buffer_data(handle) };
    if data.is_null() {
        unsafe { buffer_free(handle) };
        return -66;
    }
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), data, bytes.len());
        output.buffer = handle;
    }
    if set_plugin_output_mime(output, OUTPUT_MIME).is_err() {
        unsafe { buffer_free(handle) };
        output.buffer = ptr::null_mut();
        return -67;
    }
    0
}

fn select_scaled_tile_geometry(
    spec: TileSpec,
    mcu_width: u32,
    max_decoded_pixels: u64,
) -> Result<ScaledTileGeometry, i32> {
    let mut factors = supported_scaling_factors()?;
    factors.retain(|factor| factor.num > 0 && factor.denom > 0 && factor.num <= factor.denom);
    factors.sort_by(|left, right| {
        let left_value = i64::from(left.num) * i64::from(right.denom);
        let right_value = i64::from(right.num) * i64::from(left.denom);
        left_value.cmp(&right_value)
    });
    factors.dedup_by(|left, right| {
        i64::from(left.num) * i64::from(right.denom) == i64::from(right.num) * i64::from(left.denom)
    });

    let mut fitting = Vec::with_capacity(factors.len());
    for factor in factors {
        let Ok(geometry) = scaled_tile_geometry(spec, mcu_width, factor) else {
            continue;
        };
        if pixel_count(geometry.crop_width, geometry.crop_height)? <= max_decoded_pixels {
            fitting.push(geometry);
        }
    }
    fitting
        .iter()
        .copied()
        .find(|geometry| {
            geometry.tile_width >= spec.decoded_width && geometry.tile_height >= spec.decoded_height
        })
        .or_else(|| fitting.last().copied())
        .ok_or(-37)
}

fn supported_scaling_factors() -> Result<Vec<TjScalingFactor>, i32> {
    let mut count = 0;
    let factors = unsafe { tj3GetScalingFactors(&mut count) };
    if factors.is_null() || !(1..=64).contains(&count) {
        return Err(-34);
    }
    Ok(unsafe { std::slice::from_raw_parts(factors, count as usize) }.to_vec())
}

fn scaled_tile_geometry(
    spec: TileSpec,
    mcu_width: u32,
    factor: TjScalingFactor,
) -> Result<ScaledTileGeometry, i32> {
    let source_right = spec.x.checked_add(spec.width).ok_or(-35)?;
    let source_bottom = spec.y.checked_add(spec.height).ok_or(-36)?;
    let tile_x = scaled_dimension(spec.x, factor)?;
    let tile_y = scaled_dimension(spec.y, factor)?;
    let tile_right = scaled_dimension(source_right, factor)?;
    let tile_bottom = scaled_dimension(source_bottom, factor)?;
    let tile_width = tile_right.checked_sub(tile_x).ok_or(-35)?;
    let tile_height = tile_bottom.checked_sub(tile_y).ok_or(-36)?;
    if tile_width == 0 || tile_height == 0 {
        return Err(-37);
    }
    let scaled_mcu_width = scaled_dimension(mcu_width, factor)?;
    if scaled_mcu_width == 0 {
        return Err(-34);
    }
    let crop_x = align_down(tile_x, scaled_mcu_width);
    let crop_width = tile_right.checked_sub(crop_x).ok_or(-35)?;

    Ok(ScaledTileGeometry {
        factor,
        crop_x,
        crop_y: tile_y,
        crop_width,
        crop_height: tile_height,
        tile_offset_x: tile_x.checked_sub(crop_x).ok_or(-35)?,
        tile_offset_y: 0,
        tile_width,
        tile_height,
    })
}

fn scaled_dimension(value: u32, factor: TjScalingFactor) -> Result<u32, i32> {
    let numerator = u64::try_from(factor.num).map_err(|_| -34)?;
    let denominator = u64::try_from(factor.denom).map_err(|_| -34)?;
    if numerator == 0 || denominator == 0 {
        return Err(-34);
    }
    let scaled = u64::from(value)
        .checked_mul(numerator)
        .and_then(|value| value.checked_add(denominator - 1))
        .ok_or(-36)?
        / denominator;
    u32::try_from(scaled).map_err(|_| -36)
}

fn validate_pixel_budget(width: u32, height: u32, limit: u64) -> Result<(), i32> {
    let pixels = pixel_count(width, height)?;
    if pixels == 0 || pixels > limit {
        Err(-37)
    } else {
        Ok(())
    }
}

fn rgba_allocation_pixel_budget(
    max_decoded_pixels: u64,
    max_output_bytes: usize,
) -> Result<u64, i32> {
    let byte_limited_pixels = u64::try_from(max_output_bytes / 4).map_err(|_| -37)?;
    let limit = max_decoded_pixels.min(byte_limited_pixels);
    if limit == 0 {
        Err(-37)
    } else {
        Ok(limit)
    }
}

fn validate_full_frame_working_set(
    width: u32,
    height: u32,
    max_decoded_pixels: u64,
    max_output_bytes: usize,
) -> Result<(), i32> {
    let pixels = pixel_count(width, height)?;
    if pixels == 0 || pixels > max_decoded_pixels {
        return Err(-37);
    }
    let working_bytes = pixels
        .checked_mul(FULL_FRAME_WORKING_BYTES_PER_PIXEL)
        .ok_or(-37)?;
    if working_bytes > max_output_bytes as u64 {
        Err(-37)
    } else {
        Ok(())
    }
}

fn pixel_count(width: u32, height: u32) -> Result<u64, i32> {
    u64::from(width).checked_mul(u64::from(height)).ok_or(-36)
}

fn checked_header_dimension(handle: TjHandle, param: c_int) -> Result<u32, i32> {
    let value = unsafe { tj3Get(handle, param) };
    u32::try_from(value).map_err(|_| -70).and_then(
        |value| {
            if value == 0 {
                Err(-71)
            } else {
                Ok(value)
            }
        },
    )
}

fn validate_tile_spec(spec: TileSpec) -> Result<(), i32> {
    if spec.width == 0 || spec.height == 0 || spec.decoded_width == 0 || spec.decoded_height == 0 {
        return Err(-72);
    }
    Ok(())
}

fn validate_bounds(spec: TileSpec, image_width: u32, image_height: u32) -> Result<(), i32> {
    let right = spec.x.checked_add(spec.width).ok_or(-73)?;
    let bottom = spec.y.checked_add(spec.height).ok_or(-74)?;
    if right > image_width || bottom > image_height {
        return Err(-75);
    }
    Ok(())
}

fn encode_png(image: image::DynamicImage, max_output_bytes: usize) -> Result<Vec<u8>, i32> {
    let rgba = image.into_rgba8();
    let (width, height) = rgba.dimensions();
    let mut output = BoundedBytesWriter::new(max_output_bytes);
    image::codecs::png::PngEncoder::new(&mut output)
        .write_image(
            rgba.as_raw(),
            width,
            height,
            image::ExtendedColorType::Rgba8,
        )
        .map_err(|_| -80)?;
    Ok(output.into_inner())
}

fn align_down(value: u32, quantum: u32) -> u32 {
    value - value % quantum
}

fn mcu_size(subsamp: c_int) -> Option<(u32, u32)> {
    match subsamp {
        0 | 3 => Some((8, 8)),
        1 => Some((16, 8)),
        2 => Some((16, 16)),
        4 => Some((8, 16)),
        5 => Some((32, 8)),
        6 => Some((8, 32)),
        _ => None,
    }
}

fn parse_tile_spec(descriptor: &str) -> Option<TileSpec> {
    let trimmed = descriptor.trim();
    let args = trimmed
        .strip_prefix("tile(")
        .and_then(|value| value.strip_suffix(')'))?;
    let mut spec = TileSpec {
        x: 0,
        y: 0,
        width: 0,
        height: 0,
        decoded_width: 0,
        decoded_height: 0,
        filter: FilterType::Lanczos3,
    };
    for part in args.split(',') {
        let (key, value) = part.split_once('=')?;
        let key = key.trim();
        let value = value.trim().trim_matches('"').trim_matches('\'');
        if key.eq_ignore_ascii_case("x") {
            spec.x = value.parse().ok()?;
        } else if key.eq_ignore_ascii_case("y") {
            spec.y = value.parse().ok()?;
        } else if key.eq_ignore_ascii_case("width") {
            spec.width = value.parse().ok()?;
        } else if key.eq_ignore_ascii_case("height") {
            spec.height = value.parse().ok()?;
        } else if key.eq_ignore_ascii_case("decodedWidth")
            || key.eq_ignore_ascii_case("decoded_width")
        {
            spec.decoded_width = value.parse().ok()?;
        } else if key.eq_ignore_ascii_case("decodedHeight")
            || key.eq_ignore_ascii_case("decoded_height")
        {
            spec.decoded_height = value.parse().ok()?;
        } else if key.eq_ignore_ascii_case("filter") {
            spec.filter = parse_filter(value)?;
        } else {
            return None;
        }
    }
    Some(spec)
}

fn parse_filter(value: &str) -> Option<FilterType> {
    match value.to_ascii_lowercase().as_str() {
        "nearest" => Some(FilterType::Nearest),
        "triangle" | "linear" => Some(FilterType::Triangle),
        "catmullrom" | "catmull_rom" | "cubic" => Some(FilterType::CatmullRom),
        "gaussian" => Some(FilterType::Gaussian),
        "lanczos3" | "lanczos" => Some(FilterType::Lanczos3),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::GenericImageView;

    unsafe extern "C" {
        fn tj3Compress8(
            handle: TjHandle,
            src_buf: *const c_uchar,
            width: c_int,
            pitch: c_int,
            height: c_int,
            pixel_format: c_int,
            jpeg_buf: *mut *mut c_uchar,
            jpeg_size: *mut usize,
        ) -> c_int;
        fn tj3Free(buffer: *mut c_void);
    }

    #[test]
    fn jpeg_turbo_processor_decodes_tile_under_full_frame_budget() {
        let mut module = crate::empty_plugin_module_api();
        let status = unsafe {
            pixa_jpeg_turbo_processor_plugin_init(&crate::PLUGIN_HOST_API_V1, &mut module)
        };
        assert_eq!(status, 0);
        let process = module.process.expect("processor callback should be set");

        let operation = b"tile:jpeg";
        let descriptor =
            b"tile(x=16,y=16,width=16,height=16,decodedWidth=16,decodedHeight=16,filter=nearest)";
        let format_id = b"jpeg";
        let mime_type = b"image/jpeg";
        let jpeg = gradient_jpeg(64, 64);
        let mut output = crate::empty_plugin_output();
        let request = PixaPluginProcessRequestV1 {
            abi_version: pixa_core::PIXA_PLUGIN_ABI_VERSION,
            struct_size: crate::abi_struct_size::<PixaPluginProcessRequestV1>(),
            operation_ptr: operation.as_ptr(),
            operation_len: operation.len(),
            descriptor_ptr: descriptor.as_ptr(),
            descriptor_len: descriptor.len(),
            format_id_ptr: format_id.as_ptr(),
            format_id_len: format_id.len(),
            mime_type_ptr: mime_type.as_ptr(),
            mime_type_len: mime_type.len(),
            bytes_ptr: jpeg.as_ptr(),
            bytes_len: jpeg.len(),
            max_decoded_pixels: 512,
            max_output_bytes: 8192,
        };

        let status = unsafe { process(&request, &mut output) };
        assert_eq!(status, 0);
        assert_eq!(&output.mime_type[..output.mime_type_len], b"image/png");
        let bytes = crate::take_plugin_host_buffer(output.buffer).unwrap();
        let decoded = image::load_from_memory(&bytes).expect("tile PNG should decode");
        assert_eq!(decoded.dimensions(), (16, 16));
    }

    #[test]
    fn jpeg_turbo_processor_tile_pixels_match_expected_region() {
        let mut module = crate::empty_plugin_module_api();
        let status = unsafe {
            pixa_jpeg_turbo_processor_plugin_init(&crate::PLUGIN_HOST_API_V1, &mut module)
        };
        assert_eq!(status, 0);
        let process = module.process.expect("processor callback should be set");

        let operation = b"tile:jpeg";
        let descriptor =
            b"tile(x=16,y=16,width=16,height=16,decodedWidth=16,decodedHeight=16,filter=nearest)";
        let format_id = b"jpeg";
        let mime_type = b"image/jpeg";
        let jpeg = grayscale_gradient_jpeg(64, 64);
        let mut output = crate::empty_plugin_output();
        let request = PixaPluginProcessRequestV1 {
            abi_version: pixa_core::PIXA_PLUGIN_ABI_VERSION,
            struct_size: crate::abi_struct_size::<PixaPluginProcessRequestV1>(),
            operation_ptr: operation.as_ptr(),
            operation_len: operation.len(),
            descriptor_ptr: descriptor.as_ptr(),
            descriptor_len: descriptor.len(),
            format_id_ptr: format_id.as_ptr(),
            format_id_len: format_id.len(),
            mime_type_ptr: mime_type.as_ptr(),
            mime_type_len: mime_type.len(),
            bytes_ptr: jpeg.as_ptr(),
            bytes_len: jpeg.len(),
            max_decoded_pixels: 512,
            max_output_bytes: 8192,
        };

        let status = unsafe { process(&request, &mut output) };
        assert_eq!(status, 0);
        let bytes = crate::take_plugin_host_buffer(output.buffer).unwrap();
        let decoded = image::load_from_memory(&bytes)
            .expect("tile PNG should decode")
            .to_rgba8();
        assert_eq!(decoded.dimensions(), (16, 16));

        for (x, y, pixel) in decoded.enumerate_pixels() {
            let expected = grayscale_gradient_value(x + 16, y + 16);
            for channel in &pixel.0[0..3] {
                let delta = i16::from(*channel) - i16::from(expected);
                assert!(
                    delta.abs() <= 16,
                    "pixel ({x},{y}) channel {channel} should match expected {expected}"
                );
            }
            assert_eq!(pixel.0[3], 255);
        }
    }

    #[test]
    fn jpeg_turbo_processor_native_scales_zoomed_out_tile_under_source_budget() {
        let jpeg = grayscale_gradient_jpeg(64, 64);
        let png = decode_tile_to_png(
            &jpeg,
            TileSpec {
                x: 16,
                y: 16,
                width: 32,
                height: 32,
                decoded_width: 8,
                decoded_height: 8,
                filter: FilterType::Triangle,
            },
            80,
            8192,
        )
        .expect("decoder-native scaling should avoid a 32x32 RGBA allocation");
        let decoded = image::load_from_memory(&png)
            .expect("scaled JPEG tile PNG should decode")
            .to_rgba8();

        assert_eq!(decoded.dimensions(), (8, 8));
        let first = decoded.get_pixel(0, 0).0[0];
        let last = decoded.get_pixel(7, 7).0[0];
        assert!(
            (60..=95).contains(&first),
            "unexpected first tile sample {first}"
        );
        assert!(
            (115..=150).contains(&last),
            "unexpected last tile sample {last}"
        );
        assert!(first < last);
    }

    #[test]
    fn jpeg_turbo_processor_scaled_odd_region_keeps_pixel_position() {
        let jpeg = grayscale_gradient_jpeg(64, 64);
        let png = decode_tile_to_png(
            &jpeg,
            TileSpec {
                x: 17,
                y: 19,
                width: 31,
                height: 27,
                decoded_width: 8,
                decoded_height: 7,
                filter: FilterType::Triangle,
            },
            200,
            8192,
        )
        .expect("scaled odd JPEG ROI should remain within its target working set");
        let decoded = image::load_from_memory(&png)
            .expect("scaled odd JPEG tile should decode")
            .to_luma8();
        let full = image::load_from_memory(&jpeg)
            .expect("full JPEG reference should decode")
            .to_luma8();
        let reference_crop = image::imageops::crop_imm(&full, 17, 19, 31, 27).to_image();
        let reference = image::imageops::resize(&reference_crop, 8, 7, FilterType::Triangle);

        assert_eq!(decoded.dimensions(), (8, 7));
        assert_luma_images_close(&decoded, &reference, 4);
    }

    #[test]
    fn jpeg_turbo_processor_rejects_final_target_over_pixel_budget() {
        let jpeg = grayscale_gradient_jpeg(64, 64);
        let error = decode_tile_to_png(
            &jpeg,
            TileSpec {
                x: 16,
                y: 16,
                width: 8,
                height: 8,
                decoded_width: 16,
                decoded_height: 16,
                filter: FilterType::Triangle,
            },
            128,
            8192,
        )
        .expect_err("final target allocation must obey max decoded pixels");

        assert_eq!(error, -37);
    }

    #[test]
    fn jpeg_turbo_processor_rejects_final_target_over_byte_budget() {
        let jpeg = grayscale_gradient_jpeg(64, 64);
        let error = decode_tile_to_png(
            &jpeg,
            TileSpec {
                x: 16,
                y: 16,
                width: 8,
                height: 8,
                decoded_width: 16,
                decoded_height: 16,
                filter: FilterType::Triangle,
            },
            1_024,
            512,
        )
        .expect_err("final target allocation must obey the byte budget");

        assert_eq!(error, -37);
    }

    #[test]
    fn jpeg_turbo_processor_rejects_progressive_hidden_full_frame_over_budget() {
        let jpeg = turbo_gradient_jpeg(64, 64, true, false);
        let error = decode_tile_to_png(
            &jpeg,
            TileSpec {
                x: 16,
                y: 16,
                width: 32,
                height: 32,
                decoded_width: 8,
                decoded_height: 8,
                filter: FilterType::Triangle,
            },
            80,
            8192,
        )
        .expect_err("progressive coefficient storage must obey the full-frame budget");

        assert_eq!(error, -37);
    }

    #[test]
    fn jpeg_turbo_processor_rejects_progressive_hidden_working_bytes() {
        let jpeg = turbo_gradient_jpeg(64, 64, true, false);
        let error = decode_tile_to_png(
            &jpeg,
            TileSpec {
                x: 16,
                y: 16,
                width: 32,
                height: 32,
                decoded_width: 8,
                decoded_height: 8,
                filter: FilterType::Triangle,
            },
            8_192,
            8_192,
        )
        .expect_err("progressive coefficient storage must obey the byte budget");

        assert_eq!(error, -37);
    }

    #[test]
    fn jpeg_turbo_processor_rejects_lossless_roi_without_idct_scaling() {
        let jpeg = turbo_gradient_jpeg(64, 64, false, true);
        let error = decode_tile_to_png(
            &jpeg,
            TileSpec {
                x: 16,
                y: 16,
                width: 16,
                height: 16,
                decoded_width: 8,
                decoded_height: 8,
                filter: FilterType::Triangle,
            },
            4096,
            8192,
        )
        .expect_err("lossless JPEG does not support TurboJPEG ROI crop or IDCT scaling");

        assert_eq!(error, -31);
    }

    fn gradient_jpeg(width: u32, height: u32) -> Vec<u8> {
        let mut image = image::RgbaImage::new(width, height);
        for y in 0..height {
            for x in 0..width {
                image.put_pixel(
                    x,
                    y,
                    image::Rgba([(x * 3) as u8, (y * 5) as u8, (x + y) as u8, 255]),
                );
            }
        }
        let mut cursor = Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(image)
            .write_to(&mut cursor, image::ImageFormat::Jpeg)
            .expect("JPEG fixture should encode");
        cursor.into_inner()
    }

    fn grayscale_gradient_jpeg(width: u32, height: u32) -> Vec<u8> {
        let mut image = image::RgbaImage::new(width, height);
        for y in 0..height {
            for x in 0..width {
                let value = grayscale_gradient_value(x, y);
                image.put_pixel(x, y, image::Rgba([value, value, value, 255]));
            }
        }
        let mut cursor = Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(image)
            .write_to(&mut cursor, image::ImageFormat::Jpeg)
            .expect("JPEG fixture should encode");
        cursor.into_inner()
    }

    fn turbo_gradient_jpeg(width: u32, height: u32, progressive: bool, lossless: bool) -> Vec<u8> {
        const TJINIT_COMPRESS: c_int = 0;
        const TJPARAM_QUALITY: c_int = 3;
        let mut pixels = Vec::with_capacity((width * height * 4) as usize);
        for y in 0..height {
            for x in 0..width {
                let value = grayscale_gradient_value(x, y);
                pixels.extend_from_slice(&[value, value, value, 255]);
            }
        }
        let handle = unsafe { tj3Init(TJINIT_COMPRESS) };
        assert!(!handle.is_null());
        assert_eq!(unsafe { tj3Set(handle, TJPARAM_QUALITY, 90) }, 0);
        assert_eq!(unsafe { tj3Set(handle, TJPARAM_SUBSAMP, 0) }, 0);
        if progressive {
            assert_eq!(unsafe { tj3Set(handle, TJPARAM_PROGRESSIVE, 1) }, 0);
        }
        if lossless {
            assert_eq!(unsafe { tj3Set(handle, TJPARAM_LOSSLESS, 1) }, 0);
        }
        let mut jpeg_ptr = ptr::null_mut();
        let mut jpeg_len = 0;
        let status = unsafe {
            tj3Compress8(
                handle,
                pixels.as_ptr(),
                i32::try_from(width).expect("fixture width should fit"),
                i32::try_from(width * 4).expect("fixture pitch should fit"),
                i32::try_from(height).expect("fixture height should fit"),
                TJPF_RGBA,
                &mut jpeg_ptr,
                &mut jpeg_len,
            )
        };
        assert_eq!(status, 0);
        assert!(!jpeg_ptr.is_null());
        let jpeg = unsafe { std::slice::from_raw_parts(jpeg_ptr, jpeg_len).to_vec() };
        unsafe {
            tj3Free(jpeg_ptr.cast());
            tj3Destroy(handle);
        }
        jpeg
    }

    fn grayscale_gradient_value(x: u32, y: u32) -> u8 {
        u8::try_from(40 + x + y).expect("64x64 grayscale fixture value should fit")
    }

    fn assert_luma_images_close(
        actual: &image::GrayImage,
        expected: &image::GrayImage,
        max_error: u8,
    ) {
        assert_eq!(actual.dimensions(), expected.dimensions());
        for (x, y, pixel) in actual.enumerate_pixels() {
            let expected_value = expected.get_pixel(x, y).0[0];
            let actual_value = pixel.0[0];
            assert!(
                actual_value.abs_diff(expected_value) <= max_error,
                "pixel ({x},{y}) differs: actual={actual_value}, expected={expected_value}",
            );
        }
    }
}
