#[cfg(any(pixa_jpeg_turbo_processor, pixa_webp_processor))]
use image::GenericImageView;
use pixa_runtime::{
    pixa_buffer_free, pixa_cache_stats, pixa_configure, pixa_fnv1a64,
    pixa_load_with_cancel_and_progress, pixa_owned_buffer_create, pixa_owned_buffer_data,
    pixa_owned_buffer_free, pixa_owned_buffer_len, pixa_progress_session_create,
    pixa_progress_session_drain, pixa_progress_session_free,
};
#[cfg(pixa_webp_processor)]
use std::ffi::{c_int, c_uchar, c_void};
use std::hint::black_box;
#[cfg(pixa_jpeg_turbo_processor)]
use std::io::Cursor;
use std::slice;
use std::time::Instant;

fn main() {
    assert_eq!(pixa_configure(64 * 1024 * 1024, 128 * 1024 * 1024, 6), 0);

    println!("name,iterations,total_us,avg_ns,bytes");
    bench_small_call();
    bench_cache_stats_metadata();
    bench_progress_stream();
    bench_large_buffer_handle();
    bench_jpeg_turbo_tile_processor();
    bench_webp_tile_processor();
}

fn bench_small_call() {
    let input = [17_u8; 32];
    run(
        "runtime_small_fnv1a64_32b",
        iterations("PIXA_BENCH_RUNTIME_SMALL_ITERS", 2_000_000),
        || {
            black_box(pixa_fnv1a64(input.as_ptr(), input.len()));
            input.len()
        },
    );
}

fn bench_cache_stats_metadata() {
    run(
        "runtime_cache_stats_binary_metadata",
        iterations("PIXA_BENCH_RUNTIME_STATS_ITERS", 100_000),
        || {
            let mut out_len = 0_usize;
            let ptr = pixa_cache_stats(&mut out_len);
            assert!(!ptr.is_null());
            unsafe {
                black_box(slice::from_raw_parts(ptr, out_len)[0]);
            }
            pixa_buffer_free(ptr, out_len);
            out_len
        },
    );
}

fn bench_progress_stream() {
    let request = binary_request_fixture("runtime-progress");
    let image = minimal_gif();
    let root = b"";
    run(
        "runtime_progress_load_and_drain_min_gif",
        iterations("PIXA_BENCH_RUNTIME_PROGRESS_ITERS", 2_000),
        || {
            let session_id = pixa_progress_session_create();
            assert_ne!(session_id, 0);
            let mut out_len = 0_usize;
            let mut error_ptr = std::ptr::null_mut();
            let mut error_len = 0_usize;
            let ptr = pixa_load_with_cancel_and_progress(
                root.as_ptr(),
                root.len(),
                request.as_ptr(),
                request.len(),
                image.as_ptr(),
                image.len(),
                0,
                session_id,
                &mut out_len,
                &mut error_ptr,
                &mut error_len,
            );
            if ptr.is_null() {
                panic!(
                    "runtime progress benchmark load failed: {}",
                    runtime_error_message(error_ptr, error_len)
                );
            }
            assert!(error_ptr.is_null());
            pixa_buffer_free(ptr, out_len);

            let mut progress_len = 0_usize;
            let progress_ptr = pixa_progress_session_drain(session_id, &mut progress_len);
            assert!(!progress_ptr.is_null());
            unsafe {
                black_box(slice::from_raw_parts(progress_ptr, progress_len)[0]);
            }
            pixa_buffer_free(progress_ptr, progress_len);
            assert_eq!(pixa_progress_session_free(session_id), 0);
            out_len + progress_len
        },
    );
}

fn bench_large_buffer_handle() {
    run(
        "runtime_owned_buffer_create_free_1mb",
        iterations("PIXA_BENCH_RUNTIME_LARGE_BUFFER_ITERS", 500),
        || {
            let mut bytes = vec![91_u8; 1024 * 1024];
            let len = bytes.len();
            let ptr = bytes.as_mut_ptr();
            std::mem::forget(bytes);
            let handle = pixa_owned_buffer_create(ptr, len);
            assert!(!handle.is_null());
            assert_eq!(pixa_owned_buffer_len(handle), len);
            let data = pixa_owned_buffer_data(handle);
            assert!(!data.is_null());
            unsafe {
                black_box(slice::from_raw_parts(data, len)[len - 1]);
            }
            pixa_owned_buffer_free(handle);
            len
        },
    );
}

#[cfg(pixa_jpeg_turbo_processor)]
fn bench_jpeg_turbo_tile_processor() {
    if !env_flag_enabled("PIXA_BENCH_JPEG_TURBO") {
        return;
    }

    let request = binary_request_fixture_with_processors(
        "runtime-jpeg-turbo-tile",
        64 * 1024,
        512,
        8192,
        vec![
            "tile(x=16,y=16,width=16,height=16,decodedWidth=16,decodedHeight=16,filter=nearest)"
                .to_string(),
        ],
    );
    let image = gradient_jpeg(64, 64);
    let root = b"";
    run(
        "processor_tile_region_jpeg_turbo_16",
        iterations("PIXA_BENCH_JPEG_TURBO_ITERS", 200),
        || {
            let mut out_len = 0_usize;
            let mut error_ptr = std::ptr::null_mut();
            let mut error_len = 0_usize;
            let ptr = pixa_load_with_cancel_and_progress(
                root.as_ptr(),
                root.len(),
                request.as_ptr(),
                request.len(),
                image.as_ptr(),
                image.len(),
                0,
                0,
                &mut out_len,
                &mut error_ptr,
                &mut error_len,
            );
            if ptr.is_null() {
                panic!(
                    "JPEG Turbo ROI benchmark failed: {}",
                    runtime_error_message(error_ptr, error_len)
                );
            }
            assert!(error_ptr.is_null());
            let output = unsafe { slice::from_raw_parts(ptr, out_len) };
            let decoded = image::load_from_memory(output)
                .expect("JPEG Turbo ROI benchmark output should decode as PNG");
            assert_eq!(decoded.dimensions(), (16, 16));
            black_box(decoded.color());
            pixa_buffer_free(ptr, out_len);
            out_len
        },
    );
}

#[cfg(not(pixa_jpeg_turbo_processor))]
fn bench_jpeg_turbo_tile_processor() {
    if env_flag_enabled("PIXA_BENCH_JPEG_TURBO") {
        panic!(
            "PIXA_BENCH_JPEG_TURBO requires a PIXA_PLUGIN_PLAN that enables \
             pixa_jpeg_turbo_processor_plugin_init"
        );
    }
}

#[cfg(pixa_webp_processor)]
fn bench_webp_tile_processor() {
    if !env_flag_enabled("PIXA_BENCH_WEBP_ROI") {
        return;
    }

    let request = binary_request_fixture_with_processors(
        "runtime-webp-roi-tile",
        64 * 1024,
        512,
        8192,
        vec![
            "tile(x=15,y=17,width=16,height=16,decodedWidth=16,decodedHeight=16,filter=nearest)"
                .to_string(),
        ],
    );
    let image = grayscale_gradient_webp(64, 64);
    let root = b"";
    run(
        "processor_tile_region_webp_native_16",
        iterations("PIXA_BENCH_WEBP_ROI_ITERS", 200),
        || {
            let mut out_len = 0_usize;
            let mut error_ptr = std::ptr::null_mut();
            let mut error_len = 0_usize;
            let ptr = pixa_load_with_cancel_and_progress(
                root.as_ptr(),
                root.len(),
                request.as_ptr(),
                request.len(),
                image.as_ptr(),
                image.len(),
                0,
                0,
                &mut out_len,
                &mut error_ptr,
                &mut error_len,
            );
            if ptr.is_null() {
                panic!(
                    "WebP ROI benchmark failed: {}",
                    runtime_error_message(error_ptr, error_len)
                );
            }
            assert!(error_ptr.is_null());
            let output = unsafe { slice::from_raw_parts(ptr, out_len) };
            let decoded = image::load_from_memory(output)
                .expect("WebP ROI benchmark output should decode as PNG");
            assert_eq!(decoded.dimensions(), (16, 16));
            black_box(decoded.color());
            pixa_buffer_free(ptr, out_len);
            out_len
        },
    );
}

#[cfg(not(pixa_webp_processor))]
fn bench_webp_tile_processor() {
    if env_flag_enabled("PIXA_BENCH_WEBP_ROI") {
        panic!(
            "PIXA_BENCH_WEBP_ROI requires a PIXA_PLUGIN_PLAN that enables \
             pixa_webp_processor_plugin_init"
        );
    }
}

fn runtime_error_message(ptr: *mut u8, len: usize) -> String {
    if ptr.is_null() || len == 0 {
        return "missing runtime error payload".to_string();
    }
    let bytes = unsafe { slice::from_raw_parts(ptr, len) };
    let message = if bytes.len() >= 10 && &bytes[0..4] == b"PXE1" {
        let stage = bytes[4];
        let retryable = bytes[5] != 0;
        let message_len = u32::from_le_bytes([bytes[6], bytes[7], bytes[8], bytes[9]]) as usize;
        let message_start = 10usize;
        let message_end = message_start.saturating_add(message_len);
        if message_end <= bytes.len() {
            format!(
                "stage={stage} retryable={retryable} message={}",
                String::from_utf8_lossy(&bytes[message_start..message_end])
            )
        } else {
            "truncated runtime PXE1 error payload".to_string()
        }
    } else {
        String::from_utf8_lossy(bytes).to_string()
    };
    pixa_buffer_free(ptr, len);
    message
}

fn run(name: &str, iterations: usize, mut work: impl FnMut() -> usize) {
    let started = Instant::now();
    let mut bytes = 0usize;
    for _ in 0..iterations {
        bytes = bytes.saturating_add(work());
    }
    let elapsed = started.elapsed();
    let total_ns = elapsed.as_nanos();
    let avg_ns = average_nanoseconds(total_ns, iterations);
    println!(
        "{name},{iterations},{},{:.3},{}",
        total_ns / 1_000,
        avg_ns,
        bytes
    );
}

fn iterations(env_name: &str, default: usize) -> usize {
    std::env::var(env_name)
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

fn average_nanoseconds(total_ns: u128, iterations: usize) -> f64 {
    total_ns as f64 / iterations.max(1) as f64
}

#[cfg(test)]
mod tests {
    use super::average_nanoseconds;

    #[test]
    fn average_nanoseconds_preserves_sub_nanosecond_precision() {
        assert_eq!(average_nanoseconds(1_250_000, 2_000_000), 0.625);
    }
}

fn binary_request_fixture(id: &str) -> Vec<u8> {
    binary_request_fixture_with_processors(id, 4096, 4096, 8192, Vec::new())
}

fn binary_request_fixture_with_processors(
    id: &str,
    max_encoded_bytes: usize,
    max_decoded_pixels: u64,
    max_processor_output_bytes: usize,
    processors: Vec<String>,
) -> Vec<u8> {
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"PXR1");
    push_u8(&mut bytes, 2);
    push_string(&mut bytes, id);
    push_u32(&mut bytes, 0);
    push_string(&mut bytes, "benchmark");
    push_string(&mut bytes, id);
    push_string(&mut bytes, &format!("{id}-encoded"));
    push_u32(&mut bytes, 0);
    push_u32(&mut bytes, 0);
    push_u8(&mut bytes, 0);
    push_u8(&mut bytes, 1);
    push_u8(&mut bytes, 0);
    push_u8(&mut bytes, 0);
    push_i64(&mut bytes, 0);
    push_usize(&mut bytes, max_encoded_bytes);
    push_u64(&mut bytes, max_decoded_pixels);
    push_u64(&mut bytes, 24);
    push_u64(&mut bytes, 3000);
    push_usize(&mut bytes, max_processor_output_bytes);
    push_u64(&mut bytes, 2);
    push_u64(&mut bytes, 5000);
    push_u64(&mut bytes, 1000);
    push_u64(&mut bytes, 2000);
    push_u8(&mut bytes, 1);
    push_u8(&mut bytes, 0);
    push_u8(&mut bytes, 0);
    push_u64(&mut bytes, 1);
    push_u64(&mut bytes, 250);
    push_u64(&mut bytes, 0);
    push_string(&mut bytes, "");
    push_string(&mut bytes, "");
    push_u32(&mut bytes, processors.len() as u32);
    for processor in processors {
        push_string(&mut bytes, &processor);
    }
    bytes
}

fn minimal_gif() -> Vec<u8> {
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"GIF89a");
    bytes.extend_from_slice(&[1, 0, 1, 0, 0x80, 0, 0]);
    bytes.extend_from_slice(&[0, 0, 0, 255, 255, 255]);
    bytes.extend_from_slice(&[0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0]);
    bytes.extend_from_slice(&[2, 2, 0x4c, 0x01, 0]);
    bytes.push(0x3b);
    bytes
}

#[cfg(pixa_jpeg_turbo_processor)]
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
        .expect("JPEG benchmark fixture should encode");
    cursor.into_inner()
}

#[cfg(pixa_webp_processor)]
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

#[cfg(pixa_webp_processor)]
fn grayscale_gradient_webp(width: u32, height: u32) -> Vec<u8> {
    let mut pixels = Vec::with_capacity((width * height * 4) as usize);
    for y in 0..height {
        for x in 0..width {
            let value = grayscale_gradient_value(x, y);
            pixels.extend_from_slice(&[value, value, value, 255]);
        }
    }
    let mut output = std::ptr::null_mut();
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

#[cfg(pixa_webp_processor)]
fn grayscale_gradient_value(x: u32, y: u32) -> u8 {
    u8::try_from(40 + x + y).expect("64x64 grayscale fixture value should fit")
}

fn env_flag_enabled(name: &str) -> bool {
    std::env::var(name)
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn push_u8(bytes: &mut Vec<u8>, value: u8) {
    bytes.push(value);
}

fn push_u32(bytes: &mut Vec<u8>, value: u32) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn push_u64(bytes: &mut Vec<u8>, value: u64) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn push_usize(bytes: &mut Vec<u8>, value: usize) {
    push_u64(bytes, value as u64);
}

fn push_i64(bytes: &mut Vec<u8>, value: i64) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn push_string(bytes: &mut Vec<u8>, value: &str) {
    push_u32(bytes, value.len() as u32);
    bytes.extend_from_slice(value.as_bytes());
}
