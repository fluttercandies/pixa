use crate::{RuntimeError, RuntimeResult};
use std::collections::BTreeMap;

const BINARY_REQUEST_MAGIC: &[u8; 4] = b"PXR1";
const MAX_REQUEST_STRING_BYTES: usize = 1024 * 1024;
const MAX_REQUEST_HEADERS: usize = 256;
const MAX_REQUEST_PROCESSORS: usize = 128;

/// Runtime image source.
#[derive(Clone, Debug)]
pub enum RuntimeSource {
    Network {
        uri: String,
    },
    File {
        path: String,
    },
    Bytes {
        id: String,
    },
    AssetBytes {
        id: String,
    },
    ExifThumbnail {
        path: String,
    },
    RuntimePlugin {
        source_kind: String,
        locator: String,
    },
    VideoFrame {
        locator: String,
        timestamp_micros: i64,
        exact: bool,
        backend: Option<String>,
    },
}

/// Cache mode mirrored from Dart.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CacheMode {
    NoStore,
    MemoryOnly,
    DiskOnly,
    MemoryAndDisk,
    CacheOnly,
    NetworkOnly,
    Refresh,
    StaleWhileRevalidate,
}

/// Runtime scheduler priority mirrored from Dart.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimePriority {
    Low,
    Normal,
    High,
    Immediate,
}

/// Runtime retry mode mirrored from Dart.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeRetryMode {
    None,
    Fixed,
    Exponential,
}

/// Retry policy executed by Rust around retryable runtime failures.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RuntimeRetryPolicy {
    pub mode: RuntimeRetryMode,
    pub max_attempts: usize,
    pub delay_ms: u64,
    pub jitter_ms: u64,
}

impl Default for RuntimeRetryPolicy {
    fn default() -> Self {
        Self {
            mode: RuntimeRetryMode::None,
            max_attempts: 1,
            delay_ms: 250,
            jitter_ms: 0,
        }
    }
}

impl CacheMode {
    pub fn read_memory(self) -> bool {
        matches!(
            self,
            Self::MemoryOnly | Self::MemoryAndDisk | Self::CacheOnly | Self::StaleWhileRevalidate
        )
    }

    pub fn read_disk(self) -> bool {
        matches!(
            self,
            Self::DiskOnly | Self::MemoryAndDisk | Self::CacheOnly | Self::StaleWhileRevalidate
        )
    }

    pub fn write_memory(self) -> bool {
        matches!(
            self,
            Self::MemoryOnly
                | Self::MemoryAndDisk
                | Self::NetworkOnly
                | Self::Refresh
                | Self::StaleWhileRevalidate
        )
    }

    pub fn write_disk(self) -> bool {
        matches!(
            self,
            Self::DiskOnly
                | Self::MemoryAndDisk
                | Self::NetworkOnly
                | Self::Refresh
                | Self::StaleWhileRevalidate
        )
    }
}

/// runtime request limits.
#[derive(Clone, Debug)]
pub struct RuntimeLimits {
    pub max_encoded_bytes: usize,
    pub max_decoded_pixels: u64,
    pub max_animation_frames: usize,
    pub max_animation_duration_ms: u64,
    pub max_processor_output_bytes: usize,
    pub max_redirects: usize,
    pub timeout_ms: u64,
    pub connect_timeout_ms: u64,
    pub idle_timeout_ms: u64,
}

/// Runtime redirect policy mirrored from Dart.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RuntimeRedirectPolicy {
    pub allow_cross_host_redirects: bool,
    pub allow_https_to_http: bool,
}

impl Default for RuntimeRedirectPolicy {
    fn default() -> Self {
        Self {
            allow_cross_host_redirects: true,
            allow_https_to_http: false,
        }
    }
}

impl Default for RuntimeLimits {
    fn default() -> Self {
        Self {
            max_encoded_bytes: default_max_encoded_bytes(),
            max_decoded_pixels: default_max_decoded_pixels(),
            max_animation_frames: default_max_animation_frames(),
            max_animation_duration_ms: default_max_animation_duration_ms(),
            max_processor_output_bytes: default_max_processor_output_bytes(),
            max_redirects: default_max_redirects(),
            timeout_ms: default_timeout_ms(),
            connect_timeout_ms: default_connect_timeout_ms(),
            idle_timeout_ms: default_idle_timeout_ms(),
        }
    }
}

/// Normalized runtime load request.
#[derive(Clone, Debug)]
pub struct RuntimeRequest {
    pub source: RuntimeSource,
    pub headers: BTreeMap<String, String>,
    pub namespace: String,
    pub cache_key: String,
    pub encoded_cache_key: String,
    pub target_width: Option<u32>,
    pub target_height: Option<u32>,
    pub decoder_mime_type: Option<String>,
    pub decoder_format_id: Option<String>,
    pub cache_mode: CacheMode,
    pub ttl_ms: Option<i64>,
    pub private_cache: bool,
    pub processors: Vec<String>,
    pub limits: RuntimeLimits,
    pub redirect_policy: RuntimeRedirectPolicy,
    pub priority: RuntimePriority,
    pub retry: RuntimeRetryPolicy,
}

/// Decodes the compact Dart-to-Rust request ABI.
pub fn decode_binary_request(bytes: &[u8]) -> RuntimeResult<RuntimeRequest> {
    let mut reader = BinaryRequestReader::new(bytes);
    let magic = reader.take(4)?;
    if magic != BINARY_REQUEST_MAGIC {
        return Err(RuntimeError::new(
            "request",
            false,
            "invalid binary request magic",
        ));
    }

    let source = match reader.read_u8()? {
        0 => RuntimeSource::Network {
            uri: reader.read_string()?,
        },
        1 => RuntimeSource::File {
            path: reader.read_string()?,
        },
        2 => RuntimeSource::Bytes {
            id: reader.read_string()?,
        },
        3 => RuntimeSource::AssetBytes {
            id: reader.read_string()?,
        },
        4 => RuntimeSource::ExifThumbnail {
            path: reader.read_string()?,
        },
        5 => RuntimeSource::RuntimePlugin {
            source_kind: reader.read_string()?,
            locator: reader.read_string()?,
        },
        6 => {
            let locator = reader.read_string()?;
            let timestamp_micros = reader.read_i64()?;
            if timestamp_micros < 0 {
                return Err(RuntimeError::new(
                    "request",
                    false,
                    "video frame timestamp must not be negative",
                ));
            }
            RuntimeSource::VideoFrame {
                locator,
                timestamp_micros,
                exact: decode_video_frame_exact(reader.read_u8()?)?,
                backend: optional_route_claim(reader.read_string()?),
            }
        }
        value => {
            return Err(RuntimeError::new(
                "request",
                false,
                format!("unknown binary request source kind {value}"),
            ));
        }
    };

    let headers = reader.read_string_map(MAX_REQUEST_HEADERS, "headers")?;
    let namespace = reader.read_string()?;
    let cache_key = reader.read_string()?;
    let encoded_cache_key = reader.read_string()?;
    let target_width = non_zero_dimension(reader.read_u32()?);
    let target_height = non_zero_dimension(reader.read_u32()?);
    let cache_mode = decode_cache_mode(reader.read_u8()?)?;
    let priority = decode_priority(reader.read_u8()?)?;
    let private_cache = reader.read_bool()?;
    let has_ttl = reader.read_bool()?;
    let ttl_value = reader.read_i64()?;
    let ttl_ms = has_ttl.then_some(ttl_value);
    let limits = RuntimeLimits {
        max_encoded_bytes: reader.read_usize("max_encoded_bytes")?,
        max_decoded_pixels: reader.read_u64()?,
        max_animation_frames: reader.read_usize("max_animation_frames")?,
        max_animation_duration_ms: reader.read_u64()?,
        max_processor_output_bytes: reader.read_usize("max_processor_output_bytes")?,
        max_redirects: reader.read_usize("max_redirects")?,
        timeout_ms: reader.read_u64()?,
        connect_timeout_ms: reader.read_u64()?,
        idle_timeout_ms: reader.read_u64()?,
    };
    let redirect_policy = RuntimeRedirectPolicy {
        allow_cross_host_redirects: reader.read_bool()?,
        allow_https_to_http: reader.read_bool()?,
    };
    let retry = RuntimeRetryPolicy {
        mode: decode_retry_mode(reader.read_u8()?)?,
        max_attempts: reader.read_usize("max_attempts")?,
        delay_ms: reader.read_u64()?,
        jitter_ms: reader.read_u64()?,
    };
    let decoder_mime_type = optional_route_claim(reader.read_string()?);
    let decoder_format_id = optional_route_claim(reader.read_string()?);
    let processors = reader.read_string_list(MAX_REQUEST_PROCESSORS, "processors")?;
    reader.finish()?;

    Ok(RuntimeRequest {
        source,
        headers,
        namespace,
        cache_key,
        encoded_cache_key,
        target_width,
        target_height,
        decoder_mime_type,
        decoder_format_id,
        cache_mode,
        ttl_ms,
        private_cache,
        processors,
        limits,
        redirect_policy,
        priority,
        retry,
    })
}

struct BinaryRequestReader<'a> {
    bytes: &'a [u8],
    cursor: usize,
}

impl<'a> BinaryRequestReader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, cursor: 0 }
    }

    fn take(&mut self, len: usize) -> RuntimeResult<&'a [u8]> {
        let end = self
            .cursor
            .checked_add(len)
            .ok_or_else(|| RuntimeError::new("request", false, "binary request offset overflow"))?;
        if end > self.bytes.len() {
            return Err(RuntimeError::new(
                "request",
                false,
                "truncated binary request",
            ));
        }
        let slice = &self.bytes[self.cursor..end];
        self.cursor = end;
        Ok(slice)
    }

    fn read_u8(&mut self) -> RuntimeResult<u8> {
        Ok(self.take(1)?[0])
    }

    fn read_bool(&mut self) -> RuntimeResult<bool> {
        match self.read_u8()? {
            0 => Ok(false),
            1 => Ok(true),
            value => Err(RuntimeError::new(
                "request",
                false,
                format!("invalid binary boolean value {value}"),
            )),
        }
    }

    fn read_u32(&mut self) -> RuntimeResult<u32> {
        let bytes = self.take(4)?;
        Ok(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn read_u64(&mut self) -> RuntimeResult<u64> {
        let bytes = self.take(8)?;
        Ok(u64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]))
    }

    fn read_i64(&mut self) -> RuntimeResult<i64> {
        let bytes = self.take(8)?;
        Ok(i64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]))
    }

    fn read_usize(&mut self, label: &'static str) -> RuntimeResult<usize> {
        usize::try_from(self.read_u64()?).map_err(|_| {
            RuntimeError::new(
                "request",
                false,
                format!("binary request {label} does not fit this platform"),
            )
        })
    }

    fn read_string(&mut self) -> RuntimeResult<String> {
        let len = self.read_u32()? as usize;
        if len > MAX_REQUEST_STRING_BYTES {
            return Err(RuntimeError::new(
                "request",
                false,
                "binary request string exceeds length limit",
            ));
        }
        let bytes = self.take(len)?;
        std::str::from_utf8(bytes)
            .map(str::to_owned)
            .map_err(|error| RuntimeError::new("request", false, format!("invalid UTF-8: {error}")))
    }

    fn read_string_map(
        &mut self,
        max_len: usize,
        label: &'static str,
    ) -> RuntimeResult<BTreeMap<String, String>> {
        let count = self.read_u32()? as usize;
        if count > max_len {
            return Err(RuntimeError::new(
                "request",
                false,
                format!("binary request {label} count exceeds limit"),
            ));
        }
        let mut values = BTreeMap::new();
        for _ in 0..count {
            values.insert(self.read_string()?, self.read_string()?);
        }
        Ok(values)
    }

    fn read_string_list(
        &mut self,
        max_len: usize,
        label: &'static str,
    ) -> RuntimeResult<Vec<String>> {
        let count = self.read_u32()? as usize;
        if count > max_len {
            return Err(RuntimeError::new(
                "request",
                false,
                format!("binary request {label} count exceeds limit"),
            ));
        }
        let mut values = Vec::with_capacity(count);
        for _ in 0..count {
            values.push(self.read_string()?);
        }
        Ok(values)
    }

    fn finish(self) -> RuntimeResult<()> {
        if self.cursor == self.bytes.len() {
            return Ok(());
        }
        Err(RuntimeError::new(
            "request",
            false,
            "binary request has trailing bytes",
        ))
    }
}

fn decode_cache_mode(value: u8) -> RuntimeResult<CacheMode> {
    match value {
        0 => Ok(CacheMode::NoStore),
        1 => Ok(CacheMode::MemoryOnly),
        2 => Ok(CacheMode::DiskOnly),
        3 => Ok(CacheMode::MemoryAndDisk),
        4 => Ok(CacheMode::CacheOnly),
        5 => Ok(CacheMode::NetworkOnly),
        6 => Ok(CacheMode::Refresh),
        7 => Ok(CacheMode::StaleWhileRevalidate),
        _ => Err(RuntimeError::new(
            "request",
            false,
            format!("unknown binary request cache mode {value}"),
        )),
    }
}

fn decode_priority(value: u8) -> RuntimeResult<RuntimePriority> {
    match value {
        0 => Ok(RuntimePriority::Low),
        1 => Ok(RuntimePriority::Normal),
        2 => Ok(RuntimePriority::High),
        3 => Ok(RuntimePriority::Immediate),
        _ => Err(RuntimeError::new(
            "request",
            false,
            format!("unknown binary request priority {value}"),
        )),
    }
}

fn decode_retry_mode(value: u8) -> RuntimeResult<RuntimeRetryMode> {
    match value {
        0 => Ok(RuntimeRetryMode::None),
        1 => Ok(RuntimeRetryMode::Fixed),
        2 => Ok(RuntimeRetryMode::Exponential),
        _ => Err(RuntimeError::new(
            "request",
            false,
            format!("unknown binary request retry mode {value}"),
        )),
    }
}

fn decode_video_frame_exact(value: u8) -> RuntimeResult<bool> {
    match value {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(RuntimeError::new(
            "request",
            false,
            format!("unknown binary request video frame selection {value}"),
        )),
    }
}

fn non_zero_dimension(value: u32) -> Option<u32> {
    (value != 0).then_some(value)
}

fn optional_route_claim(value: String) -> Option<String> {
    let normalized = value.split(';').next().unwrap_or("").trim().to_lowercase();
    (!normalized.is_empty()).then_some(normalized)
}

fn default_max_encoded_bytes() -> usize {
    32 * 1024 * 1024
}

fn default_max_decoded_pixels() -> u64 {
    64 * 1000 * 1000
}

fn default_max_animation_frames() -> usize {
    600
}

fn default_max_animation_duration_ms() -> u64 {
    60_000
}

fn default_max_processor_output_bytes() -> usize {
    64 * 1024 * 1024
}

fn default_max_redirects() -> usize {
    5
}

fn default_timeout_ms() -> u64 {
    30_000
}

fn default_connect_timeout_ms() -> u64 {
    10_000
}

fn default_idle_timeout_ms() -> u64 {
    15_000
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_binary_request_with_all_control_fields() {
        let bytes = binary_request_fixture();

        let request = decode_binary_request(&bytes).expect("binary request should decode");

        assert!(
            matches!(request.source, RuntimeSource::Network { ref uri } if uri == "https://example.test/a.jpg")
        );
        assert_eq!(
            request.headers.get("Accept").map(String::as_str),
            Some("image/*")
        );
        assert_eq!(request.namespace, "avatars");
        assert_eq!(request.cache_key, "abc123");
        assert_eq!(request.encoded_cache_key, "encoded123");
        assert_eq!(request.target_width, Some(320));
        assert_eq!(request.target_height, Some(180));
        assert_eq!(request.decoder_mime_type.as_deref(), Some("image/gif"));
        assert_eq!(request.decoder_format_id.as_deref(), Some("gif"));
        assert_eq!(request.cache_mode, CacheMode::Refresh);
        assert_eq!(request.priority, RuntimePriority::High);
        assert_eq!(request.ttl_ms, Some(1234));
        assert!(request.private_cache);
        assert_eq!(request.processors, vec!["resize(width=64)"]);
        assert_eq!(request.limits.max_encoded_bytes, 4096);
        assert_eq!(request.limits.max_decoded_pixels, 8192);
        assert_eq!(request.limits.max_animation_frames, 24);
        assert_eq!(request.limits.max_animation_duration_ms, 3000);
        assert_eq!(request.limits.max_processor_output_bytes, 8192);
        assert_eq!(request.limits.max_redirects, 2);
        assert_eq!(request.limits.timeout_ms, 5000);
        assert_eq!(request.limits.connect_timeout_ms, 1000);
        assert_eq!(request.limits.idle_timeout_ms, 2000);
        assert!(!request.redirect_policy.allow_cross_host_redirects);
        assert!(request.redirect_policy.allow_https_to_http);
        assert_eq!(request.retry.mode, RuntimeRetryMode::Exponential);
        assert_eq!(request.retry.max_attempts, 3);
        assert_eq!(request.retry.delay_ms, 250);
        assert_eq!(request.retry.jitter_ms, 50);
    }

    #[test]
    fn rejects_invalid_binary_request_magic() {
        let error = decode_binary_request(b"{\"source\":{}}").expect_err("JSON is not binary ABI");

        assert_eq!(error.stage, "request");
        assert!(error.message.contains("magic"));
    }

    #[test]
    fn decodes_plugin_source_without_inline_bytes() {
        let bytes = binary_request_fixture_with_source(|bytes| {
            push_u8(bytes, 5);
            push_string(bytes, "s3");
            push_string(bytes, "s3://bucket/key.gif");
        });

        let request = decode_binary_request(&bytes).expect("runtime plugin source should decode");

        assert!(matches!(
            request.source,
            RuntimeSource::RuntimePlugin {
                ref source_kind,
                ref locator,
            } if source_kind == "s3" && locator == "s3://bucket/key.gif"
        ));
    }

    #[test]
    fn decodes_video_frame_source_without_inline_bytes() {
        let bytes = binary_request_fixture_with_source(|bytes| {
            push_u8(bytes, 6);
            push_string(bytes, "https://media.example.test/movie.mp4?token=alpha");
            push_i64(bytes, 1_234_000);
            push_u8(bytes, 1);
            push_string(bytes, "platform-codec");
        });

        let request = decode_binary_request(&bytes).expect("video frame source should decode");

        assert!(matches!(
            request.source,
            RuntimeSource::VideoFrame {
                ref locator,
                timestamp_micros,
                exact,
                ref backend,
            } if locator == "https://media.example.test/movie.mp4?token=alpha"
                && timestamp_micros == 1_234_000
                && exact
                && backend.as_deref() == Some("platform-codec")
        ));
    }

    fn binary_request_fixture() -> Vec<u8> {
        binary_request_fixture_with_source(|bytes| {
            push_u8(bytes, 0);
            push_string(bytes, "https://example.test/a.jpg");
        })
    }

    fn binary_request_fixture_with_source(write_source: impl FnOnce(&mut Vec<u8>)) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"PXR1");
        write_source(&mut bytes);
        push_u32(&mut bytes, 1);
        push_string(&mut bytes, "Accept");
        push_string(&mut bytes, "image/*");
        push_string(&mut bytes, "avatars");
        push_string(&mut bytes, "abc123");
        push_string(&mut bytes, "encoded123");
        push_u32(&mut bytes, 320);
        push_u32(&mut bytes, 180);
        push_u8(&mut bytes, 6);
        push_u8(&mut bytes, 2);
        push_u8(&mut bytes, 1);
        push_u8(&mut bytes, 1);
        push_i64(&mut bytes, 1234);
        push_u64(&mut bytes, 4096);
        push_u64(&mut bytes, 8192);
        push_u64(&mut bytes, 24);
        push_u64(&mut bytes, 3000);
        push_u64(&mut bytes, 8192);
        push_u64(&mut bytes, 2);
        push_u64(&mut bytes, 5000);
        push_u64(&mut bytes, 1000);
        push_u64(&mut bytes, 2000);
        push_u8(&mut bytes, 0);
        push_u8(&mut bytes, 1);
        push_u8(&mut bytes, 2);
        push_u64(&mut bytes, 3);
        push_u64(&mut bytes, 250);
        push_u64(&mut bytes, 50);
        push_string(&mut bytes, "Image/GIF; charset=binary");
        push_string(&mut bytes, "GIF");
        push_u32(&mut bytes, 1);
        push_string(&mut bytes, "resize(width=64)");
        bytes
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

    fn push_i64(bytes: &mut Vec<u8>, value: i64) {
        bytes.extend_from_slice(&value.to_le_bytes());
    }

    fn push_string(bytes: &mut Vec<u8>, value: &str) {
        push_u32(bytes, value.len() as u32);
        bytes.extend_from_slice(value.as_bytes());
    }
}
