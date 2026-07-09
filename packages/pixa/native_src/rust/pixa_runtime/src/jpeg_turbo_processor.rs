use super::{
    bytes_from_ptr, bytes_to_str, PixaPluginHostApiV1, PixaPluginModuleApiV1, PixaPluginOutputV1,
    PixaPluginProcessRequestV1,
};
use image::imageops::FilterType;
use std::ffi::{c_char, c_int, c_uchar, c_void, CStr};
use std::io::Cursor;
use std::ptr;
use std::sync::OnceLock;

const OUTPUT_MIME: &[u8] = b"image/png";
const TJINIT_DECOMPRESS: c_int = 1;
const TJPARAM_SUBSAMP: c_int = 4;
const TJPARAM_JPEGWIDTH: c_int = 5;
const TJPARAM_JPEGHEIGHT: c_int = 6;
const TJPF_RGBA: c_int = 7;

static HOST_API: OnceLock<PixaPluginHostApiV1> = OnceLock::new();

#[repr(C)]
#[derive(Clone, Copy)]
struct TjRegion {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
}

type TjHandle = *mut c_void;

unsafe extern "C" {
    fn tj3Init(init_type: c_int) -> TjHandle;
    fn tj3Destroy(handle: TjHandle);
    fn tj3GetErrorStr(handle: TjHandle) -> *mut c_char;
    fn tj3Get(handle: TjHandle, param: c_int) -> c_int;
    fn tj3DecompressHeader(handle: TjHandle, jpeg_buf: *const c_uchar, jpeg_size: usize) -> c_int;
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
    sample_size: u32,
    filter: FilterType,
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
    if host_api.abi_version != pixa_core::PIXA_PLUGIN_ABI_VERSION
        || host_api.buffer_alloc.is_none()
        || host_api.buffer_data.is_none()
        || host_api.buffer_free.is_none()
    {
        return -2;
    }
    let _ = HOST_API.set(host_api);
    unsafe {
        (*module).abi_version = pixa_core::PIXA_PLUGIN_ABI_VERSION;
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

    let subsamp = unsafe { tj3Get(handle.as_ptr(), TJPARAM_SUBSAMP) };
    let (mcu_width, mcu_height) = mcu_size(subsamp).ok_or(-31)?;
    let crop_x = align_down(spec.x, mcu_width);
    let crop_y = align_down(spec.y, mcu_height);
    let request_right = spec.x.checked_add(spec.width).ok_or(-32)?;
    let request_bottom = spec.y.checked_add(spec.height).ok_or(-33)?;
    let crop_width = request_right.checked_sub(crop_x).ok_or(-34)?;
    let crop_height = request_bottom.checked_sub(crop_y).ok_or(-35)?;
    let crop_pixels = u64::from(crop_width)
        .checked_mul(u64::from(crop_height))
        .ok_or(-36)?;
    if crop_pixels == 0 || crop_pixels > max_decoded_pixels {
        return Err(-37);
    }
    let raw_len = crop_pixels.checked_mul(4).ok_or(-38)?;
    let raw_len = usize::try_from(raw_len).map_err(|_| -39)?;
    let mut pixels = vec![0_u8; raw_len];
    let pitch = i32::try_from(u64::from(crop_width) * 4).map_err(|_| -40)?;
    let region = TjRegion {
        x: i32::try_from(crop_x).map_err(|_| -41)?,
        y: i32::try_from(crop_y).map_err(|_| -42)?,
        w: i32::try_from(crop_width).map_err(|_| -43)?,
        h: i32::try_from(crop_height).map_err(|_| -44)?,
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

    let crop = image::RgbaImage::from_raw(crop_width, crop_height, pixels).ok_or(-47)?;
    let offset_x = spec.x.checked_sub(crop_x).ok_or(-48)?;
    let offset_y = spec.y.checked_sub(crop_y).ok_or(-49)?;
    let exact_tile =
        image::imageops::crop_imm(&crop, offset_x, offset_y, spec.width, spec.height).to_image();
    let mut image = image::DynamicImage::ImageRgba8(exact_tile);
    if spec.width != spec.decoded_width || spec.height != spec.decoded_height {
        image = image.resize_exact(spec.decoded_width, spec.decoded_height, spec.filter);
    }
    encode_png(image, max_output_bytes)
}

fn copy_output_to_host_buffer(
    bytes: &[u8],
    output: *mut PixaPluginOutputV1,
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
        (*output).buffer = handle;
        (*output).mime_type_ptr = OUTPUT_MIME.as_ptr();
        (*output).mime_type_len = OUTPUT_MIME.len();
    }
    0
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
    if spec.width == 0
        || spec.height == 0
        || spec.decoded_width == 0
        || spec.decoded_height == 0
        || spec.sample_size == 0
        || !spec.sample_size.is_power_of_two()
    {
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
    let mut cursor = Cursor::new(Vec::new());
    image
        .write_to(&mut cursor, image::ImageFormat::Png)
        .map_err(|_| -80)?;
    let bytes = cursor.into_inner();
    if bytes.len() > max_output_bytes {
        Err(-81)
    } else {
        Ok(bytes)
    }
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
        sample_size: 1,
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
        } else if key.eq_ignore_ascii_case("sampleSize") || key.eq_ignore_ascii_case("sample_size")
        {
            spec.sample_size = value.parse().ok()?;
        } else if key.eq_ignore_ascii_case("filter") {
            spec.filter = parse_filter(value)?;
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

    #[test]
    fn jpeg_turbo_processor_decodes_tile_under_full_frame_budget() {
        let mut module = PixaPluginModuleApiV1 {
            abi_version: 0,
            fetch: None,
            decode: None,
            process: None,
            cache_read: None,
            cache_write: None,
            cache_remove: None,
            cache_clear_namespace: None,
        };
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
        let mut output = PixaPluginOutputV1 {
            buffer: ptr::null_mut(),
            mime_type_ptr: ptr::null(),
            mime_type_len: 0,
        };
        let request = PixaPluginProcessRequestV1 {
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
        assert_eq!(
            unsafe { std::slice::from_raw_parts(output.mime_type_ptr, output.mime_type_len) },
            b"image/png"
        );
        let bytes = unsafe { crate::take_plugin_host_buffer(output.buffer) };
        let decoded = image::load_from_memory(&bytes).expect("tile PNG should decode");
        assert_eq!(decoded.dimensions(), (16, 16));
    }

    #[test]
    fn jpeg_turbo_processor_tile_pixels_match_expected_region() {
        let mut module = PixaPluginModuleApiV1 {
            abi_version: 0,
            fetch: None,
            decode: None,
            process: None,
            cache_read: None,
            cache_write: None,
            cache_remove: None,
            cache_clear_namespace: None,
        };
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
        let mut output = PixaPluginOutputV1 {
            buffer: ptr::null_mut(),
            mime_type_ptr: ptr::null(),
            mime_type_len: 0,
        };
        let request = PixaPluginProcessRequestV1 {
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
        let bytes = unsafe { crate::take_plugin_host_buffer(output.buffer) };
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

    fn grayscale_gradient_value(x: u32, y: u32) -> u8 {
        u8::try_from(40 + x + y).expect("64x64 grayscale fixture value should fit")
    }
}
