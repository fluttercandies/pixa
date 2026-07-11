use super::{
    abi_struct_is_compatible, bytes_to_str, set_plugin_output_mime, PixaPluginFetchRequestV1,
    PixaPluginHostApiV1, PixaPluginModuleApiV1, PixaPluginOutputV1,
};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::ptr;
use std::sync::OnceLock;

const OUTPUT_MIME: &[u8] = b"image/jpeg";
const MAX_MJPEG_AVI_BYTES: u64 = 512 * 1024 * 1024;
const MAX_MJPEG_LIST_DEPTH: usize = 32;

static HOST_API: OnceLock<PixaPluginHostApiV1> = OnceLock::new();

#[allow(private_interfaces)]
#[no_mangle]
pub unsafe extern "C" fn pixa_mjpeg_video_frame_plugin_init(
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
        || host_api.cancel_is_requested.is_none()
        || host_api.progress_emit_fetch.is_none()
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
        (*module).fetch = Some(fetch_mjpeg_video_frame);
    }
    0
}

unsafe extern "C" fn fetch_mjpeg_video_frame(
    request: *const PixaPluginFetchRequestV1,
    output: *mut PixaPluginOutputV1,
) -> i32 {
    if request.is_null() || output.is_null() {
        return -1;
    }
    let request = unsafe { &*request };
    let output = unsafe { &mut *output };
    if !abi_struct_is_compatible::<PixaPluginFetchRequestV1>(
        request.abi_version,
        request.struct_size,
    ) || !abi_struct_is_compatible::<PixaPluginOutputV1>(output.abi_version, output.struct_size)
    {
        return -2;
    }
    let Some(source_kind) =
        (unsafe { bytes_to_str(request.source_kind_ptr, request.source_kind_len) })
    else {
        return -2;
    };
    if !source_kind.eq_ignore_ascii_case("video-frame:mjpeg") {
        return -3;
    }
    if !request.has_video_frame || request.video_exact {
        return -4;
    }
    let Some(locator) = (unsafe { bytes_to_str(request.locator_ptr, request.locator_len) }) else {
        return -5;
    };
    let path = match locator_to_path(locator) {
        Ok(path) => path,
        Err(code) => return code,
    };
    let bytes = match extract_nearest_frame_jpeg(
        path,
        request.video_timestamp_micros,
        request.max_output_bytes,
    ) {
        Ok(bytes) => bytes,
        Err(code) => return code,
    };
    copy_output_to_host_buffer(&bytes, output, request.max_output_bytes)
}

fn locator_to_path(locator: &str) -> Result<PathBuf, i32> {
    let trimmed = locator.trim();
    if trimmed.is_empty() || trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        return Err(-10);
    }
    if let Some(rest) = trimmed.strip_prefix("file://") {
        if rest.starts_with('/') {
            return percent_decode_path(rest);
        }
        return Err(-11);
    }
    Ok(PathBuf::from(trimmed))
}

fn percent_decode_path(value: &str) -> Result<PathBuf, i32> {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0_usize;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                return Err(-12);
            }
            let high = hex_value(bytes[index + 1]).ok_or(-13)?;
            let low = hex_value(bytes[index + 2]).ok_or(-13)?;
            output.push((high << 4) | low);
            index += 3;
        } else {
            output.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(output)
        .map(PathBuf::from)
        .map_err(|_| -14)
}

fn hex_value(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

fn extract_nearest_frame_jpeg(
    path: PathBuf,
    timestamp_micros: i64,
    max_output_bytes: usize,
) -> Result<Vec<u8>, i32> {
    if timestamp_micros < 0 || max_output_bytes == 0 {
        return Err(-20);
    }
    let mut file = File::open(&path).map_err(|_| -21)?;
    let file_len = file.metadata().map_err(|_| -22)?.len();
    if !(12..=MAX_MJPEG_AVI_BYTES).contains(&file_len) {
        return Err(-23);
    }

    let mut header = [0_u8; 12];
    file.read_exact(&mut header).map_err(|_| -24)?;
    if &header[0..4] != b"RIFF" || &header[8..12] != b"AVI " {
        return Err(-25);
    }
    let riff_size = u64::from(u32::from_le_bytes(
        header[4..8].try_into().map_err(|_| -26)?,
    ));
    let scan_end = file_len.min(8_u64.saturating_add(riff_size));
    let mut scanner = AviScanner::new(timestamp_micros, max_output_bytes);
    scan_chunks(&mut file, 12, scan_end, 0, &mut scanner)?;
    scanner.finish(&mut file)
}

struct AviScanner {
    timestamp_micros: i64,
    max_output_bytes: usize,
    target_index: Option<u64>,
    frame_index: u64,
    last_before_target: Option<(u64, u32)>,
    selected: Option<Vec<u8>>,
}

impl AviScanner {
    fn new(timestamp_micros: i64, max_output_bytes: usize) -> Self {
        Self {
            timestamp_micros,
            max_output_bytes,
            target_index: (timestamp_micros == 0).then_some(0),
            frame_index: 0,
            last_before_target: None,
            selected: None,
        }
    }

    fn set_frame_duration(&mut self, frame_duration_micros: u32) -> Result<(), i32> {
        if frame_duration_micros == 0 {
            return Ok(());
        }
        let duration = u64::from(frame_duration_micros);
        let timestamp = u64::try_from(self.timestamp_micros).map_err(|_| -30)?;
        self.target_index = Some(timestamp.saturating_add(duration / 2) / duration);
        Ok(())
    }

    fn visit_frame(&mut self, file: &mut File, data_start: u64, size: u32) -> Result<(), i32> {
        let index = self.frame_index;
        self.frame_index = self.frame_index.saturating_add(1);
        let Some(target) = self.target_index else {
            return Ok(());
        };
        if index == target {
            self.selected = Some(read_jpeg_chunk(
                file,
                data_start,
                size,
                self.max_output_bytes,
            )?);
        } else if index < target {
            self.last_before_target = Some((data_start, size));
        }
        Ok(())
    }

    fn done(&self) -> bool {
        self.selected.is_some()
    }

    fn finish(mut self, file: &mut File) -> Result<Vec<u8>, i32> {
        if let Some(bytes) = self.selected.take() {
            return Ok(bytes);
        }
        if self.target_index.is_none() {
            return Err(-31);
        }
        let Some((data_start, size)) = self.last_before_target else {
            return Err(-32);
        };
        read_jpeg_chunk(file, data_start, size, self.max_output_bytes)
    }
}

fn scan_chunks(
    file: &mut File,
    start: u64,
    end: u64,
    depth: usize,
    scanner: &mut AviScanner,
) -> Result<(), i32> {
    if depth > MAX_MJPEG_LIST_DEPTH {
        return Err(-54);
    }
    let mut cursor = start;
    while cursor.checked_add(8).ok_or(-40)? <= end && !scanner.done() {
        file.seek(SeekFrom::Start(cursor)).map_err(|_| -41)?;
        let mut header = [0_u8; 8];
        file.read_exact(&mut header).map_err(|_| -42)?;
        let id = [header[0], header[1], header[2], header[3]];
        let size = u32::from_le_bytes(header[4..8].try_into().map_err(|_| -43)?);
        let data_start = cursor.checked_add(8).ok_or(-44)?;
        let data_end = data_start.checked_add(u64::from(size)).ok_or(-45)?;
        if data_end > end {
            return Err(-46);
        }

        if &id == b"LIST" {
            if size >= 4 {
                let mut _list_type = [0_u8; 4];
                file.read_exact(&mut _list_type).map_err(|_| -47)?;
                scan_chunks(file, data_start + 4, data_end, depth + 1, scanner)?;
            }
        } else if &id == b"avih" {
            if size >= 4 {
                let mut duration = [0_u8; 4];
                file.read_exact(&mut duration).map_err(|_| -48)?;
                scanner.set_frame_duration(u32::from_le_bytes(duration))?;
            }
        } else if is_video_frame_chunk(id) {
            scanner.visit_frame(file, data_start, size)?;
        }

        cursor = data_end.checked_add(u64::from(size % 2)).ok_or(-49)?;
    }
    Ok(())
}

fn is_video_frame_chunk(id: [u8; 4]) -> bool {
    id[2].eq_ignore_ascii_case(&b'd') && matches!(id[3].to_ascii_lowercase(), b'b' | b'c')
}

fn read_jpeg_chunk(
    file: &mut File,
    data_start: u64,
    size: u32,
    max_output_bytes: usize,
) -> Result<Vec<u8>, i32> {
    let size = usize::try_from(size).map_err(|_| -50)?;
    if size == 0 || size > max_output_bytes {
        return Err(-51);
    }
    let mut bytes = vec![0_u8; size];
    file.seek(SeekFrom::Start(data_start)).map_err(|_| -52)?;
    file.read_exact(&mut bytes).map_err(|_| -53)?;
    extract_jpeg_payload(&bytes, max_output_bytes)
}

fn extract_jpeg_payload(bytes: &[u8], max_output_bytes: usize) -> Result<Vec<u8>, i32> {
    let soi = bytes
        .windows(2)
        .position(|pair| pair == [0xff, 0xd8])
        .ok_or(-60)?;
    let tail = &bytes[soi + 2..];
    let relative_eoi = tail
        .windows(2)
        .position(|pair| pair == [0xff, 0xd9])
        .ok_or(-61)?;
    let end = soi
        .checked_add(2)
        .and_then(|value| value.checked_add(relative_eoi))
        .and_then(|value| value.checked_add(2))
        .ok_or(-62)?;
    let payload = &bytes[soi..end];
    if payload.is_empty() || payload.len() > max_output_bytes {
        return Err(-63);
    }
    Ok(payload.to_vec())
}

fn copy_output_to_host_buffer(
    bytes: &[u8],
    output: &mut PixaPluginOutputV1,
    max_output_bytes: usize,
) -> i32 {
    if bytes.is_empty() || bytes.len() > max_output_bytes {
        return -70;
    }
    let Some(host) = HOST_API.get() else {
        return -71;
    };
    let Some(buffer_alloc) = host.buffer_alloc else {
        return -72;
    };
    let Some(buffer_data) = host.buffer_data else {
        return -73;
    };
    let Some(buffer_free) = host.buffer_free else {
        return -74;
    };
    let handle = unsafe { buffer_alloc(bytes.len()) };
    if handle.is_null() {
        return -75;
    }
    let data = unsafe { buffer_data(handle) };
    if data.is_null() {
        unsafe {
            buffer_free(handle);
        }
        return -76;
    }
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), data, bytes.len());
        output.buffer = handle;
    }
    if set_plugin_output_mime(output, OUTPUT_MIME).is_err() {
        unsafe { buffer_free(handle) };
        output.buffer = ptr::null_mut();
        return -77;
    }
    0
}

#[cfg(test)]
mod tests {
    use super::super::{ensure_generated_plugins_registered, PluginFetchRequest};
    use super::extract_nearest_frame_jpeg;
    use pixa_core::{
        image_metadata, plugin_registry_stats, runtime_fetcher_executor_for_source_kind,
        ImageMetadataFormat, RuntimePluginVideoFrameSpec,
    };
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn generated_mjpeg_video_frame_module_extracts_nearest_jpeg_frame() {
        ensure_generated_plugins_registered().expect("generated runtime plugins should register");
        let (module, executor) = runtime_fetcher_executor_for_source_kind("video-frame:mjpeg")
            .expect("runtime fetcher registry lookup should not fail")
            .expect("MJPEG video-frame module should be registered");

        let first = jpeg_rgb([255, 0, 0]);
        let second = jpeg_rgb([0, 255, 0]);
        let avi = mjpeg_avi_with_two_frames(1_000_000, &first, &second);
        let path = temp_video_path();
        fs::write(&path, avi).expect("test AVI should be writable");

        let output = executor
            .fetch(PluginFetchRequest {
                source_kind: "video-frame:mjpeg",
                locator: path.to_str().expect("temp path should be UTF-8"),
                video_frame: Some(RuntimePluginVideoFrameSpec {
                    timestamp_micros: 1_100_000,
                    exact: false,
                    backend: Some("mjpeg"),
                }),
                max_output_bytes: 8192,
                context: None,
            })
            .expect("fetch callback should succeed")
            .expect("fetch callback should be present");
        let _ = fs::remove_file(&path);

        assert_eq!(module.module_id, "pixa.video_frame.mjpeg");
        assert_eq!(output.mime_type.as_deref(), Some("image/jpeg"));
        assert_eq!(output.bytes.as_ref(), second.as_slice());
        let metadata = image_metadata(output.bytes.as_ref()).expect("JPEG metadata should parse");
        assert_eq!(metadata.format, ImageMetadataFormat::Jpeg);
        assert_eq!((metadata.width, metadata.height), (1, 1));
        let stats = plugin_registry_stats().expect("plugin stats should be available");
        assert_eq!(stats.video_frame_fetchers, 1);
        assert_eq!(stats.video_frame_encoded_output_fetchers, 1);
        assert_eq!(stats.video_frame_source_kinds, vec!["video-frame:mjpeg"]);
        assert_eq!(stats.video_frame_output_mime_types, vec!["image/jpeg"]);
    }

    #[test]
    fn mjpeg_nested_list_depth_is_bounded() {
        let jpeg = jpeg_rgb([12, 34, 56]);
        let allowed = mjpeg_avi_with_nested_frame(32, &jpeg);
        let allowed_path = temp_video_path();
        fs::write(&allowed_path, allowed).expect("boundary AVI should be writable");
        let extracted = extract_nearest_frame_jpeg(allowed_path.clone(), 0, 8192)
            .expect("maximum supported LIST depth should decode");
        let _ = fs::remove_file(&allowed_path);
        assert_eq!(extracted, jpeg);

        let excessive = mjpeg_avi_with_nested_frame(33, &jpeg);
        let excessive_path = temp_video_path();
        fs::write(&excessive_path, excessive).expect("deep AVI should be writable");
        let result = extract_nearest_frame_jpeg(excessive_path.clone(), 0, 8192);
        let _ = fs::remove_file(&excessive_path);
        assert_eq!(result, Err(-54));
    }

    fn jpeg_rgb(pixel: [u8; 3]) -> Vec<u8> {
        let mut bytes = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 90)
            .encode(&pixel, 1, 1, image::ExtendedColorType::Rgb8)
            .expect("test JPEG should encode");
        bytes
    }

    fn mjpeg_avi_with_two_frames(frame_duration_us: u32, first: &[u8], second: &[u8]) -> Vec<u8> {
        let mut avih = vec![0_u8; 56];
        avih[0..4].copy_from_slice(&frame_duration_us.to_le_bytes());
        avih[16..20].copy_from_slice(&2_u32.to_le_bytes());
        avih[32..36].copy_from_slice(&1_u32.to_le_bytes());
        avih[36..40].copy_from_slice(&1_u32.to_le_bytes());

        let hdrl = list_chunk(b"hdrl", &[chunk(b"avih", &avih)].concat());
        let movi = list_chunk(
            b"movi",
            &[chunk(b"00dc", first), chunk(b"00dc", second)].concat(),
        );
        let mut payload = Vec::new();
        payload.extend_from_slice(b"AVI ");
        payload.extend_from_slice(&hdrl);
        payload.extend_from_slice(&movi);

        let mut riff = Vec::new();
        riff.extend_from_slice(b"RIFF");
        riff.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        riff.extend_from_slice(&payload);
        riff
    }

    fn mjpeg_avi_with_nested_frame(depth: usize, jpeg: &[u8]) -> Vec<u8> {
        let mut avih = vec![0_u8; 56];
        avih[0..4].copy_from_slice(&1_000_000_u32.to_le_bytes());
        avih[16..20].copy_from_slice(&1_u32.to_le_bytes());
        avih[32..36].copy_from_slice(&1_u32.to_le_bytes());
        avih[36..40].copy_from_slice(&1_u32.to_le_bytes());

        let hdrl = list_chunk(b"hdrl", &[chunk(b"avih", &avih)].concat());
        let mut nested = chunk(b"00dc", jpeg);
        for _ in 0..depth {
            nested = list_chunk(b"nest", &nested);
        }
        let mut payload = Vec::new();
        payload.extend_from_slice(b"AVI ");
        payload.extend_from_slice(&hdrl);
        payload.extend_from_slice(&nested);

        let mut riff = Vec::new();
        riff.extend_from_slice(b"RIFF");
        riff.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        riff.extend_from_slice(&payload);
        riff
    }

    fn list_chunk(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(kind);
        data.extend_from_slice(payload);
        chunk(b"LIST", &data)
    }

    fn chunk(id: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(id);
        data.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        data.extend_from_slice(payload);
        if !payload.len().is_multiple_of(2) {
            data.push(0);
        }
        data
    }

    fn temp_video_path() -> std::path::PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be after epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("pixa-mjpeg-{nanos}.avi"))
    }
}
