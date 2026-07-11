use image::codecs::png::PngEncoder;
use image::{ExtendedColorType, ImageEncoder};
use pixa_core::cache::DiskCache;
use pixa_core::request::{
    RuntimeLimits, RuntimePriority, RuntimeRedirectPolicy, RuntimeRetryPolicy,
};
use pixa_core::{
    configure, decode_image_to_rgba, fnv1a64, load_image, memory_clear, CacheMode,
    RuntimePipelineConfig, RuntimeRequest, RuntimeSource,
};
use std::collections::BTreeMap;
use std::hint::black_box;
use std::io::{Cursor, Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

fn main() {
    configure(RuntimePipelineConfig {
        memory_cache_bytes: 64 * 1024 * 1024,
        disk_cache_bytes: 128 * 1024 * 1024,
        network_concurrency: 6,
    })
    .expect("runtime pipeline config should apply");

    println!("name,iterations,total_us,avg_ns,bytes");
    bench_hash();
    bench_memory_hit();
    bench_disk_hit();
    bench_disk_metadata_probe();
    bench_origin_fetch_coalescing();
    bench_resize_processor();
    bench_region_tile_processors();
    bench_format_decode_matrix();
}

fn bench_hash() {
    let material = (0..4096)
        .map(|index| (index % 251) as u8)
        .collect::<Vec<u8>>();
    run(
        "fnv1a64_4kb",
        iterations("PIXA_BENCH_HASH_ITERS", 500_000),
        || {
            black_box(fnv1a64(black_box(&material)));
            material.len()
        },
    );
}

fn bench_memory_hit() {
    memory_clear().expect("memory cache should clear");
    let png = png_fixture(32, 32);
    let request = request("memory-hit-final", CacheMode::MemoryOnly, Vec::new());
    let loaded = load_image("", request.clone(), Some(&png)).expect("seed memory cache");
    black_box(loaded.bytes.len());

    run(
        "encoded_memory_hit_32px_png",
        iterations("PIXA_BENCH_MEMORY_ITERS", 20_000),
        || {
            let loaded = load_image("", request.clone(), None).expect("memory hit should load");
            let bytes = loaded.bytes.len();
            black_box(bytes);
            bytes
        },
    );
}

fn bench_disk_hit() {
    let root = benchmark_root("disk-hit");
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).expect("benchmark root should be created");
    let png = png_fixture(32, 32);
    let request = request("1111111111111111", CacheMode::DiskOnly, Vec::new());
    let loaded =
        load_image(root.to_str().unwrap(), request.clone(), Some(&png)).expect("seed disk cache");
    black_box(loaded.bytes.len());

    run(
        "encoded_disk_hit_32px_png",
        iterations("PIXA_BENCH_DISK_ITERS", 2_000),
        || {
            let loaded =
                load_image(root.to_str().unwrap(), request.clone(), None).expect("disk hit");
            let bytes = loaded.bytes.len();
            black_box(bytes);
            bytes
        },
    );
    let _ = std::fs::remove_dir_all(root);
}

fn bench_disk_metadata_probe() {
    let root = benchmark_root("disk-metadata-probe");
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).expect("benchmark root should be created");
    let png = png_fixture(32, 32);
    let disk = DiskCache::new(&root);
    let key = "2222222222222222";
    disk.write("benchmark", key, &png, Some(60_000))
        .expect("seed disk metadata probe entry");

    run(
        "disk_metadata_contains_32px_png",
        iterations("PIXA_BENCH_DISK_INDEX_ITERS", 10_000),
        || {
            let hit = disk
                .contains("benchmark", key, false)
                .expect("disk metadata probe should succeed");
            black_box(hit);
            png.len()
        },
    );
    let _ = std::fs::remove_dir_all(root);
}

fn bench_origin_fetch_coalescing() {
    let body = Arc::new(png_fixture(48, 48));
    let fanout = iterations("PIXA_BENCH_ORIGIN_FANOUT", 64);
    let mut batch = 0usize;

    run(
        "origin_fetch_coalesced_network_variants",
        iterations("PIXA_BENCH_ORIGIN_BATCHES", 20),
        || {
            batch += 1;
            memory_clear().expect("memory cache should clear");
            let (url, server) =
                spawn_single_response_server(body.clone(), Duration::from_millis(5));
            let barrier = Arc::new(Barrier::new(fanout + 1));
            let mut handles = Vec::with_capacity(fanout);
            for index in 0..fanout {
                let request = network_request(
                    &format!("coalesced-final-{batch}-{index}"),
                    &format!("coalesced-origin-{batch}"),
                    &url,
                );
                let request_barrier = barrier.clone();
                handles.push(thread::spawn(move || {
                    request_barrier.wait();
                    load_image("", request, None).expect("coalesced network variant should load")
                }));
            }
            barrier.wait();
            let mut bytes = 0usize;
            for handle in handles {
                bytes = bytes.saturating_add(handle.join().unwrap().bytes.len());
            }
            let request_bytes = server.join().expect("benchmark server should join");
            black_box(request_bytes);
            bytes
        },
    );
}

fn bench_resize_processor() {
    memory_clear().expect("memory cache should clear");
    let png = png_fixture(96, 96);
    let request = request(
        "resize-final",
        CacheMode::NoStore,
        vec!["resize(width=48,height=48,mode=exact,filter=nearest)".to_string()],
    );

    run(
        "processor_resize_96_to_48_png",
        iterations("PIXA_BENCH_PROCESSOR_ITERS", 300),
        || {
            let loaded = load_image("", request.clone(), Some(&png)).expect("resize should run");
            let bytes = loaded.bytes.len();
            black_box(bytes);
            bytes
        },
    );
}

fn bench_region_tile_processors() {
    let fixtures: Vec<(&str, Vec<u8>)> = vec![
        ("png", png_fixture(256, 256)),
        ("bmp", bmp_rgb_fixture(256, 256)),
        ("farbfeld", farbfeld_rgba_fixture(256, 256)),
    ];
    let count = iterations("PIXA_BENCH_REGION_ITERS", 200);

    for (label, bytes) in fixtures {
        let request = request(
            &format!("tile-region-{label}-final"),
            CacheMode::NoStore,
            vec![
                "tile(x=64,y=64,width=128,height=128,decodedWidth=128,decodedHeight=128,filter=nearest)"
                    .to_string(),
            ],
        );
        let benchmark = format!("processor_tile_region_{label}_128");
        run(&benchmark, count, || {
            let loaded = load_image("", request.clone(), Some(&bytes))
                .unwrap_or_else(|error| panic!("{label} tile region failed: {error:?}"));
            let byte_len = loaded.bytes.len();
            black_box(byte_len);
            byte_len
        });
    }
}

fn bench_format_decode_matrix() {
    let fixtures: Vec<(&str, Vec<u8>, u32, u32)> = vec![
        ("tiff", tiff_rgba_1x1(), 1, 1),
        ("pnm", pnm_rgb_1x1(), 1, 1),
        ("qoi", qoi_rgba_1x1(), 1, 1),
        ("tga", tga_rgb_1x1(), 1, 1),
        ("dds", dds_dxt1_4x4(), 4, 4),
        ("hdr", hdr_rgb_1x1(), 1, 1),
        ("farbfeld", farbfeld_rgba_1x1(), 1, 1),
        ("pcx", pcx_rgb_1x1(), 1, 1),
        ("sgi", sgi_rgb_1x1(), 1, 1),
        ("wbmp", wbmp_image(1, 1), 1, 1),
        ("xbm", xbm_1x1(), 1, 1),
        ("xpm", xpm_1x1(), 1, 1),
    ];
    let count = iterations("PIXA_BENCH_FORMAT_DECODE_ITERS", 300);

    for (label, bytes, expected_width, expected_height) in fixtures {
        let benchmark = format!("runtime_format_decode_{label}_rgba");
        let max_pixels = u64::from(expected_width) * u64::from(expected_height);
        let max_output_bytes = (max_pixels as usize) * 4;
        run(&benchmark, count, || {
            let rgba = decode_image_to_rgba(&bytes, max_pixels, max_output_bytes)
                .unwrap_or_else(|error| panic!("{label} RGBA decode failed: {error:?}"));
            assert_eq!(rgba.width, expected_width, "{label} width mismatch");
            assert_eq!(rgba.height, expected_height, "{label} height mismatch");
            let byte_len = rgba.bytes.len();
            black_box(byte_len);
            byte_len
        });
    }
}

fn run(name: &str, iterations: usize, mut work: impl FnMut() -> usize) {
    let started = Instant::now();
    let mut bytes = 0usize;
    for _ in 0..iterations {
        bytes = bytes.saturating_add(work());
    }
    let elapsed = started.elapsed();
    let total_ns = elapsed.as_nanos();
    let avg_ns = total_ns / iterations.max(1) as u128;
    println!(
        "{name},{iterations},{},{},{}",
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

fn request(cache_key: &str, cache_mode: CacheMode, processors: Vec<String>) -> RuntimeRequest {
    RuntimeRequest {
        source: RuntimeSource::Bytes {
            id: cache_key.to_string(),
        },
        headers: BTreeMap::new(),
        namespace: "benchmark".to_string(),
        cache_key: cache_key.to_string(),
        encoded_cache_key: format!("{cache_key}e"),
        target_width: None,
        target_height: None,
        decoder_mime_type: None,
        decoder_format_id: None,
        cache_mode,
        ttl_ms: None,
        private_cache: false,
        processors,
        limits: RuntimeLimits::default(),
        redirect_policy: RuntimeRedirectPolicy::default(),
        priority: RuntimePriority::Normal,
        retry: RuntimeRetryPolicy::default(),
    }
}

fn network_request(cache_key: &str, encoded_cache_key: &str, url: &str) -> RuntimeRequest {
    let mut request = request(cache_key, CacheMode::MemoryOnly, Vec::new());
    request.source = RuntimeSource::Network {
        uri: url.to_string(),
    };
    request.encoded_cache_key = encoded_cache_key.to_string();
    request
}

fn png_fixture(width: u32, height: u32) -> Vec<u8> {
    let mut pixels = Vec::with_capacity((width * height * 4) as usize);
    for y in 0..height {
        for x in 0..width {
            pixels.push((x % 251) as u8);
            pixels.push((y % 251) as u8);
            pixels.push(((x + y) % 251) as u8);
            pixels.push(255);
        }
    }

    let mut bytes = Vec::new();
    PngEncoder::new(&mut bytes)
        .write_image(&pixels, width, height, ExtendedColorType::Rgba8)
        .expect("PNG fixture should encode");
    bytes
}

fn bmp_rgb_fixture(width: u32, height: u32) -> Vec<u8> {
    let mut pixels = Vec::with_capacity((width * height * 3) as usize);
    for y in 0..height {
        for x in 0..width {
            pixels.push((x % 251) as u8);
            pixels.push((y % 251) as u8);
            pixels.push(((x + y) % 251) as u8);
        }
    }
    let mut bytes = Vec::new();
    image::codecs::bmp::BmpEncoder::new(&mut bytes)
        .encode(&pixels, width, height, ExtendedColorType::Rgb8)
        .expect("BMP fixture should encode");
    bytes
}

fn farbfeld_rgba_fixture(width: u32, height: u32) -> Vec<u8> {
    let mut bytes = b"farbfeld".to_vec();
    bytes.extend_from_slice(&width.to_be_bytes());
    bytes.extend_from_slice(&height.to_be_bytes());
    for y in 0..height {
        for x in 0..width {
            let red = ((x % 251) as u16) * 257;
            let green = ((y % 251) as u16) * 257;
            let blue = (((x + y) % 251) as u16) * 257;
            bytes.extend_from_slice(&red.to_be_bytes());
            bytes.extend_from_slice(&green.to_be_bytes());
            bytes.extend_from_slice(&blue.to_be_bytes());
            bytes.extend_from_slice(&u16::MAX.to_be_bytes());
        }
    }
    bytes
}

fn pnm_rgb_1x1() -> Vec<u8> {
    let mut bytes = b"P6\n1 1\n255\n".to_vec();
    bytes.extend_from_slice(&[255, 0, 0]);
    bytes
}

fn tiff_rgba_1x1() -> Vec<u8> {
    let mut cursor = Cursor::new(Vec::new());
    image::codecs::tiff::TiffEncoder::new(&mut cursor)
        .write_image(&[255, 0, 0, 255], 1, 1, ExtendedColorType::Rgba8)
        .expect("benchmark TIFF should encode");
    cursor.into_inner()
}

fn qoi_rgba_1x1() -> Vec<u8> {
    let mut bytes = Vec::new();
    image::codecs::qoi::QoiEncoder::new(&mut bytes)
        .write_image(&[255, 0, 0, 255], 1, 1, ExtendedColorType::Rgba8)
        .expect("benchmark QOI should encode");
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
        .expect("benchmark HDR should encode");
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

fn wbmp_image(width: u32, height: u32) -> Vec<u8> {
    let row_bytes = width.div_ceil(8);
    let mut bytes = vec![0, 0];
    push_wbmp_multi_byte_integer(&mut bytes, width);
    push_wbmp_multi_byte_integer(&mut bytes, height);
    bytes.extend(std::iter::repeat_n(0xff, (row_bytes * height) as usize));
    bytes
}

fn xbm_1x1() -> Vec<u8> {
    b"#define test_width 1\n#define test_height 1\nstatic unsigned char test_bits[] = { 0x01 };\n"
        .to_vec()
}

fn xpm_1x1() -> Vec<u8> {
    b"/* XPM */\nstatic char *xpm[] = {\n\"1 1 1 1\",\n\"a c #ff0000\",\n\"a\"\n};\n".to_vec()
}

fn push_wbmp_multi_byte_integer(bytes: &mut Vec<u8>, mut value: u32) {
    let mut encoded = vec![(value & 0x7f) as u8];
    value >>= 7;
    while value != 0 {
        encoded.push(((value & 0x7f) as u8) | 0x80);
        value >>= 7;
    }
    for byte in encoded.iter().rev() {
        bytes.push(*byte);
    }
}

fn benchmark_root(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("pixa-benchmark-{name}-{}", std::process::id()))
}

fn spawn_single_response_server(
    body: Arc<Vec<u8>>,
    delay: Duration,
) -> (String, thread::JoinHandle<usize>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("benchmark server should bind");
    let address = listener
        .local_addr()
        .expect("benchmark server should expose local address");
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("benchmark server should accept");
        let mut buffer = [0_u8; 2048];
        let request_bytes = stream.read(&mut buffer).unwrap_or(0);
        if !delay.is_zero() {
            thread::sleep(delay);
        }
        let headers = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        stream
            .write_all(headers.as_bytes())
            .expect("benchmark server should write headers");
        stream
            .write_all(body.as_ref())
            .expect("benchmark server should write body");
        request_bytes
    });
    (format!("http://{address}/image.png"), handle)
}
