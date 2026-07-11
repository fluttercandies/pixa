use super::{
    abi_struct_is_compatible, bytes_from_ptr, bytes_to_str, set_plugin_output_mime,
    PixaPluginHostApiV1, PixaPluginModuleApiV1, PixaPluginOutputV1, PixaPluginProcessRequestV1,
};
use image::{imageops::FilterType, ImageEncoder};
use pixa_core::BoundedBytesWriter;
use std::ffi::{c_int, c_uchar};
use std::ptr;
use std::sync::OnceLock;

const OUTPUT_MIME: &[u8] = b"image/png";
const WEBP_DECODER_ABI_VERSION: c_int = 0x0210;
const MODE_RGBA: c_int = 1;
const VP8_STATUS_OK: c_int = 0;
const FULL_FRAME_WORKING_BYTES_PER_PIXEL: u64 = 16;

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
    let allocation_pixel_budget =
        rgba_allocation_pixel_budget(max_decoded_pixels, max_output_bytes)?;
    validate_pixel_budget(
        spec.decoded_width,
        spec.decoded_height,
        allocation_pixel_budget,
    )?;
    if features.format != 1 || features.has_alpha != 0 {
        validate_full_frame_working_set(
            image_width,
            image_height,
            max_decoded_pixels,
            max_output_bytes,
        )?;
    }

    let crop_x = align_down(spec.x, 2);
    let crop_y = align_down(spec.y, 2);
    let request_right = spec.x.checked_add(spec.width).ok_or(-33)?;
    let request_bottom = spec.y.checked_add(spec.height).ok_or(-34)?;
    let crop_width = request_right.checked_sub(crop_x).ok_or(-35)?;
    let crop_height = request_bottom.checked_sub(crop_y).ok_or(-36)?;
    let uses_native_scaling =
        spec.decoded_width != spec.width || spec.decoded_height != spec.height;
    let native_width = if uses_native_scaling {
        spec.decoded_width
    } else {
        crop_width
    };
    let native_height = if uses_native_scaling {
        spec.decoded_height
    } else {
        crop_height
    };
    validate_pixel_budget(native_width, native_height, allocation_pixel_budget)?;
    let native_pixels = pixel_count(native_width, native_height)?;
    let raw_len = native_pixels.checked_mul(4).ok_or(-39)?;
    let raw_len = usize::try_from(raw_len).map_err(|_| -40)?;
    let mut pixels = vec![0_u8; raw_len];

    let mut config = init_decoder_config()?;
    config.input = features;
    config.options.use_cropping = 1;
    config.options.crop_left = i32::try_from(crop_x).map_err(|_| -41)?;
    config.options.crop_top = i32::try_from(crop_y).map_err(|_| -42)?;
    config.options.crop_width = i32::try_from(crop_width).map_err(|_| -43)?;
    config.options.crop_height = i32::try_from(crop_height).map_err(|_| -44)?;
    if uses_native_scaling {
        config.options.use_scaling = 1;
        config.options.scaled_width = i32::try_from(native_width).map_err(|_| -45)?;
        config.options.scaled_height = i32::try_from(native_height).map_err(|_| -46)?;
    }
    config.output.colorspace = MODE_RGBA;
    config.output.width = i32::try_from(native_width).map_err(|_| -45)?;
    config.output.height = i32::try_from(native_height).map_err(|_| -46)?;
    config.output.is_external_memory = 1;
    config.output.u.rgba = WebPRgbaBuffer {
        rgba: pixels.as_mut_ptr(),
        stride: i32::try_from(u64::from(native_width) * 4).map_err(|_| -47)?,
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

    let crop = image::RgbaImage::from_raw(native_width, native_height, pixels).ok_or(-50)?;
    let offset_x = if uses_native_scaling {
        0
    } else {
        spec.x.checked_sub(crop_x).ok_or(-51)?
    };
    let offset_y = if uses_native_scaling {
        0
    } else {
        spec.y.checked_sub(crop_y).ok_or(-52)?
    };
    let exact_tile = if offset_x == 0
        && offset_y == 0
        && native_width == spec.decoded_width
        && native_height == spec.decoded_height
    {
        crop
    } else {
        image::imageops::crop_imm(
            &crop,
            offset_x,
            offset_y,
            spec.decoded_width,
            spec.decoded_height,
        )
        .to_image()
    };
    let mut image = image::DynamicImage::ImageRgba8(exact_tile);
    if image.width() != spec.decoded_width || image.height() != spec.decoded_height {
        image = image.resize_exact(spec.decoded_width, spec.decoded_height, spec.filter);
    }
    encode_png(image, max_output_bytes)
}

fn validate_pixel_budget(width: u32, height: u32, limit: u64) -> Result<(), i32> {
    let pixels = pixel_count(width, height)?;
    if pixels == 0 || pixels > limit {
        Err(-38)
    } else {
        Ok(())
    }
}

fn rgba_allocation_pixel_budget(
    max_decoded_pixels: u64,
    max_output_bytes: usize,
) -> Result<u64, i32> {
    let byte_limited_pixels = u64::try_from(max_output_bytes / 4).map_err(|_| -38)?;
    let limit = max_decoded_pixels.min(byte_limited_pixels);
    if limit == 0 {
        Err(-38)
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
        return Err(-38);
    }
    let working_bytes = pixels
        .checked_mul(FULL_FRAME_WORKING_BYTES_PER_PIXEL)
        .ok_or(-38)?;
    if working_bytes > max_output_bytes as u64 {
        Err(-38)
    } else {
        Ok(())
    }
}

fn pixel_count(width: u32, height: u32) -> Result<u64, i32> {
    u64::from(width).checked_mul(u64::from(height)).ok_or(-37)
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
    use std::ffi::c_void;
    use std::slice;

    unsafe extern "C" {
        fn WebPEncodeRGBA(
            rgba: *const c_uchar,
            width: c_int,
            height: c_int,
            stride: c_int,
            quality_factor: f32,
            output: *mut *mut c_uchar,
        ) -> usize;
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
        let webp = grayscale_gradient_lossy_webp(64, 64);
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
        let bytes = run_process(process, descriptor, &webp, 4096);
        let decoded = image::load_from_memory(&bytes)
            .expect("tile PNG should decode")
            .to_rgba8();
        assert_eq!(decoded.dimensions(), (16, 16));

        for (x, y, pixel) in decoded.enumerate_pixels() {
            let expected = grayscale_gradient_value(x + 15, y + 17);
            assert_eq!(pixel.0, [expected, expected, expected, 255]);
        }
    }

    #[test]
    fn webp_processor_native_scales_zoomed_out_lossy_tile_under_source_budget() {
        let webp = grayscale_gradient_lossy_webp(64, 64);
        let png = decode_tile_to_png(
            &webp,
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
            .expect("scaled WebP tile PNG should decode")
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
    fn webp_processor_scaled_odd_region_keeps_pixel_position() {
        let webp = grayscale_gradient_lossy_webp(64, 64);
        let png = decode_tile_to_png(
            &webp,
            TileSpec {
                x: 15,
                y: 17,
                width: 32,
                height: 24,
                decoded_width: 8,
                decoded_height: 6,
                filter: FilterType::Triangle,
            },
            80,
            8192,
        )
        .expect("scaled odd WebP ROI should remain within its target working set");
        let decoded = image::load_from_memory(&png)
            .expect("scaled odd WebP tile should decode")
            .to_luma8();
        let full = image::load_from_memory(&webp)
            .expect("full WebP reference should decode")
            .to_luma8();
        let reference_crop = image::imageops::crop_imm(&full, 15, 17, 32, 24).to_image();
        let reference = image::imageops::resize(&reference_crop, 8, 6, FilterType::Triangle);

        assert_eq!(decoded.dimensions(), (8, 6));
        assert_luma_images_close(&decoded, &reference, 3);
    }

    #[test]
    fn webp_processor_rejects_final_target_over_pixel_budget() {
        let webp = grayscale_gradient_lossy_webp(64, 64);
        let error = decode_tile_to_png(
            &webp,
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

        assert_eq!(error, -38);
    }

    #[test]
    fn webp_processor_rejects_final_target_over_byte_budget() {
        let webp = grayscale_gradient_lossy_webp(64, 64);
        let error = decode_tile_to_png(
            &webp,
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

        assert_eq!(error, -38);
    }

    #[test]
    fn webp_processor_rejects_lossless_hidden_full_frame_over_budget() {
        let webp = grayscale_gradient_webp(64, 64);
        let error = decode_tile_to_png(
            &webp,
            TileSpec {
                x: 16,
                y: 16,
                width: 16,
                height: 16,
                decoded_width: 8,
                decoded_height: 8,
                filter: FilterType::Triangle,
            },
            512,
            8192,
        )
        .expect_err("VP8L full-frame scratch allocation must obey the pixel budget");

        assert_eq!(error, -38);
    }

    #[test]
    fn webp_processor_rejects_lossless_hidden_working_bytes() {
        let webp = grayscale_gradient_webp(64, 64);
        let error = decode_tile_to_png(
            &webp,
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
        .expect_err("VP8L transformed pixels must obey the byte budget");

        assert_eq!(error, -38);
    }

    #[test]
    fn webp_processor_rejects_lossy_alpha_hidden_full_frame_over_budget() {
        let webp = grayscale_gradient_lossy_alpha_webp(64, 64);
        let error = decode_tile_to_png(
            &webp,
            TileSpec {
                x: 16,
                y: 16,
                width: 16,
                height: 16,
                decoded_width: 8,
                decoded_height: 8,
                filter: FilterType::Triangle,
            },
            512,
            8192,
        )
        .expect_err("lossy alpha full-frame scratch allocation must obey the pixel budget");

        assert_eq!(error, -38);
    }

    #[test]
    fn webp_processor_rejects_lossy_alpha_hidden_working_bytes() {
        let webp = grayscale_gradient_lossy_alpha_webp(64, 64);
        let error = decode_tile_to_png(
            &webp,
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
        .expect_err("lossy alpha storage must obey the byte budget");

        assert_eq!(error, -38);
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
            max_output_bytes: 128 * 1024,
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
        encode_grayscale_gradient_webp(width, height, None, false)
    }

    fn grayscale_gradient_lossy_webp(width: u32, height: u32) -> Vec<u8> {
        encode_grayscale_gradient_webp(width, height, Some(100.0), false)
    }

    fn grayscale_gradient_lossy_alpha_webp(width: u32, height: u32) -> Vec<u8> {
        encode_grayscale_gradient_webp(width, height, Some(100.0), true)
    }

    fn encode_grayscale_gradient_webp(
        width: u32,
        height: u32,
        quality: Option<f32>,
        with_alpha: bool,
    ) -> Vec<u8> {
        let mut pixels = Vec::with_capacity((width * height * 4) as usize);
        for y in 0..height {
            for x in 0..width {
                let value = grayscale_gradient_value(x, y);
                pixels.extend_from_slice(&[
                    value,
                    value,
                    value,
                    if with_alpha { 128 } else { 255 },
                ]);
            }
        }
        let mut output = ptr::null_mut();
        let width = i32::try_from(width).expect("fixture width should fit");
        let height = i32::try_from(height).expect("fixture height should fit");
        let stride = width.checked_mul(4).expect("fixture stride should fit");
        let len = unsafe {
            match quality {
                Some(quality) => {
                    WebPEncodeRGBA(pixels.as_ptr(), width, height, stride, quality, &mut output)
                }
                None => WebPEncodeLosslessRGBA(pixels.as_ptr(), width, height, stride, &mut output),
            }
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
