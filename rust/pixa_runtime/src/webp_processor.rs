use super::{
    bytes_from_ptr, bytes_to_str, PixaPluginHostApiV1, PixaPluginModuleApiV1, PixaPluginOutputV1,
    PixaPluginProcessRequestV1,
};
use image::imageops::FilterType;
use std::ffi::{c_int, c_uchar};
use std::io::Cursor;
use std::ptr;
use std::sync::OnceLock;

const OUTPUT_MIME: &[u8] = b"image/png";
const WEBP_DECODER_ABI_VERSION: c_int = 0x0210;
const MODE_RGBA: c_int = 1;
const VP8_STATUS_OK: c_int = 0;

static HOST_API: OnceLock<PixaPluginHostApiV1> = OnceLock::new();

#[repr(C)]
#[derive(Clone, Copy)]
struct WebPRgbaBuffer {
    rgba: *mut c_uchar,
    stride: c_int,
    size: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct WebPYuvaBuffer {
    y: *mut c_uchar,
    u: *mut c_uchar,
    v: *mut c_uchar,
    a: *mut c_uchar,
    y_stride: c_int,
    u_stride: c_int,
    v_stride: c_int,
    a_stride: c_int,
    y_size: usize,
    u_size: usize,
    v_size: usize,
    a_size: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
union WebPDecBufferUnion {
    rgba: WebPRgbaBuffer,
    yuva: WebPYuvaBuffer,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct WebPDecBuffer {
    colorspace: c_int,
    width: c_int,
    height: c_int,
    is_external_memory: c_int,
    u: WebPDecBufferUnion,
    pad: [u32; 4],
    private_memory: *mut c_uchar,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct WebPBitstreamFeatures {
    width: c_int,
    height: c_int,
    has_alpha: c_int,
    has_animation: c_int,
    format: c_int,
    pad: [u32; 5],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct WebPDecoderOptions {
    bypass_filtering: c_int,
    no_fancy_upsampling: c_int,
    use_cropping: c_int,
    crop_left: c_int,
    crop_top: c_int,
    crop_width: c_int,
    crop_height: c_int,
    use_scaling: c_int,
    scaled_width: c_int,
    scaled_height: c_int,
    use_threads: c_int,
    dithering_strength: c_int,
    flip: c_int,
    alpha_dithering_strength: c_int,
    pad: [u32; 5],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct WebPDecoderConfig {
    input: WebPBitstreamFeatures,
    output: WebPDecBuffer,
    options: WebPDecoderOptions,
}

unsafe extern "C" {
    fn WebPGetFeaturesInternal(
        data: *const c_uchar,
        data_size: usize,
        features: *mut WebPBitstreamFeatures,
        version: c_int,
    ) -> c_int;
    fn WebPInitDecoderConfigInternal(config: *mut WebPDecoderConfig, version: c_int) -> c_int;
    fn WebPValidateDecoderConfig(config: *const WebPDecoderConfig) -> c_int;
    fn WebPDecode(data: *const c_uchar, data_size: usize, config: *mut WebPDecoderConfig) -> c_int;
    fn WebPFreeDecBuffer(buffer: *mut WebPDecBuffer);
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
pub unsafe extern "C" fn pixa_webp_processor_plugin_init(
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
        (*module).process = Some(process_webp_tile);
    }
    0
}

unsafe extern "C" fn process_webp_tile(
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
    if !operation.eq_ignore_ascii_case("tile:webp") {
        return -3;
    }
    let Some(format_id) = (unsafe { bytes_to_str(request.format_id_ptr, request.format_id_len) })
    else {
        return -4;
    };
    if !format_id.eq_ignore_ascii_case("webp") {
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
    let features = read_features(input)?;
    if features.has_animation != 0 {
        return Err(-30);
    }
    let image_width = u32::try_from(features.width).map_err(|_| -31)?;
    let image_height = u32::try_from(features.height).map_err(|_| -32)?;
    validate_bounds(spec, image_width, image_height)?;

    let crop_x = align_down(spec.x, 2);
    let crop_y = align_down(spec.y, 2);
    let request_right = spec.x.checked_add(spec.width).ok_or(-33)?;
    let request_bottom = spec.y.checked_add(spec.height).ok_or(-34)?;
    let crop_width = request_right.checked_sub(crop_x).ok_or(-35)?;
    let crop_height = request_bottom.checked_sub(crop_y).ok_or(-36)?;
    let crop_pixels = u64::from(crop_width)
        .checked_mul(u64::from(crop_height))
        .ok_or(-37)?;
    if crop_pixels == 0 || crop_pixels > max_decoded_pixels {
        return Err(-38);
    }
    let raw_len = crop_pixels.checked_mul(4).ok_or(-39)?;
    let raw_len = usize::try_from(raw_len).map_err(|_| -40)?;
    let mut pixels = vec![0_u8; raw_len];

    let mut config = init_decoder_config()?;
    config.input = features;
    config.options.use_cropping = 1;
    config.options.crop_left = i32::try_from(crop_x).map_err(|_| -41)?;
    config.options.crop_top = i32::try_from(crop_y).map_err(|_| -42)?;
    config.options.crop_width = i32::try_from(crop_width).map_err(|_| -43)?;
    config.options.crop_height = i32::try_from(crop_height).map_err(|_| -44)?;
    config.output.colorspace = MODE_RGBA;
    config.output.width = i32::try_from(crop_width).map_err(|_| -45)?;
    config.output.height = i32::try_from(crop_height).map_err(|_| -46)?;
    config.output.is_external_memory = 1;
    config.output.u.rgba = WebPRgbaBuffer {
        rgba: pixels.as_mut_ptr(),
        stride: i32::try_from(u64::from(crop_width) * 4).map_err(|_| -47)?,
        size: pixels.len(),
    };
    if unsafe { WebPValidateDecoderConfig(&config) } == 0 {
        return Err(-48);
    }
    let status = unsafe { WebPDecode(input.as_ptr(), input.len(), &mut config) };
    unsafe { WebPFreeDecBuffer(&mut config.output) };
    if status != VP8_STATUS_OK {
        return Err(-49);
    }

    let crop = image::RgbaImage::from_raw(crop_width, crop_height, pixels).ok_or(-50)?;
    let offset_x = spec.x.checked_sub(crop_x).ok_or(-51)?;
    let offset_y = spec.y.checked_sub(crop_y).ok_or(-52)?;
    let exact_tile =
        image::imageops::crop_imm(&crop, offset_x, offset_y, spec.width, spec.height).to_image();
    let mut image = image::DynamicImage::ImageRgba8(exact_tile);
    if spec.width != spec.decoded_width || spec.height != spec.decoded_height {
        image = image.resize_exact(spec.decoded_width, spec.decoded_height, spec.filter);
    }
    encode_png(image, max_output_bytes)
}

fn read_features(input: &[u8]) -> Result<WebPBitstreamFeatures, i32> {
    let mut features = WebPBitstreamFeatures {
        width: 0,
        height: 0,
        has_alpha: 0,
        has_animation: 0,
        format: 0,
        pad: [0; 5],
    };
    let status = unsafe {
        WebPGetFeaturesInternal(
            input.as_ptr(),
            input.len(),
            &mut features,
            WEBP_DECODER_ABI_VERSION,
        )
    };
    if status == VP8_STATUS_OK {
        Ok(features)
    } else {
        Err(-53)
    }
}

fn init_decoder_config() -> Result<WebPDecoderConfig, i32> {
    let mut config = unsafe { std::mem::zeroed::<WebPDecoderConfig>() };
    if unsafe { WebPInitDecoderConfigInternal(&mut config, WEBP_DECODER_ABI_VERSION) } == 0 {
        Err(-54)
    } else {
        Ok(config)
    }
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
    use std::ffi::c_void;
    use std::slice;

    unsafe extern "C" {
        fn WebPEncodeLosslessRGBA(
            rgba: *const c_uchar,
            width: c_int,
            height: c_int,
            stride: c_int,
            output: *mut *mut c_uchar,
        ) -> usize;
        fn WebPFree(ptr: *mut c_void);
    }

    #[test]
    fn webp_processor_decodes_tile_under_full_frame_budget() {
        let process = init_process();
        let descriptor =
            b"tile(x=16,y=16,width=16,height=16,decodedWidth=16,decodedHeight=16,filter=nearest)";
        let webp = grayscale_gradient_webp(64, 64);
        let bytes = run_process(process, descriptor, &webp, 512);
        let decoded = image::load_from_memory(&bytes).expect("tile PNG should decode");
        assert_eq!(decoded.dimensions(), (16, 16));
    }

    #[test]
    fn webp_processor_tile_pixels_match_expected_odd_region() {
        let process = init_process();
        let descriptor =
            b"tile(x=15,y=17,width=16,height=16,decodedWidth=16,decodedHeight=16,filter=nearest)";
        let webp = grayscale_gradient_webp(64, 64);
        let bytes = run_process(process, descriptor, &webp, 512);
        let decoded = image::load_from_memory(&bytes)
            .expect("tile PNG should decode")
            .to_rgba8();
        assert_eq!(decoded.dimensions(), (16, 16));

        for (x, y, pixel) in decoded.enumerate_pixels() {
            let expected = grayscale_gradient_value(x + 15, y + 17);
            assert_eq!(pixel.0, [expected, expected, expected, 255]);
        }
    }

    fn init_process(
    ) -> unsafe extern "C" fn(*const PixaPluginProcessRequestV1, *mut PixaPluginOutputV1) -> i32
    {
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
        let status =
            unsafe { pixa_webp_processor_plugin_init(&crate::PLUGIN_HOST_API_V1, &mut module) };
        assert_eq!(status, 0);
        module.process.expect("processor callback should be set")
    }

    fn run_process(
        process: unsafe extern "C" fn(
            *const PixaPluginProcessRequestV1,
            *mut PixaPluginOutputV1,
        ) -> i32,
        descriptor: &[u8],
        webp: &[u8],
        max_decoded_pixels: u64,
    ) -> Vec<u8> {
        let operation = b"tile:webp";
        let format_id = b"webp";
        let mime_type = b"image/webp";
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
            bytes_ptr: webp.as_ptr(),
            bytes_len: webp.len(),
            max_decoded_pixels,
            max_output_bytes: 8192,
        };

        let status = unsafe { process(&request, &mut output) };
        assert_eq!(status, 0);
        assert_eq!(
            unsafe { slice::from_raw_parts(output.mime_type_ptr, output.mime_type_len) },
            b"image/png"
        );
        unsafe { crate::take_plugin_host_buffer(output.buffer) }
    }

    fn grayscale_gradient_webp(width: u32, height: u32) -> Vec<u8> {
        let mut pixels = Vec::with_capacity((width * height * 4) as usize);
        for y in 0..height {
            for x in 0..width {
                let value = grayscale_gradient_value(x, y);
                pixels.extend_from_slice(&[value, value, value, 255]);
            }
        }
        let mut output = ptr::null_mut();
        let len = unsafe {
            WebPEncodeLosslessRGBA(
                pixels.as_ptr(),
                i32::try_from(width).expect("fixture width should fit"),
                i32::try_from(height).expect("fixture height should fit"),
                i32::try_from(width * 4).expect("fixture stride should fit"),
                &mut output,
            )
        };
        assert!(len > 0);
        assert!(!output.is_null());
        let bytes = unsafe { slice::from_raw_parts(output, len).to_vec() };
        unsafe { WebPFree(output.cast::<c_void>()) };
        bytes
    }

    fn grayscale_gradient_value(x: u32, y: u32) -> u8 {
        u8::try_from(40 + x + y).expect("64x64 grayscale fixture value should fit")
    }
}
