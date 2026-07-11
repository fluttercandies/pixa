use crate::cache::{
    now_millis, DiskCache, DiskCacheEntry, DiskCacheHttpMetadata, DiskCacheRead, MemoryCache,
    SharedBytes,
};
use crate::cancel::{RuntimeCancelToken, RuntimeCancelWaker};
use crate::http_transport::{self, HttpCacheMetadata, HttpConditionalHeaders, HttpFetchResult};
use crate::image_format::{sniff_image_format, RuntimeImageFormat, RuntimeImageRegion};
use crate::progress::{
    emit_progress, RuntimeProgressEvent, RuntimeProgressSink, RuntimeProgressStage,
};
use crate::request::{
    CacheMode, RuntimeLimits, RuntimeRedirectPolicy, RuntimeRequest, RuntimeRetryMode,
    RuntimeRetryPolicy, RuntimeSource,
};
use crate::{
    jpeg_exif_orientation, jpeg_exif_thumbnail_from_reader, runtime_decoder_executor_for_format_id,
    runtime_decoder_executor_for_mime_type, runtime_decoder_executor_for_signature,
    runtime_decoder_for_format_id, runtime_decoder_for_mime_type,
    runtime_fetcher_executor_for_source_kind, runtime_fetcher_for_source_kind, runtime_process,
    BoundedBytesWriter, RuntimeError, RuntimePluginDecodeRequest, RuntimePluginExecutorRef,
    RuntimePluginFetchContext, RuntimePluginFetchRequest, RuntimePluginModule, RuntimePluginOutput,
    RuntimePluginProcessRequest, RuntimePluginVideoFrameSpec, RuntimeResult,
};
use image::{GenericImageView, ImageEncoder};
use sha2::{Digest, Sha256};
use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Read;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::Duration;

const DEFAULT_MEMORY_BYTES: usize = 96 * 1024 * 1024;
const MAX_DYNAMIC_IMAGE_BYTES_PER_PIXEL: usize = 16;

static MEMORY_CACHE: OnceLock<Mutex<MemoryCache>> = OnceLock::new();
static CONFIG: OnceLock<Mutex<RuntimePipelineConfig>> = OnceLock::new();
static DISK_METRICS: OnceLock<Mutex<DiskMetrics>> = OnceLock::new();
static BACKGROUND_REFRESHES: OnceLock<Mutex<BTreeSet<String>>> = OnceLock::new();
static RUNTIME_INFLIGHT_LOADS: OnceLock<Mutex<HashMap<String, Arc<RuntimeInflightLoad>>>> =
    OnceLock::new();
static RUNTIME_INFLIGHT_FETCHES: OnceLock<Mutex<HashMap<String, Arc<RuntimeInflightFetch>>>> =
    OnceLock::new();
static RUNTIME_INFLIGHT_PROCESSOR_INPUTS: OnceLock<
    Mutex<HashMap<String, Arc<RuntimeInflightProcessorInput>>>,
> = OnceLock::new();
static BACKGROUND_REFRESH_COUNT: AtomicUsize = AtomicUsize::new(0);
static STALE_REVALIDATES_STARTED: AtomicUsize = AtomicUsize::new(0);
static STALE_REVALIDATES_COMPLETED: AtomicUsize = AtomicUsize::new(0);
static STALE_REVALIDATES_FAILED: AtomicUsize = AtomicUsize::new(0);
static STALE_REVALIDATES_SKIPPED: AtomicUsize = AtomicUsize::new(0);

/// Runtime runtime pipeline configuration.
#[derive(Clone, Copy, Debug)]
pub struct RuntimePipelineConfig {
    pub memory_cache_bytes: usize,
    pub disk_cache_bytes: usize,
    pub network_concurrency: usize,
}

impl Default for RuntimePipelineConfig {
    fn default() -> Self {
        Self {
            memory_cache_bytes: DEFAULT_MEMORY_BYTES,
            disk_cache_bytes: 512 * 1024 * 1024,
            network_concurrency: 6,
        }
    }
}

/// Applies runtime configuration.
pub fn configure(config: RuntimePipelineConfig) -> RuntimeResult<()> {
    validate_pipeline_config(config)?;
    *pipeline_config()
        .lock()
        .map_err(|_| RuntimeError::new("config", true, "runtime config lock poisoned"))? = config;
    memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))?
        .set_max_bytes(config.memory_cache_bytes);
    Ok(())
}

fn validate_pipeline_config(config: RuntimePipelineConfig) -> RuntimeResult<()> {
    if config.network_concurrency == 0 {
        return Err(RuntimeError::new(
            "config",
            false,
            "network concurrency must be greater than zero",
        ));
    }
    Ok(())
}

/// Runtime load outcome.
#[derive(Clone, Debug)]
pub struct LoadOutcome {
    pub bytes: SharedBytes,
    pub cache_status: CacheStatus,
    pub source_label: String,
    cacheable: bool,
    cache_ttl_ms: Option<i64>,
    http_cache_metadata: Option<DiskCacheHttpMetadata>,
}

/// Runtime RGBA image decoded for display handoff experiments.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeRgbaImage {
    pub width: u32,
    pub height: u32,
    pub row_bytes: usize,
    pub bytes: Vec<u8>,
}

/// runtime cache stats snapshot.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RuntimeCacheStats {
    pub memory_entries: usize,
    pub memory_bytes: usize,
    pub memory_hits: u64,
    pub memory_misses: u64,
    pub disk_hits: u64,
    pub disk_misses: u64,
    pub disk_writes: u64,
    pub disk_corruption_recoveries: u64,
    pub evictions: u64,
    pub stale_revalidates_started: u64,
    pub stale_revalidates_completed: u64,
    pub stale_revalidates_failed: u64,
    pub stale_revalidates_skipped: u64,
    pub stale_revalidates_in_flight: u64,
    pub processed_memory_entries: usize,
    pub processed_memory_bytes: usize,
    pub processed_memory_hits: u64,
    pub processed_memory_misses: u64,
    pub processed_memory_evictions: u64,
    pub processed_disk_hits: u64,
    pub processed_disk_misses: u64,
    pub processed_disk_stale_hits: u64,
    pub processed_disk_writes: u64,
    pub processed_disk_corruption_recoveries: u64,
}

/// Cache status for observer/debug payloads.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CacheStatus {
    MemoryHit,
    DiskHit,
    Miss,
    Stored,
}

/// Loads encoded image bytes using the Rust pipeline.
pub fn load_image(
    root: &str,
    request: RuntimeRequest,
    inline_bytes: Option<&[u8]>,
) -> RuntimeResult<LoadOutcome> {
    load_image_with_cancel(root, request, inline_bytes, None)
}

/// Loads encoded image bytes with an optional runtime cancellation token.
pub fn load_image_with_cancel(
    root: &str,
    request: RuntimeRequest,
    inline_bytes: Option<&[u8]>,
    cancel_token: Option<RuntimeCancelToken>,
) -> RuntimeResult<LoadOutcome> {
    load_image_with_cancel_and_progress(root, request, inline_bytes, cancel_token, None)
}

/// Loads encoded image bytes with optional cancellation and progress sink.
pub fn load_image_with_cancel_and_progress(
    root: &str,
    request: RuntimeRequest,
    inline_bytes: Option<&[u8]>,
    cancel_token: Option<RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<LoadOutcome> {
    if runtime_inflight_coalescing_allowed(&request) {
        let inflight_key = runtime_inflight_key(root, &request);
        let (inflight, listener, is_leader) =
            runtime_inflight_entry(&inflight_key, cancel_token.as_ref())?;
        if !is_leader {
            emit_progress(
                progress_sink,
                RuntimeProgressEvent::new(RuntimeProgressStage::Request, "request.coalesced"),
            );
            return wait_for_runtime_inflight(inflight, listener, &request, cancel_token.as_ref());
        }

        let work_cancel = inflight.cancellation.work_token();
        let result = load_image_with_retry(
            root,
            request,
            inline_bytes,
            Some(work_cancel),
            progress_sink,
        );
        publish_runtime_inflight_result(&inflight_key, inflight, result.clone());
        ensure_not_cancelled(cancel_token.as_ref())?;
        drop(listener);
        return result;
    }

    load_image_with_retry(root, request, inline_bytes, cancel_token, progress_sink)
}

/// Decodes encoded bytes into RGBA without taking ownership of the Pixa pipeline.
pub fn decode_image_to_rgba(
    bytes: &[u8],
    max_decoded_pixels: u64,
    max_output_bytes: usize,
) -> RuntimeResult<RuntimeRgbaImage> {
    if max_decoded_pixels == 0 {
        return Err(RuntimeError::new(
            "decode",
            false,
            "max decoded pixels must be greater than zero",
        ));
    }
    if max_output_bytes == 0 {
        return Err(RuntimeError::new(
            "decode",
            false,
            "max RGBA output bytes must be greater than zero",
        ));
    }
    let format = select_runtime_image_format(bytes, "decode", "display decode input")?;
    reject_animated_display_input(bytes)?;
    let (preflight_width, preflight_height) =
        preflight_decoded_dimensions(format, bytes, "decode", max_decoded_pixels)?;
    let _ = validate_rgba_display_dimensions(
        preflight_width,
        preflight_height,
        max_decoded_pixels,
        max_output_bytes,
    )?;
    let mut image = format.decode(bytes, "decode", "display image")?;
    image = apply_exif_orientation(image, bytes)?;
    let (width, height) = image.dimensions();
    let row_bytes =
        validate_rgba_display_dimensions(width, height, max_decoded_pixels, max_output_bytes)?;
    let rgba = image.into_rgba8();
    let raw = rgba.into_raw();
    let expected_len = row_bytes
        .checked_mul(height as usize)
        .ok_or_else(|| RuntimeError::new("decode", false, "RGBA output byte length overflows"))?;
    if raw.len() != expected_len {
        return Err(RuntimeError::new(
            "decode",
            false,
            "RGBA decoder returned an unexpected byte length",
        ));
    }
    Ok(RuntimeRgbaImage {
        width,
        height,
        row_bytes,
        bytes: raw,
    })
}

/// Decodes encoded bytes and returns a normalized PNG processed variant.
pub fn decode_image_to_png_variant(
    bytes: &[u8],
    max_decoded_pixels: u64,
    max_output_bytes: usize,
) -> RuntimeResult<Vec<u8>> {
    if max_decoded_pixels == 0 {
        return Err(RuntimeError::new(
            "decode",
            false,
            "max decoded pixels must be greater than zero",
        ));
    }
    if max_output_bytes == 0 {
        return Err(RuntimeError::new(
            "decode",
            false,
            "max PNG output bytes must be greater than zero",
        ));
    }
    let format = select_runtime_image_format(bytes, "decode", "runtime decoder input")?;
    reject_animated_display_input(bytes)?;
    let _ = preflight_decoded_dimensions(format, bytes, "decode", max_decoded_pixels)?;
    let mut image = format.decode(bytes, "decode", "runtime decoder input")?;
    image = apply_exif_orientation(image, bytes)?;
    encode_png_variant(image, "decode", "runtime decoder output", max_output_bytes)
}

fn load_image_with_retry(
    root: &str,
    request: RuntimeRequest,
    inline_bytes: Option<&[u8]>,
    cancel_token: Option<RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<LoadOutcome> {
    let retry = normalized_retry(request.retry);
    let mut attempt = 1;
    loop {
        ensure_not_cancelled(cancel_token.as_ref())?;
        emit_progress(
            progress_sink,
            RuntimeProgressEvent::new(RuntimeProgressStage::Request, "request.attempt")
                .with_message(format!("{attempt}/{}", retry.max_attempts)),
        );
        match load_image_once(
            root,
            &request,
            inline_bytes,
            cancel_token.as_ref(),
            progress_sink,
        ) {
            Ok(outcome) => {
                emit_progress(
                    progress_sink,
                    RuntimeProgressEvent::new(RuntimeProgressStage::Complete, "request.complete")
                        .with_bytes(outcome.bytes.len(), Some(outcome.bytes.len())),
                );
                return Ok(outcome);
            }
            Err(error) if should_retry(&error, retry, attempt) => {
                let delay = retry_delay(retry, attempt + 1);
                emit_progress(
                    progress_sink,
                    RuntimeProgressEvent::new(RuntimeProgressStage::Request, "request.retry")
                        .with_message(format!("retrying after {} ms", delay.as_millis())),
                );
                sleep_cancelable(delay, cancel_token.as_ref())?;
                attempt += 1;
            }
            Err(error) => {
                if error.stage == "cancel" {
                    emit_progress(
                        progress_sink,
                        RuntimeProgressEvent::new(RuntimeProgressStage::Cancel, "request.cancel"),
                    );
                }
                return Err(error);
            }
        }
    }
}

fn load_image_once(
    root: &str,
    request: &RuntimeRequest,
    inline_bytes: Option<&[u8]>,
    cancel_token: Option<&RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<LoadOutcome> {
    ensure_not_cancelled(cancel_token)?;
    if !request.processors.is_empty() {
        return load_processed_image_once(root, request, inline_bytes, cancel_token, progress_sink);
    }
    load_unprocessed_image_once(root, request, inline_bytes, cancel_token, progress_sink)
}

fn load_unprocessed_image_once(
    root: &str,
    request: &RuntimeRequest,
    inline_bytes: Option<&[u8]>,
    cancel_token: Option<&RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<LoadOutcome> {
    ensure_not_cancelled(cancel_token)?;
    if let Some(outcome) = read_prepared_final_memory_cache(request, progress_sink)? {
        return Ok(outcome);
    }
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::CacheLookup, "cache.memory.lookup"),
    );
    if request.cache_mode.read_memory() {
        let memory_entry = memory_cache()
            .lock()
            .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))?
            .get_entry(&request.encoded_cache_key);
        if let Some(entry) = memory_entry {
            if !cache_entry_reusable(request, entry.http.as_ref())? {
                memory_remove(&request.encoded_cache_key)?;
            } else {
                let cache_ttl_ms = remaining_ttl_ms(entry.expires_ms);
                let bytes = entry.bytes;
                validate_cached_image_limits(bytes.as_ref(), request, "decode")?;
                let prepared = prepare_decodable_image(bytes.clone(), request, progress_sink)?;
                maybe_write_prepared_final_memory_cache(
                    request,
                    &prepared,
                    cache_ttl_ms,
                    entry.http.as_ref(),
                    progress_sink,
                )?;
                emit_progress(
                    progress_sink,
                    RuntimeProgressEvent::new(
                        RuntimeProgressStage::CacheLookup,
                        "cache.memory.hit",
                    )
                    .with_bytes(prepared.bytes.len(), Some(prepared.bytes.len())),
                );
                return Ok(LoadOutcome {
                    bytes: prepared.bytes,
                    cache_status: CacheStatus::MemoryHit,
                    source_label: "memory-cache".to_string(),
                    cacheable: true,
                    cache_ttl_ms,
                    http_cache_metadata: entry.http,
                });
            }
        }
    }

    ensure_not_cancelled(cancel_token)?;
    let disk = DiskCache::new(root);
    if let Some(outcome) = read_prepared_final_disk_cache(&disk, request, progress_sink)? {
        return Ok(outcome);
    }
    let mut stale_disk_entry: Option<DiskCacheEntry> = None;
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::CacheLookup, "cache.disk.lookup"),
    );
    if request.cache_mode.read_disk() {
        match disk.read_entry_limited(
            &request.namespace,
            &request.encoded_cache_key,
            request.limits.max_encoded_bytes,
            "decode",
            "cached encoded bytes exceed max encoded byte limit",
        )? {
            DiskCacheRead::Hit(entry) => {
                if !cache_entry_reusable(request, Some(&entry.http))? {
                    emit_progress(
                        progress_sink,
                        RuntimeProgressEvent::new(
                            RuntimeProgressStage::CacheLookup,
                            "cache.disk.varyMiss",
                        ),
                    );
                } else if entry.is_expired {
                    if request.cache_mode == CacheMode::StaleWhileRevalidate {
                        let http = entry.http.as_ref().clone();
                        let bytes = shared_bytes(entry.bytes);
                        validate_cached_image_limits(bytes.as_ref(), request, "decode")?;
                        let prepared =
                            prepare_decodable_image(bytes.clone(), request, progress_sink)?;
                        spawn_stale_revalidate(root, request);
                        record_disk_hit()?;
                        emit_progress(
                            progress_sink,
                            RuntimeProgressEvent::new(
                                RuntimeProgressStage::CacheLookup,
                                "cache.disk.staleReturned",
                            )
                            .with_bytes(prepared.bytes.len(), Some(prepared.bytes.len())),
                        );
                        return Ok(LoadOutcome {
                            bytes: prepared.bytes,
                            cache_status: CacheStatus::DiskHit,
                            source_label: "disk-cache-stale".to_string(),
                            cacheable: false,
                            cache_ttl_ms: Some(0),
                            http_cache_metadata: Some(http),
                        });
                    }
                    emit_progress(
                        progress_sink,
                        RuntimeProgressEvent::new(
                            RuntimeProgressStage::CacheLookup,
                            "cache.disk.stale",
                        )
                        .with_bytes(entry.bytes.len(), Some(entry.bytes.len())),
                    );
                    stale_disk_entry = Some(entry);
                } else {
                    let cache_ttl_ms = remaining_disk_ttl_ms(entry.expires_ms);
                    let http = entry.http.as_ref().clone();
                    let bytes = shared_bytes(entry.bytes);
                    validate_cached_image_limits(bytes.as_ref(), request, "decode")?;
                    let prepared = prepare_decodable_image(bytes.clone(), request, progress_sink)?;
                    if request.cache_mode.write_memory() {
                        memory_cache()
                            .lock()
                            .map_err(|_| {
                                RuntimeError::new(
                                    "memory_cache",
                                    true,
                                    "memory cache lock poisoned",
                                )
                            })?
                            .put_with_http_metadata(
                                &request.namespace,
                                request.encoded_cache_key.clone(),
                                bytes.clone(),
                                cache_ttl_ms,
                                Some(http.clone()),
                            );
                    }
                    maybe_write_prepared_final_cache(
                        &disk,
                        request,
                        &prepared,
                        cache_ttl_ms,
                        Some(&http),
                        progress_sink,
                    )?;
                    record_disk_hit()?;
                    emit_progress(
                        progress_sink,
                        RuntimeProgressEvent::new(
                            RuntimeProgressStage::CacheLookup,
                            "cache.disk.hit",
                        )
                        .with_bytes(prepared.bytes.len(), Some(prepared.bytes.len())),
                    );
                    return Ok(LoadOutcome {
                        bytes: prepared.bytes,
                        cache_status: CacheStatus::DiskHit,
                        source_label: "disk-cache".to_string(),
                        cacheable: true,
                        cache_ttl_ms,
                        http_cache_metadata: Some(http),
                    });
                }
            }
            DiskCacheRead::Miss => {}
            DiskCacheRead::RecoveredCorruption => {
                record_disk_corruption_recovery()?;
                emit_progress(
                    progress_sink,
                    RuntimeProgressEvent::new(
                        RuntimeProgressStage::CacheLookup,
                        "cache.disk.corruptionRecovered",
                    )
                    .with_message("corrupt disk cache entry recovered"),
                );
            }
        }
        record_disk_miss()?;
        emit_progress(
            progress_sink,
            RuntimeProgressEvent::new(RuntimeProgressStage::CacheLookup, "cache.disk.miss"),
        );
        if request.cache_mode == CacheMode::CacheOnly {
            return Err(RuntimeError::new("cache", false, "cache miss"));
        }
    }

    ensure_not_cancelled(cancel_token)?;
    let conditional = stale_disk_entry
        .as_ref()
        .and_then(|entry| conditional_headers(&request.source, &entry.http));
    let fetched = fetch_source(
        request,
        inline_bytes,
        conditional.as_ref(),
        cancel_token,
        progress_sink,
    )?;

    if fetched.not_modified {
        let stale_entry = stale_disk_entry.ok_or_else(|| {
            RuntimeError::new("cache", true, "received 304 without stale cache entry")
        })?;
        let stale_bytes = shared_bytes(stale_entry.bytes);
        validate_cached_image_limits(stale_bytes.as_ref(), request, "decode")?;
        let prepared = prepare_decodable_image(stale_bytes.clone(), request, progress_sink)?;
        let merged_metadata = merge_http_metadata(&stale_entry.http, fetched.http_cache_metadata);
        let effective_ttl_ms = effective_ttl_ms_from_disk_metadata(request, &merged_metadata);
        let allow_storage = disk_http_metadata_allows_storage(&merged_metadata);
        let allow_disk = allow_storage
            && request.cache_mode.write_disk()
            && should_store_disk_metadata_on_disk(request, Some(&merged_metadata));
        if allow_storage {
            if allow_disk {
                disk.write_with_http_metadata(
                    &request.namespace,
                    &request.encoded_cache_key,
                    stale_bytes.as_ref(),
                    effective_ttl_ms,
                    Some(&merged_metadata),
                )?;
                emit_progress(
                    progress_sink,
                    RuntimeProgressEvent::new(
                        RuntimeProgressStage::CacheWrite,
                        "cache.disk.revalidated",
                    )
                    .with_bytes(stale_bytes.len(), Some(stale_bytes.len())),
                );
            } else {
                evict_request_disk_cache_entries(&disk, request)?;
            }
            if request.cache_mode.write_memory() {
                memory_cache()
                    .lock()
                    .map_err(|_| {
                        RuntimeError::new("memory_cache", true, "memory cache lock poisoned")
                    })?
                    .put_with_http_metadata(
                        &request.namespace,
                        request.encoded_cache_key.clone(),
                        stale_bytes.clone(),
                        effective_ttl_ms,
                        Some(merged_metadata.clone()),
                    );
            }
            maybe_write_prepared_final_cache(
                &disk,
                request,
                &prepared,
                effective_ttl_ms,
                Some(&merged_metadata),
                progress_sink,
            )?;
        } else {
            evict_request_cache_entries(&disk, request)?;
        }
        record_disk_hit()?;
        emit_progress(
            progress_sink,
            RuntimeProgressEvent::new(RuntimeProgressStage::CacheLookup, "cache.disk.reuseStale")
                .with_bytes(prepared.bytes.len(), Some(prepared.bytes.len())),
        );
        return Ok(LoadOutcome {
            bytes: prepared.bytes,
            cache_status: CacheStatus::DiskHit,
            source_label: fetched.source_label,
            cacheable: allow_storage,
            cache_ttl_ms: effective_ttl_ms,
            http_cache_metadata: Some(merged_metadata),
        });
    }

    ensure_not_cancelled(cancel_token)?;
    let prepared = prepare_decodable_image(fetched.bytes.clone(), request, progress_sink)?;
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::Decode, "decode.encodedValidated")
            .with_bytes(prepared.bytes.len(), Some(prepared.bytes.len())),
    );

    let allow_storage = http_metadata_allows_storage(fetched.http_cache_metadata.as_ref());
    let allow_disk = allow_storage
        && request.cache_mode.write_disk()
        && should_store_on_disk(request, fetched.http_cache_metadata.as_ref());
    let effective_ttl_ms = effective_ttl_ms(request, fetched.http_cache_metadata.as_ref());
    let disk_metadata = fetched
        .http_cache_metadata
        .as_ref()
        .map(DiskCacheHttpMetadata::from);
    if allow_disk {
        disk.write_with_http_metadata(
            &request.namespace,
            &request.encoded_cache_key,
            fetched.bytes.as_ref(),
            effective_ttl_ms,
            disk_metadata.as_ref(),
        )?;
        let disk_cache_bytes = disk_cache_byte_budget()?;
        disk.trim_to_bytes(disk_cache_bytes)?;
        record_disk_write()?;
        emit_progress(
            progress_sink,
            RuntimeProgressEvent::new(RuntimeProgressStage::CacheWrite, "cache.disk.write")
                .with_bytes(fetched.bytes.len(), Some(fetched.bytes.len())),
        );
    }
    if allow_storage && request.cache_mode.write_memory() {
        memory_cache()
            .lock()
            .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))?
            .put_with_http_metadata(
                &request.namespace,
                request.encoded_cache_key.clone(),
                fetched.bytes.clone(),
                effective_ttl_ms,
                disk_metadata.clone(),
            );
        emit_progress(
            progress_sink,
            RuntimeProgressEvent::new(RuntimeProgressStage::CacheWrite, "cache.memory.write")
                .with_bytes(fetched.bytes.len(), Some(fetched.bytes.len())),
        );
    }
    if allow_storage {
        maybe_write_prepared_final_cache(
            &disk,
            request,
            &prepared,
            effective_ttl_ms,
            disk_metadata.as_ref(),
            progress_sink,
        )?;
    } else {
        evict_request_cache_entries(&disk, request)?;
    }

    Ok(LoadOutcome {
        bytes: prepared.bytes,
        cache_status: if allow_disk {
            CacheStatus::Stored
        } else {
            CacheStatus::Miss
        },
        source_label: fetched.source_label,
        cacheable: allow_storage,
        cache_ttl_ms: effective_ttl_ms,
        http_cache_metadata: disk_metadata,
    })
}

fn load_processed_image_once(
    root: &str,
    request: &RuntimeRequest,
    inline_bytes: Option<&[u8]>,
    cancel_token: Option<&RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<LoadOutcome> {
    let processors = parse_processor_chain(&request.processors)?;
    let disk = DiskCache::new(root);
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::CacheLookup, "cache.processed.lookup"),
    );
    if request.cache_mode.read_memory() {
        let memory_entry = memory_cache()
            .lock()
            .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))?
            .get_processed_entry(&request.cache_key);
        if let Some(entry) = memory_entry {
            if !cache_entry_reusable(request, entry.http.as_ref())? {
                memory_remove(&request.cache_key)?;
            } else {
                let cache_ttl_ms = remaining_ttl_ms(entry.expires_ms);
                let bytes = entry.bytes;
                validate_processed_cache_hit(bytes.as_ref(), request)?;
                validate_cached_image_limits(bytes.as_ref(), request, "processor")?;
                let prepared = prepare_decodable_image(bytes.clone(), request, progress_sink)?;
                emit_progress(
                    progress_sink,
                    RuntimeProgressEvent::new(
                        RuntimeProgressStage::CacheLookup,
                        "cache.processed.memory.hit",
                    )
                    .with_bytes(prepared.bytes.len(), Some(prepared.bytes.len())),
                );
                return Ok(LoadOutcome {
                    bytes: prepared.bytes,
                    cache_status: CacheStatus::MemoryHit,
                    source_label: "processed-memory-cache".to_string(),
                    cacheable: true,
                    cache_ttl_ms,
                    http_cache_metadata: entry.http,
                });
            }
        }
    }

    if request.cache_mode.read_disk() {
        match disk.read_entry_limited(
            &request.namespace,
            &request.cache_key,
            request.limits.max_processor_output_bytes,
            "processor",
            "cached processor output exceeds max processor output byte limit",
        )? {
            DiskCacheRead::Hit(entry) if !entry.is_expired => {
                if cache_entry_reusable(request, Some(&entry.http))? {
                    let cache_ttl_ms = remaining_disk_ttl_ms(entry.expires_ms);
                    let http = entry.http.as_ref().clone();
                    let bytes = shared_bytes(entry.bytes);
                    validate_processed_cache_hit(bytes.as_ref(), request)?;
                    validate_cached_image_limits(bytes.as_ref(), request, "processor")?;
                    let prepared = prepare_decodable_image(bytes.clone(), request, progress_sink)?;
                    if request.cache_mode.write_memory() {
                        memory_cache()
                            .lock()
                            .map_err(|_| {
                                RuntimeError::new(
                                    "memory_cache",
                                    true,
                                    "memory cache lock poisoned",
                                )
                            })?
                            .put_processed_with_http_metadata(
                                &request.namespace,
                                request.cache_key.clone(),
                                prepared.bytes.clone(),
                                cache_ttl_ms,
                                Some(http.clone()),
                            );
                    }
                    record_disk_hit()?;
                    record_processed_disk_hit()?;
                    emit_progress(
                        progress_sink,
                        RuntimeProgressEvent::new(
                            RuntimeProgressStage::CacheLookup,
                            "cache.processed.disk.hit",
                        )
                        .with_bytes(prepared.bytes.len(), Some(prepared.bytes.len())),
                    );
                    return Ok(LoadOutcome {
                        bytes: prepared.bytes,
                        cache_status: CacheStatus::DiskHit,
                        source_label: "processed-disk-cache".to_string(),
                        cacheable: true,
                        cache_ttl_ms,
                        http_cache_metadata: Some(http),
                    });
                }
            }
            DiskCacheRead::Hit(_) => {
                record_processed_disk_stale_hit()?;
                disk.remove(&request.namespace, &request.cache_key)?;
                emit_progress(
                    progress_sink,
                    RuntimeProgressEvent::new(
                        RuntimeProgressStage::CacheLookup,
                        "cache.processed.disk.stale",
                    ),
                );
            }
            DiskCacheRead::RecoveredCorruption => {
                record_disk_corruption_recovery()?;
                record_processed_disk_corruption_recovery()?;
                emit_progress(
                    progress_sink,
                    RuntimeProgressEvent::new(
                        RuntimeProgressStage::CacheLookup,
                        "cache.processed.disk.corruptionRecovered",
                    ),
                );
            }
            DiskCacheRead::Miss => {}
        }
        record_disk_miss()?;
        record_processed_disk_miss()?;
        if request.cache_mode == CacheMode::CacheOnly {
            return Err(RuntimeError::new("cache", false, "processed cache miss"));
        }
    }

    let mut origin_request = request.clone();
    origin_request.processors.clear();
    let origin = load_unprocessed_image_once(
        root,
        &origin_request,
        inline_bytes,
        cancel_token,
        progress_sink,
    )?;
    ensure_not_cancelled(cancel_token)?;
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::Process, "process.start")
            .with_bytes(origin.bytes.len(), Some(origin.bytes.len())),
    );
    let processed = apply_processor_chain_for_request(
        request,
        &origin.bytes,
        &processors,
        cancel_token,
        progress_sink,
    )?;
    validate_decodable_image(processed.as_ref(), request, progress_sink)?;
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::Process, "process.complete")
            .with_bytes(processed.len(), Some(processed.len())),
    );

    let allow_disk = origin.cacheable
        && request.cache_mode.write_disk()
        && should_store_disk_metadata_on_disk(request, origin.http_cache_metadata.as_ref());
    if allow_disk {
        disk.write_with_http_metadata(
            &request.namespace,
            &request.cache_key,
            processed.as_ref(),
            origin.cache_ttl_ms,
            origin.http_cache_metadata.as_ref(),
        )?;
        let disk_cache_bytes = disk_cache_byte_budget()?;
        disk.trim_to_bytes(disk_cache_bytes)?;
        record_disk_write()?;
        record_processed_disk_write()?;
        emit_progress(
            progress_sink,
            RuntimeProgressEvent::new(
                RuntimeProgressStage::CacheWrite,
                "cache.processed.disk.write",
            )
            .with_bytes(processed.len(), Some(processed.len())),
        );
    }
    if origin.cacheable && request.cache_mode.write_memory() {
        memory_cache()
            .lock()
            .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))?
            .put_processed_with_http_metadata(
                &request.namespace,
                request.cache_key.clone(),
                processed.clone(),
                origin.cache_ttl_ms,
                origin.http_cache_metadata.clone(),
            );
        emit_progress(
            progress_sink,
            RuntimeProgressEvent::new(
                RuntimeProgressStage::CacheWrite,
                "cache.processed.memory.write",
            )
            .with_bytes(processed.len(), Some(processed.len())),
        );
    }

    Ok(LoadOutcome {
        bytes: processed,
        cache_status: if allow_disk {
            CacheStatus::Stored
        } else {
            origin.cache_status
        },
        source_label: format!("processed:{}", origin.source_label),
        cacheable: origin.cacheable,
        cache_ttl_ms: origin.cache_ttl_ms,
        http_cache_metadata: origin.http_cache_metadata,
    })
}

/// Removes one encoded memory entry.
pub fn memory_remove(key: &str) -> RuntimeResult<bool> {
    memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))
        .map(|mut cache| cache.remove(key))
}

/// Pins one encoded memory entry against pressure trim while actively used.
pub fn memory_pin(key: &str) -> RuntimeResult<bool> {
    memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))
        .map(|mut cache| cache.pin(key))
}

/// Releases one active encoded memory pin.
pub fn memory_unpin(key: &str) -> RuntimeResult<bool> {
    memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))
        .map(|mut cache| cache.unpin(key))
}

/// Returns whether encoded memory contains a fresh entry.
pub fn memory_contains(key: &str) -> RuntimeResult<bool> {
    memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))
        .map(|mut cache| cache.contains(key))
}

/// Reads one processed variant from encoded memory cache.
pub fn memory_get_processed(key: &str) -> RuntimeResult<Option<SharedBytes>> {
    memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))
        .map(|mut cache| cache.get_processed(key))
}

/// Writes one processed variant into encoded memory cache.
pub fn memory_put_processed(
    namespace: &str,
    key: &str,
    bytes: &[u8],
    ttl_ms: Option<i64>,
) -> RuntimeResult<()> {
    memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))?
        .put_processed(
            namespace,
            key.to_string(),
            shared_bytes(bytes.to_vec()),
            ttl_ms,
        );
    Ok(())
}

/// Trims a disk cache root to the configured byte budget.
pub fn disk_trim_to_configured_budget(root: &str) -> RuntimeResult<()> {
    DiskCache::new(root).trim_to_bytes(disk_cache_byte_budget()?)
}

/// Clears the encoded memory cache.
pub fn memory_clear() -> RuntimeResult<()> {
    memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))?
        .clear();
    Ok(())
}

/// Clears encoded memory entries in one namespace.
pub fn memory_clear_namespace(namespace: &str) -> RuntimeResult<usize> {
    memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))
        .map(|mut cache| cache.clear_namespace(namespace))
}

/// Trims the encoded memory cache to a target byte budget.
pub fn memory_trim_to_bytes(target_bytes: usize) -> RuntimeResult<()> {
    memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))?
        .trim_to_bytes(target_bytes);
    Ok(())
}

/// Returns a runtime cache stats snapshot.
pub fn cache_stats() -> RuntimeResult<RuntimeCacheStats> {
    let memory = memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))?
        .stats();
    let disk = disk_metrics()
        .lock()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk metrics lock poisoned"))?;
    Ok(RuntimeCacheStats {
        memory_entries: memory.entries,
        memory_bytes: memory.bytes,
        memory_hits: memory.hits,
        memory_misses: memory.misses,
        disk_hits: disk.hits,
        disk_misses: disk.misses,
        disk_writes: disk.writes,
        disk_corruption_recoveries: disk.corruption_recoveries,
        evictions: memory.evictions,
        stale_revalidates_started: STALE_REVALIDATES_STARTED.load(Ordering::Relaxed) as u64,
        stale_revalidates_completed: STALE_REVALIDATES_COMPLETED.load(Ordering::Relaxed) as u64,
        stale_revalidates_failed: STALE_REVALIDATES_FAILED.load(Ordering::Relaxed) as u64,
        stale_revalidates_skipped: STALE_REVALIDATES_SKIPPED.load(Ordering::Relaxed) as u64,
        stale_revalidates_in_flight: BACKGROUND_REFRESH_COUNT.load(Ordering::Relaxed) as u64,
        processed_memory_entries: memory.processed_entries,
        processed_memory_bytes: memory.processed_bytes,
        processed_memory_hits: memory.processed_hits,
        processed_memory_misses: memory.processed_misses,
        processed_memory_evictions: memory.processed_evictions,
        processed_disk_hits: disk.processed_hits,
        processed_disk_misses: disk.processed_misses,
        processed_disk_stale_hits: disk.processed_stale_hits,
        processed_disk_writes: disk.processed_writes,
        processed_disk_corruption_recoveries: disk.processed_corruption_recoveries,
    })
}

fn memory_cache() -> &'static Mutex<MemoryCache> {
    MEMORY_CACHE.get_or_init(|| Mutex::new(MemoryCache::new(DEFAULT_MEMORY_BYTES)))
}

fn pipeline_config() -> &'static Mutex<RuntimePipelineConfig> {
    CONFIG.get_or_init(|| Mutex::new(RuntimePipelineConfig::default()))
}

fn disk_cache_byte_budget() -> RuntimeResult<usize> {
    pipeline_config()
        .lock()
        .map_err(|_| RuntimeError::new("config", true, "runtime config lock poisoned"))
        .map(|config| config.disk_cache_bytes)
}

fn disk_metrics() -> &'static Mutex<DiskMetrics> {
    DISK_METRICS.get_or_init(|| Mutex::new(DiskMetrics::default()))
}

fn background_refreshes() -> &'static Mutex<BTreeSet<String>> {
    BACKGROUND_REFRESHES.get_or_init(|| Mutex::new(BTreeSet::new()))
}

fn runtime_inflight_loads() -> &'static Mutex<HashMap<String, Arc<RuntimeInflightLoad>>> {
    RUNTIME_INFLIGHT_LOADS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn runtime_inflight_fetches() -> &'static Mutex<HashMap<String, Arc<RuntimeInflightFetch>>> {
    RUNTIME_INFLIGHT_FETCHES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn runtime_inflight_processor_inputs(
) -> &'static Mutex<HashMap<String, Arc<RuntimeInflightProcessorInput>>> {
    RUNTIME_INFLIGHT_PROCESSOR_INPUTS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[derive(Debug)]
struct RuntimeInflightLoad {
    state: Mutex<Option<RuntimeResult<LoadOutcome>>>,
    ready: Condvar,
    cancellation: Arc<RuntimeInflightCancellation>,
}

impl RuntimeInflightLoad {
    fn new() -> Self {
        Self {
            state: Mutex::new(None),
            ready: Condvar::new(),
            cancellation: Arc::new(RuntimeInflightCancellation::new()),
        }
    }
}

impl RuntimeCancelWaker for RuntimeInflightLoad {
    fn wake_cancelled(&self) {
        if let Ok(_state) = self.state.lock() {
            self.ready.notify_all();
        } else {
            self.ready.notify_all();
        }
    }
}

#[derive(Debug)]
struct RuntimeInflightFetch {
    state: Mutex<Option<RuntimeResult<FetchOutcome>>>,
    ready: Condvar,
    cancellation: Arc<RuntimeInflightCancellation>,
}

impl RuntimeInflightFetch {
    fn new() -> Self {
        Self {
            state: Mutex::new(None),
            ready: Condvar::new(),
            cancellation: Arc::new(RuntimeInflightCancellation::new()),
        }
    }
}

impl RuntimeCancelWaker for RuntimeInflightFetch {
    fn wake_cancelled(&self) {
        if let Ok(_state) = self.state.lock() {
            self.ready.notify_all();
        } else {
            self.ready.notify_all();
        }
    }
}

#[derive(Debug)]
struct RuntimeInflightCancellation {
    listeners: AtomicUsize,
    work_cancel: RuntimeCancelToken,
}

impl RuntimeInflightCancellation {
    fn new() -> Self {
        Self {
            listeners: AtomicUsize::new(0),
            work_cancel: RuntimeCancelToken::new(),
        }
    }

    fn subscribe(
        self: &Arc<Self>,
        cancel_token: Option<&RuntimeCancelToken>,
    ) -> Arc<RuntimeInflightListener> {
        self.listeners.fetch_add(1, Ordering::AcqRel);
        let listener = Arc::new(RuntimeInflightListener {
            cancellation: self.clone(),
            released: AtomicBool::new(false),
        });
        if let Some(token) = cancel_token {
            token.register_waker(&listener);
        }
        listener
    }

    fn work_token(&self) -> RuntimeCancelToken {
        self.work_cancel.clone()
    }

    fn release_listener(&self) {
        if self.listeners.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.work_cancel.cancel();
        }
    }
}

#[derive(Debug)]
struct RuntimeInflightListener {
    cancellation: Arc<RuntimeInflightCancellation>,
    released: AtomicBool,
}

impl RuntimeInflightListener {
    fn release(&self) {
        if !self.released.swap(true, Ordering::AcqRel) {
            self.cancellation.release_listener();
        }
    }
}

impl RuntimeCancelWaker for RuntimeInflightListener {
    fn wake_cancelled(&self) {
        self.release();
    }
}

impl Drop for RuntimeInflightListener {
    fn drop(&mut self) {
        self.release();
    }
}

#[derive(Debug)]
struct RuntimeInflightProcessorInput {
    state: Mutex<Option<RuntimeResult<Arc<DecodedProcessorInput>>>>,
    ready: Condvar,
}

impl RuntimeInflightProcessorInput {
    fn new() -> Self {
        Self {
            state: Mutex::new(None),
            ready: Condvar::new(),
        }
    }
}

impl RuntimeCancelWaker for RuntimeInflightProcessorInput {
    fn wake_cancelled(&self) {
        if let Ok(_state) = self.state.lock() {
            self.ready.notify_all();
        } else {
            self.ready.notify_all();
        }
    }
}

fn runtime_inflight_entry(
    key: &str,
    cancel_token: Option<&RuntimeCancelToken>,
) -> RuntimeResult<(Arc<RuntimeInflightLoad>, Arc<RuntimeInflightListener>, bool)> {
    let mut loads = runtime_inflight_loads()
        .lock()
        .map_err(|_| RuntimeError::new("scheduler", true, "runtime inflight lock poisoned"))?;
    if let Some(inflight) = loads
        .get(key)
        .filter(|inflight| !inflight.cancellation.work_cancel.is_cancelled())
    {
        let listener = inflight.cancellation.subscribe(cancel_token);
        return Ok((inflight.clone(), listener, false));
    }
    let inflight = Arc::new(RuntimeInflightLoad::new());
    let listener = inflight.cancellation.subscribe(cancel_token);
    loads.insert(key.to_string(), inflight.clone());
    Ok((inflight, listener, true))
}

fn wait_for_runtime_inflight(
    inflight: Arc<RuntimeInflightLoad>,
    _listener: Arc<RuntimeInflightListener>,
    request: &RuntimeRequest,
    cancel_token: Option<&RuntimeCancelToken>,
) -> RuntimeResult<LoadOutcome> {
    if let Some(token) = cancel_token {
        token.register_waker(&inflight);
    }
    let mut state = inflight
        .state
        .lock()
        .map_err(|_| RuntimeError::new("scheduler", true, "runtime inflight state poisoned"))?;
    loop {
        if let Some(result) = state.clone() {
            let outcome = result?;
            validate_decodable_image(&outcome.bytes, request, None)?;
            return Ok(outcome);
        }
        ensure_not_cancelled(cancel_token)?;
        state = inflight
            .ready
            .wait(state)
            .map_err(|_| RuntimeError::new("scheduler", true, "runtime inflight wait poisoned"))?;
    }
}

fn publish_runtime_inflight_result(
    key: &str,
    inflight: Arc<RuntimeInflightLoad>,
    result: RuntimeResult<LoadOutcome>,
) {
    if let Ok(mut state) = inflight.state.lock() {
        *state = Some(result);
        inflight.ready.notify_all();
    }
    if let Ok(mut loads) = runtime_inflight_loads().lock() {
        if loads
            .get(key)
            .is_some_and(|current| Arc::ptr_eq(current, &inflight))
        {
            loads.remove(key);
        }
    }
}

fn runtime_inflight_fetch_entry(
    key: &str,
    cancel_token: Option<&RuntimeCancelToken>,
) -> RuntimeResult<(
    Arc<RuntimeInflightFetch>,
    Arc<RuntimeInflightListener>,
    bool,
)> {
    let mut fetches = runtime_inflight_fetches().lock().map_err(|_| {
        RuntimeError::new("scheduler", true, "runtime fetch inflight lock poisoned")
    })?;
    if let Some(inflight) = fetches
        .get(key)
        .filter(|inflight| !inflight.cancellation.work_cancel.is_cancelled())
    {
        let listener = inflight.cancellation.subscribe(cancel_token);
        return Ok((inflight.clone(), listener, false));
    }
    let inflight = Arc::new(RuntimeInflightFetch::new());
    let listener = inflight.cancellation.subscribe(cancel_token);
    fetches.insert(key.to_string(), inflight.clone());
    Ok((inflight, listener, true))
}

fn wait_for_runtime_inflight_fetch(
    inflight: Arc<RuntimeInflightFetch>,
    _listener: Arc<RuntimeInflightListener>,
    request: &RuntimeRequest,
    cancel_token: Option<&RuntimeCancelToken>,
) -> RuntimeResult<FetchOutcome> {
    if let Some(token) = cancel_token {
        token.register_waker(&inflight);
    }
    let mut state = inflight.state.lock().map_err(|_| {
        RuntimeError::new("scheduler", true, "runtime fetch inflight state poisoned")
    })?;
    loop {
        if let Some(result) = state.clone() {
            let outcome = result?;
            validate_fetch_outcome_for_request(&outcome, request)?;
            return Ok(outcome);
        }
        ensure_not_cancelled(cancel_token)?;
        state = inflight.ready.wait(state).map_err(|_| {
            RuntimeError::new("scheduler", true, "runtime fetch inflight wait poisoned")
        })?;
    }
}

fn publish_runtime_inflight_fetch_result(
    key: &str,
    inflight: Arc<RuntimeInflightFetch>,
    result: RuntimeResult<FetchOutcome>,
) {
    if let Ok(mut state) = inflight.state.lock() {
        *state = Some(result);
        inflight.ready.notify_all();
    }
    if let Ok(mut fetches) = runtime_inflight_fetches().lock() {
        if fetches
            .get(key)
            .is_some_and(|current| Arc::ptr_eq(current, &inflight))
        {
            fetches.remove(key);
        }
    }
}

fn runtime_inflight_processor_input_entry(
    key: &str,
) -> RuntimeResult<(Arc<RuntimeInflightProcessorInput>, bool)> {
    let mut inputs = runtime_inflight_processor_inputs()
        .lock()
        .map_err(|_| RuntimeError::new("scheduler", true, "processor input lock poisoned"))?;
    if let Some(inflight) = inputs.get(key) {
        return Ok((inflight.clone(), false));
    }
    let inflight = Arc::new(RuntimeInflightProcessorInput::new());
    inputs.insert(key.to_string(), inflight.clone());
    Ok((inflight, true))
}

fn wait_for_runtime_inflight_processor_input(
    inflight: Arc<RuntimeInflightProcessorInput>,
    cancel_token: Option<&RuntimeCancelToken>,
) -> RuntimeResult<Arc<DecodedProcessorInput>> {
    if let Some(token) = cancel_token {
        token.register_waker(&inflight);
    }
    let mut state = inflight
        .state
        .lock()
        .map_err(|_| RuntimeError::new("scheduler", true, "processor input state poisoned"))?;
    loop {
        if let Some(result) = state.clone() {
            return result;
        }
        ensure_not_cancelled(cancel_token)?;
        state = inflight
            .ready
            .wait(state)
            .map_err(|_| RuntimeError::new("scheduler", true, "processor input wait poisoned"))?;
    }
}

fn publish_runtime_inflight_processor_input_result(
    key: &str,
    inflight: Arc<RuntimeInflightProcessorInput>,
    result: RuntimeResult<Arc<DecodedProcessorInput>>,
) {
    if let Ok(mut state) = inflight.state.lock() {
        *state = Some(result);
        inflight.ready.notify_all();
    }
    if let Ok(mut inputs) = runtime_inflight_processor_inputs().lock() {
        if inputs
            .get(key)
            .is_some_and(|current| Arc::ptr_eq(current, &inflight))
        {
            inputs.remove(key);
        }
    }
}

fn runtime_inflight_key(root: &str, request: &RuntimeRequest) -> String {
    let mut identity = CanonicalIdentity::new("pixa.runtime.inflight.load.v2");
    identity.text(1, root);
    identity.text(2, &request.namespace);
    identity.text(3, &request.cache_key);
    identity.text(4, &request.encoded_cache_key);
    identity.text(5, &source_identity(&request.source));
    identity.text(6, &runtime_headers_identity(request));
    identity.usize(7, request.processors.len());
    for processor in &request.processors {
        identity.text(8, processor);
    }
    identity.optional_i64(9, 10, request.ttl_ms);
    identity.boolean(11, request.private_cache);
    identity.byte(12, runtime_cache_mode_identity(request.cache_mode));
    append_runtime_limits(&mut identity, 20, &request.limits);
    append_runtime_retry(&mut identity, 40, request.retry);
    append_runtime_redirect(&mut identity, 50, request.redirect_policy);
    identity.finish()
}

fn runtime_inflight_fetch_key(
    request: &RuntimeRequest,
    conditional: Option<&HttpConditionalHeaders>,
    inline_bytes: Option<&[u8]>,
) -> String {
    let mut identity = CanonicalIdentity::new("pixa.runtime.inflight.fetch.v2");
    identity.text(1, &request.namespace);
    identity.text(2, &request.encoded_cache_key);
    identity.text(3, &source_identity(&request.source));
    identity.text(4, &runtime_headers_identity(request));
    identity.text(5, &runtime_conditional_identity(conditional));
    identity.usize(6, request.limits.max_encoded_bytes);
    identity.usize(7, request.limits.max_redirects);
    identity.u64(8, request.limits.timeout_ms);
    identity.u64(9, request.limits.connect_timeout_ms);
    identity.u64(10, request.limits.idle_timeout_ms);
    append_runtime_redirect(&mut identity, 20, request.redirect_policy);
    identity.text(30, &runtime_inline_bytes_identity(inline_bytes));
    identity.finish()
}

fn runtime_processor_input_key(request: &RuntimeRequest, bytes: &SharedBytes) -> String {
    let mut identity = CanonicalIdentity::new("pixa.runtime.inflight.processor-input.v2");
    identity.text(1, &request.namespace);
    identity.text(2, &request.encoded_cache_key);
    identity.text(3, &source_identity(&request.source));
    identity.bytes(4, bytes.as_ref());
    append_runtime_limits(&mut identity, 20, &request.limits);
    identity.finish()
}

fn runtime_inflight_coalescing_allowed(request: &RuntimeRequest) -> bool {
    matches!(
        request.cache_mode,
        CacheMode::MemoryOnly
            | CacheMode::DiskOnly
            | CacheMode::MemoryAndDisk
            | CacheMode::StaleWhileRevalidate
    )
}

fn runtime_fetch_coalescing_allowed(request: &RuntimeRequest) -> bool {
    !matches!(request.cache_mode, CacheMode::CacheOnly)
}

fn runtime_cache_mode_identity(mode: CacheMode) -> u8 {
    match mode {
        CacheMode::NoStore => 0,
        CacheMode::MemoryOnly => 1,
        CacheMode::DiskOnly => 2,
        CacheMode::MemoryAndDisk => 3,
        CacheMode::CacheOnly => 4,
        CacheMode::NetworkOnly => 5,
        CacheMode::Refresh => 6,
        CacheMode::StaleWhileRevalidate => 7,
    }
}

fn runtime_retry_mode_identity(mode: RuntimeRetryMode) -> u8 {
    match mode {
        RuntimeRetryMode::None => 0,
        RuntimeRetryMode::Fixed => 1,
        RuntimeRetryMode::Exponential => 2,
    }
}

#[cfg(test)]
fn runtime_limits_identity(limits: &RuntimeLimits) -> String {
    let mut identity = CanonicalIdentity::new("pixa.runtime.limits.v2");
    append_runtime_limits(&mut identity, 1, limits);
    identity.finish()
}

fn source_identity(source: &RuntimeSource) -> String {
    let mut identity = CanonicalIdentity::new("pixa.runtime.source.v2");
    match source {
        RuntimeSource::Network { uri } => {
            identity.byte(1, 1);
            identity.text(2, &identity_digest(uri));
        }
        RuntimeSource::File { path } => {
            identity.byte(1, 2);
            identity.text(2, &identity_digest(path));
        }
        RuntimeSource::Bytes { id } => {
            identity.byte(1, 3);
            identity.text(2, &identity_digest(id));
        }
        RuntimeSource::AssetBytes { id } => {
            identity.byte(1, 4);
            identity.text(2, &identity_digest(id));
        }
        RuntimeSource::ExifThumbnail { path } => {
            identity.byte(1, 5);
            identity.text(2, &identity_digest(path));
        }
        RuntimeSource::RuntimePlugin {
            source_kind,
            locator,
        } => {
            identity.byte(1, 6);
            identity.text(2, &source_kind.trim().to_ascii_lowercase());
            identity.text(3, &identity_digest(locator));
        }
        RuntimeSource::VideoFrame {
            locator,
            timestamp_micros,
            exact,
            backend,
        } => {
            identity.byte(1, 7);
            identity.text(2, &identity_digest(locator));
            identity.i64(3, *timestamp_micros);
            identity.boolean(4, *exact);
            identity.optional_text(5, 6, backend.as_deref());
        }
    }
    identity.finish()
}

fn identity_digest(value: &str) -> String {
    let mut identity = CanonicalIdentity::new("pixa.runtime.value.v2");
    identity.text(1, value);
    identity.finish()
}

fn runtime_headers_identity(request: &RuntimeRequest) -> String {
    let mut normalized = BTreeMap::<String, &str>::new();
    for (name, value) in &request.headers {
        normalized.insert(name.to_ascii_lowercase(), value);
    }
    let mut identity = CanonicalIdentity::new("pixa.runtime.headers.v2");
    identity.usize(1, normalized.len());
    for (name, value) in normalized {
        identity.text(2, &name);
        identity.text(3, value);
    }
    identity.finish()
}

fn runtime_conditional_identity(conditional: Option<&HttpConditionalHeaders>) -> String {
    let mut identity = CanonicalIdentity::new("pixa.runtime.conditional.v2");
    identity.boolean(1, conditional.is_some());
    if let Some(conditional) = conditional {
        identity.optional_text(2, 3, conditional.etag.as_deref());
        identity.optional_text(4, 5, conditional.last_modified.as_deref());
    }
    identity.finish()
}

fn runtime_inline_bytes_identity(inline_bytes: Option<&[u8]>) -> String {
    let mut identity = CanonicalIdentity::new("pixa.runtime.inline-bytes.v2");
    identity.boolean(1, inline_bytes.is_some());
    if let Some(bytes) = inline_bytes {
        identity.bytes(2, bytes);
    }
    identity.finish()
}

fn append_runtime_limits(identity: &mut CanonicalIdentity, base: u8, limits: &RuntimeLimits) {
    identity.usize(base, limits.max_encoded_bytes);
    identity.u64(base + 1, limits.max_decoded_pixels);
    identity.usize(base + 2, limits.max_animation_frames);
    identity.u64(base + 3, limits.max_animation_duration_ms);
    identity.usize(base + 4, limits.max_processor_output_bytes);
    identity.usize(base + 5, limits.max_redirects);
    identity.u64(base + 6, limits.timeout_ms);
    identity.u64(base + 7, limits.connect_timeout_ms);
    identity.u64(base + 8, limits.idle_timeout_ms);
}

fn append_runtime_retry(identity: &mut CanonicalIdentity, base: u8, retry: RuntimeRetryPolicy) {
    identity.byte(base, runtime_retry_mode_identity(retry.mode));
    identity.usize(base + 1, retry.max_attempts);
    identity.u64(base + 2, retry.delay_ms);
    identity.u64(base + 3, retry.jitter_ms);
}

fn append_runtime_redirect(
    identity: &mut CanonicalIdentity,
    base: u8,
    policy: RuntimeRedirectPolicy,
) {
    identity.boolean(base, policy.allow_cross_host_redirects);
    identity.boolean(base + 1, policy.allow_https_to_http);
}

struct CanonicalIdentity {
    hasher: Sha256,
}

impl CanonicalIdentity {
    fn new(domain: &str) -> Self {
        let mut identity = Self {
            hasher: Sha256::new(),
        };
        identity.text(0, domain);
        identity
    }

    fn bytes(&mut self, tag: u8, value: &[u8]) {
        self.hasher.update([tag]);
        self.hasher
            .update(u64::try_from(value.len()).unwrap_or(u64::MAX).to_be_bytes());
        self.hasher.update(value);
    }

    fn text(&mut self, tag: u8, value: &str) {
        self.bytes(tag, value.as_bytes());
    }

    fn byte(&mut self, tag: u8, value: u8) {
        self.bytes(tag, &[value]);
    }

    fn boolean(&mut self, tag: u8, value: bool) {
        self.byte(tag, u8::from(value));
    }

    fn usize(&mut self, tag: u8, value: usize) {
        self.u64(tag, u64::try_from(value).unwrap_or(u64::MAX));
    }

    fn u64(&mut self, tag: u8, value: u64) {
        self.bytes(tag, &value.to_be_bytes());
    }

    fn i64(&mut self, tag: u8, value: i64) {
        self.bytes(tag, &value.to_be_bytes());
    }

    fn optional_i64(&mut self, presence_tag: u8, value_tag: u8, value: Option<i64>) {
        self.boolean(presence_tag, value.is_some());
        if let Some(value) = value {
            self.i64(value_tag, value);
        }
    }

    fn optional_text(&mut self, presence_tag: u8, value_tag: u8, value: Option<&str>) {
        self.boolean(presence_tag, value.is_some());
        if let Some(value) = value {
            self.text(value_tag, value);
        }
    }

    fn finish(self) -> String {
        let digest = self.hasher.finalize();
        format!("sha256:{}", hex_lower(&digest))
    }
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

fn spawn_stale_revalidate(root: &str, request: &RuntimeRequest) {
    if !matches!(request.source, RuntimeSource::Network { .. }) {
        STALE_REVALIDATES_SKIPPED.fetch_add(1, Ordering::Relaxed);
        return;
    }

    let network_concurrency = pipeline_config()
        .lock()
        .map(|config| config.network_concurrency)
        .unwrap_or(1);
    let available_parallelism = std::thread::available_parallelism()
        .map(|parallelism| parallelism.get())
        .unwrap_or(1);
    let max_refreshes = background_refresh_slot_limit(network_concurrency, available_parallelism);
    if !try_reserve_background_refresh_slot(&BACKGROUND_REFRESH_COUNT, max_refreshes) {
        STALE_REVALIDATES_SKIPPED.fetch_add(1, Ordering::Relaxed);
        return;
    }

    let refresh_key = format!("{}:{}", request.namespace, request.encoded_cache_key);
    let Ok(mut refreshes) = background_refreshes().lock() else {
        release_background_refresh_slot(&BACKGROUND_REFRESH_COUNT);
        return;
    };
    if !refreshes.insert(refresh_key.clone()) {
        release_background_refresh_slot(&BACKGROUND_REFRESH_COUNT);
        STALE_REVALIDATES_SKIPPED.fetch_add(1, Ordering::Relaxed);
        return;
    }
    STALE_REVALIDATES_STARTED.fetch_add(1, Ordering::Relaxed);
    drop(refreshes);

    let root = root.to_string();
    let mut refresh_request = request.clone();
    refresh_request.cache_mode = CacheMode::Refresh;
    let spawn_result = std::thread::Builder::new()
        .name("pixa-swr".to_string())
        .spawn(move || {
            match load_image_once(&root, &refresh_request, None, None, None) {
                Ok(_) => {
                    STALE_REVALIDATES_COMPLETED.fetch_add(1, Ordering::Relaxed);
                }
                Err(_) => {
                    STALE_REVALIDATES_FAILED.fetch_add(1, Ordering::Relaxed);
                }
            }
            finish_stale_revalidate(&refresh_key);
        });
    if spawn_result.is_err() {
        STALE_REVALIDATES_FAILED.fetch_add(1, Ordering::Relaxed);
        finish_stale_revalidate(&format!(
            "{}:{}",
            request.namespace, request.encoded_cache_key
        ));
    }
}

fn finish_stale_revalidate(refresh_key: &str) {
    if let Ok(mut refreshes) = background_refreshes().lock() {
        refreshes.remove(refresh_key);
    }
    release_background_refresh_slot(&BACKGROUND_REFRESH_COUNT);
}

fn background_refresh_slot_limit(
    network_concurrency: usize,
    available_parallelism: usize,
) -> usize {
    let thread_budget = available_parallelism.max(1).saturating_mul(2);
    network_concurrency.max(1).min(thread_budget)
}

fn try_reserve_background_refresh_slot(counter: &AtomicUsize, max_slots: usize) -> bool {
    counter
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |current| {
            (current < max_slots).then_some(current + 1)
        })
        .is_ok()
}

fn release_background_refresh_slot(counter: &AtomicUsize) {
    counter
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
            Some(value.saturating_sub(1))
        })
        .ok();
}

fn record_disk_hit() -> RuntimeResult<()> {
    disk_metrics()
        .lock()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk metrics lock poisoned"))?
        .hits += 1;
    Ok(())
}

fn record_disk_miss() -> RuntimeResult<()> {
    disk_metrics()
        .lock()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk metrics lock poisoned"))?
        .misses += 1;
    Ok(())
}

fn record_disk_write() -> RuntimeResult<()> {
    disk_metrics()
        .lock()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk metrics lock poisoned"))?
        .writes += 1;
    Ok(())
}

fn record_disk_corruption_recovery() -> RuntimeResult<()> {
    disk_metrics()
        .lock()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk metrics lock poisoned"))?
        .corruption_recoveries += 1;
    Ok(())
}

fn record_processed_disk_hit() -> RuntimeResult<()> {
    disk_metrics()
        .lock()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk metrics lock poisoned"))?
        .processed_hits += 1;
    Ok(())
}

fn record_processed_disk_miss() -> RuntimeResult<()> {
    disk_metrics()
        .lock()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk metrics lock poisoned"))?
        .processed_misses += 1;
    Ok(())
}

fn record_processed_disk_stale_hit() -> RuntimeResult<()> {
    disk_metrics()
        .lock()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk metrics lock poisoned"))?
        .processed_stale_hits += 1;
    Ok(())
}

fn record_processed_disk_write() -> RuntimeResult<()> {
    disk_metrics()
        .lock()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk metrics lock poisoned"))?
        .processed_writes += 1;
    Ok(())
}

fn record_processed_disk_corruption_recovery() -> RuntimeResult<()> {
    disk_metrics()
        .lock()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk metrics lock poisoned"))?
        .processed_corruption_recoveries += 1;
    Ok(())
}

fn normalized_retry(mut retry: RuntimeRetryPolicy) -> RuntimeRetryPolicy {
    retry.max_attempts = retry.max_attempts.clamp(1, 16);
    retry
}

fn should_retry(error: &RuntimeError, retry: RuntimeRetryPolicy, attempt: usize) -> bool {
    retry.mode != RuntimeRetryMode::None && error.retryable && attempt < retry.max_attempts
}

fn retry_delay(retry: RuntimeRetryPolicy, next_attempt: usize) -> Duration {
    if retry.mode == RuntimeRetryMode::None || next_attempt <= 1 {
        return Duration::ZERO;
    }
    let multiplier = match retry.mode {
        RuntimeRetryMode::None | RuntimeRetryMode::Fixed => 1,
        RuntimeRetryMode::Exponential => {
            let exponent = next_attempt.saturating_sub(2).min(20);
            1_u64 << exponent
        }
    };
    let base = retry.delay_ms.saturating_mul(multiplier);
    Duration::from_millis(base.saturating_add(jitter_ms(retry.jitter_ms)))
}

fn jitter_ms(max_jitter_ms: u64) -> u64 {
    if max_jitter_ms == 0 {
        return 0;
    }
    (now_millis().unsigned_abs()) % (max_jitter_ms + 1)
}

fn sleep_cancelable(
    delay: Duration,
    cancel_token: Option<&RuntimeCancelToken>,
) -> RuntimeResult<()> {
    let mut remaining = delay;
    while remaining > Duration::ZERO {
        ensure_not_cancelled(cancel_token)?;
        let chunk = remaining.min(Duration::from_millis(25));
        std::thread::sleep(chunk);
        remaining = remaining.saturating_sub(chunk);
    }
    ensure_not_cancelled(cancel_token)
}

#[derive(Default)]
struct DiskMetrics {
    hits: u64,
    misses: u64,
    writes: u64,
    corruption_recoveries: u64,
    processed_hits: u64,
    processed_misses: u64,
    processed_stale_hits: u64,
    processed_writes: u64,
    processed_corruption_recoveries: u64,
}

fn shared_bytes(bytes: Vec<u8>) -> SharedBytes {
    Arc::<[u8]>::from(bytes.into_boxed_slice())
}

fn remaining_ttl_ms(expires_ms: Option<i64>) -> Option<i64> {
    expires_ms.map(|expires| expires.saturating_sub(now_millis()).max(0))
}

fn remaining_disk_ttl_ms(expires_ms: i64) -> Option<i64> {
    (expires_ms >= 0).then(|| expires_ms.saturating_sub(now_millis()).max(0))
}

fn read_prepared_final_memory_cache(
    request: &RuntimeRequest,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<Option<LoadOutcome>> {
    if !has_distinct_final_cache_key(request) || !request.cache_mode.read_memory() {
        return Ok(None);
    }
    let Some(entry) = memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))?
        .get_processed_entry(&request.cache_key)
    else {
        return Ok(None);
    };
    if !cache_entry_reusable(request, entry.http.as_ref())? {
        memory_remove(&request.cache_key)?;
        return Ok(None);
    }
    let cache_ttl_ms = remaining_ttl_ms(entry.expires_ms);
    let bytes = entry.bytes;
    validate_processed_cache_hit(bytes.as_ref(), request)?;
    validate_cached_image_limits(bytes.as_ref(), request, "decode")?;
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(
            RuntimeProgressStage::CacheLookup,
            "cache.decoder.memory.hit",
        )
        .with_bytes(bytes.len(), Some(bytes.len())),
    );
    Ok(Some(LoadOutcome {
        bytes,
        cache_status: CacheStatus::MemoryHit,
        source_label: "decoder-memory-cache".to_string(),
        cacheable: true,
        cache_ttl_ms,
        http_cache_metadata: entry.http,
    }))
}

fn read_prepared_final_disk_cache(
    disk: &DiskCache,
    request: &RuntimeRequest,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<Option<LoadOutcome>> {
    if !has_distinct_final_cache_key(request) || !request.cache_mode.read_disk() {
        return Ok(None);
    }
    match disk.read_entry_limited(
        &request.namespace,
        &request.cache_key,
        request.limits.max_processor_output_bytes,
        "decode",
        "cached decoder output exceeds max processor output byte limit",
    )? {
        DiskCacheRead::Hit(entry) if !entry.is_expired => {
            if !cache_entry_reusable(request, Some(&entry.http))? {
                return Ok(None);
            }
            let cache_ttl_ms = remaining_disk_ttl_ms(entry.expires_ms);
            let http = entry.http.as_ref().clone();
            let bytes = shared_bytes(entry.bytes);
            validate_processed_cache_hit(bytes.as_ref(), request)?;
            validate_cached_image_limits(bytes.as_ref(), request, "decode")?;
            if request.cache_mode.write_memory() {
                memory_cache()
                    .lock()
                    .map_err(|_| {
                        RuntimeError::new("memory_cache", true, "memory cache lock poisoned")
                    })?
                    .put_processed_with_http_metadata(
                        &request.namespace,
                        request.cache_key.clone(),
                        bytes.clone(),
                        cache_ttl_ms,
                        Some(http.clone()),
                    );
            }
            record_disk_hit()?;
            record_processed_disk_hit()?;
            emit_progress(
                progress_sink,
                RuntimeProgressEvent::new(
                    RuntimeProgressStage::CacheLookup,
                    "cache.decoder.disk.hit",
                )
                .with_bytes(bytes.len(), Some(bytes.len())),
            );
            Ok(Some(LoadOutcome {
                bytes,
                cache_status: CacheStatus::DiskHit,
                source_label: "decoder-disk-cache".to_string(),
                cacheable: true,
                cache_ttl_ms,
                http_cache_metadata: Some(http),
            }))
        }
        DiskCacheRead::Hit(_) => {
            record_processed_disk_stale_hit()?;
            disk.remove(&request.namespace, &request.cache_key)?;
            emit_progress(
                progress_sink,
                RuntimeProgressEvent::new(
                    RuntimeProgressStage::CacheLookup,
                    "cache.decoder.disk.stale",
                ),
            );
            Ok(None)
        }
        DiskCacheRead::RecoveredCorruption => {
            record_disk_corruption_recovery()?;
            record_processed_disk_corruption_recovery()?;
            emit_progress(
                progress_sink,
                RuntimeProgressEvent::new(
                    RuntimeProgressStage::CacheLookup,
                    "cache.decoder.disk.corruptionRecovered",
                ),
            );
            Ok(None)
        }
        DiskCacheRead::Miss => {
            record_processed_disk_miss()?;
            Ok(None)
        }
    }
}

fn maybe_write_prepared_final_cache(
    disk: &DiskCache,
    request: &RuntimeRequest,
    prepared: &PreparedImage,
    ttl_ms: Option<i64>,
    http: Option<&DiskCacheHttpMetadata>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<()> {
    maybe_write_prepared_final_memory_cache(request, prepared, ttl_ms, http, progress_sink)?;
    if !prepared.transformed
        || !has_distinct_final_cache_key(request)
        || !request.cache_mode.write_disk()
        || !should_store_disk_metadata_on_disk(request, http)
    {
        return Ok(());
    }
    disk.write_with_http_metadata(
        &request.namespace,
        &request.cache_key,
        prepared.bytes.as_ref(),
        ttl_ms,
        http,
    )?;
    let disk_cache_bytes = disk_cache_byte_budget()?;
    disk.trim_to_bytes(disk_cache_bytes)?;
    record_disk_write()?;
    record_processed_disk_write()?;
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::CacheWrite, "cache.decoder.disk.write")
            .with_bytes(prepared.bytes.len(), Some(prepared.bytes.len())),
    );
    Ok(())
}

fn maybe_write_prepared_final_memory_cache(
    request: &RuntimeRequest,
    prepared: &PreparedImage,
    ttl_ms: Option<i64>,
    http: Option<&DiskCacheHttpMetadata>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<()> {
    if !prepared.transformed
        || !has_distinct_final_cache_key(request)
        || !request.cache_mode.write_memory()
    {
        return Ok(());
    }
    memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))?
        .put_processed_with_http_metadata(
            &request.namespace,
            request.cache_key.clone(),
            prepared.bytes.clone(),
            ttl_ms,
            http.cloned(),
        );
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(
            RuntimeProgressStage::CacheWrite,
            "cache.decoder.memory.write",
        )
        .with_bytes(prepared.bytes.len(), Some(prepared.bytes.len())),
    );
    Ok(())
}

fn has_distinct_final_cache_key(request: &RuntimeRequest) -> bool {
    request.cache_key != request.encoded_cache_key
}

#[derive(Clone, Debug)]
struct FetchOutcome {
    bytes: SharedBytes,
    source_label: String,
    http_cache_metadata: Option<HttpCacheMetadata>,
    not_modified: bool,
}

#[derive(Clone, Debug)]
struct PreparedImage {
    bytes: SharedBytes,
    transformed: bool,
}

impl From<&HttpCacheMetadata> for DiskCacheHttpMetadata {
    fn from(metadata: &HttpCacheMetadata) -> Self {
        Self {
            etag: metadata.etag.clone(),
            last_modified: metadata.last_modified.clone(),
            cache_control: metadata.cache_control.clone(),
            date: metadata.date.clone(),
            expires: metadata.expires.clone(),
            age: metadata.age.clone(),
            vary: metadata.vary.clone(),
            vary_request_key: metadata.vary_request_key.clone(),
            fetched_at_ms: Some(metadata.fetched_at_ms),
        }
    }
}

fn fetch_source(
    request: &RuntimeRequest,
    inline_bytes: Option<&[u8]>,
    conditional: Option<&HttpConditionalHeaders>,
    cancel_token: Option<&RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<FetchOutcome> {
    if runtime_fetch_coalescing_allowed(request) {
        let inflight_key = runtime_inflight_fetch_key(request, conditional, inline_bytes);
        let (inflight, listener, is_leader) =
            runtime_inflight_fetch_entry(&inflight_key, cancel_token)?;
        if !is_leader {
            emit_progress(
                progress_sink,
                RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.coalesced"),
            );
            return wait_for_runtime_inflight_fetch(inflight, listener, request, cancel_token);
        }

        let work_cancel = inflight.cancellation.work_token();
        let result = fetch_source_uncached(
            request,
            inline_bytes,
            conditional,
            Some(&work_cancel),
            progress_sink,
        );
        publish_runtime_inflight_fetch_result(&inflight_key, inflight, result.clone());
        ensure_not_cancelled(cancel_token)?;
        drop(listener);
        return result;
    }

    fetch_source_uncached(
        request,
        inline_bytes,
        conditional,
        cancel_token,
        progress_sink,
    )
}

fn fetch_source_uncached(
    request: &RuntimeRequest,
    inline_bytes: Option<&[u8]>,
    conditional: Option<&HttpConditionalHeaders>,
    cancel_token: Option<&RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<FetchOutcome> {
    match &request.source {
        RuntimeSource::Network { uri } => {
            fetch_network(request, uri, conditional, cancel_token, progress_sink)
        }
        RuntimeSource::File { path } => fetch_file(request, path, progress_sink),
        RuntimeSource::ExifThumbnail { path } => fetch_exif_thumbnail(request, path, progress_sink),
        RuntimeSource::Bytes { id } | RuntimeSource::AssetBytes { id } => {
            let bytes = inline_bytes.ok_or_else(|| {
                RuntimeError::new(
                    "fetch",
                    false,
                    "inline source requires bytes supplied through the runtime boundary",
                )
            })?;
            if bytes.len() > request.limits.max_encoded_bytes {
                return Err(RuntimeError::new(
                    "fetch",
                    false,
                    "inline bytes exceed max encoded byte limit",
                ));
            }
            emit_progress(
                progress_sink,
                RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.inline")
                    .with_bytes(bytes.len(), Some(bytes.len())),
            );
            Ok(FetchOutcome {
                bytes: shared_bytes(bytes.to_vec()),
                source_label: id.clone(),
                http_cache_metadata: None,
                not_modified: false,
            })
        }
        RuntimeSource::RuntimePlugin {
            source_kind,
            locator,
        } => fetch_plugin_source(
            request,
            source_kind,
            locator,
            None,
            cancel_token,
            progress_sink,
        ),
        RuntimeSource::VideoFrame {
            locator,
            timestamp_micros,
            exact,
            backend,
        } => {
            let source_kind = video_frame_source_kind(backend.as_deref());
            fetch_plugin_source(
                request,
                &source_kind,
                locator,
                Some(RuntimePluginVideoFrameSpec {
                    timestamp_micros: *timestamp_micros,
                    exact: *exact,
                    backend: backend.as_deref(),
                }),
                cancel_token,
                progress_sink,
            )
        }
    }
}

fn fetch_plugin_source(
    request: &RuntimeRequest,
    source_kind: &str,
    locator: &str,
    video_frame: Option<RuntimePluginVideoFrameSpec<'_>>,
    cancel_token: Option<&RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<FetchOutcome> {
    let module = runtime_fetcher_for_source_kind(source_kind)?.ok_or_else(|| {
        RuntimeError::new(
            "fetch",
            false,
            format!("no runtime fetcher module registered for source kind {source_kind}"),
        )
    })?;
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "plugin.runtime.fetch.selected")
            .with_message(format!("{}:{}", module.module_id, source_kind)),
    );
    let Some((module, executor)) = runtime_fetcher_executor_for_source_kind(source_kind)? else {
        return Err(plugin_entrypoint_missing_error(
            "fetch",
            "fetcher",
            &module.module_id,
            source_kind,
        ));
    };
    let output = executor
        .fetch(RuntimePluginFetchRequest {
            source_kind,
            locator,
            video_frame,
            max_output_bytes: request.limits.max_encoded_bytes,
            context: Some(RuntimePluginFetchContext {
                request,
                network_concurrency: pipeline_config()
                    .lock()
                    .map_err(|_| RuntimeError::new("config", true, "runtime config lock poisoned"))?
                    .network_concurrency,
                cancel_token,
                progress_sink,
            }),
        })?
        .ok_or_else(|| {
            plugin_entrypoint_missing_error("fetch", "fetcher", &module.module_id, source_kind)
        })?;
    if output.bytes.len() > request.limits.max_encoded_bytes {
        return Err(RuntimeError::new(
            "fetch",
            false,
            "runtime fetcher output exceeds max encoded byte limit",
        ));
    }
    if video_frame.is_some() {
        validate_video_frame_fetcher_output(&module, &output)?;
    }
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "plugin.runtime.fetch.complete")
            .with_bytes(output.bytes.len(), Some(output.bytes.len()))
            .with_message(format!("{}:{}", module.module_id, source_kind)),
    );
    Ok(FetchOutcome {
        bytes: output.bytes,
        source_label: format!("runtime-plugin:{source_kind}"),
        http_cache_metadata: None,
        not_modified: false,
    })
}

fn validate_video_frame_fetcher_output(
    module: &RuntimePluginModule,
    output: &RuntimePluginOutput,
) -> RuntimeResult<()> {
    let Some(mime_type) = output
        .mime_type
        .as_deref()
        .map(normalize_mime_type)
        .filter(|value| !value.is_empty())
    else {
        return Err(RuntimeError::new(
            "fetch",
            false,
            format!(
                "video-frame fetcher {} returned bytes without an output MIME",
                module.module_id
            ),
        ));
    };
    let declared = module
        .routes
        .video_frame_output_mime_types
        .iter()
        .any(|declared| normalize_mime_type(declared) == mime_type);
    if !declared {
        return Err(RuntimeError::new(
            "fetch",
            false,
            format!(
                "video-frame fetcher output MIME {mime_type} is not declared by {}",
                module.module_id
            ),
        ));
    }
    Ok(())
}

fn normalize_mime_type(mime_type: &str) -> String {
    mime_type
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase()
}

fn video_frame_source_kind(backend: Option<&str>) -> Cow<'_, str> {
    match backend {
        Some(backend) => Cow::Owned(format!("video-frame:{backend}")),
        None => Cow::Borrowed("video-frame"),
    }
}

fn plugin_entrypoint_missing_error(
    stage: &'static str,
    capability: &'static str,
    module_id: &str,
    route: &str,
) -> RuntimeError {
    RuntimeError::new(
        stage,
        false,
        format!(
            "runtime {capability} module {module_id} selected for route {route} but has no execution entrypoint"
        ),
    )
}

fn fetch_exif_thumbnail(
    request: &RuntimeRequest,
    path: &str,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<FetchOutcome> {
    let mut file = std::fs::File::open(path).map_err(|error| {
        RuntimeError::new(
            "fetch",
            false,
            format!("failed to open EXIF thumbnail source: {error}"),
        )
    })?;
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.exifThumbnail"),
    );
    let bytes = jpeg_exif_thumbnail_from_reader(&mut file)?
        .ok_or_else(|| RuntimeError::new("fetch", false, "JPEG EXIF thumbnail is not available"))?;
    if bytes.len() > request.limits.max_encoded_bytes {
        return Err(RuntimeError::new(
            "fetch",
            false,
            "EXIF thumbnail exceeds max encoded byte limit",
        ));
    }
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.exifThumbnail.complete")
            .with_bytes(bytes.len(), Some(bytes.len())),
    );
    Ok(FetchOutcome {
        bytes: shared_bytes(bytes),
        source_label: format!("exif-thumbnail:{}", file_label(path)),
        http_cache_metadata: None,
        not_modified: false,
    })
}

fn validate_fetch_outcome_for_request(
    outcome: &FetchOutcome,
    request: &RuntimeRequest,
) -> RuntimeResult<()> {
    if !outcome.not_modified && outcome.bytes.len() > request.limits.max_encoded_bytes {
        return Err(RuntimeError::new(
            "fetch",
            false,
            "shared fetch exceeds max encoded byte limit",
        ));
    }
    Ok(())
}

fn fetch_file(
    request: &RuntimeRequest,
    path: &str,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<FetchOutcome> {
    let file = std::fs::File::open(path).map_err(|error| {
        RuntimeError::new(
            "fetch",
            false,
            format!("failed to open image file: {error}"),
        )
    })?;
    let metadata = file.metadata().map_err(|error| {
        RuntimeError::new(
            "fetch",
            false,
            format!("failed to stat image file: {error}"),
        )
    })?;
    let expected_length = checked_file_length(metadata.len(), request.limits.max_encoded_bytes)?;
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.file")
            .with_bytes(0, Some(expected_length)),
    );
    let read_limit = u64::try_from(request.limits.max_encoded_bytes)
        .unwrap_or(u64::MAX)
        .saturating_add(1);
    let mut bytes = Vec::with_capacity(expected_length);
    file.take(read_limit)
        .read_to_end(&mut bytes)
        .map_err(|error| {
            RuntimeError::new(
                "fetch",
                false,
                format!("failed to read image file: {error}"),
            )
        })?;
    validate_encoded_byte_limit(&bytes, request.limits.max_encoded_bytes, "fetch")?;
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.file.complete")
            .with_bytes(bytes.len(), Some(bytes.len())),
    );
    Ok(FetchOutcome {
        bytes: shared_bytes(bytes),
        source_label: file_label(path),
        http_cache_metadata: None,
        not_modified: false,
    })
}

fn checked_file_length(length: u64, max_encoded_bytes: usize) -> RuntimeResult<usize> {
    let length = usize::try_from(length).map_err(|_| {
        RuntimeError::new(
            "fetch",
            false,
            "file length exceeds this platform's addressable memory",
        )
    })?;
    if length > max_encoded_bytes {
        return Err(RuntimeError::new(
            "fetch",
            false,
            "file exceeds max encoded byte limit",
        ));
    }
    Ok(length)
}

fn fetch_network(
    request: &RuntimeRequest,
    uri: &str,
    conditional: Option<&HttpConditionalHeaders>,
    cancel_token: Option<&RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<FetchOutcome> {
    let concurrency = pipeline_config()
        .lock()
        .map_err(|_| RuntimeError::new("config", true, "runtime config lock poisoned"))?
        .network_concurrency;
    match http_transport::fetch(
        concurrency,
        request,
        uri,
        conditional,
        cancel_token,
        progress_sink,
    )? {
        HttpFetchResult::Fetched(fetched) => Ok(FetchOutcome {
            bytes: shared_bytes(fetched.bytes),
            source_label: fetched.source_label,
            http_cache_metadata: Some(fetched.cache_metadata),
            not_modified: false,
        }),
        HttpFetchResult::NotModified(not_modified) => Ok(FetchOutcome {
            bytes: shared_bytes(Vec::new()),
            source_label: not_modified.source_label,
            http_cache_metadata: Some(not_modified.cache_metadata),
            not_modified: true,
        }),
    }
}

fn ensure_not_cancelled(cancel_token: Option<&RuntimeCancelToken>) -> RuntimeResult<()> {
    if let Some(token) = cancel_token {
        token.ensure_not_cancelled()?;
    }
    Ok(())
}

#[derive(Clone, Debug)]
enum RuntimeProcessor {
    Resize {
        width: Option<u32>,
        height: Option<u32>,
        mode: ResizeMode,
        filter: image::imageops::FilterType,
    },
    ResizeToFill {
        width: u32,
        height: u32,
        filter: image::imageops::FilterType,
    },
    Thumbnail {
        width: u32,
        height: u32,
    },
    ThumbnailExact {
        width: u32,
        height: u32,
    },
    Crop {
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    },
    Tile(TileSpec),
    Rotate {
        degrees: u16,
    },
    Blur {
        sigma: f32,
    },
    FastBlur {
        sigma: f32,
    },
    Filter3x3 {
        kernel: [f32; 9],
    },
    FlipHorizontal,
    FlipVertical,
    Grayscale,
    Invert,
    Brighten {
        value: i32,
    },
    Contrast {
        value: f32,
    },
    HueRotate {
        degrees: i32,
    },
    Unsharpen {
        sigma: f32,
        threshold: i32,
    },
    Watermark(WatermarkSpec),
}

#[derive(Debug)]
struct DecodedProcessorInput {
    image: image::DynamicImage,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ResizeMode {
    Fit,
    Exact,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WatermarkPosition {
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
    Center,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TileSpec {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    decoded_width: u32,
    decoded_height: u32,
    filter: image::imageops::FilterType,
}

#[derive(Clone, Debug)]
struct WatermarkSpec {
    text: String,
    position: WatermarkPosition,
    padding: u32,
    scale: u32,
    color: [u8; 4],
    background: Option<[u8; 4]>,
    opacity: f32,
}

fn parse_processor_chain(descriptors: &[String]) -> RuntimeResult<Vec<RuntimeProcessor>> {
    descriptors
        .iter()
        .map(|descriptor| parse_processor_descriptor(descriptor))
        .collect()
}

fn parse_processor_descriptor(descriptor: &str) -> RuntimeResult<RuntimeProcessor> {
    if let Some(tile) = parse_tile_processor_descriptor(descriptor)? {
        return Ok(RuntimeProcessor::Tile(tile));
    }
    let operation = processor_operation_label(descriptor);
    let operation_key = normalize_processor_operation(&operation);
    let args = processor_args(descriptor);
    match operation_key.as_str() {
        "resize" => {
            let width = optional_processor_u32(&args, "width")?;
            let height = optional_processor_u32(&args, "height")?;
            if width.is_none() && height.is_none() {
                return processor_descriptor_error("resize requires width or height");
            }
            Ok(RuntimeProcessor::Resize {
                width,
                height,
                mode: parse_resize_mode(args.get("mode").map(String::as_str))?,
                filter: parse_resize_filter(args.get("filter").map(String::as_str))?,
            })
        }
        "resizeexact" => {
            let width = required_processor_u32(&args, "width")?;
            let height = required_processor_u32(&args, "height")?;
            Ok(RuntimeProcessor::Resize {
                width: Some(width),
                height: Some(height),
                mode: ResizeMode::Exact,
                filter: parse_resize_filter(args.get("filter").map(String::as_str))?,
            })
        }
        "resizetofill" | "centercrop" => Ok(RuntimeProcessor::ResizeToFill {
            width: required_processor_u32(&args, "width")?,
            height: required_processor_u32(&args, "height")?,
            filter: parse_resize_filter(args.get("filter").map(String::as_str))?,
        }),
        "thumbnail" => Ok(RuntimeProcessor::Thumbnail {
            width: required_processor_u32(&args, "width")?,
            height: required_processor_u32(&args, "height")?,
        }),
        "thumbnailexact" => Ok(RuntimeProcessor::ThumbnailExact {
            width: required_processor_u32(&args, "width")?,
            height: required_processor_u32(&args, "height")?,
        }),
        "crop" => Ok(RuntimeProcessor::Crop {
            x: required_processor_u32_allow_zero(&args, "x")?,
            y: required_processor_u32_allow_zero(&args, "y")?,
            width: required_processor_u32(&args, "width")?,
            height: required_processor_u32(&args, "height")?,
        }),
        "tile" | "tilecropresize" => Ok(RuntimeProcessor::Tile(TileSpec {
            x: required_processor_u32_allow_zero(&args, "x")?,
            y: required_processor_u32_allow_zero(&args, "y")?,
            width: required_processor_u32(&args, "width")?,
            height: required_processor_u32(&args, "height")?,
            decoded_width: required_processor_u32_alias(&args, "decodedwidth", "decoded_width")?,
            decoded_height: required_processor_u32_alias(&args, "decodedheight", "decoded_height")?,
            filter: parse_resize_filter(args.get("filter").map(String::as_str))?,
        })),
        "rotate" => Ok(RuntimeProcessor::Rotate {
            degrees: parse_rotate_degrees(&args)?,
        }),
        "blur" => Ok(RuntimeProcessor::Blur {
            sigma: required_processor_f32(&args, "sigma")?,
        }),
        "fastblur" => Ok(RuntimeProcessor::FastBlur {
            sigma: required_processor_f32(&args, "sigma")?,
        }),
        "filter3x3" => Ok(RuntimeProcessor::Filter3x3 {
            kernel: required_processor_kernel3x3(&args, "kernel")?,
        }),
        "fliphorizontal" | "fliph" => Ok(RuntimeProcessor::FlipHorizontal),
        "flipvertical" | "flipv" => Ok(RuntimeProcessor::FlipVertical),
        "grayscale" | "greyscale" => Ok(RuntimeProcessor::Grayscale),
        "invert" => Ok(RuntimeProcessor::Invert),
        "brighten" | "brightness" => Ok(RuntimeProcessor::Brighten {
            value: required_processor_i32_alias(&args, "value", "amount", -255, 255)?,
        }),
        "contrast" => Ok(RuntimeProcessor::Contrast {
            value: required_processor_f32_range(&args, "value", -255.0, 255.0)?,
        }),
        "huerotate" => Ok(RuntimeProcessor::HueRotate {
            degrees: required_processor_i32_alias(&args, "degrees", "angle", -360, 360)?,
        }),
        "unsharpen" | "unsharpmask" => Ok(RuntimeProcessor::Unsharpen {
            sigma: required_processor_f32(&args, "sigma")?,
            threshold: required_processor_i32_range(&args, "threshold", 0, 255)?,
        }),
        "watermark" => Ok(RuntimeProcessor::Watermark(WatermarkSpec {
            text: required_processor_text(&args, "text")?,
            position: parse_watermark_position(args.get("position").map(String::as_str))?,
            padding: optional_processor_u32_allow_zero(&args, "padding")?.unwrap_or(8),
            scale: parse_watermark_scale(args.get("scale").map(String::as_str))?,
            color: parse_processor_color(
                args.get("color").map(String::as_str),
                [255, 255, 255, 255],
            )?,
            background: parse_processor_optional_color(args.get("background").map(String::as_str))?,
            opacity: parse_processor_opacity(args.get("opacity").map(String::as_str))?,
        })),
        _ => processor_descriptor_error(format!(
            "unsupported runtime processor operation: {}",
            operation
        )),
    }
}

fn normalize_processor_operation(operation: &str) -> String {
    operation
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

fn parse_tile_processor_descriptor(descriptor: &str) -> RuntimeResult<Option<TileSpec>> {
    let trimmed = descriptor.trim();
    let Some(start) = trimmed.find('(') else {
        return Ok(None);
    };
    let operation = trimmed[..start].trim();
    if !operation.eq_ignore_ascii_case("tile")
        && !operation.eq_ignore_ascii_case("tileCropResize")
        && !operation.eq_ignore_ascii_case("tile_crop_resize")
    {
        return Ok(None);
    }
    let Some(end) = trimmed.rfind(')') else {
        return processor_descriptor_error("missing tile processor argument list");
    };
    if end <= start {
        return processor_descriptor_error("missing tile processor argument list");
    }

    let mut x = None;
    let mut y = None;
    let mut width = None;
    let mut height = None;
    let mut decoded_width_camel = None;
    let mut decoded_width_snake = None;
    let mut decoded_height_camel = None;
    let mut decoded_height_snake = None;
    let mut filter = image::imageops::FilterType::Lanczos3;

    for part in trimmed[start + 1..end].split(',') {
        let Some((key, value)) = part.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let value = value.trim().trim_matches('"').trim_matches('\'');
        if key.eq_ignore_ascii_case("x") {
            x = Some(parse_processor_u32_fast(value, "x", true)?);
        } else if key.eq_ignore_ascii_case("y") {
            y = Some(parse_processor_u32_fast(value, "y", true)?);
        } else if key.eq_ignore_ascii_case("width") {
            width = Some(parse_processor_u32_fast(value, "width", false)?);
        } else if key.eq_ignore_ascii_case("height") {
            height = Some(parse_processor_u32_fast(value, "height", false)?);
        } else if key.eq_ignore_ascii_case("decodedwidth") {
            decoded_width_camel = Some(parse_processor_u32_fast(value, "decodedwidth", false)?);
        } else if key.eq_ignore_ascii_case("decoded_width") {
            decoded_width_snake = Some(parse_processor_u32_fast(value, "decoded_width", false)?);
        } else if key.eq_ignore_ascii_case("decodedheight") {
            decoded_height_camel = Some(parse_processor_u32_fast(value, "decodedheight", false)?);
        } else if key.eq_ignore_ascii_case("decoded_height") {
            decoded_height_snake = Some(parse_processor_u32_fast(value, "decoded_height", false)?);
        } else if key.eq_ignore_ascii_case("filter") {
            filter = parse_resize_filter_fast(value)?;
        } else {
            return processor_descriptor_error(format!(
                "unsupported tile processor argument {key}"
            ));
        }
    }

    Ok(Some(TileSpec {
        x: required_fast_u32(x, "x")?,
        y: required_fast_u32(y, "y")?,
        width: required_fast_u32(width, "width")?,
        height: required_fast_u32(height, "height")?,
        decoded_width: resolve_fast_alias(
            decoded_width_camel,
            decoded_width_snake,
            "decodedwidth",
            "decoded_width",
        )?
        .ok_or_else(|| {
            RuntimeError::new(
                "processor",
                false,
                "missing processor argument decodedwidth",
            )
        })?,
        decoded_height: resolve_fast_alias(
            decoded_height_camel,
            decoded_height_snake,
            "decodedheight",
            "decoded_height",
        )?
        .ok_or_else(|| {
            RuntimeError::new(
                "processor",
                false,
                "missing processor argument decodedheight",
            )
        })?,
        filter,
    }))
}

fn parse_processor_u32_fast(
    value: &str,
    name: &'static str,
    allow_zero: bool,
) -> RuntimeResult<u32> {
    let parsed = value.parse::<u32>().map_err(|_| {
        RuntimeError::new(
            "processor",
            false,
            if allow_zero {
                format!("processor argument {name} must be a non-negative integer")
            } else {
                format!("processor argument {name} must be a positive integer")
            },
        )
    })?;
    if !allow_zero && parsed == 0 {
        return processor_descriptor_error(format!(
            "processor argument {name} must be greater than zero"
        ));
    }
    Ok(parsed)
}

fn required_fast_u32(value: Option<u32>, name: &'static str) -> RuntimeResult<u32> {
    value.ok_or_else(|| {
        RuntimeError::new(
            "processor",
            false,
            format!("missing processor argument {name}"),
        )
    })
}

fn resolve_fast_alias(
    value: Option<u32>,
    alias_value: Option<u32>,
    name: &'static str,
    alias: &'static str,
) -> RuntimeResult<Option<u32>> {
    match (value, alias_value) {
        (Some(value), Some(alias_value)) if value != alias_value => {
            processor_descriptor_error(format!("processor arguments {name} and {alias} must match"))
        }
        (Some(value), _) | (_, Some(value)) => Ok(Some(value)),
        (None, None) => Ok(None),
    }
}

fn parse_resize_filter_fast(value: &str) -> RuntimeResult<image::imageops::FilterType> {
    if value.eq_ignore_ascii_case("nearest") {
        Ok(image::imageops::FilterType::Nearest)
    } else if value.eq_ignore_ascii_case("triangle") || value.eq_ignore_ascii_case("linear") {
        Ok(image::imageops::FilterType::Triangle)
    } else if value.eq_ignore_ascii_case("catmullrom") || value.eq_ignore_ascii_case("cubic") {
        Ok(image::imageops::FilterType::CatmullRom)
    } else if value.eq_ignore_ascii_case("gaussian") {
        Ok(image::imageops::FilterType::Gaussian)
    } else if value.eq_ignore_ascii_case("lanczos3") || value.eq_ignore_ascii_case("lanczos") {
        Ok(image::imageops::FilterType::Lanczos3)
    } else {
        processor_descriptor_error(format!("unsupported resize filter: {value}"))
    }
}

fn processor_operation_label(descriptor: &str) -> String {
    let raw = descriptor
        .split(|ch: char| ch == '(' || ch == ':' || ch == '{' || ch.is_whitespace())
        .next()
        .unwrap_or("processor")
        .trim();
    let label = raw
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric() || *ch == '_' || *ch == '-')
        .take(48)
        .collect::<String>();
    if label.is_empty() {
        "processor".to_string()
    } else {
        label
    }
}

fn processor_args(descriptor: &str) -> HashMap<String, String> {
    let Some(start) = descriptor.find('(') else {
        return HashMap::new();
    };
    let Some(end) = descriptor.rfind(')') else {
        return HashMap::new();
    };
    if end <= start {
        return HashMap::new();
    }
    descriptor[start + 1..end]
        .split(',')
        .filter_map(|part| {
            let part = part.trim();
            if part.is_empty() {
                return None;
            }
            let (key, value) = part.split_once('=')?;
            let key = key.trim().to_ascii_lowercase();
            let value = value
                .trim()
                .trim_matches('"')
                .trim_matches('\'')
                .to_string();
            (!key.is_empty()).then_some((key, value))
        })
        .collect()
}

fn optional_processor_u32(
    args: &HashMap<String, String>,
    name: &'static str,
) -> RuntimeResult<Option<u32>> {
    let Some(value) = args.get(name) else {
        return Ok(None);
    };
    let parsed = value.parse::<u32>().map_err(|_| {
        RuntimeError::new(
            "processor",
            false,
            format!("processor argument {name} must be a positive integer"),
        )
    })?;
    if parsed == 0 {
        return processor_descriptor_error(format!(
            "processor argument {name} must be greater than zero"
        ));
    }
    Ok(Some(parsed))
}

fn required_processor_u32(
    args: &HashMap<String, String>,
    name: &'static str,
) -> RuntimeResult<u32> {
    optional_processor_u32(args, name)?.ok_or_else(|| {
        RuntimeError::new(
            "processor",
            false,
            format!("missing processor argument {name}"),
        )
    })
}

fn optional_processor_u32_alias(
    args: &HashMap<String, String>,
    name: &'static str,
    alias: &'static str,
) -> RuntimeResult<Option<u32>> {
    let value = optional_processor_u32(args, name)?;
    let alias_value = optional_processor_u32(args, alias)?;
    match (value, alias_value) {
        (Some(value), Some(alias_value)) if value != alias_value => {
            processor_descriptor_error(format!("processor arguments {name} and {alias} must match"))
        }
        (Some(value), _) | (_, Some(value)) => Ok(Some(value)),
        (None, None) => Ok(None),
    }
}

fn required_processor_u32_alias(
    args: &HashMap<String, String>,
    name: &'static str,
    alias: &'static str,
) -> RuntimeResult<u32> {
    optional_processor_u32_alias(args, name, alias)?.ok_or_else(|| {
        RuntimeError::new(
            "processor",
            false,
            format!("missing processor argument {name}"),
        )
    })
}

fn required_processor_f32(
    args: &HashMap<String, String>,
    name: &'static str,
) -> RuntimeResult<f32> {
    let Some(value) = args.get(name) else {
        return processor_descriptor_error(format!("missing processor argument {name}"));
    };
    let parsed = value.parse::<f32>().map_err(|_| {
        RuntimeError::new(
            "processor",
            false,
            format!("processor argument {name} must be a finite number"),
        )
    })?;
    if !parsed.is_finite() || !(0.0..=128.0).contains(&parsed) {
        return processor_descriptor_error(format!(
            "processor argument {name} must be in range 0..128"
        ));
    }
    Ok(parsed)
}

fn required_processor_f32_range(
    args: &HashMap<String, String>,
    name: &'static str,
    min: f32,
    max: f32,
) -> RuntimeResult<f32> {
    let Some(value) = args.get(name) else {
        return processor_descriptor_error(format!("missing processor argument {name}"));
    };
    let parsed = value.parse::<f32>().map_err(|_| {
        RuntimeError::new(
            "processor",
            false,
            format!("processor argument {name} must be a finite number"),
        )
    })?;
    if !parsed.is_finite() || parsed < min || parsed > max {
        return processor_descriptor_error(format!(
            "processor argument {name} must be in range {min}..{max}"
        ));
    }
    Ok(parsed)
}

fn required_processor_kernel3x3(
    args: &HashMap<String, String>,
    name: &'static str,
) -> RuntimeResult<[f32; 9]> {
    let Some(value) = args.get(name) else {
        return processor_descriptor_error(format!("missing processor argument {name}"));
    };
    let parts = value
        .split(['|', ';'])
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .collect::<Vec<&str>>();
    if parts.len() != 9 {
        return processor_descriptor_error(format!("processor argument {name} must have 9 values"));
    }
    let mut kernel = [0.0_f32; 9];
    for (index, part) in parts.iter().enumerate() {
        let parsed = part.parse::<f32>().map_err(|_| {
            RuntimeError::new(
                "processor",
                false,
                format!("processor argument {name}[{index}] must be a finite number"),
            )
        })?;
        if !parsed.is_finite() || !(-64.0..=64.0).contains(&parsed) {
            return processor_descriptor_error(format!(
                "processor argument {name}[{index}] must be in range -64..64"
            ));
        }
        kernel[index] = parsed;
    }
    Ok(kernel)
}

fn required_processor_i32_alias(
    args: &HashMap<String, String>,
    name: &'static str,
    alias: &'static str,
    min: i32,
    max: i32,
) -> RuntimeResult<i32> {
    let value = optional_processor_i32_range(args, name, min, max)?;
    let alias_value = optional_processor_i32_range(args, alias, min, max)?;
    match (value, alias_value) {
        (Some(value), Some(alias_value)) if value != alias_value => {
            processor_descriptor_error(format!("processor arguments {name} and {alias} must match"))
        }
        (Some(value), _) | (_, Some(value)) => Ok(value),
        (None, None) => processor_descriptor_error(format!("missing processor argument {name}")),
    }
}

fn required_processor_i32_range(
    args: &HashMap<String, String>,
    name: &'static str,
    min: i32,
    max: i32,
) -> RuntimeResult<i32> {
    optional_processor_i32_range(args, name, min, max)?.ok_or_else(|| {
        RuntimeError::new(
            "processor",
            false,
            format!("missing processor argument {name}"),
        )
    })
}

fn optional_processor_i32_range(
    args: &HashMap<String, String>,
    name: &'static str,
    min: i32,
    max: i32,
) -> RuntimeResult<Option<i32>> {
    let Some(value) = args.get(name) else {
        return Ok(None);
    };
    let parsed = value.parse::<i32>().map_err(|_| {
        RuntimeError::new(
            "processor",
            false,
            format!("processor argument {name} must be an integer"),
        )
    })?;
    if parsed < min || parsed > max {
        return processor_descriptor_error(format!(
            "processor argument {name} must be in range {min}..{max}"
        ));
    }
    Ok(Some(parsed))
}

fn required_processor_text(
    args: &HashMap<String, String>,
    name: &'static str,
) -> RuntimeResult<String> {
    let Some(value) = args.get(name) else {
        return processor_descriptor_error(format!("missing processor argument {name}"));
    };
    let text = value.trim();
    if text.is_empty() {
        return processor_descriptor_error(format!("processor argument {name} must not be empty"));
    }
    if text.chars().count() > 256 {
        return processor_descriptor_error(format!(
            "processor argument {name} must be at most 256 characters"
        ));
    }
    Ok(text.to_string())
}

fn optional_processor_u32_allow_zero(
    args: &HashMap<String, String>,
    name: &'static str,
) -> RuntimeResult<Option<u32>> {
    let Some(value) = args.get(name) else {
        return Ok(None);
    };
    let parsed = value.parse::<u32>().map_err(|_| {
        RuntimeError::new(
            "processor",
            false,
            format!("processor argument {name} must be a non-negative integer"),
        )
    })?;
    Ok(Some(parsed))
}

fn required_processor_u32_allow_zero(
    args: &HashMap<String, String>,
    name: &'static str,
) -> RuntimeResult<u32> {
    optional_processor_u32_allow_zero(args, name)?.ok_or_else(|| {
        RuntimeError::new(
            "processor",
            false,
            format!("missing processor argument {name}"),
        )
    })
}

fn parse_resize_mode(value: Option<&str>) -> RuntimeResult<ResizeMode> {
    match value.unwrap_or("fit").to_ascii_lowercase().as_str() {
        "fit" => Ok(ResizeMode::Fit),
        "exact" => Ok(ResizeMode::Exact),
        other => processor_descriptor_error(format!("unsupported resize mode: {other}")),
    }
}

fn parse_resize_filter(value: Option<&str>) -> RuntimeResult<image::imageops::FilterType> {
    match value.unwrap_or("lanczos3").to_ascii_lowercase().as_str() {
        "nearest" => Ok(image::imageops::FilterType::Nearest),
        "triangle" | "linear" => Ok(image::imageops::FilterType::Triangle),
        "catmullrom" | "cubic" => Ok(image::imageops::FilterType::CatmullRom),
        "gaussian" => Ok(image::imageops::FilterType::Gaussian),
        "lanczos3" | "lanczos" => Ok(image::imageops::FilterType::Lanczos3),
        other => processor_descriptor_error(format!("unsupported resize filter: {other}")),
    }
}

fn parse_watermark_position(value: Option<&str>) -> RuntimeResult<WatermarkPosition> {
    match value.unwrap_or("bottomRight").to_ascii_lowercase().as_str() {
        "topleft" | "top_left" | "top-left" => Ok(WatermarkPosition::TopLeft),
        "topright" | "top_right" | "top-right" => Ok(WatermarkPosition::TopRight),
        "bottomleft" | "bottom_left" | "bottom-left" => Ok(WatermarkPosition::BottomLeft),
        "bottomright" | "bottom_right" | "bottom-right" => Ok(WatermarkPosition::BottomRight),
        "center" | "centre" => Ok(WatermarkPosition::Center),
        other => processor_descriptor_error(format!("unsupported watermark position: {other}")),
    }
}

fn parse_watermark_scale(value: Option<&str>) -> RuntimeResult<u32> {
    let Some(value) = value else {
        return Ok(2);
    };
    let parsed = value.parse::<u32>().map_err(|_| {
        RuntimeError::new(
            "processor",
            false,
            "watermark scale must be an integer in range 1..16",
        )
    })?;
    if !(1..=16).contains(&parsed) {
        return processor_descriptor_error("watermark scale must be in range 1..16");
    }
    Ok(parsed)
}

fn parse_processor_opacity(value: Option<&str>) -> RuntimeResult<f32> {
    let Some(value) = value else {
        return Ok(0.70);
    };
    let parsed = value.parse::<f32>().map_err(|_| {
        RuntimeError::new(
            "processor",
            false,
            "watermark opacity must be a finite number in range 0..1",
        )
    })?;
    if !parsed.is_finite() || !(0.0..=1.0).contains(&parsed) {
        return processor_descriptor_error("watermark opacity must be in range 0..1");
    }
    Ok(parsed)
}

fn parse_processor_optional_color(value: Option<&str>) -> RuntimeResult<Option<[u8; 4]>> {
    match value {
        None => Ok(Some([0, 0, 0, 128])),
        Some(value) if value.eq_ignore_ascii_case("none") => Ok(None),
        Some(value) => parse_processor_color(Some(value), [0, 0, 0, 128]).map(Some),
    }
}

fn parse_processor_color(value: Option<&str>, default: [u8; 4]) -> RuntimeResult<[u8; 4]> {
    let Some(value) = value else {
        return Ok(default);
    };
    let raw = value.trim().trim_start_matches('#');
    if raw.len() != 6 && raw.len() != 8 {
        return processor_descriptor_error("color must be #RRGGBB or #RRGGBBAA");
    }
    let parse_channel = |start: usize| -> RuntimeResult<u8> {
        u8::from_str_radix(&raw[start..start + 2], 16)
            .map_err(|_| RuntimeError::new("processor", false, "color contains invalid hex digits"))
    };
    Ok([
        parse_channel(0)?,
        parse_channel(2)?,
        parse_channel(4)?,
        if raw.len() == 8 {
            parse_channel(6)?
        } else {
            255
        },
    ])
}

fn parse_rotate_degrees(args: &HashMap<String, String>) -> RuntimeResult<u16> {
    let value = args
        .get("degrees")
        .or_else(|| args.get("angle"))
        .ok_or_else(|| RuntimeError::new("processor", false, "missing rotate degrees"))?;
    let degrees = value.parse::<u16>().map_err(|_| {
        RuntimeError::new(
            "processor",
            false,
            "rotate degrees must be one of 0, 90, 180, 270",
        )
    })?;
    match degrees {
        0 | 90 | 180 | 270 => Ok(degrees),
        _ => processor_descriptor_error("rotate degrees must be one of 0, 90, 180, 270"),
    }
}

fn apply_processor_chain(
    bytes: &[u8],
    processors: &[RuntimeProcessor],
    limits: &RuntimeLimits,
) -> RuntimeResult<Vec<u8>> {
    let image = decode_processor_input(bytes, limits)?;
    apply_processor_chain_to_image(image, processors, limits)
}

fn apply_processor_chain_for_request(
    request: &RuntimeRequest,
    bytes: &SharedBytes,
    processors: &[RuntimeProcessor],
    cancel_token: Option<&RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<SharedBytes> {
    if let Some(tile) = single_tile_processor(processors) {
        validate_processor_target_dimensions(
            tile.decoded_width,
            tile.decoded_height,
            &request.limits,
        )?;
        if let Some(processed) =
            try_apply_runtime_plugin_tile_processor(request, bytes.as_ref(), tile, progress_sink)?
        {
            return Ok(processed);
        }
        if let Some(processed) = try_apply_encoded_region_tile_processor(
            bytes.as_ref(),
            tile,
            &request.limits,
            progress_sink,
        )? {
            return Ok(shared_bytes(processed));
        }
        validate_tile_full_decode_fallback_budget(bytes.as_ref(), &request.limits)?;
        let key = runtime_processor_input_key(request, bytes);
        let input = decoded_processor_input_for_tile(
            &key,
            bytes.as_ref(),
            &request.limits,
            cancel_token,
            progress_sink,
        )?;
        ensure_not_cancelled(cancel_token)?;
        let image = apply_tile_processor(&input.image, tile)?;
        validate_processor_dimensions(&image, &request.limits)?;
        return encode_processor_output(image, &request.limits).map(shared_bytes);
    }
    apply_processor_chain(bytes.as_ref(), processors, &request.limits).map(shared_bytes)
}

fn decode_processor_input(
    bytes: &[u8],
    limits: &RuntimeLimits,
) -> RuntimeResult<image::DynamicImage> {
    reject_animated_processor_input(bytes)?;
    let format = select_runtime_image_format(bytes, "processor", "processor input")?;
    let _ = preflight_decoded_dimensions(format, bytes, "processor", limits.max_decoded_pixels)?;
    let mut image = format.decode(bytes, "processor", "processor input")?;
    image = apply_exif_orientation(image, bytes)?;
    Ok(image)
}

fn apply_processor_chain_to_image(
    mut image: image::DynamicImage,
    processors: &[RuntimeProcessor],
    limits: &RuntimeLimits,
) -> RuntimeResult<Vec<u8>> {
    for processor in processors {
        image = apply_processor(image, processor, limits)?;
    }
    encode_processor_output(image, limits)
}

fn encode_processor_output(
    image: image::DynamicImage,
    limits: &RuntimeLimits,
) -> RuntimeResult<Vec<u8>> {
    encode_png_variant(
        image,
        "processor",
        "processor output",
        limits.max_processor_output_bytes,
    )
}

fn encode_png_variant(
    image: image::DynamicImage,
    stage: &'static str,
    label: &'static str,
    max_output_bytes: usize,
) -> RuntimeResult<Vec<u8>> {
    // Processed variants are shared cache artifacts; normalize decoder-specific
    // color types before encoding so future backends do not leak into PNG output.
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
        .map_err(|error| {
            RuntimeError::new(stage, false, format!("failed to encode {label}: {error}"))
        })?;
    Ok(output.into_inner())
}

fn single_tile_processor(processors: &[RuntimeProcessor]) -> Option<TileSpec> {
    match processors {
        [RuntimeProcessor::Tile(tile)] => Some(*tile),
        _ => None,
    }
}

fn decoded_processor_input_for_tile(
    key: &str,
    bytes: &[u8],
    limits: &RuntimeLimits,
    cancel_token: Option<&RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<Arc<DecodedProcessorInput>> {
    let (inflight, is_leader) = runtime_inflight_processor_input_entry(key)?;
    if !is_leader {
        emit_progress(
            progress_sink,
            RuntimeProgressEvent::new(RuntimeProgressStage::Process, "process.decode.coalesced"),
        );
        return wait_for_runtime_inflight_processor_input(inflight, cancel_token);
    }

    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::Process, "process.decode.start")
            .with_bytes(bytes.len(), Some(bytes.len())),
    );
    let result = decode_processor_input(bytes, limits)
        .map(|image| Arc::new(DecodedProcessorInput { image }));
    if let Ok(input) = &result {
        emit_progress(
            progress_sink,
            RuntimeProgressEvent::new(RuntimeProgressStage::Process, "process.decode.complete")
                .with_bytes(decoded_image_bytes(&input.image), None),
        );
    }
    publish_runtime_inflight_processor_input_result(key, inflight, result.clone());
    result
}

fn decoded_image_bytes(image: &image::DynamicImage) -> usize {
    let (width, height) = image.dimensions();
    let pixels = u64::from(width).saturating_mul(u64::from(height));
    pixels.saturating_mul(4).min(usize::MAX as u64) as usize
}

fn try_apply_runtime_plugin_tile_processor(
    request: &RuntimeRequest,
    bytes: &[u8],
    tile: TileSpec,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<Option<SharedBytes>> {
    let Some(descriptor) = request.processors.first() else {
        return Ok(None);
    };
    let format = sniff_image_format(bytes);
    let format_id = format.map(RuntimeImageFormat::format_id);
    let mime_type = format.map(RuntimeImageFormat::primary_mime_type);
    let orientation = if format == Some(RuntimeImageFormat::Jpeg) {
        jpeg_exif_orientation(bytes)?.unwrap_or(1)
    } else {
        1
    };
    let plugin_tile = if orientation == 1 {
        tile
    } else {
        let (source_width, source_height) = RuntimeImageFormat::Jpeg.dimensions(bytes)?;
        map_oriented_tile_to_source(tile, source_width, source_height, orientation)?
    };
    let plugin_descriptor = if plugin_tile == tile {
        Cow::Borrowed(descriptor.as_str())
    } else {
        Cow::Owned(tile_processor_descriptor(plugin_tile))
    };
    let mut route_operations = Vec::<Cow<'_, str>>::with_capacity(2);
    if let Some(format_id) = format_id {
        route_operations.push(Cow::Owned(format!("tile:{format_id}")));
    }
    route_operations.push(Cow::Borrowed("tile"));

    for operation in route_operations {
        if runtime_processor_for_operation_fast_path(operation.as_ref())?.is_none() {
            continue;
        }
        emit_progress(
            progress_sink,
            RuntimeProgressEvent::new(
                RuntimeProgressStage::Process,
                "plugin.runtime.processor.selected",
            )
            .with_message(operation.as_ref()),
        );
        let Some(output) = runtime_process(RuntimePluginProcessRequest {
            operation: operation.as_ref(),
            descriptor: plugin_descriptor.as_ref(),
            format_id,
            mime_type,
            bytes,
            max_decoded_pixels: request.limits.max_decoded_pixels,
            max_output_bytes: request.limits.max_processor_output_bytes,
        })?
        else {
            return Ok(None);
        };
        let output_format = validate_runtime_tile_processor_output(
            output.bytes.as_ref(),
            plugin_tile.decoded_width,
            plugin_tile.decoded_height,
            &request.limits,
        )?;
        let output_bytes = if orientation == 1 {
            output.bytes
        } else {
            let image = output_format.decode(
                output.bytes.as_ref(),
                "processor",
                "runtime tile processor output",
            )?;
            let image = apply_image_orientation(image, orientation)?;
            validate_processor_target_dimensions(image.width(), image.height(), &request.limits)?;
            if image.dimensions() != (tile.decoded_width, tile.decoded_height) {
                return Err(RuntimeError::new(
                    "processor",
                    false,
                    "oriented runtime tile processor output dimensions do not match request",
                ));
            }
            shared_bytes(encode_processor_output(image, &request.limits)?)
        };
        emit_progress(
            progress_sink,
            RuntimeProgressEvent::new(
                RuntimeProgressStage::Process,
                "plugin.runtime.processor.complete",
            )
            .with_bytes(output_bytes.len(), Some(output_bytes.len()))
            .with_message(operation.as_ref()),
        );
        return Ok(Some(output_bytes));
    }
    Ok(None)
}

fn validate_runtime_tile_processor_output(
    bytes: &[u8],
    expected_width: u32,
    expected_height: u32,
    limits: &RuntimeLimits,
) -> RuntimeResult<RuntimeImageFormat> {
    if bytes.len() > limits.max_processor_output_bytes {
        return Err(RuntimeError::new(
            "processor",
            false,
            "runtime processor output exceeds max output byte limit",
        ));
    }
    validate_supported_image(bytes, limits)?;
    reject_animated_processor_input(bytes)?;
    let format = select_runtime_image_format(bytes, "processor", "runtime tile processor output")?;
    let (width, height) = format.dimensions(bytes)?;
    validate_processor_target_dimensions(width, height, limits)?;
    if (width, height) != (expected_width, expected_height) {
        return Err(RuntimeError::new(
            "processor",
            false,
            "runtime tile processor output dimensions do not match request",
        ));
    }
    Ok(format)
}

fn map_oriented_tile_to_source(
    tile: TileSpec,
    source_width: u32,
    source_height: u32,
    orientation: u16,
) -> RuntimeResult<TileSpec> {
    let swaps_axes = matches!(orientation, 5..=8);
    let (oriented_width, oriented_height) = if swaps_axes {
        (source_height, source_width)
    } else {
        (source_width, source_height)
    };
    validate_tile_spec_for_dimensions(tile, oriented_width, oriented_height)?;
    let right = tile
        .x
        .checked_add(tile.width)
        .ok_or_else(|| RuntimeError::new("processor", false, "tile x range overflows"))?;
    let bottom = tile
        .y
        .checked_add(tile.height)
        .ok_or_else(|| RuntimeError::new("processor", false, "tile y range overflows"))?;
    let (x, y, width, height) = match orientation {
        1 => (tile.x, tile.y, tile.width, tile.height),
        2 => (
            source_width.checked_sub(right).ok_or_else(|| {
                RuntimeError::new("processor", false, "oriented tile x is out of bounds")
            })?,
            tile.y,
            tile.width,
            tile.height,
        ),
        3 => (
            source_width.checked_sub(right).ok_or_else(|| {
                RuntimeError::new("processor", false, "oriented tile x is out of bounds")
            })?,
            source_height.checked_sub(bottom).ok_or_else(|| {
                RuntimeError::new("processor", false, "oriented tile y is out of bounds")
            })?,
            tile.width,
            tile.height,
        ),
        4 => (
            tile.x,
            source_height.checked_sub(bottom).ok_or_else(|| {
                RuntimeError::new("processor", false, "oriented tile y is out of bounds")
            })?,
            tile.width,
            tile.height,
        ),
        5 => (tile.y, tile.x, tile.height, tile.width),
        6 => (
            tile.y,
            source_height.checked_sub(right).ok_or_else(|| {
                RuntimeError::new("processor", false, "oriented tile y is out of bounds")
            })?,
            tile.height,
            tile.width,
        ),
        7 => (
            source_width.checked_sub(bottom).ok_or_else(|| {
                RuntimeError::new("processor", false, "oriented tile x is out of bounds")
            })?,
            source_height.checked_sub(right).ok_or_else(|| {
                RuntimeError::new("processor", false, "oriented tile y is out of bounds")
            })?,
            tile.height,
            tile.width,
        ),
        8 => (
            source_width.checked_sub(bottom).ok_or_else(|| {
                RuntimeError::new("processor", false, "oriented tile x is out of bounds")
            })?,
            tile.x,
            tile.height,
            tile.width,
        ),
        _ => {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "EXIF orientation is out of range",
            ))
        }
    };
    let mapped = TileSpec {
        x,
        y,
        width,
        height,
        decoded_width: if swaps_axes {
            tile.decoded_height
        } else {
            tile.decoded_width
        },
        decoded_height: if swaps_axes {
            tile.decoded_width
        } else {
            tile.decoded_height
        },
        filter: tile.filter,
    };
    validate_tile_spec_for_dimensions(mapped, source_width, source_height)?;
    Ok(mapped)
}

fn tile_processor_descriptor(tile: TileSpec) -> String {
    format!(
        "tile(x={},y={},width={},height={},decodedWidth={},decodedHeight={},filter={})",
        tile.x,
        tile.y,
        tile.width,
        tile.height,
        tile.decoded_width,
        tile.decoded_height,
        resize_filter_name(tile.filter),
    )
}

fn resize_filter_name(filter: image::imageops::FilterType) -> &'static str {
    match filter {
        image::imageops::FilterType::Nearest => "nearest",
        image::imageops::FilterType::Triangle => "triangle",
        image::imageops::FilterType::CatmullRom => "catmullrom",
        image::imageops::FilterType::Gaussian => "gaussian",
        image::imageops::FilterType::Lanczos3 => "lanczos3",
    }
}

fn runtime_processor_for_operation_fast_path(
    operation: &str,
) -> RuntimeResult<Option<RuntimePluginModule>> {
    crate::runtime_processor_for_operation(operation)
}

fn try_apply_encoded_region_tile_processor(
    bytes: &[u8],
    spec: TileSpec,
    limits: &RuntimeLimits,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<Option<Vec<u8>>> {
    let Some(format) = sniff_image_format(bytes) else {
        return Ok(None);
    };
    if !format.supports_region_decode() {
        return Ok(None);
    }
    let (image_width, image_height) = format.dimensions(bytes)?;
    validate_tile_spec_for_dimensions(spec, image_width, image_height)?;
    let _ = validate_decoded_pixel_count(
        "processor",
        spec.decoded_width,
        spec.decoded_height,
        limits.max_decoded_pixels,
    )?;
    let _ = validate_decoded_pixel_count(
        "processor",
        spec.width,
        spec.height,
        limits.max_decoded_pixels,
    )?;
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(RuntimeProgressStage::Process, "process.regionDecode.start")
            .with_bytes(bytes.len(), Some(bytes.len())),
    );
    let region = RuntimeImageRegion {
        x: spec.x,
        y: spec.y,
        width: spec.width,
        height: spec.height,
    };
    let Some(image) = format.decode_region(
        bytes,
        region,
        limits.max_processor_output_bytes,
        "processor",
        "tile region",
    )?
    else {
        return Ok(None);
    };
    let image = if spec.width == spec.decoded_width && spec.height == spec.decoded_height {
        image
    } else {
        image.resize_exact(spec.decoded_width, spec.decoded_height, spec.filter)
    };
    validate_processor_dimensions(&image, limits)?;
    let encoded = encode_processor_output(image, limits)?;
    emit_progress(
        progress_sink,
        RuntimeProgressEvent::new(
            RuntimeProgressStage::Process,
            "process.regionDecode.complete",
        )
        .with_bytes(encoded.len(), Some(encoded.len())),
    );
    Ok(Some(encoded))
}

fn validate_tile_full_decode_fallback_budget(
    bytes: &[u8],
    limits: &RuntimeLimits,
) -> RuntimeResult<()> {
    let Some(format) = sniff_image_format(bytes) else {
        return Ok(());
    };
    if format.supports_region_decode() {
        return Ok(());
    }
    let (width, height) = format.dimensions(bytes).map_err(|error| {
        RuntimeError::new(
            "processor",
            error.retryable,
            format!(
                "failed to parse image dimensions before tile fallback decode: {}",
                error.message
            ),
        )
    })?;
    let pixels = u64::from(width)
        .checked_mul(u64::from(height))
        .ok_or_else(|| RuntimeError::new("processor", false, "decoded pixel count overflows"))?;
    let fallback_pixels = tile_full_decode_fallback_pixel_limit(limits)?;
    if pixels > fallback_pixels {
        return Err(RuntimeError::new(
            "processor",
            false,
            format!(
                "tile full-decode fallback for {} requires {pixels} decoded pixels; \
                 region decode is unavailable and fallback limit is {fallback_pixels}",
                format.format_id()
            ),
        ));
    }
    Ok(())
}

fn tile_full_decode_fallback_pixel_limit(limits: &RuntimeLimits) -> RuntimeResult<u64> {
    let output_bound_pixels =
        u64::try_from(limits.max_processor_output_bytes / MAX_DYNAMIC_IMAGE_BYTES_PER_PIXEL)
            .map_err(|_| {
                RuntimeError::new("processor", false, "tile fallback pixel limit overflows")
            })?;
    if output_bound_pixels == 0 {
        return Err(RuntimeError::new(
            "processor",
            false,
            "tile fallback pixel limit must be greater than zero",
        ));
    }
    Ok(limits.max_decoded_pixels.min(output_bound_pixels))
}

fn apply_exif_orientation(
    image: image::DynamicImage,
    bytes: &[u8],
) -> RuntimeResult<image::DynamicImage> {
    let Some(orientation) = jpeg_exif_orientation(bytes)? else {
        return Ok(image);
    };
    apply_image_orientation(image, orientation)
}

fn apply_image_orientation(
    image: image::DynamicImage,
    orientation: u16,
) -> RuntimeResult<image::DynamicImage> {
    let oriented = match orientation {
        1 => image,
        2 => image.fliph(),
        3 => image.rotate180(),
        4 => image.flipv(),
        5 => image.rotate90().fliph(),
        6 => image.rotate90(),
        7 => image.rotate270().fliph(),
        8 => image.rotate270(),
        _ => {
            return Err(RuntimeError::new(
                "metadata",
                false,
                "EXIF orientation is out of range",
            ))
        }
    };
    Ok(oriented)
}

fn apply_processor(
    image: image::DynamicImage,
    processor: &RuntimeProcessor,
    limits: &RuntimeLimits,
) -> RuntimeResult<image::DynamicImage> {
    let processed = match *processor {
        RuntimeProcessor::Resize {
            width,
            height,
            mode,
            filter,
        } => apply_resize_processor(&image, width, height, mode, filter),
        RuntimeProcessor::ResizeToFill {
            width,
            height,
            filter,
        } => image.resize_to_fill(width, height, filter),
        RuntimeProcessor::Thumbnail { width, height } => {
            apply_thumbnail_processor(&image, width, height)
        }
        RuntimeProcessor::ThumbnailExact { width, height } => image.thumbnail_exact(width, height),
        RuntimeProcessor::Crop {
            x,
            y,
            width,
            height,
        } => {
            let (image_width, image_height) = image.dimensions();
            let end_x = x
                .checked_add(width)
                .ok_or_else(|| RuntimeError::new("processor", false, "crop x + width overflows"))?;
            let end_y = y.checked_add(height).ok_or_else(|| {
                RuntimeError::new("processor", false, "crop y + height overflows")
            })?;
            if end_x > image_width || end_y > image_height {
                return processor_descriptor_error("crop rectangle exceeds image bounds");
            }
            image.crop_imm(x, y, width, height)
        }
        RuntimeProcessor::Tile(spec) => apply_tile_processor(&image, spec)?,
        RuntimeProcessor::Rotate { degrees } => match degrees {
            0 => image,
            90 => image.rotate90(),
            180 => image.rotate180(),
            270 => image.rotate270(),
            _ => return processor_descriptor_error("invalid rotate degrees"),
        },
        RuntimeProcessor::Blur { sigma } => image.blur(sigma),
        RuntimeProcessor::FastBlur { sigma } => image.fast_blur(sigma),
        RuntimeProcessor::Filter3x3 { ref kernel } => image.filter3x3(kernel),
        RuntimeProcessor::FlipHorizontal => image.fliph(),
        RuntimeProcessor::FlipVertical => image.flipv(),
        RuntimeProcessor::Grayscale => image.grayscale(),
        RuntimeProcessor::Invert => {
            let mut inverted = image;
            inverted.invert();
            inverted
        }
        RuntimeProcessor::Brighten { value } => image.brighten(value),
        RuntimeProcessor::Contrast { value } => image.adjust_contrast(value),
        RuntimeProcessor::HueRotate { degrees } => image.huerotate(degrees),
        RuntimeProcessor::Unsharpen { sigma, threshold } => image.unsharpen(sigma, threshold),
        RuntimeProcessor::Watermark(ref spec) => apply_watermark_processor(image, spec),
    };
    validate_processor_dimensions(&processed, limits)?;
    Ok(processed)
}

fn apply_tile_processor(
    image: &image::DynamicImage,
    spec: TileSpec,
) -> RuntimeResult<image::DynamicImage> {
    let (image_width, image_height) = image.dimensions();
    validate_tile_spec_for_dimensions(spec, image_width, image_height)?;
    let view = image::imageops::crop_imm(image, spec.x, spec.y, spec.width, spec.height);
    let rgba = if spec.width == spec.decoded_width && spec.height == spec.decoded_height {
        view.to_image()
    } else {
        image::imageops::resize(
            view.inner(),
            spec.decoded_width,
            spec.decoded_height,
            spec.filter,
        )
    };
    Ok(image::DynamicImage::ImageRgba8(rgba))
}

fn validate_tile_spec_for_dimensions(
    spec: TileSpec,
    image_width: u32,
    image_height: u32,
) -> RuntimeResult<()> {
    let end_x = spec
        .x
        .checked_add(spec.width)
        .ok_or_else(|| RuntimeError::new("processor", false, "tile x + width overflows"))?;
    let end_y = spec
        .y
        .checked_add(spec.height)
        .ok_or_else(|| RuntimeError::new("processor", false, "tile y + height overflows"))?;
    if end_x > image_width || end_y > image_height {
        return processor_descriptor_error("tile rectangle exceeds image bounds");
    }
    Ok(())
}

fn apply_resize_processor(
    image: &image::DynamicImage,
    width: Option<u32>,
    height: Option<u32>,
    mode: ResizeMode,
    filter: image::imageops::FilterType,
) -> image::DynamicImage {
    let (source_width, source_height) = image.dimensions();
    match (width, height, mode) {
        (Some(width), Some(height), ResizeMode::Exact) => image.resize_exact(width, height, filter),
        (Some(width), Some(height), ResizeMode::Fit) => image.resize(width, height, filter),
        (Some(width), None, _) => {
            let height = scaled_dimension(source_height, width, source_width);
            image.resize_exact(width, height, filter)
        }
        (None, Some(height), _) => {
            let width = scaled_dimension(source_width, height, source_height);
            image.resize_exact(width, height, filter)
        }
        (None, None, _) => image.clone(),
    }
}

fn apply_thumbnail_processor(
    image: &image::DynamicImage,
    width: u32,
    height: u32,
) -> image::DynamicImage {
    let (source_width, source_height) = image.dimensions();
    if width >= source_width && height >= source_height {
        return image.clone();
    }
    image.thumbnail(width, height)
}

fn scaled_dimension(numerator: u32, target: u32, denominator: u32) -> u32 {
    let scaled = (u64::from(numerator) * u64::from(target)).div_ceil(u64::from(denominator));
    scaled.clamp(1, u64::from(u32::MAX)) as u32
}

fn validate_processor_dimensions(
    image: &image::DynamicImage,
    limits: &RuntimeLimits,
) -> RuntimeResult<()> {
    let (width, height) = image.dimensions();
    validate_processor_target_dimensions(width, height, limits)
}

fn validate_processor_target_dimensions(
    width: u32,
    height: u32,
    limits: &RuntimeLimits,
) -> RuntimeResult<()> {
    let pixels =
        validate_decoded_pixel_count("processor", width, height, limits.max_decoded_pixels)?;
    let estimated_rgba_bytes = pixels
        .checked_mul(4)
        .ok_or_else(|| RuntimeError::new("processor", false, "processor output bytes overflow"))?;
    if estimated_rgba_bytes > limits.max_processor_output_bytes as u64 {
        return Err(RuntimeError::new(
            "processor",
            false,
            format!(
                "processor output decoded bytes exceed limit ({}>{})",
                estimated_rgba_bytes, limits.max_processor_output_bytes
            ),
        ));
    }
    Ok(())
}

fn apply_watermark_processor(
    image: image::DynamicImage,
    spec: &WatermarkSpec,
) -> image::DynamicImage {
    let mut rgba = image.into_rgba8();
    let width = rgba.width();
    let height = rgba.height();
    let glyph_count = spec.text.chars().count().max(1) as u32;
    let glyph_width = 5_u32.saturating_mul(spec.scale);
    let glyph_height = 7_u32.saturating_mul(spec.scale);
    let spacing = spec.scale;
    let text_width = glyph_count
        .saturating_mul(glyph_width)
        .saturating_add(glyph_count.saturating_sub(1).saturating_mul(spacing));
    let text_height = glyph_height;
    let box_width = text_width.saturating_add(spec.padding.saturating_mul(2));
    let box_height = text_height.saturating_add(spec.padding.saturating_mul(2));
    let (box_x, box_y) = watermark_origin(width, height, box_width, box_height, spec.position);
    if let Some(background) = spec.background {
        fill_rect_alpha(
            &mut rgba,
            box_x,
            box_y,
            box_width,
            box_height,
            apply_opacity(background, spec.opacity),
        );
    }
    let mut cursor_x = box_x.saturating_add(spec.padding);
    let text_y = box_y.saturating_add(spec.padding);
    let text_color = apply_opacity(spec.color, spec.opacity);
    for ch in spec.text.chars() {
        draw_glyph(
            &mut rgba,
            cursor_x,
            text_y,
            spec.scale,
            glyph_pattern(ch),
            text_color,
        );
        cursor_x = cursor_x.saturating_add(glyph_width).saturating_add(spacing);
    }
    image::DynamicImage::ImageRgba8(rgba)
}

fn watermark_origin(
    image_width: u32,
    image_height: u32,
    box_width: u32,
    box_height: u32,
    position: WatermarkPosition,
) -> (u32, u32) {
    let right = image_width.saturating_sub(box_width);
    let bottom = image_height.saturating_sub(box_height);
    match position {
        WatermarkPosition::TopLeft => (0, 0),
        WatermarkPosition::TopRight => (right, 0),
        WatermarkPosition::BottomLeft => (0, bottom),
        WatermarkPosition::BottomRight => (right, bottom),
        WatermarkPosition::Center => (right / 2, bottom / 2),
    }
}

fn fill_rect_alpha(
    image: &mut image::RgbaImage,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    color: [u8; 4],
) {
    let max_x = x.saturating_add(width).min(image.width());
    let max_y = y.saturating_add(height).min(image.height());
    for py in y..max_y {
        for px in x..max_x {
            blend_pixel(image.get_pixel_mut(px, py), color);
        }
    }
}

fn draw_glyph(
    image: &mut image::RgbaImage,
    x: u32,
    y: u32,
    scale: u32,
    pattern: [u8; 7],
    color: [u8; 4],
) {
    for (row, bits) in pattern.iter().enumerate() {
        for col in 0..5_u32 {
            if bits & (1 << (4 - col)) == 0 {
                continue;
            }
            fill_rect_alpha(
                image,
                x.saturating_add(col.saturating_mul(scale)),
                y.saturating_add((row as u32).saturating_mul(scale)),
                scale,
                scale,
                color,
            );
        }
    }
}

fn apply_opacity(mut color: [u8; 4], opacity: f32) -> [u8; 4] {
    color[3] = ((color[3] as f32 * opacity).round()).clamp(0.0, 255.0) as u8;
    color
}

fn blend_pixel(pixel: &mut image::Rgba<u8>, color: [u8; 4]) {
    let alpha = color[3] as u16;
    if alpha == 0 {
        return;
    }
    let inverse = 255_u16.saturating_sub(alpha);
    for channel in 0..3 {
        pixel[channel] =
            ((u16::from(color[channel]) * alpha + u16::from(pixel[channel]) * inverse + 127) / 255)
                as u8;
    }
    pixel[3] = (alpha + (u16::from(pixel[3]) * inverse + 127) / 255).min(255) as u8;
}

fn glyph_pattern(ch: char) -> [u8; 7] {
    match ch.to_ascii_uppercase() {
        'A' => [0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11],
        'B' => [0x1e, 0x11, 0x11, 0x1e, 0x11, 0x11, 0x1e],
        'C' => [0x0e, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0e],
        'D' => [0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e],
        'E' => [0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f],
        'F' => [0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x10],
        'G' => [0x0e, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0e],
        'H' => [0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11],
        'I' => [0x0e, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e],
        'J' => [0x07, 0x02, 0x02, 0x02, 0x12, 0x12, 0x0c],
        'K' => [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
        'L' => [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f],
        'M' => [0x11, 0x1b, 0x15, 0x15, 0x11, 0x11, 0x11],
        'N' => [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11],
        'O' => [0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e],
        'P' => [0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10],
        'Q' => [0x0e, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0d],
        'R' => [0x1e, 0x11, 0x11, 0x1e, 0x14, 0x12, 0x11],
        'S' => [0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e],
        'T' => [0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
        'U' => [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e],
        'V' => [0x11, 0x11, 0x11, 0x11, 0x11, 0x0a, 0x04],
        'W' => [0x11, 0x11, 0x11, 0x15, 0x15, 0x1b, 0x11],
        'X' => [0x11, 0x0a, 0x04, 0x04, 0x04, 0x0a, 0x11],
        'Y' => [0x11, 0x0a, 0x04, 0x04, 0x04, 0x04, 0x04],
        'Z' => [0x1f, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1f],
        '0' => [0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e],
        '1' => [0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e],
        '2' => [0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f],
        '3' => [0x1e, 0x01, 0x01, 0x0e, 0x01, 0x01, 0x1e],
        '4' => [0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02],
        '5' => [0x1f, 0x10, 0x1e, 0x01, 0x01, 0x11, 0x0e],
        '6' => [0x06, 0x08, 0x10, 0x1e, 0x11, 0x11, 0x0e],
        '7' => [0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        '8' => [0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e],
        '9' => [0x0e, 0x11, 0x11, 0x0f, 0x01, 0x02, 0x0c],
        ' ' => [0x00; 7],
        '-' => [0x00, 0x00, 0x00, 0x1f, 0x00, 0x00, 0x00],
        '_' => [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1f],
        '.' => [0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x0c],
        ':' => [0x00, 0x0c, 0x0c, 0x00, 0x0c, 0x0c, 0x00],
        '/' => [0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10],
        '@' => [0x0e, 0x11, 0x17, 0x15, 0x17, 0x10, 0x0e],
        '#' => [0x0a, 0x0a, 0x1f, 0x0a, 0x1f, 0x0a, 0x0a],
        '&' => [0x0c, 0x12, 0x14, 0x08, 0x15, 0x12, 0x0d],
        '+' => [0x00, 0x04, 0x04, 0x1f, 0x04, 0x04, 0x00],
        '?' => [0x0e, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04],
        _ => [0x0e, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04],
    }
}

fn reject_animated_processor_input(bytes: &[u8]) -> RuntimeResult<()> {
    if is_gif(bytes) && gif_frame_count(bytes)? > 1 {
        return processor_descriptor_error("animated GIF processor input is not supported");
    }
    if is_webp(bytes) && webp_animation_frame_count(bytes)? > 1 {
        return processor_descriptor_error("animated WebP processor input is not supported");
    }
    Ok(())
}

fn processor_descriptor_error<T>(message: impl Into<String>) -> RuntimeResult<T> {
    Err(RuntimeError::new("processor", false, message.into()))
}

fn has_private_headers(request: &RuntimeRequest) -> bool {
    request.headers.keys().any(|name| {
        matches!(
            name.to_ascii_lowercase().as_str(),
            "authorization"
                | "cookie"
                | "proxy-authorization"
                | "x-api-key"
                | "x-auth-token"
                | "x-amz-security-token"
                | "x-pixa-s3-access-key-id"
                | "x-pixa-s3-secret-access-key"
                | "x-pixa-s3-session-token"
        )
    })
}

fn conditional_headers(
    source: &RuntimeSource,
    metadata: &DiskCacheHttpMetadata,
) -> Option<HttpConditionalHeaders> {
    if !matches!(source, RuntimeSource::Network { .. }) {
        return None;
    }
    if metadata.etag.is_none() && metadata.last_modified.is_none() {
        return None;
    }
    Some(HttpConditionalHeaders {
        etag: metadata.etag.clone(),
        last_modified: metadata.last_modified.clone(),
    })
}

fn merge_http_metadata(
    stale: &DiskCacheHttpMetadata,
    fresh: Option<HttpCacheMetadata>,
) -> DiskCacheHttpMetadata {
    let Some(fresh) = fresh else {
        return stale.clone();
    };
    DiskCacheHttpMetadata {
        etag: fresh.etag.or_else(|| stale.etag.clone()),
        last_modified: fresh.last_modified.or_else(|| stale.last_modified.clone()),
        cache_control: fresh.cache_control.or_else(|| stale.cache_control.clone()),
        date: fresh.date,
        expires: fresh.expires.or_else(|| stale.expires.clone()),
        age: fresh.age,
        vary: fresh.vary.or_else(|| stale.vary.clone()),
        vary_request_key: fresh
            .vary_request_key
            .or_else(|| stale.vary_request_key.clone()),
        fetched_at_ms: Some(fresh.fetched_at_ms),
    }
}

fn should_store_on_disk(
    request: &RuntimeRequest,
    http_metadata: Option<&HttpCacheMetadata>,
) -> bool {
    should_store_on_disk_with_cache_control(
        request,
        http_metadata.and_then(|metadata| metadata.cache_control.as_deref()),
    )
}

fn should_store_disk_metadata_on_disk(
    request: &RuntimeRequest,
    http_metadata: Option<&DiskCacheHttpMetadata>,
) -> bool {
    should_store_on_disk_with_cache_control(
        request,
        http_metadata.and_then(|metadata| metadata.cache_control.as_deref()),
    )
}

fn should_store_on_disk_with_cache_control(
    request: &RuntimeRequest,
    cache_control: Option<&str>,
) -> bool {
    if has_private_headers(request) && !request.private_cache {
        return false;
    }
    let Some(cache_control) = cache_control else {
        return true;
    };
    let directives = cache_control_directives(cache_control);
    if directives
        .iter()
        .any(|directive| directive.name.eq_ignore_ascii_case("no-store"))
    {
        return false;
    }
    if directives
        .iter()
        .any(|directive| directive.name.eq_ignore_ascii_case("private"))
        && !request.private_cache
    {
        return false;
    }
    true
}

fn http_metadata_allows_storage(http_metadata: Option<&HttpCacheMetadata>) -> bool {
    http_metadata.is_none_or(|metadata| {
        cache_headers_allow_storage(metadata.cache_control.as_deref(), metadata.vary.as_deref())
    })
}

fn disk_http_metadata_allows_storage(metadata: &DiskCacheHttpMetadata) -> bool {
    cache_headers_allow_storage(metadata.cache_control.as_deref(), metadata.vary.as_deref())
}

fn cache_headers_allow_storage(cache_control: Option<&str>, vary: Option<&str>) -> bool {
    let no_store = cache_control.is_some_and(|value| {
        cache_control_directives(value)
            .iter()
            .any(|directive| directive.name.eq_ignore_ascii_case("no-store"))
    });
    let vary_star = vary.is_some_and(|value| {
        value
            .split(',')
            .any(|name| name.trim().eq_ignore_ascii_case("*"))
    });
    !no_store && !vary_star
}

fn cache_entry_reusable(
    request: &RuntimeRequest,
    metadata: Option<&DiskCacheHttpMetadata>,
) -> RuntimeResult<bool> {
    let Some(metadata) = metadata else {
        return Ok(true);
    };
    if !disk_http_metadata_allows_storage(metadata) {
        return Ok(false);
    }
    let Some(vary) = metadata
        .vary
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    else {
        return Ok(true);
    };
    let Some(stored_key) = metadata.vary_request_key.as_deref() else {
        return Ok(false);
    };
    Ok(http_transport::request_vary_key(vary, &request.headers)?.as_deref() == Some(stored_key))
}

fn evict_request_cache_entries(disk: &DiskCache, request: &RuntimeRequest) -> RuntimeResult<()> {
    let mut memory = memory_cache()
        .lock()
        .map_err(|_| RuntimeError::new("memory_cache", true, "memory cache lock poisoned"))?;
    memory.remove(&request.encoded_cache_key);
    if has_distinct_final_cache_key(request) {
        memory.remove(&request.cache_key);
    }
    drop(memory);
    if request.cache_mode.write_disk() {
        evict_request_disk_cache_entries(disk, request)?;
    }
    Ok(())
}

fn evict_request_disk_cache_entries(
    disk: &DiskCache,
    request: &RuntimeRequest,
) -> RuntimeResult<()> {
    disk.remove(&request.namespace, &request.encoded_cache_key)?;
    if has_distinct_final_cache_key(request) {
        disk.remove(&request.namespace, &request.cache_key)?;
    }
    Ok(())
}

fn effective_ttl_ms_from_disk_metadata(
    request: &RuntimeRequest,
    metadata: &DiskCacheHttpMetadata,
) -> Option<i64> {
    let directives = metadata
        .cache_control
        .as_deref()
        .map(cache_control_directives)
        .unwrap_or_default();
    if directives.iter().any(|directive| {
        directive.name.eq_ignore_ascii_case("no-cache")
            || directive.name.eq_ignore_ascii_case("must-revalidate")
    }) {
        return Some(0);
    }
    let max_age_seconds = directives
        .iter()
        .find(|directive| directive.name.eq_ignore_ascii_case("max-age"))
        .and_then(|directive| directive.value)
        .and_then(|value| value.parse::<i64>().ok());
    let age_seconds = metadata
        .age
        .as_deref()
        .and_then(parse_age_seconds)
        .unwrap_or(0);
    if let Some(max_age_seconds) = max_age_seconds {
        return Some(
            max_age_seconds
                .saturating_sub(age_seconds)
                .max(0)
                .saturating_mul(1000),
        );
    }
    expires_ttl_ms(
        metadata.expires.as_deref(),
        metadata.date.as_deref(),
        metadata.fetched_at_ms,
        age_seconds,
    )
    .or(request.ttl_ms)
}

fn effective_ttl_ms(
    request: &RuntimeRequest,
    http_metadata: Option<&HttpCacheMetadata>,
) -> Option<i64> {
    let directives = http_metadata
        .and_then(|metadata| metadata.cache_control.as_deref())
        .map(cache_control_directives)
        .unwrap_or_default();
    if directives.iter().any(|directive| {
        directive.name.eq_ignore_ascii_case("no-cache")
            || directive.name.eq_ignore_ascii_case("must-revalidate")
    }) {
        return Some(0);
    }
    let max_age_seconds = directives
        .iter()
        .find(|directive| directive.name.eq_ignore_ascii_case("max-age"))
        .and_then(|directive| directive.value)
        .and_then(|value| value.parse::<i64>().ok());
    let age_seconds = http_metadata
        .and_then(|metadata| metadata.age.as_deref())
        .and_then(parse_age_seconds)
        .unwrap_or(0);
    if let Some(max_age_seconds) = max_age_seconds {
        return Some(
            max_age_seconds
                .saturating_sub(age_seconds)
                .max(0)
                .saturating_mul(1000),
        );
    }
    let Some(metadata) = http_metadata else {
        return request.ttl_ms;
    };
    expires_ttl_ms(
        metadata.expires.as_deref(),
        metadata.date.as_deref(),
        Some(metadata.fetched_at_ms),
        age_seconds,
    )
    .or(request.ttl_ms)
}

fn parse_age_seconds(value: &str) -> Option<i64> {
    value.trim().parse::<i64>().ok().map(|age| age.max(0))
}

fn expires_ttl_ms(
    expires: Option<&str>,
    date: Option<&str>,
    fetched_at_ms: Option<i64>,
    age_seconds: i64,
) -> Option<i64> {
    let expires = httpdate::parse_http_date(expires?).ok()?;
    let expires_ms = expires
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_millis()
        .min(i64::MAX as u128) as i64;
    let reference_ms = date
        .and_then(|value| httpdate::parse_http_date(value).ok())
        .and_then(|value| value.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|value| value.as_millis().min(i64::MAX as u128) as i64)
        .or(fetched_at_ms)?;
    Some(
        expires_ms
            .saturating_sub(reference_ms)
            .saturating_sub(age_seconds.saturating_mul(1000))
            .max(0),
    )
}

#[derive(Clone, Copy)]
struct CacheControlDirective<'a> {
    name: &'a str,
    value: Option<&'a str>,
}

fn cache_control_directives(value: &str) -> Vec<CacheControlDirective<'_>> {
    value
        .split(',')
        .filter_map(|directive| {
            let directive = directive.trim();
            if directive.is_empty() {
                return None;
            }
            let (name, value) = directive
                .split_once('=')
                .map_or((directive, None), |(name, value)| {
                    (name.trim(), Some(value.trim().trim_matches('"')))
                });
            Some(CacheControlDirective {
                name: name.trim(),
                value,
            })
        })
        .collect()
}

fn validate_decodable_image(
    bytes: &[u8],
    request: &RuntimeRequest,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<()> {
    if runtime_plugin_decoder_route(bytes, request)?.is_some() {
        return prepare_decodable_image(shared_bytes(bytes.to_vec()), request, progress_sink)
            .map(|_| ());
    }
    validate_supported_image(bytes, &request.limits)
}

fn prepare_decodable_image(
    bytes: SharedBytes,
    request: &RuntimeRequest,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<PreparedImage> {
    if let Some(route) = runtime_plugin_decoder_route(bytes.as_ref(), request)? {
        if let Some(module) = route.module()? {
            emit_progress(
                progress_sink,
                RuntimeProgressEvent::new(
                    RuntimeProgressStage::Decode,
                    "plugin.runtime.decoder.selected",
                )
                .with_message(format!(
                    "{}:{}",
                    module.module_id,
                    route.route_label()
                )),
            );
            let Some((module, executor)) = route.executor()? else {
                return Err(plugin_entrypoint_missing_error(
                    "decode",
                    "decoder",
                    &module.module_id,
                    route.route_label(),
                ));
            };
            let output = executor
                .decode(RuntimePluginDecodeRequest {
                    mime_type: route.mime_type(),
                    format_id: route.format_id(),
                    bytes: bytes.as_ref(),
                    target_width: request.target_width,
                    target_height: request.target_height,
                    max_decoded_pixels: request.limits.max_decoded_pixels,
                    max_output_bytes: request.limits.max_processor_output_bytes,
                })?
                .ok_or_else(|| {
                    plugin_entrypoint_missing_error(
                        "decode",
                        "decoder",
                        &module.module_id,
                        route.route_label(),
                    )
                })?;
            if output.bytes.len() > request.limits.max_processor_output_bytes {
                return Err(RuntimeError::new(
                    "decode",
                    false,
                    "runtime decoder output exceeds max output byte limit",
                ));
            }
            validate_supported_image(output.bytes.as_ref(), &request.limits)?;
            emit_progress(
                progress_sink,
                RuntimeProgressEvent::new(
                    RuntimeProgressStage::Decode,
                    "plugin.runtime.decoder.complete",
                )
                .with_bytes(output.bytes.len(), Some(output.bytes.len()))
                .with_message(format!(
                    "{}:{}",
                    module.module_id,
                    route.route_label()
                )),
            );
            return Ok(PreparedImage {
                bytes: output.bytes,
                transformed: true,
            });
        }
    }
    validate_supported_image(bytes.as_ref(), &request.limits)?;
    Ok(PreparedImage {
        bytes,
        transformed: false,
    })
}

fn validate_supported_image(bytes: &[u8], limits: &RuntimeLimits) -> RuntimeResult<()> {
    validate_encoded_byte_limit(bytes, limits.max_encoded_bytes, "decode")?;
    if !looks_like_supported_image(bytes) {
        return Err(RuntimeError::new(
            "decode",
            false,
            "encoded bytes do not match a supported image signature",
        ));
    }
    if is_gif(bytes) {
        validate_gif_animation_limits(bytes, limits)?;
    } else if is_webp(bytes) {
        validate_webp_animation_limits(bytes, limits)?;
    }
    Ok(())
}

fn validate_cached_image_limits(
    bytes: &[u8],
    request: &RuntimeRequest,
    stage: &'static str,
) -> RuntimeResult<()> {
    validate_encoded_byte_limit(bytes, request.limits.max_encoded_bytes, stage)?;
    let format = select_runtime_image_format(bytes, stage, "cached image")?;
    let _ = preflight_decoded_dimensions(format, bytes, stage, request.limits.max_decoded_pixels)?;
    validate_supported_image(bytes, &request.limits)
}

fn validate_encoded_byte_limit(
    bytes: &[u8],
    max_encoded_bytes: usize,
    stage: &'static str,
) -> RuntimeResult<()> {
    if bytes.len() > max_encoded_bytes {
        return Err(RuntimeError::new(
            stage,
            false,
            "encoded bytes exceed max encoded byte limit",
        ));
    }
    Ok(())
}

fn validate_processed_cache_hit(bytes: &[u8], request: &RuntimeRequest) -> RuntimeResult<()> {
    if bytes.len() > request.limits.max_processor_output_bytes {
        return Err(RuntimeError::new(
            "processor",
            false,
            "cached processor output exceeds max processor output byte limit",
        ));
    }
    Ok(())
}

fn reject_animated_display_input(bytes: &[u8]) -> RuntimeResult<()> {
    if is_gif(bytes) && gif_frame_count(bytes)? > 1 {
        return Err(RuntimeError::new(
            "decode",
            false,
            "animated GIF display input is not supported by runtime RGBA decode",
        ));
    }
    if is_webp(bytes) && webp_animation_frame_count(bytes)? > 1 {
        return Err(RuntimeError::new(
            "decode",
            false,
            "animated WebP display input is not supported by runtime RGBA decode",
        ));
    }
    Ok(())
}

fn preflight_decoded_dimensions(
    format: RuntimeImageFormat,
    bytes: &[u8],
    stage: &'static str,
    max_decoded_pixels: u64,
) -> RuntimeResult<(u32, u32)> {
    let (width, height) = format.dimensions(bytes).map_err(|error| {
        RuntimeError::new(
            stage,
            error.retryable,
            format!(
                "failed to parse image dimensions before decode: {}",
                error.message
            ),
        )
    })?;
    validate_decoded_pixel_count(stage, width, height, max_decoded_pixels)?;
    Ok((width, height))
}

fn validate_decoded_pixel_count(
    stage: &'static str,
    width: u32,
    height: u32,
    max_decoded_pixels: u64,
) -> RuntimeResult<u64> {
    if max_decoded_pixels == 0 {
        return Err(RuntimeError::new(
            stage,
            false,
            "max decoded pixels must be greater than zero",
        ));
    }
    if width == 0 || height == 0 {
        return Err(RuntimeError::new(
            stage,
            false,
            "decoded image dimensions must be greater than zero",
        ));
    }
    let pixels = u64::from(width)
        .checked_mul(u64::from(height))
        .ok_or_else(|| RuntimeError::new(stage, false, "decoded pixel count overflows"))?;
    if pixels > max_decoded_pixels {
        return Err(RuntimeError::new(
            stage,
            false,
            format!("decoded pixel count exceeds limit ({pixels}>{max_decoded_pixels})"),
        ));
    }
    Ok(pixels)
}

fn validate_rgba_display_dimensions(
    width: u32,
    height: u32,
    max_decoded_pixels: u64,
    max_output_bytes: usize,
) -> RuntimeResult<usize> {
    let _ = validate_decoded_pixel_count("decode", width, height, max_decoded_pixels)?;
    let row_bytes = (width as usize)
        .checked_mul(4)
        .ok_or_else(|| RuntimeError::new("decode", false, "RGBA row byte count overflows"))?;
    let output_bytes = row_bytes
        .checked_mul(height as usize)
        .ok_or_else(|| RuntimeError::new("decode", false, "RGBA output byte length overflows"))?;
    if output_bytes > max_output_bytes {
        return Err(RuntimeError::new(
            "decode",
            false,
            format!("RGBA output bytes exceed limit ({output_bytes}>{max_output_bytes})"),
        ));
    }
    Ok(row_bytes)
}

fn plugin_decoder_mime(bytes: &[u8]) -> Option<&'static str> {
    let _ = bytes;
    None
}

#[derive(Clone)]
enum RuntimePluginDecoderRoute<'a> {
    Format {
        format_id: Cow<'a, str>,
        mime_type: Cow<'a, str>,
    },
    Mime {
        mime_type: Cow<'a, str>,
    },
    Signature {
        module: Box<RuntimePluginModule>,
        executor: RuntimePluginExecutorRef,
        format_id: Option<Cow<'a, str>>,
        mime_type: Cow<'a, str>,
    },
}

impl RuntimePluginDecoderRoute<'_> {
    fn route_label(&self) -> &str {
        match self {
            RuntimePluginDecoderRoute::Format { format_id, .. } => format_id,
            RuntimePluginDecoderRoute::Mime { mime_type } => mime_type,
            RuntimePluginDecoderRoute::Signature {
                format_id: Some(format_id),
                ..
            } => format_id,
            RuntimePluginDecoderRoute::Signature { mime_type, .. } => mime_type,
        }
    }

    fn mime_type(&self) -> &str {
        match self {
            RuntimePluginDecoderRoute::Format { mime_type, .. } => mime_type,
            RuntimePluginDecoderRoute::Mime { mime_type } => mime_type,
            RuntimePluginDecoderRoute::Signature { mime_type, .. } => mime_type,
        }
    }

    fn format_id(&self) -> Option<&str> {
        match self {
            RuntimePluginDecoderRoute::Format { format_id, .. } => Some(format_id),
            RuntimePluginDecoderRoute::Mime { .. } => None,
            RuntimePluginDecoderRoute::Signature { format_id, .. } => format_id.as_deref(),
        }
    }

    fn module(&self) -> RuntimeResult<Option<RuntimePluginModule>> {
        match self {
            RuntimePluginDecoderRoute::Format { format_id, .. } => {
                runtime_decoder_for_format_id(format_id)
            }
            RuntimePluginDecoderRoute::Mime { mime_type } => {
                runtime_decoder_for_mime_type(mime_type)
            }
            RuntimePluginDecoderRoute::Signature { module, .. } => Ok(Some((**module).clone())),
        }
    }

    fn executor(&self) -> RuntimeResult<Option<(RuntimePluginModule, RuntimePluginExecutorRef)>> {
        match self {
            RuntimePluginDecoderRoute::Format { format_id, .. } => {
                runtime_decoder_executor_for_format_id(format_id)
            }
            RuntimePluginDecoderRoute::Mime { mime_type } => {
                runtime_decoder_executor_for_mime_type(mime_type)
            }
            RuntimePluginDecoderRoute::Signature {
                module, executor, ..
            } => Ok(Some(((**module).clone(), executor.clone()))),
        }
    }
}

fn runtime_plugin_decoder_route<'a>(
    bytes: &[u8],
    request: &'a RuntimeRequest,
) -> RuntimeResult<Option<RuntimePluginDecoderRoute<'a>>> {
    if let Some(format_id) = request.decoder_format_id.as_deref() {
        let route = RuntimePluginDecoderRoute::Format {
            format_id: Cow::Borrowed(format_id),
            mime_type: Cow::Borrowed(
                request
                    .decoder_mime_type
                    .as_deref()
                    .or_else(|| {
                        sniff_image_format(bytes).map(RuntimeImageFormat::primary_mime_type)
                    })
                    .unwrap_or("application/octet-stream"),
            ),
        };
        if route.module()?.is_some() {
            return Ok(Some(route));
        }
    }
    if let Some(mime_type) = request.decoder_mime_type.as_deref() {
        let route = RuntimePluginDecoderRoute::Mime {
            mime_type: Cow::Borrowed(mime_type),
        };
        if route.module()?.is_some() {
            return Ok(Some(route));
        }
    }
    if let Some(format) = sniff_image_format(bytes) {
        let route = RuntimePluginDecoderRoute::Format {
            format_id: Cow::Borrowed(format.format_id()),
            mime_type: Cow::Borrowed(format.primary_mime_type()),
        };
        if route.module()?.is_some() {
            return Ok(Some(route));
        }
    }
    if let Some(mime_type) = plugin_decoder_mime(bytes) {
        let route = RuntimePluginDecoderRoute::Mime {
            mime_type: Cow::Borrowed(mime_type),
        };
        if route.module()?.is_some() {
            return Ok(Some(route));
        }
    }
    if let Some((module, signature, executor)) = runtime_decoder_executor_for_signature(bytes)? {
        return Ok(Some(RuntimePluginDecoderRoute::Signature {
            module: Box::new(module),
            executor,
            format_id: signature.format_id.map(Cow::Owned),
            mime_type: Cow::Owned(signature.mime_type),
        }));
    }
    Ok(None)
}

fn select_runtime_image_format(
    bytes: &[u8],
    stage: &'static str,
    label: &'static str,
) -> RuntimeResult<RuntimeImageFormat> {
    sniff_image_format(bytes).ok_or_else(|| {
        RuntimeError::new(
            stage,
            false,
            format!("{label} bytes do not match a supported image signature"),
        )
    })
}

fn looks_like_supported_image(bytes: &[u8]) -> bool {
    sniff_image_format(bytes).is_some()
}

fn is_gif(bytes: &[u8]) -> bool {
    bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a")
}

fn is_webp(bytes: &[u8]) -> bool {
    bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP"
}

fn validate_gif_animation_limits(bytes: &[u8], limits: &RuntimeLimits) -> RuntimeResult<()> {
    let metrics = gif_animation_metrics(bytes)?;
    if metrics.frames > limits.max_animation_frames {
        return Err(RuntimeError::new(
            "decode",
            false,
            format!(
                "image animation frame count exceeds limit ({}>{})",
                metrics.frames, limits.max_animation_frames
            ),
        ));
    }
    if metrics.duration_ms > limits.max_animation_duration_ms {
        return Err(RuntimeError::new(
            "decode",
            false,
            format!(
                "image animation duration exceeds limit ({} ms>{} ms)",
                metrics.duration_ms, limits.max_animation_duration_ms
            ),
        ));
    }
    Ok(())
}

fn gif_frame_count(bytes: &[u8]) -> RuntimeResult<usize> {
    Ok(gif_animation_metrics(bytes)?.frames)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct AnimationMetrics {
    frames: usize,
    duration_ms: u64,
}

fn gif_animation_metrics(bytes: &[u8]) -> RuntimeResult<AnimationMetrics> {
    if bytes.len() < 13 {
        return Err(malformed_image("GIF", "missing logical screen descriptor"));
    }

    let mut cursor = 13;
    let global_color_table_bytes = gif_color_table_bytes(bytes[10])?;
    cursor = checked_advance(cursor, global_color_table_bytes, bytes.len(), "GIF")?;

    let mut frames = 0usize;
    let mut pending_delay_ms = 0u64;
    let mut total_duration_ms = 0u64;

    while cursor < bytes.len() {
        match bytes[cursor] {
            0x3b => {
                return Ok(AnimationMetrics {
                    frames,
                    duration_ms: total_duration_ms,
                })
            }
            0x21 => {
                cursor = checked_advance(cursor, 1, bytes.len(), "GIF")?;
                if cursor >= bytes.len() {
                    return Err(malformed_image("GIF", "missing extension label"));
                }
                let label = bytes[cursor];
                cursor = checked_advance(cursor, 1, bytes.len(), "GIF")?;
                if label == 0xf9 {
                    if cursor >= bytes.len() || bytes[cursor] != 4 {
                        return Err(malformed_image("GIF", "invalid graphic control extension"));
                    }
                    cursor = checked_advance(cursor, 1, bytes.len(), "GIF")?;
                    let control = checked_slice(bytes, cursor, 4, "GIF")?;
                    pending_delay_ms = u64::from(u16::from_le_bytes([control[1], control[2]])) * 10;
                    cursor = checked_advance(cursor, 4, bytes.len(), "GIF")?;
                    if cursor >= bytes.len() || bytes[cursor] != 0 {
                        return Err(malformed_image(
                            "GIF",
                            "unterminated graphic control extension",
                        ));
                    }
                    cursor = checked_advance(cursor, 1, bytes.len(), "GIF")?;
                } else {
                    cursor = skip_data_sub_blocks(bytes, cursor, "GIF")?;
                }
            }
            0x2c => {
                let descriptor = checked_slice(bytes, cursor, 10, "GIF")?;
                cursor = checked_advance(cursor, 10, bytes.len(), "GIF")?;
                let local_color_table_bytes = gif_color_table_bytes(descriptor[9])?;
                cursor = checked_advance(cursor, local_color_table_bytes, bytes.len(), "GIF")?;
                cursor = checked_advance(cursor, 1, bytes.len(), "GIF")?;
                cursor = skip_data_sub_blocks(bytes, cursor, "GIF")?;

                frames = frames.saturating_add(1);
                total_duration_ms = total_duration_ms.saturating_add(pending_delay_ms);
                pending_delay_ms = 0;
            }
            _ => return Err(malformed_image("GIF", "unexpected block marker")),
        }
    }

    Err(malformed_image("GIF", "missing trailer"))
}

fn gif_color_table_bytes(packed: u8) -> RuntimeResult<usize> {
    if packed & 0x80 == 0 {
        return Ok(0);
    }
    let colors = 1usize << (usize::from(packed & 0x07) + 1);
    colors
        .checked_mul(3)
        .ok_or_else(|| malformed_image("GIF", "color table length overflow"))
}

fn validate_webp_animation_limits(bytes: &[u8], limits: &RuntimeLimits) -> RuntimeResult<()> {
    let metrics = webp_animation_metrics(bytes)?;
    if metrics.frames > limits.max_animation_frames {
        return Err(RuntimeError::new(
            "decode",
            false,
            format!(
                "image animation frame count exceeds limit ({}>{})",
                metrics.frames, limits.max_animation_frames
            ),
        ));
    }
    if metrics.duration_ms > limits.max_animation_duration_ms {
        return Err(RuntimeError::new(
            "decode",
            false,
            format!(
                "image animation duration exceeds limit ({} ms>{} ms)",
                metrics.duration_ms, limits.max_animation_duration_ms
            ),
        ));
    }
    Ok(())
}

fn webp_animation_frame_count(bytes: &[u8]) -> RuntimeResult<usize> {
    Ok(webp_animation_metrics(bytes)?.frames)
}

fn webp_animation_metrics(bytes: &[u8]) -> RuntimeResult<AnimationMetrics> {
    let riff_payload_len = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]) as usize;
    let declared_end = 8usize
        .checked_add(riff_payload_len)
        .ok_or_else(|| malformed_image("WebP", "RIFF length overflow"))?;
    if declared_end < 12 {
        return Err(malformed_image("WebP", "RIFF payload missing form type"));
    }
    if declared_end > bytes.len() {
        return Err(malformed_image("WebP", "truncated RIFF payload"));
    }

    let mut cursor = 12usize;
    let mut has_animation_flag = false;
    let mut frames = 0usize;
    let mut total_duration_ms = 0u64;

    while cursor < declared_end {
        let header = checked_slice(bytes, cursor, 8, "WebP")?;
        let fourcc = &header[0..4];
        let chunk_len = u32::from_le_bytes([header[4], header[5], header[6], header[7]]) as usize;
        cursor = checked_advance(cursor, 8, declared_end, "WebP")?;
        let chunk_end = checked_advance(cursor, chunk_len, declared_end, "WebP")?;

        match fourcc {
            b"VP8X" => {
                let payload = checked_slice(bytes, cursor, chunk_len, "WebP")?;
                if payload.len() < 10 {
                    return Err(malformed_image("WebP", "invalid VP8X chunk"));
                }
                has_animation_flag |= payload[0] & 0x02 != 0;
            }
            b"ANMF" => {
                let payload = checked_slice(bytes, cursor, chunk_len, "WebP")?;
                if payload.len() < 16 {
                    return Err(malformed_image("WebP", "invalid ANMF chunk"));
                }
                has_animation_flag = true;
                frames = frames.saturating_add(1);

                let frame_duration_ms = read_u24_le(&payload[12..15]);
                total_duration_ms = total_duration_ms.saturating_add(frame_duration_ms);
            }
            _ => {}
        }

        cursor = chunk_end;
        if chunk_len % 2 == 1 {
            cursor = checked_advance(cursor, 1, declared_end, "WebP")?;
        }
    }

    if has_animation_flag && frames == 0 {
        return Err(malformed_image("WebP", "animation flag set without frames"));
    }
    Ok(AnimationMetrics {
        frames,
        duration_ms: total_duration_ms,
    })
}

fn skip_data_sub_blocks(
    bytes: &[u8],
    mut cursor: usize,
    format: &'static str,
) -> RuntimeResult<usize> {
    loop {
        if cursor >= bytes.len() {
            return Err(malformed_image(format, "unterminated data sub-block"));
        }
        let block_len = usize::from(bytes[cursor]);
        cursor = checked_advance(cursor, 1, bytes.len(), format)?;
        if block_len == 0 {
            return Ok(cursor);
        }
        cursor = checked_advance(cursor, block_len, bytes.len(), format)?;
    }
}

fn checked_slice<'a>(
    bytes: &'a [u8],
    offset: usize,
    length: usize,
    format: &'static str,
) -> RuntimeResult<&'a [u8]> {
    let end = checked_advance(offset, length, bytes.len(), format)?;
    Ok(&bytes[offset..end])
}

fn checked_advance(
    offset: usize,
    length: usize,
    limit: usize,
    format: &'static str,
) -> RuntimeResult<usize> {
    let end = offset
        .checked_add(length)
        .ok_or_else(|| malformed_image(format, "container offset overflow"))?;
    if end > limit {
        return Err(malformed_image(format, "truncated container block"));
    }
    Ok(end)
}

fn read_u24_le(bytes: &[u8]) -> u64 {
    u64::from(bytes[0]) | (u64::from(bytes[1]) << 8) | (u64::from(bytes[2]) << 16)
}

fn malformed_image(format: &'static str, reason: &'static str) -> RuntimeError {
    RuntimeError::new(
        "decode",
        false,
        format!("malformed {format} image: {reason}"),
    )
}

fn file_label(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .map(|name| format!("file:{name}"))
        .unwrap_or_else(|| "file:<unknown>".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cancel::{
        cancel_token, cancel_token_handle, create_cancel_token, free_cancel_token,
    };
    use crate::plugin_host::{
        clear_plugin_registry_for_test, plugin_registry_test_guard, register_plugin_module,
        register_plugin_module_with_executor, RuntimePluginCapabilities,
        RuntimePluginDecodeRequest, RuntimePluginDecoderSignature, RuntimePluginExecutor,
        RuntimePluginFetchRequest, RuntimePluginModule, RuntimePluginOutput,
        RuntimePluginProcessRequest, RuntimePluginRoutes,
    };
    use crate::request::{RuntimeLimits, RuntimePriority, RuntimeRedirectPolicy};
    use image::ImageEncoder;
    use std::collections::BTreeMap;
    use std::io::{Cursor, Read, Write};
    use std::net::Shutdown;
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::{Arc, Barrier, Mutex};
    use std::thread;
    use std::time::{Duration, Instant};

    static TEST_ROOT_COUNTER: AtomicUsize = AtomicUsize::new(0);

    #[derive(Default)]
    struct CapturingProgressSink {
        events: Mutex<Vec<RuntimeProgressEvent>>,
    }

    impl CapturingProgressSink {
        fn names(&self) -> Vec<String> {
            self.events
                .lock()
                .expect("progress events lock should not be poisoned")
                .iter()
                .map(|event| event.name.clone())
                .collect()
        }
    }

    impl RuntimeProgressSink for CapturingProgressSink {
        fn emit(&self, event: RuntimeProgressEvent) {
            self.events
                .lock()
                .expect("progress events lock should not be poisoned")
                .push(event);
        }
    }

    struct ReplacingFileProgressSink {
        path: std::path::PathBuf,
        replacement: Vec<u8>,
    }

    impl RuntimeProgressSink for ReplacingFileProgressSink {
        fn emit(&self, event: RuntimeProgressEvent) {
            if event.name == "fetch.file" {
                std::fs::write(&self.path, &self.replacement)
                    .expect("test should replace file after metadata validation");
            }
        }
    }

    #[test]
    fn coalesces_concurrent_runtime_loads_for_same_key() {
        let server = SlowImageServer::spawn(minimal_gif(1, 0));
        let mut request = network_request(server.url.clone(), "runtime-coalesced-key");
        request.cache_mode = CacheMode::MemoryOnly;
        let barrier = Arc::new(Barrier::new(3));
        let first_barrier = barrier.clone();
        let second_barrier = barrier.clone();
        let first_request = request.clone();
        let second_request = request.clone();

        let first = thread::spawn(move || {
            first_barrier.wait();
            load_image("", first_request, None).expect("first load should complete");
        });
        let second = thread::spawn(move || {
            second_barrier.wait();
            load_image("", second_request, None).expect("second load should complete");
        });

        barrier.wait();
        first.join().unwrap();
        second.join().unwrap();
        let request_count = server.stop();

        assert_eq!(request_count, 1);
    }

    #[test]
    fn coalesces_origin_fetch_for_different_variant_keys() {
        let server = SlowImageServer::spawn(minimal_gif(1, 0));
        let mut small_request =
            network_request(server.url.clone(), "runtime-origin-coalesced-small");
        small_request.cache_mode = CacheMode::MemoryOnly;
        let mut large_request =
            network_request(server.url.clone(), "runtime-origin-coalesced-large");
        large_request.cache_mode = CacheMode::MemoryOnly;
        large_request.encoded_cache_key = small_request.encoded_cache_key.clone();
        let barrier = Arc::new(Barrier::new(3));
        let small_barrier = barrier.clone();
        let large_barrier = barrier.clone();

        let small = thread::spawn(move || {
            small_barrier.wait();
            load_image("", small_request, None).expect("small variant should complete");
        });
        let large = thread::spawn(move || {
            large_barrier.wait();
            load_image("", large_request, None).expect("large variant should complete");
        });

        barrier.wait();
        small.join().unwrap();
        large.join().unwrap();
        let request_count = server.stop();

        assert_eq!(request_count, 1);
    }

    #[test]
    fn coalesces_large_origin_fetch_fanout_for_variant_keys() {
        let server = SlowImageServer::spawn(minimal_gif(1, 0));
        let mut base_request = network_request(server.url.clone(), "runtime-origin-fanout-base");
        base_request.cache_mode = CacheMode::MemoryOnly;
        base_request.encoded_cache_key = "runtime-origin-fanout-encoded".to_string();
        let fanout = 512;
        let barrier = Arc::new(Barrier::new(fanout + 1));
        let mut handles = Vec::with_capacity(fanout);

        for index in 0..fanout {
            let mut request = base_request.clone();
            request.cache_key = format!("runtime-origin-fanout-{index:016x}");
            let request_barrier = barrier.clone();
            handles.push(thread::spawn(move || {
                request_barrier.wait();
                load_image("", request, None).expect("fanout variant should complete");
            }));
        }

        barrier.wait();
        for handle in handles {
            handle.join().unwrap();
        }
        let request_count = server.stop();

        assert_eq!(request_count, 1);
    }

    #[test]
    fn coalesces_origin_fetch_without_merging_cache_side_effects() {
        let server =
            SlowImageServer::spawn_with_delay(minimal_gif(1, 0), Duration::from_millis(500));
        let root = temp_cache_root("cache-side-effects");
        let mut disk_request = network_request(server.url.clone(), "0123456789abcdea");
        disk_request.cache_mode = CacheMode::DiskOnly;
        disk_request.encoded_cache_key = "0123456789abcdeb".to_string();
        let mut memory_request = disk_request.clone();
        memory_request.cache_mode = CacheMode::MemoryOnly;
        let encoded_key = disk_request.encoded_cache_key.clone();
        let leader_root = root.clone();

        let leader = thread::spawn(move || {
            load_image(&leader_root, disk_request, None).expect("disk-only leader should complete");
        });
        server.wait_for_requests(1);
        let follower = thread::spawn(move || {
            load_image("", memory_request, None).expect("memory follower should complete");
        });

        leader.join().unwrap();
        follower.join().unwrap();
        let request_count = server.stop();
        let memory_had_entry = memory_remove(&encoded_key).unwrap();
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(request_count, 1);
        assert!(memory_had_entry);
    }

    #[test]
    fn coalesces_uncached_origin_fetch_without_merging_cache_side_effects() {
        let server =
            SlowImageServer::spawn_with_delay(minimal_gif(1, 0), Duration::from_millis(500));
        let mut uncached_request =
            network_request(server.url.clone(), "runtime-uncached-origin-leader");
        uncached_request.cache_mode = CacheMode::NoStore;
        uncached_request.encoded_cache_key = "runtime-uncached-origin-encoded".to_string();
        let mut memory_request = uncached_request.clone();
        memory_request.cache_key = "runtime-uncached-origin-follower".to_string();
        memory_request.cache_mode = CacheMode::MemoryOnly;
        let encoded_key = uncached_request.encoded_cache_key.clone();

        let leader = thread::spawn(move || {
            load_image("", uncached_request, None).expect("uncached leader should complete");
        });
        server.wait_for_requests(1);
        let follower = thread::spawn(move || {
            load_image("", memory_request, None).expect("memory follower should complete");
        });

        leader.join().unwrap();
        follower.join().unwrap();
        let request_count = server.stop();
        let memory_had_entry = memory_remove(&encoded_key).unwrap();

        assert_eq!(request_count, 1);
        assert!(memory_had_entry);
    }

    #[test]
    fn coalesces_video_frame_origin_fetch_without_merging_processed_variants() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.fetcher = true;
        let executor = Arc::new(VideoFrameRuntimePluginExecutor::default());
        register_plugin_module_with_executor(
            RuntimePluginModule::built_in("pixa.video_frame.test", capabilities).with_routes(
                RuntimePluginRoutes {
                    fetcher_source_kinds: vec!["video-frame:platform".to_string()],
                    video_frame_output_mime_types: vec!["image/png".to_string()],
                    ..RuntimePluginRoutes::default()
                },
            ),
            executor.clone(),
        )
        .expect("video frame runtime fetcher should register");

        let mut small_request = video_frame_request("video-frame-shared-small-final");
        small_request.cache_mode = CacheMode::MemoryOnly;
        small_request.processors =
            vec!["resize(width=1,height=1,mode=exact,filter=nearest)".to_string()];
        let mut large_request = video_frame_request("video-frame-shared-large-final");
        large_request.cache_mode = CacheMode::MemoryOnly;
        large_request.processors =
            vec!["resize(width=2,height=2,mode=exact,filter=nearest)".to_string()];
        assert_eq!(
            small_request.encoded_cache_key,
            large_request.encoded_cache_key
        );
        assert_ne!(small_request.cache_key, large_request.cache_key);
        let barrier = Arc::new(Barrier::new(3));
        let small_barrier = barrier.clone();
        let large_barrier = barrier.clone();

        let small = thread::spawn(move || {
            small_barrier.wait();
            load_image("", small_request, None).expect("small video frame variant should complete")
        });
        let large = thread::spawn(move || {
            large_barrier.wait();
            load_image("", large_request, None).expect("large video frame variant should complete")
        });

        barrier.wait();
        let small_outcome = small.join().unwrap();
        let large_outcome = large.join().unwrap();
        let small_decoded =
            image::load_from_memory(&small_outcome.bytes).expect("small variant should decode");
        let large_decoded =
            image::load_from_memory(&large_outcome.bytes).expect("large variant should decode");
        let observed = executor.observed();

        assert_eq!(executor.fetch_count.load(Ordering::Relaxed), 1);
        assert_eq!(small_decoded.dimensions(), (1, 1));
        assert_eq!(large_decoded.dimensions(), (2, 2));
        assert_eq!(
            small_outcome.source_label,
            "processed:runtime-plugin:video-frame:platform"
        );
        assert_eq!(
            large_outcome.source_label,
            "processed:runtime-plugin:video-frame:platform"
        );
        assert!(memory_get_processed("video-frame-shared-small-final")
            .expect("processed memory lookup should succeed")
            .is_some());
        assert!(memory_get_processed("video-frame-shared-large-final")
            .expect("processed memory lookup should succeed")
            .is_some());
        assert_eq!(observed.len(), 1);
        assert_eq!(observed[0].source_kind, "video-frame:platform");
        assert_eq!(observed[0].locator, "file:///clips/sample.mp4?token=secret");
        assert_eq!(observed[0].timestamp_micros, 1_500_000);
        assert!(observed[0].exact);
        assert_eq!(observed[0].backend.as_deref(), Some("platform"));
        clear_plugin_registry_for_test();
    }

    #[test]
    fn rejects_video_frame_output_mime_outside_contract() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.fetcher = true;
        register_plugin_module_with_executor(
            RuntimePluginModule::built_in("pixa.video_frame.test", capabilities).with_routes(
                RuntimePluginRoutes {
                    fetcher_source_kinds: vec!["video-frame:platform".to_string()],
                    video_frame_output_mime_types: vec!["image/gif".to_string()],
                    ..RuntimePluginRoutes::default()
                },
            ),
            Arc::new(VideoFrameRuntimePluginExecutor::default()),
        )
        .expect("video frame runtime fetcher should register");

        let mut request = video_frame_request("video-frame-bad-output-mime");
        request.cache_mode = CacheMode::NoStore;

        let error = load_image("", request, None)
            .expect_err("video frame output outside its MIME contract must fail");

        assert_eq!(error.stage, "fetch");
        assert!(error
            .message
            .contains("video-frame fetcher output MIME image/png is not declared"));
        clear_plugin_registry_for_test();
    }

    #[test]
    fn rejects_video_frame_output_without_mime() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.fetcher = true;
        register_plugin_module_with_executor(
            RuntimePluginModule::built_in("pixa.video_frame.test", capabilities).with_routes(
                RuntimePluginRoutes {
                    fetcher_source_kinds: vec!["video-frame:platform".to_string()],
                    video_frame_output_mime_types: vec!["image/png".to_string()],
                    ..RuntimePluginRoutes::default()
                },
            ),
            Arc::new(VideoFrameRuntimePluginExecutor {
                output_mime: None,
                ..VideoFrameRuntimePluginExecutor::default()
            }),
        )
        .expect("video frame runtime fetcher should register");

        let mut request = video_frame_request("video-frame-missing-output-mime");
        request.cache_mode = CacheMode::NoStore;

        let error = load_image("", request, None).expect_err("video frame output MIME is required");

        assert_eq!(error.stage, "fetch");
        assert!(error
            .message
            .contains("returned bytes without an output MIME"));
        clear_plugin_registry_for_test();
    }

    #[test]
    fn origin_fetch_key_separates_distinct_inline_payloads() {
        let request = bytes_request(RuntimeLimits::default());
        let first = minimal_gif(1, 0);
        let second = minimal_gif(2, 10);

        let first_key = runtime_inflight_fetch_key(&request, None, Some(&first));
        let second_key = runtime_inflight_fetch_key(&request, None, Some(&second));

        assert_ne!(first_key, second_key);
        assert!(runtime_inline_bytes_identity(Some(&first)).starts_with("sha256:"));
    }

    #[test]
    fn inflight_keys_are_cryptographic_and_do_not_expose_secrets() {
        let mut request = bytes_request(RuntimeLimits::default());
        request.source = RuntimeSource::RuntimePlugin {
            source_kind: "s3".to_string(),
            locator: "s3://private-bucket/image.gif?signature=locator-secret".to_string(),
        };
        request.headers.insert(
            "authorization".to_string(),
            "Bearer authorization-secret".to_string(),
        );
        request
            .headers
            .insert("cookie".to_string(), "session=cookie-secret".to_string());
        request.headers.insert(
            "x-pixa-s3-secret-access-key".to_string(),
            "s3-header-secret".to_string(),
        );
        let mut different_secret = request.clone();
        different_secret.headers.insert(
            "authorization".to_string(),
            "Bearer different-secret".to_string(),
        );

        let full_key = runtime_inflight_key("/cache", &request);
        let fetch_key = runtime_inflight_fetch_key(&request, None, None);
        let headers_key = runtime_headers_identity(&request);
        let source_key = source_identity(&request.source);
        for key in [&full_key, &fetch_key, &headers_key, &source_key] {
            assert!(key.starts_with("sha256:"), "unexpected identity: {key}");
            for secret in [
                "authorization-secret",
                "cookie-secret",
                "s3-header-secret",
                "locator-secret",
                "private-bucket",
            ] {
                assert!(!key.contains(secret), "identity exposed {secret}: {key}");
            }
        }
        assert_ne!(full_key, runtime_inflight_key("/cache", &different_secret));
        assert_ne!(
            fetch_key,
            runtime_inflight_fetch_key(&different_secret, None, None)
        );
    }

    #[test]
    fn canonical_header_identity_resists_delimiter_collisions() {
        let mut first = bytes_request(RuntimeLimits::default());
        first
            .headers
            .insert("a".to_string(), "b\u{1e}c=d".to_string());
        let mut second = bytes_request(RuntimeLimits::default());
        second.headers.insert("a".to_string(), "b".to_string());
        second.headers.insert("c".to_string(), "d".to_string());

        assert_ne!(
            runtime_headers_identity(&first),
            runtime_headers_identity(&second)
        );
        assert_ne!(
            runtime_inflight_fetch_key(&first, None, None),
            runtime_inflight_fetch_key(&second, None, None)
        );
    }

    #[test]
    fn canonical_full_load_identity_resists_processor_delimiter_collisions() {
        let mut first = bytes_request(RuntimeLimits::default());
        first.processors = vec!["a\u{1f}b".to_string(), "c".to_string()];
        let mut second = first.clone();
        second.processors = vec!["a".to_string(), "b\u{1f}c".to_string()];

        assert_ne!(
            runtime_inflight_key("/cache", &first),
            runtime_inflight_key("/cache", &second)
        );
    }

    #[test]
    fn runtime_fetch_key_normalizes_plugin_source_kind_without_locator_leak() {
        let mut first = bytes_request(RuntimeLimits::default());
        first.source = RuntimeSource::RuntimePlugin {
            source_kind: "S3".to_string(),
            locator: "s3://bucket/key.gif?X-Amz-Signature=secret-token".to_string(),
        };
        first.encoded_cache_key = "runtime-plugin-origin".to_string();
        let mut second = first.clone();
        second.source = RuntimeSource::RuntimePlugin {
            source_kind: "s3".to_string(),
            locator: "s3://bucket/key.gif?X-Amz-Signature=secret-token".to_string(),
        };

        let first_key = runtime_inflight_fetch_key(&first, None, None);
        let second_key = runtime_inflight_fetch_key(&second, None, None);

        assert_eq!(first_key, second_key);
        assert!(!first_key.contains("secret-token"));
        assert!(!first_key.contains("bucket/key.gif"));
    }

    #[test]
    fn recovers_corrupt_disk_entry_and_fetches_fresh_bytes() {
        let fresh_image = minimal_gif(1, 0);
        let stale_image = minimal_gif(1, 5);
        let server = SlowImageServer::spawn(fresh_image.clone());
        let root = temp_cache_root("disk-corruption-recovery");
        let mut request = network_request(server.url.clone(), "0123456789abcdf0");
        request.cache_mode = CacheMode::DiskOnly;
        request.encoded_cache_key = "0123456789abcdf1".to_string();
        let disk = DiskCache::new(&root);
        disk.write(
            &request.namespace,
            &request.encoded_cache_key,
            &stale_image,
            Some(60_000),
        )
        .expect("seed disk cache entry should be written");
        let data_path = disk
            .entry_paths(&request.namespace, &request.encoded_cache_key)
            .expect("cache entry path should resolve")
            .data;
        std::fs::write(data_path, b"corrupt").expect("test should be able to corrupt cache data");
        let before = cache_stats().expect("cache stats should be available");

        let outcome = load_image(&root, request.clone(), None)
            .expect("corrupt disk entry should recover as a cache miss");

        let request_count = server.count.load(Ordering::Relaxed);
        let _ = server.stop();
        let after = cache_stats().expect("cache stats should be available");
        let recovered = match disk
            .read_entry(&request.namespace, &request.encoded_cache_key)
            .expect("rewritten disk entry should be readable")
        {
            DiskCacheRead::Hit(entry) => entry.bytes,
            other => panic!("expected rewritten disk hit, got {other:?}"),
        };
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(outcome.bytes.as_ref(), fresh_image.as_slice());
        assert_eq!(recovered, fresh_image);
        assert_eq!(request_count, 1);
        assert!(after.disk_misses > before.disk_misses);
        assert!(after.disk_corruption_recoveries > before.disk_corruption_recoveries);
    }

    #[test]
    fn revalidates_expired_disk_entry_with_304() {
        let stale_image = minimal_gif(1, 0);
        let server = OneShotHttpServer::spawn(
            "HTTP/1.1 304 Not Modified\r\nETag: \"v1\"\r\nCache-Control: max-age=60\r\nAge: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .to_string(),
        );
        let root = temp_cache_root("disk-304-revalidate");
        let mut request = network_request(server.url.clone(), "0123456789abcde1");
        request.cache_mode = CacheMode::DiskOnly;
        request.encoded_cache_key = "0123456789abcde2".to_string();
        let disk = DiskCache::new(&root);
        disk.write_with_http_metadata(
            &request.namespace,
            &request.encoded_cache_key,
            &stale_image,
            Some(-1),
            Some(&DiskCacheHttpMetadata {
                etag: Some("\"v1\"".to_string()),
                cache_control: Some("max-age=0".to_string()),
                fetched_at_ms: Some(now_millis().saturating_sub(1_000)),
                ..Default::default()
            }),
        )
        .expect("stale disk entry should be seeded");

        let outcome = load_image(&root, request.clone(), None)
            .expect("304 revalidate should reuse stale encoded bytes");

        let raw_request = server.join().to_ascii_lowercase();
        let revalidated = match disk
            .read_entry(&request.namespace, &request.encoded_cache_key)
            .expect("revalidated disk entry should be readable")
        {
            DiskCacheRead::Hit(entry) => entry,
            other => panic!("expected revalidated disk hit, got {other:?}"),
        };
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(outcome.bytes.as_ref(), stale_image.as_slice());
        assert!(raw_request.contains("if-none-match: \"v1\""));
        assert!(!revalidated.is_expired);
        assert_eq!(
            revalidated.http.cache_control.as_deref(),
            Some("max-age=60")
        );
    }

    #[test]
    fn private_304_response_removes_previously_public_disk_entry() {
        let stale_image = minimal_gif(1, 0);
        let server = OneShotHttpServer::spawn(
            "HTTP/1.1 304 Not Modified\r\nETag: \"v2\"\r\nCache-Control: private, max-age=60\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .to_string(),
        );
        let root = temp_cache_root("private-disk-304");
        let mut request = network_request(server.url.clone(), "0123456789abcde3");
        request.cache_mode = CacheMode::DiskOnly;
        request.encoded_cache_key = "0123456789abcde4".to_string();
        let disk = DiskCache::new(&root);
        disk.write_with_http_metadata(
            &request.namespace,
            &request.encoded_cache_key,
            &stale_image,
            Some(-1),
            Some(&DiskCacheHttpMetadata {
                etag: Some("\"v1\"".to_string()),
                cache_control: Some("max-age=0".to_string()),
                fetched_at_ms: Some(now_millis().saturating_sub(1_000)),
                ..Default::default()
            }),
        )
        .expect("public stale disk entry should be seeded");

        let outcome = load_image(&root, request.clone(), None)
            .expect("private 304 response should still reuse the validated bytes");
        server.join();
        let disk_read = disk
            .read_entry(&request.namespace, &request.encoded_cache_key)
            .expect("post-revalidation disk lookup should succeed");
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(outcome.bytes.as_ref(), stale_image.as_slice());
        assert!(matches!(disk_read, DiskCacheRead::Miss));
    }

    #[test]
    fn network_200_writes_disk_entry_with_http_metadata_for_cache_only_reuse() {
        let image = minimal_gif(1, 0);
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nETag: \"disk-v1\"\r\nLast-Modified: Wed, 21 Oct 2015 07:28:00 GMT\r\nCache-Control: max-age=60\r\nExpires: Wed, 21 Oct 2030 07:28:00 GMT\r\nAge: 1\r\nVary: Accept\r\nConnection: close\r\n\r\n",
            image.len()
        )
        .into_bytes();
        response.extend_from_slice(&image);
        let server = OneShotHttpServer::spawn(response);
        let root = temp_cache_root("network-disk-write");
        let mut request = network_request(server.url.clone(), "0123456789abcdf3");
        request.cache_mode = CacheMode::DiskOnly;
        request.encoded_cache_key = "0123456789abcdf4".to_string();
        request
            .headers
            .insert("accept".to_string(), "image/gif".to_string());
        let disk = DiskCache::new(&root);

        let fetched = load_image(&root, request.clone(), None)
            .expect("200 network response should load and write disk cache");
        let raw_request = server.join().to_ascii_lowercase();
        let disk_entry = match disk
            .read_entry(&request.namespace, &request.encoded_cache_key)
            .expect("disk entry should be readable after 200")
        {
            DiskCacheRead::Hit(entry) => entry,
            other => panic!("expected disk hit after 200, got {other:?}"),
        };
        let mut cache_only = request.clone();
        cache_only.cache_mode = CacheMode::CacheOnly;
        let cached = load_image(&root, cache_only, None)
            .expect("cache-only request should reuse disk entry without network");
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(fetched.bytes.as_ref(), image.as_slice());
        assert_eq!(cached.bytes.as_ref(), image.as_slice());
        assert!(raw_request.contains("accept: image/gif"));
        assert_eq!(disk_entry.bytes, image);
        assert!(!disk_entry.is_expired);
        assert_eq!(disk_entry.http.etag.as_deref(), Some("\"disk-v1\""));
        assert_eq!(
            disk_entry.http.last_modified.as_deref(),
            Some("Wed, 21 Oct 2015 07:28:00 GMT")
        );
        assert_eq!(disk_entry.http.cache_control.as_deref(), Some("max-age=60"));
        assert_eq!(
            disk_entry.http.expires.as_deref(),
            Some("Wed, 21 Oct 2030 07:28:00 GMT")
        );
        assert_eq!(disk_entry.http.age.as_deref(), Some("1"));
        assert_eq!(disk_entry.http.vary.as_deref(), Some("Accept"));
    }

    #[test]
    fn http_no_store_prevents_encoded_memory_and_disk_writes() {
        let image = minimal_gif(1, 0);
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
            image.len()
        )
        .into_bytes();
        response.extend_from_slice(&image);
        let server = FixedResponseServer::spawn(response);
        let root = temp_cache_root("http-no-store");
        let mut request = network_request(server.url.clone(), "9999000011112222");
        request.cache_mode = CacheMode::MemoryAndDisk;
        request.encoded_cache_key = "9999000011112223".to_string();
        let disk = DiskCache::new(&root);

        load_image(&root, request.clone(), None).expect("no-store response should still load");

        let memory_had_entry = memory_remove(&request.encoded_cache_key).unwrap();
        let disk_read = disk
            .read_entry(&request.namespace, &request.encoded_cache_key)
            .expect("disk lookup should succeed");
        let request_count = server.stop();
        let _ = std::fs::remove_dir_all(root);

        assert!(
            !memory_had_entry,
            "no-store must prevent encoded memory writes"
        );
        assert!(matches!(disk_read, DiskCacheRead::Miss));
        assert_eq!(request_count, 1);
    }

    #[test]
    fn repeated_cache_control_fields_preserve_no_store() {
        let image = minimal_gif(1, 0);
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nCache-Control: max-age=60\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
            image.len()
        )
        .into_bytes();
        response.extend_from_slice(&image);
        let server = OneShotHttpServer::spawn(response);
        let root = temp_cache_root("repeated-cache-control");
        let mut request = network_request(server.url.clone(), "9999000011112242");
        request.cache_mode = CacheMode::MemoryAndDisk;
        request.encoded_cache_key = "9999000011112243".to_string();

        load_image(&root, request.clone(), None).expect("response should load");
        server.join();

        assert!(!memory_remove(&request.encoded_cache_key).unwrap());
        assert!(matches!(
            DiskCache::new(&root)
                .read_entry(&request.namespace, &request.encoded_cache_key)
                .unwrap(),
            DiskCacheRead::Miss
        ));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn http_no_store_prevents_processed_memory_and_disk_writes() {
        let image = minimal_gif(1, 0);
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
            image.len()
        )
        .into_bytes();
        response.extend_from_slice(&image);
        let server = OneShotHttpServer::spawn(response);
        let root = temp_cache_root("http-no-store-processed");
        let mut request = network_request(server.url.clone(), "9999000011113332");
        request.cache_mode = CacheMode::MemoryAndDisk;
        request.encoded_cache_key = "9999000011113333".to_string();
        request.processors = vec!["resize(width=1,height=1,mode=exact,filter=nearest)".to_string()];
        let disk = DiskCache::new(&root);

        load_image(&root, request.clone(), None)
            .expect("processed no-store response should still load");
        server.join();

        let encoded_memory = memory_remove(&request.encoded_cache_key).unwrap();
        let processed_memory = memory_remove(&request.cache_key).unwrap();
        let encoded_disk = disk
            .read_entry(&request.namespace, &request.encoded_cache_key)
            .unwrap();
        let processed_disk = disk
            .read_entry(&request.namespace, &request.cache_key)
            .unwrap();
        let _ = std::fs::remove_dir_all(root);

        assert!(!encoded_memory);
        assert!(!processed_memory);
        assert!(matches!(encoded_disk, DiskCacheRead::Miss));
        assert!(matches!(processed_disk, DiskCacheRead::Miss));
    }

    #[test]
    fn expires_and_age_define_remaining_ttl_without_cache_control() {
        let request = network_request("http://127.0.0.1/image.gif".to_string(), "ttl-test");
        let http = HttpCacheMetadata {
            expires: Some("Thu, 01 Jan 1970 00:02:00 GMT".to_string()),
            age: Some("30".to_string()),
            fetched_at_ms: 60_000,
            ..Default::default()
        };
        let disk = DiskCacheHttpMetadata::from(&http);

        assert_eq!(effective_ttl_ms(&request, Some(&http)), Some(30_000));
        assert_eq!(
            effective_ttl_ms_from_disk_metadata(&request, &disk),
            Some(30_000)
        );
    }

    #[test]
    fn expires_uses_response_date_before_local_fetch_time() {
        let request = network_request("http://127.0.0.1/image.gif".to_string(), "date-ttl-test");
        let http = HttpCacheMetadata {
            date: Some("Thu, 01 Jan 1970 00:01:00 GMT".to_string()),
            expires: Some("Thu, 01 Jan 1970 00:02:00 GMT".to_string()),
            age: Some("30".to_string()),
            fetched_at_ms: 0,
            ..Default::default()
        };

        assert_eq!(effective_ttl_ms(&request, Some(&http)), Some(30_000));
    }

    #[test]
    fn encoded_disk_hit_does_not_extend_remaining_ttl_in_memory() {
        let body = minimal_gif(1, 0);
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes();
        response.extend_from_slice(&body);
        let server = FixedResponseServer::spawn(response);
        let root = temp_cache_root("disk-memory-ttl");
        let mut request = network_request(server.url.clone(), "aaaabbbb00000001");
        request.encoded_cache_key = "aaaabbbb00000002".to_string();
        request.cache_mode = CacheMode::MemoryAndDisk;
        request.ttl_ms = Some(60_000);
        DiskCache::new(&root)
            .write(
                &request.namespace,
                &request.encoded_cache_key,
                &body,
                Some(40),
            )
            .expect("short-lived disk entry should write");

        load_image(&root, request.clone(), None).expect("fresh disk response should load");
        thread::sleep(Duration::from_millis(60));
        load_image(&root, request, None).expect("expired disk response should refetch");

        let request_count = server.stop();
        let _ = std::fs::remove_dir_all(root);
        assert_eq!(request_count, 1);
    }

    #[test]
    fn http_age_expiry_is_not_extended_by_processed_memory_cache() {
        let body = minimal_png(2, 2);
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nCache-Control: max-age=60\r\nAge: 60\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes();
        response.extend_from_slice(&body);
        let server = FixedResponseServer::spawn(response);
        let root = temp_cache_root("http-processed-memory-ttl");
        let mut request = network_request(server.url.clone(), "aaaabbbb00000003");
        request.encoded_cache_key = "aaaabbbb00000004".to_string();
        request.cache_mode = CacheMode::MemoryAndDisk;
        request.ttl_ms = Some(60_000);
        request.processors = vec!["resize(width=1,height=1,mode=exact,filter=nearest)".to_string()];

        load_image(&root, request.clone(), None).expect("first response should process");
        thread::sleep(Duration::from_millis(2));
        load_image(&root, request, None).expect("expired processed response should refetch");

        let request_count = server.stop();
        let _ = std::fs::remove_dir_all(root);
        assert_eq!(request_count, 2);
    }

    #[test]
    fn vary_star_prevents_memory_and_disk_reuse() {
        let image = minimal_gif(1, 0);
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nCache-Control: max-age=60\r\nVary: *\r\nConnection: close\r\n\r\n",
            image.len()
        )
        .into_bytes();
        response.extend_from_slice(&image);
        let server = OneShotHttpServer::spawn(response);
        let root = temp_cache_root("vary-star");
        let mut request = network_request(server.url.clone(), "aaaaffff11112222");
        request.cache_mode = CacheMode::MemoryAndDisk;
        request.encoded_cache_key = "aaaaffff11112223".to_string();
        let disk = DiskCache::new(&root);

        load_image(&root, request.clone(), None).expect("Vary star response should load");
        server.join();

        assert!(!memory_remove(&request.encoded_cache_key).unwrap());
        assert!(matches!(
            disk.read_entry(&request.namespace, &request.encoded_cache_key)
                .unwrap(),
            DiskCacheRead::Miss
        ));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn vary_reuses_only_matching_request_header_values() {
        let image = minimal_gif(1, 0);
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nCache-Control: max-age=60\r\nVary: Accept\r\n\r\n",
            image.len()
        )
        .into_bytes();
        response.extend_from_slice(&image);
        let server = FixedResponseServer::spawn(response);
        let root = temp_cache_root("vary-request-headers");
        let mut request = network_request(server.url.clone(), "bbbbffff11112222");
        request.cache_mode = CacheMode::MemoryAndDisk;
        request.encoded_cache_key = "bbbbffff11112223".to_string();
        request
            .headers
            .insert("accept".to_string(), "image/gif".to_string());

        load_image(&root, request.clone(), None).expect("first variant should load");
        request
            .headers
            .insert("accept".to_string(), "image/webp".to_string());
        load_image(&root, request.clone(), None)
            .expect("different Vary value should fetch a new representation");
        request.cache_mode = CacheMode::CacheOnly;
        load_image(&root, request, None).expect("matching Vary value should reuse the cache");

        let request_count = server.stop();
        let _ = std::fs::remove_dir_all(root);
        assert_eq!(request_count, 2);
    }

    #[test]
    fn authenticated_response_requires_explicit_private_disk_cache() {
        let image = minimal_gif(1, 0);
        let server = SlowImageServer::spawn(image.clone());
        let root = temp_cache_root("private-disk-cache");
        let disk = DiskCache::new(&root);
        let mut public_request = network_request(server.url.clone(), "1111111111111111");
        public_request.cache_mode = CacheMode::DiskOnly;
        public_request.encoded_cache_key = "1111111111111112".to_string();
        public_request.headers.insert(
            "authorization".to_string(),
            "Bearer private-token".to_string(),
        );
        let mut private_request = public_request.clone();
        private_request.cache_key = "2222222222222221".to_string();
        private_request.encoded_cache_key = "2222222222222222".to_string();
        private_request.private_cache = true;

        load_image(&root, public_request.clone(), None)
            .expect("authenticated response should still load");
        load_image(&root, private_request.clone(), None)
            .expect("explicit private disk cache response should load");

        let public_read = disk
            .read_entry(&public_request.namespace, &public_request.encoded_cache_key)
            .expect("public disk lookup should not fail");
        let private_read = disk
            .read_entry(
                &private_request.namespace,
                &private_request.encoded_cache_key,
            )
            .expect("private disk lookup should not fail");
        let request_count = server.count.load(Ordering::Relaxed);
        let _ = server.stop();
        let _ = std::fs::remove_dir_all(root);

        assert!(matches!(public_read, DiskCacheRead::Miss));
        assert!(matches!(private_read, DiskCacheRead::Hit(_)));
        assert_eq!(request_count, 2);
    }

    #[test]
    fn authenticated_processed_response_does_not_bypass_private_disk_policy() {
        let image = minimal_png(2, 2);
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            image.len()
        )
        .into_bytes();
        response.extend_from_slice(&image);
        let server = OneShotHttpServer::spawn(response);
        let root = temp_cache_root("private-processed-disk-cache");
        let disk = DiskCache::new(&root);
        let mut request = network_request(server.url.clone(), "3333333333333331");
        request.cache_mode = CacheMode::DiskOnly;
        request.encoded_cache_key = "3333333333333332".to_string();
        request.headers.insert(
            "authorization".to_string(),
            "Bearer private-token".to_string(),
        );
        request.processors = vec!["resize(width=1,height=1,mode=exact,filter=nearest)".to_string()];

        load_image(&root, request.clone(), None)
            .expect("authenticated processed response should still load");
        server.join();

        let encoded = disk
            .read_entry(&request.namespace, &request.encoded_cache_key)
            .expect("encoded disk lookup should succeed");
        let processed = disk
            .read_entry(&request.namespace, &request.cache_key)
            .expect("processed disk lookup should succeed");
        let _ = std::fs::remove_dir_all(root);

        assert!(matches!(encoded, DiskCacheRead::Miss));
        assert!(matches!(processed, DiskCacheRead::Miss));
    }

    #[test]
    fn follower_cancellation_does_not_cancel_coalesced_leader() {
        let server = SlowImageServer::spawn(minimal_gif(1, 0));
        let mut request = network_request(server.url.clone(), "runtime-coalesced-cancel-key");
        request.cache_mode = CacheMode::MemoryOnly;
        let leader_request = request.clone();
        let follower_request = request.clone();
        let cancel_id = create_cancel_token().unwrap();
        let follower_cancel = cancel_token_handle(cancel_id).unwrap();

        let leader = thread::spawn(move || {
            load_image("", leader_request, None).expect("leader should complete");
        });
        server.wait_for_requests(1);
        let follower = thread::spawn(move || {
            load_image_with_cancel("", follower_request, None, follower_cancel)
                .expect_err("cancelled follower should stop waiting")
        });
        thread::sleep(Duration::from_millis(30));
        cancel_token(cancel_id).unwrap();

        let follower_error = follower.join().unwrap();
        leader.join().unwrap();
        free_cancel_token(cancel_id).unwrap();
        let request_count = server.stop();

        assert_eq!(follower_error.stage, "cancel");
        assert_eq!(request_count, 1);
    }

    #[test]
    fn full_load_leader_cancellation_does_not_poison_uncancelled_follower() {
        let server =
            SlowImageServer::spawn_with_delay(minimal_gif(1, 0), Duration::from_millis(500));
        let mut request = network_request(server.url.clone(), "full-load-leader-cancel");
        request.cache_mode = CacheMode::MemoryOnly;
        request.encoded_cache_key = "aaaabbbbcccc0001".to_string();
        request.cache_key = "aaaabbbbcccc0002".to_string();
        let inflight_key = runtime_inflight_key("", &request);
        let leader_request = request.clone();
        let follower_request = request;
        let cancel_id = create_cancel_token().unwrap();
        let leader_cancel = cancel_token_handle(cancel_id).unwrap();

        let leader = thread::spawn(move || {
            load_image_with_cancel("", leader_request, None, leader_cancel)
                .expect_err("cancelled leader should return cancellation")
        });
        server.wait_for_requests(1);
        let follower = thread::spawn(move || {
            load_image("", follower_request, None)
                .expect("uncancelled follower should receive the shared successful load")
        });
        wait_for_inflight_participants(runtime_inflight_loads(), &inflight_key, 3);
        cancel_token(cancel_id).unwrap();

        let leader_error = leader.join().unwrap();
        let follower_outcome = follower.join().unwrap();
        free_cancel_token(cancel_id).unwrap();
        let request_count = server.stop();

        assert_eq!(leader_error.stage, "cancel");
        assert!(looks_like_supported_image(&follower_outcome.bytes));
        assert_eq!(request_count, 1);
    }

    #[test]
    fn origin_fetch_leader_cancellation_does_not_poison_other_variant() {
        let server =
            SlowImageServer::spawn_with_delay(minimal_gif(1, 0), Duration::from_millis(500));
        let mut leader_request = network_request(server.url.clone(), "origin-leader-cancel-final");
        leader_request.cache_mode = CacheMode::MemoryOnly;
        leader_request.encoded_cache_key = "aaaabbbbdddd0001".to_string();
        let mut follower_request = leader_request.clone();
        follower_request.cache_key = "origin-follower-final".to_string();
        let fetch_key = runtime_inflight_fetch_key(&leader_request, None, None);
        let cancel_id = create_cancel_token().unwrap();
        let leader_cancel = cancel_token_handle(cancel_id).unwrap();

        let leader = thread::spawn(move || {
            load_image_with_cancel("", leader_request, None, leader_cancel)
                .expect_err("cancelled origin leader should return cancellation")
        });
        server.wait_for_requests(1);
        let follower = thread::spawn(move || {
            load_image("", follower_request, None)
                .expect("uncancelled variant should receive the shared origin bytes")
        });
        wait_for_inflight_participants(runtime_inflight_fetches(), &fetch_key, 3);
        cancel_token(cancel_id).unwrap();

        let leader_error = leader.join().unwrap();
        let follower_outcome = follower.join().unwrap();
        free_cancel_token(cancel_id).unwrap();
        let request_count = server.stop();

        assert_eq!(leader_error.stage, "cancel");
        assert!(looks_like_supported_image(&follower_outcome.bytes));
        assert_eq!(request_count, 1);
    }

    #[test]
    fn full_load_cancels_shared_work_after_every_listener_cancels() {
        let server = SlowImageServer::spawn_with_delay(minimal_gif(1, 0), Duration::from_secs(3));
        let mut request = network_request(server.url.clone(), "all-listeners-cancel");
        request.cache_mode = CacheMode::MemoryOnly;
        request.encoded_cache_key = "aaaabbbbeeee0001".to_string();
        request.cache_key = "aaaabbbbeeee0002".to_string();
        let inflight_key = runtime_inflight_key("", &request);
        let first_id = create_cancel_token().unwrap();
        let second_id = create_cancel_token().unwrap();
        let first_cancel = cancel_token_handle(first_id).unwrap();
        let second_cancel = cancel_token_handle(second_id).unwrap();
        let first_request = request.clone();

        let first = thread::spawn(move || {
            load_image_with_cancel("", first_request, None, first_cancel)
                .expect_err("first listener should be cancelled")
        });
        server.wait_for_requests(1);
        let second = thread::spawn(move || {
            load_image_with_cancel("", request, None, second_cancel)
                .expect_err("second listener should be cancelled")
        });
        wait_for_inflight_participants(runtime_inflight_loads(), &inflight_key, 3);
        let cancelled_at = Instant::now();
        cancel_token(first_id).unwrap();
        thread::sleep(Duration::from_millis(100));
        assert!(
            !second.is_finished(),
            "shared work must stay alive while the second listener remains interested"
        );
        cancel_token(second_id).unwrap();

        let first_error = first.join().unwrap();
        let second_error = second.join().unwrap();
        let cancel_elapsed = cancelled_at.elapsed();
        free_cancel_token(first_id).unwrap();
        free_cancel_token(second_id).unwrap();
        let request_count = server.stop();

        assert_eq!(first_error.stage, "cancel");
        assert_eq!(second_error.stage, "cancel");
        assert!(cancel_elapsed < Duration::from_secs(1));
        assert_eq!(request_count, 1);
    }

    #[test]
    fn background_refresh_limit_has_no_fixed_sixteen_request_cap() {
        assert_eq!(background_refresh_slot_limit(64, 12), 24);
        assert_eq!(background_refresh_slot_limit(4, 12), 4);
        assert_eq!(background_refresh_slot_limit(0, 1), 1);
    }

    #[test]
    fn runtime_config_rejects_zero_network_concurrency_without_an_upper_cap() {
        let invalid = RuntimePipelineConfig {
            network_concurrency: 0,
            ..RuntimePipelineConfig::default()
        };
        let high = RuntimePipelineConfig {
            network_concurrency: 64,
            ..RuntimePipelineConfig::default()
        };

        assert!(validate_pipeline_config(invalid).is_err());
        assert!(validate_pipeline_config(high).is_ok());
    }

    #[test]
    fn stale_revalidate_slot_reservation_never_exceeds_limit() {
        let counter = Arc::new(AtomicUsize::new(0));
        let contenders = 64;
        let max_slots = 3;
        let barrier = Arc::new(Barrier::new(contenders + 1));
        let mut workers = Vec::with_capacity(contenders);
        for _ in 0..contenders {
            let counter = counter.clone();
            let barrier = barrier.clone();
            workers.push(thread::spawn(move || {
                barrier.wait();
                try_reserve_background_refresh_slot(&counter, max_slots)
            }));
        }

        barrier.wait();
        let reservations = workers
            .into_iter()
            .map(|worker| worker.join().unwrap())
            .filter(|reserved| *reserved)
            .count();

        assert_eq!(reservations, max_slots);
        assert_eq!(counter.load(Ordering::Acquire), max_slots);
    }

    #[test]
    fn leader_cancellation_aborts_runtime_http_fetch() {
        let server = SlowImageServer::spawn(minimal_gif(1, 0));
        let mut request = network_request(server.url.clone(), "3333333333333331");
        request.cache_mode = CacheMode::NoStore;
        request.encoded_cache_key = "3333333333333332".to_string();
        let cancel_id = create_cancel_token().unwrap();
        let cancel_handle = cancel_token_handle(cancel_id).unwrap();

        let worker = thread::spawn(move || {
            load_image_with_cancel("", request, None, cancel_handle)
                .expect_err("cancelled leader should abort runtime fetch")
        });
        server.wait_for_requests(1);
        cancel_token(cancel_id).unwrap();

        let error = worker.join().unwrap();
        free_cancel_token(cancel_id).unwrap();
        let request_count = server.stop();

        assert_eq!(error.stage, "cancel");
        assert_eq!(request_count, 1);
    }

    #[test]
    fn retry_stops_after_max_attempts_for_retryable_fetch_errors() {
        let server = FixedResponseServer::spawn(
            "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 5\r\nConnection: close\r\n\r\nerror"
                .to_string(),
        );
        let mut request = network_request(server.url.clone(), "4444444444444441");
        request.cache_mode = CacheMode::NoStore;
        request.encoded_cache_key = "4444444444444442".to_string();
        request.retry = RuntimeRetryPolicy {
            mode: RuntimeRetryMode::Fixed,
            max_attempts: 3,
            delay_ms: 0,
            jitter_ms: 0,
        };

        let error = load_image("", request, None)
            .expect_err("retryable HTTP failures should stop at max attempts");

        let request_count = server.stop();
        assert_eq!(error.stage, "fetch");
        assert!(error.retryable);
        assert_eq!(request_count, 3);
    }

    #[test]
    fn rejects_gif_over_animation_frame_limit() {
        let limits = RuntimeLimits {
            max_animation_frames: 2,
            ..Default::default()
        };

        let error = load_image("", bytes_request(limits), Some(&minimal_gif(3, 10)))
            .expect_err("GIF with too many frames must be rejected before decode");

        assert_eq!(error.stage, "decode");
        assert!(
            error.message.contains("animation frame"),
            "unexpected message: {}",
            error.message
        );
    }

    #[test]
    fn rejects_gif_over_animation_duration_limit() {
        let limits = RuntimeLimits {
            max_animation_frames: 10,
            max_animation_duration_ms: 1_000,
            ..Default::default()
        };

        let error = load_image("", bytes_request(limits), Some(&minimal_gif(2, 60)))
            .expect_err("GIF over the duration budget must be rejected before decode");

        assert_eq!(error.stage, "decode");
        assert!(
            error.message.contains("animation duration"),
            "unexpected message: {}",
            error.message
        );
    }

    #[test]
    fn rejects_webp_over_animation_frame_limit() {
        let limits = RuntimeLimits {
            max_animation_frames: 1,
            ..Default::default()
        };

        let error = load_image(
            "",
            bytes_request(limits),
            Some(&minimal_animated_webp(2, 100)),
        )
        .expect_err("animated WebP with too many frames must be rejected before decode");

        assert_eq!(error.stage, "decode");
        assert!(
            error.message.contains("animation frame"),
            "unexpected message: {}",
            error.message
        );
    }

    #[test]
    fn rejects_webp_over_animation_duration_limit() {
        let limits = RuntimeLimits {
            max_animation_frames: 10,
            max_animation_duration_ms: 1_000,
            ..Default::default()
        };

        let error = load_image(
            "",
            bytes_request(limits),
            Some(&minimal_animated_webp(2, 600)),
        )
        .expect_err("animated WebP over the duration budget must be rejected before decode");

        assert_eq!(error.stage, "decode");
        assert!(
            error.message.contains("animation duration"),
            "unexpected message: {}",
            error.message
        );
    }

    #[test]
    fn rejects_webp_with_truncated_riff_header() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&0_u32.to_le_bytes());
        bytes.extend_from_slice(b"WEBP");

        let error = load_image("", bytes_request(RuntimeLimits::default()), Some(&bytes))
            .expect_err("WebP RIFF length must cover the format header");

        assert_eq!(error.stage, "decode");
        assert!(error.message.contains("WebP"));
    }

    #[test]
    fn accepts_wbmp_for_flutter_engine_decode_path() {
        let bytes = wbmp_image(17, 9);
        let outcome = load_image("", bytes_request(RuntimeLimits::default()), Some(&bytes))
            .expect("WBMP should pass runtime signature validation for Flutter decode");

        assert_eq!(outcome.bytes.as_ref(), bytes.as_slice());
    }

    #[test]
    fn decodes_static_image_to_rgba_with_budget() {
        let rgba = decode_image_to_rgba(&minimal_png(2, 2), 4, 16)
            .expect("static PNG should decode to RGBA");

        assert_eq!(rgba.width, 2);
        assert_eq!(rgba.height, 2);
        assert_eq!(rgba.row_bytes, 8);
        assert_eq!(rgba.bytes.len(), 16);
        assert_eq!(&rgba.bytes[0..4], &[255, 0, 0, 255]);
    }

    #[test]
    fn decodes_ico_to_rgba_with_budget() {
        let rgba = decode_image_to_rgba(&minimal_ico(), 1, 4).expect("ICO should decode to RGBA");

        assert_eq!(rgba.width, 1);
        assert_eq!(rgba.height, 1);
        assert_eq!(rgba.row_bytes, 4);
        assert_eq!(rgba.bytes.len(), 4);
    }

    #[test]
    fn decodes_additional_image_formats_to_rgba() {
        for fixture in stable_raster_fixture_corpus() {
            let max_pixels = u64::from(fixture.width) * u64::from(fixture.height);
            let max_output = (max_pixels * 4) as usize;
            let rgba = decode_image_to_rgba(&fixture.bytes, max_pixels, max_output).unwrap_or_else(
                |error| panic!("{} should decode to RGBA: {error:?}", fixture.label),
            );
            assert_eq!(
                (rgba.width, rgba.height, rgba.row_bytes),
                (fixture.width, fixture.height, fixture.width as usize * 4)
            );
            assert_eq!(rgba.bytes.len(), max_output);
            assert_eq!(
                &rgba.bytes[0..4],
                fixture.expected_pixel,
                "{} first pixel should match fixture golden",
                fixture.label
            );
        }
    }

    #[test]
    fn processor_decodes_stable_raster_fixture_corpus() {
        for fixture in stable_raster_fixture_corpus() {
            let mut request = bytes_request(RuntimeLimits::default());
            request.cache_key = format!("processor-corpus-{}-final", fixture.label);
            request.encoded_cache_key = format!("processor-corpus-{}-origin", fixture.label);
            request.processors =
                vec!["resize(width=1,height=1,mode=exact,filter=nearest)".to_string()];

            let outcome = load_image("", request, Some(&fixture.bytes)).unwrap_or_else(|error| {
                panic!(
                    "{} should decode through processor path: {error:?}",
                    fixture.label
                )
            });
            let decoded = image::load_from_memory(&outcome.bytes)
                .unwrap_or_else(|error| panic!("{} processor output PNG: {error}", fixture.label));
            let rgba = decoded.to_rgba8();

            assert_eq!(decoded.dimensions(), (1, 1), "{}", fixture.label);
            assert_eq!(
                rgba.get_pixel(0, 0).0,
                fixture.expected_pixel,
                "{} processor first pixel should match fixture golden",
                fixture.label
            );
        }
    }

    #[test]
    fn runtime_rgba_decode_rejects_animated_input() {
        let error = decode_image_to_rgba(&minimal_gif(2, 10), 10, 1024)
            .expect_err("animated input must not enter runtime RGBA display decode");

        assert_eq!(error.stage, "decode");
        assert!(error.message.contains("animated GIF"));
    }

    #[test]
    fn runtime_rgba_decode_enforces_output_budget() {
        let error = decode_image_to_rgba(&minimal_png(2, 2), 4, 15)
            .expect_err("RGBA output budget must be enforced");

        assert_eq!(error.stage, "decode");
        assert!(error.message.contains("RGBA output bytes exceed limit"));
    }

    #[test]
    fn runtime_rgba_decode_rejects_oversized_dimensions_before_full_decode() {
        let error = decode_image_to_rgba(&pnm_header_only(4096, 4096), 1024, 4096 * 4096 * 4)
            .expect_err("decoded pixel budget must be enforced before RGBA decode");

        assert_eq!(error.stage, "decode");
        assert!(error.message.contains("decoded pixel count exceeds limit"));
    }

    #[test]
    fn processor_decode_rejects_oversized_input_before_full_decode() {
        let mut request = bytes_request(RuntimeLimits {
            max_decoded_pixels: 1024,
            ..RuntimeLimits::default()
        });
        request.cache_key = "oversized-processor-input".to_string();
        request.encoded_cache_key = "oversized-processor-origin".to_string();
        request.processors = vec!["resize(width=8,height=8,mode=exact,filter=nearest)".to_string()];

        let error = load_image("", request, Some(&pnm_header_only(4096, 4096)))
            .expect_err("processor input decoded pixel budget must be enforced");

        assert_eq!(error.stage, "processor");
        assert!(error.message.contains("decoded pixel count exceeds limit"));
    }

    #[test]
    fn encoded_memory_hit_reapplies_encoded_and_decoded_limits() {
        let bytes = minimal_png(4, 4);
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_mode = CacheMode::MemoryOnly;
        request.cache_key = "encoded-memory-limit-final".to_string();
        request.encoded_cache_key = "encoded-memory-limit-origin".to_string();
        load_image("", request.clone(), Some(&bytes)).expect("cache seed should load");

        request.limits.max_encoded_bytes = bytes.len().saturating_sub(1);
        request.limits.max_decoded_pixels = 1;
        let error = load_image("", request.clone(), None)
            .expect_err("encoded memory hit must reapply current request limits");
        memory_remove(&request.encoded_cache_key).unwrap();

        assert!(error.message.contains("max encoded byte limit"));
    }

    #[test]
    fn encoded_disk_hit_reapplies_encoded_and_decoded_limits() {
        let root = temp_cache_root("encoded-disk-limits");
        let bytes = minimal_png(4, 4);
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_mode = CacheMode::DiskOnly;
        request.cache_key = "1111222233334444".to_string();
        request.encoded_cache_key = "1111222233334445".to_string();
        load_image(&root, request.clone(), Some(&bytes)).expect("cache seed should load");

        request.cache_mode = CacheMode::CacheOnly;
        request.limits.max_encoded_bytes = bytes.len().saturating_sub(1);
        request.limits.max_decoded_pixels = 1;
        let error = load_image(&root, request, None)
            .expect_err("encoded disk hit must reapply current request limits");
        let _ = std::fs::remove_dir_all(root);

        assert!(error.message.contains("max encoded byte limit"));
    }

    #[test]
    fn encoded_disk_hit_rejects_metadata_length_before_reading_data() {
        let root = temp_cache_root("encoded-disk-preflight");
        let bytes = minimal_png(4, 4);
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_mode = CacheMode::DiskOnly;
        request.cache_key = "2222333344445555".to_string();
        request.encoded_cache_key = "2222333344445556".to_string();
        load_image(&root, request.clone(), Some(&bytes)).expect("cache seed should load");
        let disk = DiskCache::new(&root);
        let data_path = disk
            .entry_paths(&request.namespace, &request.encoded_cache_key)
            .unwrap()
            .data;
        std::fs::remove_file(&data_path).unwrap();
        std::fs::create_dir(&data_path).unwrap();

        request.cache_mode = CacheMode::CacheOnly;
        request.limits.max_encoded_bytes = 1;
        let error = load_image(&root, request, None)
            .expect_err("metadata length should reject before opening cache data");
        let _ = std::fs::remove_dir_all(root);

        assert!(error.message.contains("max encoded byte limit"));
    }

    #[test]
    fn encoded_memory_hit_reapplies_decoded_pixel_limit() {
        let bytes = minimal_png(4, 4);
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_mode = CacheMode::MemoryOnly;
        request.cache_key = "encoded-memory-pixels-final".to_string();
        request.encoded_cache_key = "encoded-memory-pixels-origin".to_string();
        load_image("", request.clone(), Some(&bytes)).expect("cache seed should load");

        request.limits.max_decoded_pixels = 1;
        let error = load_image("", request.clone(), None)
            .expect_err("encoded memory hit must reapply decoded pixel limit");
        memory_remove(&request.encoded_cache_key).unwrap();

        assert!(error.message.contains("decoded pixel count exceeds limit"));
    }

    #[test]
    fn encoded_memory_hit_reapplies_animation_frame_limit() {
        let bytes = minimal_gif(2, 10);
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_mode = CacheMode::MemoryOnly;
        request.cache_key = "encoded-memory-animation-limit".to_string();
        request.encoded_cache_key = request.cache_key.clone();
        load_image("", request.clone(), Some(&bytes)).expect("cache seed should load");

        request.limits.max_animation_frames = 1;
        let error = load_image("", request.clone(), None)
            .expect_err("encoded memory hit must reapply animation frame limit");
        memory_remove(&request.encoded_cache_key).unwrap();

        assert!(error
            .message
            .contains("animation frame count exceeds limit"));
    }

    #[test]
    fn encoded_disk_hit_reapplies_animation_duration_limit() {
        let root = temp_cache_root("encoded-disk-animation-limit");
        let bytes = minimal_gif(2, 100);
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_mode = CacheMode::DiskOnly;
        request.cache_key = "3333444455556666".to_string();
        request.encoded_cache_key = request.cache_key.clone();
        load_image(&root, request.clone(), Some(&bytes)).expect("cache seed should load");

        request.cache_mode = CacheMode::CacheOnly;
        request.limits.max_animation_duration_ms = 1_000;
        let error = load_image(&root, request, None)
            .expect_err("encoded disk hit must reapply animation duration limit");
        let _ = std::fs::remove_dir_all(root);

        assert!(error.message.contains("animation duration exceeds limit"));
    }

    #[test]
    fn processed_memory_hit_reapplies_output_limit() {
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_mode = CacheMode::MemoryOnly;
        request.cache_key = "processed-memory-output-limit".to_string();
        request.encoded_cache_key = "processed-memory-output-origin".to_string();
        request.processors = vec!["resize(width=2,height=2,mode=exact,filter=nearest)".to_string()];
        load_image("", request.clone(), Some(&minimal_png(4, 4)))
            .expect("processed cache seed should load");

        request.limits.max_processor_output_bytes = 1;
        let error = load_image("", request.clone(), None)
            .expect_err("processed memory hit must reapply output limit");
        memory_remove(&request.cache_key).unwrap();
        memory_remove(&request.encoded_cache_key).unwrap();

        assert!(error.message.contains("processor output"));
    }

    #[test]
    fn processed_disk_hit_reapplies_output_limit() {
        let root = temp_cache_root("processed-disk-output-limit");
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_mode = CacheMode::DiskOnly;
        request.cache_key = "5555666677778888".to_string();
        request.encoded_cache_key = "5555666677778889".to_string();
        request.processors = vec!["resize(width=2,height=2,mode=exact,filter=nearest)".to_string()];
        load_image(&root, request.clone(), Some(&minimal_png(4, 4)))
            .expect("processed cache seed should load");

        request.cache_mode = CacheMode::CacheOnly;
        request.limits.max_processor_output_bytes = 1;
        let error = load_image(&root, request, None)
            .expect_err("processed disk hit must reapply output limit");
        let _ = std::fs::remove_dir_all(root);

        assert!(error.message.contains("processor output"));
    }

    #[test]
    fn prepared_decoder_memory_hit_reapplies_output_limit() {
        let final_bytes = shared_bytes(minimal_png(2, 2));
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_mode = CacheMode::MemoryOnly;
        request.cache_key = "prepared-decoder-memory-final".to_string();
        request.encoded_cache_key = "prepared-decoder-memory-origin".to_string();
        memory_cache()
            .lock()
            .expect("memory cache lock should not be poisoned")
            .put_processed(
                &request.namespace,
                request.cache_key.clone(),
                final_bytes.clone(),
                None,
            );
        let permissive = load_image("", request.clone(), None)
            .expect("prepared decoder memory entry should hit");
        assert_eq!(permissive.source_label, "decoder-memory-cache");

        request.limits.max_processor_output_bytes = final_bytes.len().saturating_sub(1);
        let error = load_image("", request.clone(), None)
            .expect_err("prepared decoder memory hit must reapply output limit");
        memory_remove(&request.cache_key).unwrap();

        assert!(error.message.contains("cached processor output"));
    }

    #[test]
    fn prepared_decoder_disk_hit_reapplies_encoded_limit() {
        let root = temp_cache_root("prepared-decoder-disk-limit");
        let final_bytes = minimal_png(2, 2);
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_mode = CacheMode::DiskOnly;
        request.cache_key = "777788889999aaaa".to_string();
        request.encoded_cache_key = "777788889999aaab".to_string();
        DiskCache::new(&root)
            .write(&request.namespace, &request.cache_key, &final_bytes, None)
            .expect("prepared decoder disk entry should be written");
        let permissive = load_image(&root, request.clone(), None)
            .expect("prepared decoder disk entry should hit");
        assert_eq!(permissive.source_label, "decoder-disk-cache");

        request.cache_mode = CacheMode::CacheOnly;
        request.limits.max_encoded_bytes = final_bytes.len().saturating_sub(1);
        let error = load_image(&root, request, None)
            .expect_err("prepared decoder disk hit must reapply encoded limit");
        let _ = std::fs::remove_dir_all(root);

        assert!(error.message.contains("max encoded byte limit"));
    }

    #[test]
    fn file_fetch_rechecks_limit_after_stat_read_race() {
        let root = temp_cache_root("file-read-race");
        std::fs::create_dir_all(&root).unwrap();
        let path = std::path::PathBuf::from(&root).join("image.gif");
        let initial = minimal_gif(1, 0);
        let mut replacement = initial.clone();
        replacement.extend(std::iter::repeat_n(0, 1024));
        std::fs::write(&path, &initial).unwrap();
        let sink = ReplacingFileProgressSink {
            path: path.clone(),
            replacement,
        };
        let mut request = bytes_request(RuntimeLimits {
            max_encoded_bytes: initial.len(),
            ..RuntimeLimits::default()
        });
        request.source = RuntimeSource::File {
            path: path.to_string_lossy().into_owned(),
        };

        let error = load_image_with_cancel_and_progress("", request, None, None, Some(&sink))
            .expect_err("file growth after stat must not bypass encoded byte limit");
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(error.stage, "fetch");
        assert!(error.message.contains("max encoded byte limit"));
    }

    #[test]
    fn file_length_check_never_truncates_values_above_u32() {
        let above_u32 = u64::from(u32::MAX) + 1;
        if usize::BITS == 32 {
            let error = checked_file_length(above_u32, usize::MAX)
                .expect_err("32-bit targets must reject unaddressable file lengths");
            assert!(error.message.contains("addressable memory"));
        } else {
            assert_eq!(
                checked_file_length(above_u32, above_u32 as usize)
                    .expect("64-bit targets must preserve the full file length"),
                above_u32 as usize,
            );
        }
        let error = checked_file_length(above_u32, u32::MAX as usize)
            .expect_err("the encoded byte budget must reject the full untruncated length");
        assert!(error.message.contains("max encoded byte limit"));
    }

    #[test]
    fn applies_resize_processor_and_caches_processed_variant_in_memory() {
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_mode = CacheMode::MemoryOnly;
        request.cache_key = "processor-resize-final".to_string();
        request.encoded_cache_key = "processor-resize-origin".to_string();
        request.processors = vec!["resize(width=1,height=1,mode=exact,filter=nearest)".to_string()];

        let first = load_image("", request.clone(), Some(&minimal_png(2, 2)))
            .expect("supported resize processor should complete");
        let decoded = image::load_from_memory(&first.bytes).expect("processed PNG should decode");

        assert_eq!(decoded.dimensions(), (1, 1));

        let second = load_image("", request.clone(), None)
            .expect("processed memory cache hit should not need origin inline bytes");
        let second_decoded =
            image::load_from_memory(&second.bytes).expect("cached processed PNG should decode");

        assert_eq!(second_decoded.dimensions(), (1, 1));
    }

    #[test]
    fn applies_tile_processor_as_single_crop_resize_stage() {
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_key = "processor-tile-final".to_string();
        request.encoded_cache_key = "processor-tile-origin".to_string();
        request.processors = vec![
            "tile(x=0,y=0,width=2,height=2,decodedWidth=1,decodedHeight=1,filter=nearest)"
                .to_string(),
        ];

        let outcome = load_image("", request, Some(&minimal_png(4, 4)))
            .expect("tile processor should crop and resize in runtime pipeline");
        let decoded = image::load_from_memory(&outcome.bytes).expect("processed PNG should decode");

        assert_eq!(decoded.dimensions(), (1, 1));
    }

    #[test]
    fn applies_bmp_tile_processor_with_guarded_full_decode_fallback() {
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_key = "processor-bmp-tile-final".to_string();
        request.encoded_cache_key = "processor-bmp-tile-origin".to_string();
        request.processors = vec![
            "tile(x=1,y=1,width=2,height=2,decodedWidth=2,decodedHeight=2,filter=nearest)"
                .to_string(),
        ];
        let sink = CapturingProgressSink::default();

        let outcome = load_image_with_cancel_and_progress(
            "",
            request,
            Some(&bmp_rgb_4x4()),
            None,
            Some(&sink),
        )
        .expect("small BMP tile processor should use guarded full decode");
        let decoded = image::load_from_memory(&outcome.bytes).expect("processed PNG should decode");
        let rgb = decoded.to_rgb8();

        assert_eq!(decoded.dimensions(), (2, 2));
        assert_eq!(rgb.get_pixel(0, 0).0, [40, 40, 0]);
        assert!(!sink
            .names()
            .iter()
            .any(|name| name == "process.regionDecode.complete"));
    }

    #[test]
    fn rejects_bmp_tile_when_full_frame_exceeds_budget() {
        let mut request = bytes_request(RuntimeLimits {
            max_decoded_pixels: 4,
            ..RuntimeLimits::default()
        });
        request.cache_key = "processor-bmp-tile-budget-final".to_string();
        request.encoded_cache_key = "processor-bmp-tile-budget-origin".to_string();
        request.processors = vec![
            "tile(x=1,y=1,width=1,height=1,decodedWidth=1,decodedHeight=1,filter=nearest)"
                .to_string(),
        ];

        let error = load_image("", request, Some(&bmp_rgb_4x4()))
            .expect_err("BMP full-frame fallback must obey the decoded pixel budget");

        assert_eq!(error.stage, "processor");
        assert!(error.message.contains("tile full-decode fallback"));
        assert!(error.message.contains("bmp"));
    }

    #[test]
    fn applies_png_tile_processor_with_region_decoder() {
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_key = "processor-png-tile-final".to_string();
        request.encoded_cache_key = "processor-png-tile-origin".to_string();
        request.processors = vec![
            "tile(x=1,y=1,width=2,height=2,decodedWidth=2,decodedHeight=2,filter=nearest)"
                .to_string(),
        ];
        let sink = CapturingProgressSink::default();

        let outcome = load_image_with_cancel_and_progress(
            "",
            request,
            Some(&png_rgba_4x4()),
            None,
            Some(&sink),
        )
        .expect("PNG tile processor should use row region decoder");
        let decoded = image::load_from_memory(&outcome.bytes).expect("processed PNG should decode");
        let rgb = decoded.to_rgb8();

        assert_eq!(decoded.dimensions(), (2, 2));
        assert_eq!(rgb.get_pixel(0, 0).0, [40, 40, 0]);
        assert!(sink
            .names()
            .iter()
            .any(|name| name == "process.regionDecode.complete"));
    }

    #[test]
    fn rejects_region_tile_target_bytes_before_region_decode() {
        let mut request = bytes_request(RuntimeLimits {
            max_decoded_pixels: 100,
            max_processor_output_bytes: 32,
            ..RuntimeLimits::default()
        });
        request.cache_key = "processor-png-target-byte-limit-final".to_string();
        request.encoded_cache_key = "processor-png-target-byte-limit-origin".to_string();
        request.processors = vec![
            "tile(x=0,y=0,width=1,height=1,decodedWidth=4,decodedHeight=4,filter=nearest)"
                .to_string(),
        ];
        let sink = CapturingProgressSink::default();

        let error = load_image_with_cancel_and_progress(
            "",
            request,
            Some(&minimal_png(2, 2)),
            None,
            Some(&sink),
        )
        .expect_err("tile target bytes must be rejected before region decode");

        assert_eq!(error.stage, "processor");
        assert!(error.message.contains("decoded bytes exceed limit"));
        assert!(!sink
            .names()
            .iter()
            .any(|name| name == "process.regionDecode.start"));
    }

    #[test]
    fn rejects_png_source_region_over_pixel_budget_before_resize() {
        let mut request = bytes_request(RuntimeLimits {
            max_decoded_pixels: 4,
            ..RuntimeLimits::default()
        });
        request.cache_key = "processor-png-region-budget-final".to_string();
        request.encoded_cache_key = "processor-png-region-budget-origin".to_string();
        request.processors = vec![
            "tile(x=0,y=0,width=4,height=4,decodedWidth=1,decodedHeight=1,filter=nearest)"
                .to_string(),
        ];

        let error = load_image("", request, Some(&png_rgba_4x4()))
            .expect_err("PNG source ROI allocation must obey max decoded pixels");

        assert_eq!(error.stage, "processor");
        assert!(error.message.contains("decoded pixel count exceeds limit"));
    }

    #[test]
    fn applies_wbmp_tile_processor_under_full_frame_budget() {
        let mut request = bytes_request(RuntimeLimits {
            max_decoded_pixels: 8,
            ..RuntimeLimits::default()
        });
        request.cache_key = "processor-wbmp-tile-final".to_string();
        request.encoded_cache_key = "processor-wbmp-tile-origin".to_string();
        request.processors = vec![
            "tile(x=2,y=1,width=4,height=2,decodedWidth=4,decodedHeight=2,filter=nearest)"
                .to_string(),
        ];
        let mut wbmp = wbmp_image(64, 64);
        let data_offset = wbmp.len() - 64 * 8;
        wbmp[data_offset + 8] = 0b0101_1010;
        wbmp[data_offset + 16] = 0b1111_0000;
        let sink = CapturingProgressSink::default();

        let outcome =
            load_image_with_cancel_and_progress("", request, Some(&wbmp), None, Some(&sink))
                .expect("WBMP ROI should not allocate the 64x64 full frame");
        let decoded = image::load_from_memory(&outcome.bytes)
            .expect("processed PNG should decode")
            .to_luma8();

        assert_eq!(decoded.dimensions(), (4, 2));
        assert_eq!(decoded.into_raw(), [0, 255, 255, 0, 255, 255, 0, 0]);
        assert!(sink
            .names()
            .iter()
            .any(|name| name == "process.regionDecode.complete"));
    }

    #[test]
    fn applies_common_image_pixel_processors() {
        let cases = [
            (
                "processor-flip-horizontal",
                vec![
                    "flipHorizontal()".to_string(),
                    "crop(x=0,y=0,width=1,height=1)".to_string(),
                ],
                [120, 0, 0, 255],
            ),
            (
                "processor-flip-vertical",
                vec![
                    "flipVertical()".to_string(),
                    "crop(x=0,y=0,width=1,height=1)".to_string(),
                ],
                [0, 120, 0, 255],
            ),
            (
                "processor-grayscale",
                vec![
                    "crop(x=3,y=0,width=1,height=1)".to_string(),
                    "grayscale()".to_string(),
                ],
                [25, 25, 25, 255],
            ),
            (
                "processor-invert",
                vec![
                    "crop(x=3,y=0,width=1,height=1)".to_string(),
                    "invert()".to_string(),
                ],
                [135, 255, 255, 255],
            ),
            (
                "processor-brighten",
                vec![
                    "crop(x=1,y=1,width=1,height=1)".to_string(),
                    "brighten(value=30)".to_string(),
                ],
                [70, 70, 30, 255],
            ),
            (
                "processor-contrast",
                vec![
                    "crop(x=3,y=0,width=1,height=1)".to_string(),
                    "contrast(value=50)".to_string(),
                ],
                [110, 0, 0, 255],
            ),
            (
                "processor-unsharpen",
                vec![
                    "unsharpen(sigma=1.0,threshold=1)".to_string(),
                    "crop(x=1,y=1,width=1,height=1)".to_string(),
                ],
                [38, 38, 0, 255],
            ),
            (
                "processor-fast-blur",
                vec![
                    "fastBlur(sigma=1.0)".to_string(),
                    "crop(x=1,y=1,width=1,height=1)".to_string(),
                ],
                [47, 47, 0, 255],
            ),
            (
                "processor-filter-3x3",
                vec![
                    "filter3x3(kernel=0|0|0|0|2|0|0|-1|0)".to_string(),
                    "crop(x=1,y=1,width=1,height=1)".to_string(),
                ],
                [40, 0, 0, 255],
            ),
        ];

        for (cache_key, processors, expected_pixel) in cases {
            let mut request = bytes_request(RuntimeLimits::default());
            request.cache_key = cache_key.to_string();
            request.encoded_cache_key = format!("{cache_key}-origin");
            request.processors = processors;

            let outcome = load_image("", request, Some(&png_rgba_4x4()))
                .unwrap_or_else(|error| panic!("{cache_key} should process: {error:?}"));
            let decoded =
                image::load_from_memory(&outcome.bytes).expect("processed PNG should decode");
            let rgba = decoded.to_rgba8();

            assert_eq!(decoded.dimensions(), (1, 1), "{cache_key}");
            assert_eq!(rgba.get_pixel(0, 0).0, expected_pixel, "{cache_key}");
        }

        let mut hue_request = bytes_request(RuntimeLimits::default());
        hue_request.cache_key = "processor-hue-rotate".to_string();
        hue_request.encoded_cache_key = "processor-hue-rotate-origin".to_string();
        hue_request.processors = vec![
            "crop(x=3,y=0,width=1,height=1)".to_string(),
            "hueRotate(degrees=120)".to_string(),
        ];
        let hue_outcome =
            load_image("", hue_request, Some(&png_rgba_4x4())).expect("hue rotate should process");
        let hue_decoded =
            image::load_from_memory(&hue_outcome.bytes).expect("processed PNG should decode");
        let hue_pixel = hue_decoded.to_rgba8().get_pixel(0, 0).0;

        assert_eq!(hue_decoded.dimensions(), (1, 1));
        assert_ne!(hue_pixel, [120, 0, 0, 255]);
        assert_eq!(hue_pixel[3], 255);
    }

    #[test]
    fn applies_resize_to_fill_processor() {
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_key = "processor-resize-to-fill".to_string();
        request.encoded_cache_key = "processor-resize-to-fill-origin".to_string();
        request.processors = vec!["resizeToFill(width=3,height=1,filter=nearest)".to_string()];

        let outcome = load_image("", request, Some(&png_rgba_4x4()))
            .expect("resizeToFill processor should complete");
        let decoded = image::load_from_memory(&outcome.bytes).expect("processed PNG should decode");

        assert_eq!(decoded.dimensions(), (3, 1));
    }

    #[test]
    fn applies_thumbnail_processors() {
        let mut thumbnail_request = bytes_request(RuntimeLimits::default());
        thumbnail_request.cache_key = "processor-thumbnail".to_string();
        thumbnail_request.encoded_cache_key = "processor-thumbnail-origin".to_string();
        thumbnail_request.processors = vec!["thumbnail(width=8,height=8)".to_string()];

        let thumbnail_outcome = load_image("", thumbnail_request, Some(&png_rgba_4x4()))
            .expect("thumbnail processor should complete");
        let thumbnail_decoded =
            image::load_from_memory(&thumbnail_outcome.bytes).expect("processed PNG should decode");

        assert_eq!(thumbnail_decoded.dimensions(), (4, 4));

        let mut exact_request = bytes_request(RuntimeLimits::default());
        exact_request.cache_key = "processor-thumbnail-exact".to_string();
        exact_request.encoded_cache_key = "processor-thumbnail-exact-origin".to_string();
        exact_request.processors = vec!["thumbnailExact(width=3,height=2)".to_string()];

        let exact_outcome = load_image("", exact_request, Some(&png_rgba_4x4()))
            .expect("thumbnailExact processor should complete");
        let exact_decoded =
            image::load_from_memory(&exact_outcome.bytes).expect("processed PNG should decode");

        assert_eq!(exact_decoded.dimensions(), (3, 2));
    }

    #[test]
    fn applies_farbfeld_tile_processor_with_region_decoder() {
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_key = "processor-farbfeld-tile-final".to_string();
        request.encoded_cache_key = "processor-farbfeld-tile-origin".to_string();
        request.processors = vec![
            "tile(x=1,y=1,width=2,height=2,decodedWidth=2,decodedHeight=2,filter=nearest)"
                .to_string(),
        ];
        let sink = CapturingProgressSink::default();

        let outcome = load_image_with_cancel_and_progress(
            "",
            request,
            Some(&farbfeld_rgba_4x4()),
            None,
            Some(&sink),
        )
        .expect("Farbfeld tile processor should use region decoder");
        let decoded = image::load_from_memory(&outcome.bytes).expect("processed PNG should decode");
        let rgb = decoded.to_rgb8();

        assert_eq!(decoded.dimensions(), (2, 2));
        assert_eq!(rgb.get_pixel(0, 0).0, [40, 40, 0]);
        assert!(sink
            .names()
            .iter()
            .any(|name| name == "process.regionDecode.complete"));
    }

    #[test]
    fn rejects_jpeg_tile_full_decode_fallback_over_budget() {
        let mut request = bytes_request(RuntimeLimits {
            max_decoded_pixels: 8_192,
            max_processor_output_bytes: 1_024,
            ..RuntimeLimits::default()
        });
        request.cache_key = "processor-jpeg-tile-fallback-final".to_string();
        request.encoded_cache_key = "processor-jpeg-tile-fallback-origin".to_string();
        request.processors = vec![
            "tile(x=0,y=0,width=16,height=16,decodedWidth=1,decodedHeight=1,filter=nearest)"
                .to_string(),
        ];

        let error = load_image("", request, Some(&minimal_jpeg_with_orientation(64, 64, 1)))
            .expect_err("JPEG tile fallback must reject over-budget full-frame decode");

        assert_eq!(error.stage, "processor");
        assert!(error.message.contains("tile full-decode fallback"));
        assert!(error.message.contains("jpeg"));
    }

    #[test]
    fn runtime_processor_plugin_can_handle_jpeg_tile_before_full_decode_fallback() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.processor = true;
        let executor = Arc::new(StaticRuntimePluginExecutor::default());
        register_plugin_module_with_executor(
            RuntimePluginModule::host_linked(
                "pixa.processor.jpeg_roi.test",
                "pixa_jpeg_roi_init",
                "rust",
                capabilities,
            )
            .with_routes(RuntimePluginRoutes {
                processor_operations: vec!["tile:jpeg".to_string()],
                ..RuntimePluginRoutes::default()
            }),
            executor.clone(),
        )
        .expect("runtime processor route should register");
        let mut request = bytes_request(RuntimeLimits {
            max_decoded_pixels: 8_192,
            max_processor_output_bytes: 1_024,
            ..RuntimeLimits::default()
        });
        request.cache_key = "processor-plugin-jpeg-tile-final".to_string();
        request.encoded_cache_key = "processor-plugin-jpeg-tile-origin".to_string();
        request.processors = vec![
            "tile(x=0,y=0,width=16,height=16,decodedWidth=1,decodedHeight=1,filter=nearest)"
                .to_string(),
        ];
        let sink = CapturingProgressSink::default();

        let outcome = load_image_with_cancel_and_progress(
            "",
            request,
            Some(&minimal_jpeg_with_orientation(64, 64, 1)),
            None,
            Some(&sink),
        )
        .expect("runtime processor plugin should handle JPEG tile before fallback budget");
        let decoded = image::load_from_memory(&outcome.bytes).expect("plugin PNG should decode");

        assert_eq!(decoded.dimensions(), (1, 1));
        assert_eq!(executor.process_count.load(Ordering::Relaxed), 1);
        assert!(sink
            .names()
            .iter()
            .any(|name| name == "plugin.runtime.processor.complete"));
        clear_plugin_registry_for_test();
    }

    #[test]
    fn runtime_jpeg_tile_plugin_maps_exif_oriented_coordinates() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.processor = true;
        let executor = Arc::new(OrientedTileRuntimePluginExecutor::default());
        register_plugin_module_with_executor(
            RuntimePluginModule::host_linked(
                "pixa.processor.jpeg_orientation.test",
                "pixa_jpeg_orientation_init",
                "rust",
                capabilities,
            )
            .with_routes(RuntimePluginRoutes {
                processor_operations: vec!["tile:jpeg".to_string()],
                ..RuntimePluginRoutes::default()
            }),
            executor.clone(),
        )
        .expect("runtime processor route should register");
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_key = "processor-plugin-jpeg-orientation-final".to_string();
        request.encoded_cache_key = "processor-plugin-jpeg-orientation-origin".to_string();
        request.processors = vec![
            "tile(x=0,y=1,width=2,height=2,decodedWidth=4,decodedHeight=2,filter=nearest)"
                .to_string(),
        ];

        let outcome = load_image("", request, Some(&minimal_jpeg_with_orientation(3, 2, 6)))
            .expect("JPEG tile plugin should preserve oriented crop semantics");
        let decoded = image::load_from_memory(&outcome.bytes).expect("plugin PNG should decode");

        assert_eq!(decoded.dimensions(), (4, 2));
        assert_eq!(
            executor
                .observed
                .lock()
                .expect("orientation observation lock should not be poisoned")
                .as_ref(),
            Some(&TileSpec {
                x: 1,
                y: 0,
                width: 2,
                height: 2,
                decoded_width: 2,
                decoded_height: 4,
                filter: image::imageops::FilterType::Nearest,
            }),
        );
        clear_plugin_registry_for_test();
    }

    #[test]
    fn oriented_tile_mapping_matches_full_image_for_all_exif_values() {
        let source_width = 5;
        let source_height = 4;
        let source = image::RgbaImage::from_fn(source_width, source_height, |x, y| {
            image::Rgba([(x * 31) as u8, (y * 47) as u8, (x + y * 5) as u8, 255])
        });

        for orientation in 1..=8 {
            let fully_oriented = apply_image_orientation(
                image::DynamicImage::ImageRgba8(source.clone()),
                orientation,
            )
            .expect("test orientation should be valid")
            .into_rgba8();
            let tile = TileSpec {
                x: 1,
                y: 1,
                width: fully_oriented.width() - 2,
                height: fully_oriented.height() - 2,
                decoded_width: fully_oriented.width() - 2,
                decoded_height: fully_oriented.height() - 2,
                filter: image::imageops::FilterType::Nearest,
            };
            let mapped =
                map_oriented_tile_to_source(tile, source_width, source_height, orientation)
                    .expect("oriented tile should map to source pixels");
            let source_crop =
                image::imageops::crop_imm(&source, mapped.x, mapped.y, mapped.width, mapped.height)
                    .to_image();
            let mapped_then_oriented =
                apply_image_orientation(image::DynamicImage::ImageRgba8(source_crop), orientation)
                    .expect("mapped tile orientation should be valid")
                    .into_rgba8();
            let expected =
                image::imageops::crop_imm(&fully_oriented, tile.x, tile.y, tile.width, tile.height)
                    .to_image();

            assert_eq!(
                mapped_then_oriented, expected,
                "EXIF orientation {orientation} mapped the wrong source pixels",
            );
        }
    }

    #[test]
    fn runtime_limits_identity_includes_decoded_pixel_budget() {
        let low = RuntimeLimits {
            max_decoded_pixels: 1_024,
            ..RuntimeLimits::default()
        };
        let high = RuntimeLimits {
            max_decoded_pixels: 2_048,
            ..RuntimeLimits::default()
        };

        assert_ne!(
            runtime_limits_identity(&low),
            runtime_limits_identity(&high)
        );
    }

    #[test]
    fn tile_full_decode_budget_uses_worst_case_dynamic_image_pixel_size() {
        let limits = RuntimeLimits {
            max_decoded_pixels: 100,
            max_processor_output_bytes: 160,
            ..RuntimeLimits::default()
        };

        assert_eq!(
            tile_full_decode_fallback_pixel_limit(&limits)
                .expect("fallback budget should be valid"),
            10,
        );
    }

    #[test]
    fn parses_tile_processor_with_fast_descriptor_path() {
        let processor = parse_processor_descriptor(
            "TiLe(x=0,y=1,width=2,height=3,decoded_width=1,decodedHeight=2,filter=TRIANGLE)",
        )
        .expect("tile descriptor should parse");

        let RuntimeProcessor::Tile(tile) = processor else {
            panic!("expected tile processor");
        };
        assert_eq!(tile.x, 0);
        assert_eq!(tile.y, 1);
        assert_eq!(tile.width, 2);
        assert_eq!(tile.height, 3);
        assert_eq!(tile.decoded_width, 1);
        assert_eq!(tile.decoded_height, 2);
        assert_eq!(tile.filter, image::imageops::FilterType::Triangle);
    }

    #[test]
    fn rejects_obsolete_tile_sample_size_argument() {
        let error = parse_processor_descriptor(
            "tile(x=0,y=0,width=2,height=2,decodedWidth=1,decodedHeight=1,sampleSize=2,filter=triangle)",
        )
        .expect_err("decoder scaling must be derived from source and target geometry");

        assert!(error
            .message
            .contains("unsupported tile processor argument"));
        assert!(error.message.contains("sampleSize"));
    }

    #[test]
    fn rejects_tile_processor_out_of_bounds() {
        let mut request = bytes_request(RuntimeLimits::default());
        request.processors = vec![
            "tile(x=3,y=0,width=2,height=2,decodedWidth=1,decodedHeight=1,filter=nearest)"
                .to_string(),
        ];

        let error = load_image("", request, Some(&minimal_png(4, 4)))
            .expect_err("out-of-bounds tile processor must fail fast");

        assert_eq!(error.stage, "processor");
        assert!(
            error
                .message
                .contains("tile rectangle exceeds image bounds"),
            "unexpected message: {}",
            error.message
        );
    }

    #[test]
    fn stores_processed_variant_on_disk_under_final_cache_key() {
        let root = temp_cache_root("processed-variant-disk");
        let disk = DiskCache::new(&root);
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_mode = CacheMode::DiskOnly;
        request.cache_key = "5555555555555551".to_string();
        request.encoded_cache_key = "5555555555555552".to_string();
        request.processors = vec!["resize(width=1,height=1,mode=exact,filter=nearest)".to_string()];

        let first = load_image(&root, request.clone(), Some(&minimal_png(2, 2)))
            .expect("first processor load should complete");
        disk.remove(&request.namespace, &request.encoded_cache_key)
            .expect("origin entry should be removable");
        let second = load_image(&root, request.clone(), None)
            .expect("processed disk cache hit should not need origin bytes");
        let processed_read = disk
            .read_entry(&request.namespace, &request.cache_key)
            .expect("processed entry should be readable");
        let origin_read = disk
            .read_entry(&request.namespace, &request.encoded_cache_key)
            .expect("origin entry lookup should not fail");
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(first.bytes, second.bytes);
        assert!(matches!(processed_read, DiskCacheRead::Hit(_)));
        assert!(matches!(origin_read, DiskCacheRead::Miss));
    }

    #[test]
    fn records_processed_variant_cache_stats_separately() {
        let root = temp_cache_root("processed-variant-stats");
        let mut memory_request = bytes_request(RuntimeLimits::default());
        memory_request.cache_mode = CacheMode::MemoryOnly;
        memory_request.cache_key = "processed-stats-memory-final".to_string();
        memory_request.encoded_cache_key = "processed-stats-memory-origin".to_string();
        memory_request.processors =
            vec!["resize(width=1,height=1,mode=exact,filter=nearest)".to_string()];
        let processed_memory_key = memory_request.cache_key.clone();
        let before = cache_stats().expect("cache stats should be available");

        load_image("", memory_request.clone(), Some(&minimal_png(2, 2)))
            .expect("first processed memory load should write variant");
        load_image("", memory_request, None).expect("second load should hit processed memory");
        assert!(
            memory_remove(&processed_memory_key).expect("processed variant remove should succeed")
        );

        let mut disk_request = bytes_request(RuntimeLimits::default());
        disk_request.cache_mode = CacheMode::DiskOnly;
        disk_request.cache_key = "6666666666666601".to_string();
        disk_request.encoded_cache_key = "6666666666666602".to_string();
        disk_request.processors =
            vec!["resize(width=1,height=1,mode=exact,filter=nearest)".to_string()];
        load_image(&root, disk_request.clone(), Some(&minimal_png(2, 2)))
            .expect("first processed disk load should write variant");
        load_image(&root, disk_request.clone(), None)
            .expect("second processed disk load should hit variant");

        let mut stale_request = disk_request.clone();
        stale_request.cache_key = "6666666666666603".to_string();
        stale_request.encoded_cache_key = "6666666666666604".to_string();
        stale_request.ttl_ms = Some(1);
        load_image(&root, stale_request.clone(), Some(&minimal_png(2, 2)))
            .expect("stale seed should write processed variant");
        std::thread::sleep(Duration::from_millis(5));
        stale_request.cache_mode = CacheMode::CacheOnly;
        let stale_error = load_image(&root, stale_request, None)
            .expect_err("stale processed cache-only variant should miss");
        assert_eq!(stale_error.stage, "cache");

        let disk = DiskCache::new(&root);
        let corrupt_key = "6666666666666605";
        disk.write("test", corrupt_key, &minimal_png(2, 2), Some(60_000))
            .expect("corrupt seed should write");
        let corrupt_data = disk
            .entry_paths("test", corrupt_key)
            .expect("processed cache entry path should resolve")
            .data;
        std::fs::write(corrupt_data, b"corrupt").expect("corrupt data should overwrite");
        let mut corrupt_request = disk_request;
        corrupt_request.cache_mode = CacheMode::CacheOnly;
        corrupt_request.cache_key = corrupt_key.to_string();
        let corrupt_error = load_image(&root, corrupt_request, None)
            .expect_err("corrupt processed cache-only variant should miss");
        assert_eq!(corrupt_error.stage, "cache");

        let after = cache_stats().expect("cache stats should be available");
        let _ = std::fs::remove_dir_all(root);

        assert!(after.processed_memory_hits > before.processed_memory_hits);
        assert!(after.processed_memory_misses > before.processed_memory_misses);
        assert!(after.processed_memory_evictions > before.processed_memory_evictions);
        assert!(after.processed_disk_hits > before.processed_disk_hits);
        assert!(after.processed_disk_misses > before.processed_disk_misses);
        assert!(after.processed_disk_stale_hits > before.processed_disk_stale_hits);
        assert!(after.processed_disk_writes > before.processed_disk_writes);
        assert!(
            after.processed_disk_corruption_recoveries
                > before.processed_disk_corruption_recoveries
        );
    }

    #[test]
    fn applies_exif_orientation_before_processor_chain() {
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_key = "processor-exif-orientation-final".to_string();
        request.encoded_cache_key = "processor-exif-orientation-origin".to_string();
        request.processors = vec!["resize(width=1,filter=nearest)".to_string()];

        let jpeg = minimal_jpeg_with_orientation(2, 1, 6);
        let outcome = load_image("", request, Some(&jpeg))
            .expect("processor chain should apply EXIF orientation before resize");
        let decoded = image::load_from_memory(&outcome.bytes).expect("processed PNG should decode");

        assert_eq!(decoded.dimensions(), (1, 2));
    }

    #[test]
    fn applies_watermark_processor_without_dart_fallback() {
        let mut request = bytes_request(RuntimeLimits::default());
        request.processors = vec![
            "watermark(text=OK,position=topLeft,padding=0,scale=1,color=#ffffff,background=none,opacity=1)"
                .to_string(),
        ];

        let outcome = load_image("", request, Some(&minimal_png(16, 8)))
            .expect("watermark processor should complete");
        let decoded = image::load_from_memory(&outcome.bytes)
            .expect("watermarked processor output should decode");
        let rgba = decoded.to_rgba8();

        assert_eq!(decoded.dimensions(), (16, 8));
        assert!(
            rgba.pixels()
                .any(|pixel| pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240),
            "watermark text should draw visible white pixels"
        );
    }

    #[test]
    fn rejects_unsupported_processor_chain_instead_of_silent_passthrough() {
        let mut request = bytes_request(RuntimeLimits::default());
        request.processors = vec!["sharpen(amount=1)".to_string()];

        let error = load_image("", request, Some(&minimal_gif(1, 0)))
            .expect_err("unsupported processor descriptors must fail fast");

        assert_eq!(error.stage, "processor");
        assert!(
            error.message.contains("sharpen"),
            "unexpected message: {}",
            error.message
        );
    }

    #[test]
    fn plugin_source_selects_registered_fetcher_without_locator_leak() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.fetcher = true;
        register_plugin_module(
            RuntimePluginModule::built_in("pixa.fetcher.s3", capabilities).with_routes(
                RuntimePluginRoutes {
                    fetcher_source_kinds: vec!["s3".to_string()],
                    ..RuntimePluginRoutes::default()
                },
            ),
        )
        .expect("runtime fetcher route should register");
        let mut request = bytes_request(RuntimeLimits::default());
        request.source = RuntimeSource::RuntimePlugin {
            source_kind: "S3".to_string(),
            locator: "s3://bucket/private.gif?X-Amz-Signature=secret-token".to_string(),
        };

        let error = load_image("", request, None)
            .expect_err("selected runtime fetcher without entrypoint must fail fast");

        assert_eq!(error.stage, "fetch");
        assert!(error.message.contains("pixa.fetcher.s3"));
        assert!(error.message.contains("S3"));
        assert!(!error.message.contains("secret-token"));
        assert!(!error.message.contains("private.gif"));
        clear_plugin_registry_for_test();
    }

    #[test]
    fn s3_fetcher_executor_signs_and_fetches_through_runtime_transport() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let body = minimal_gif(1, 0);
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes()
        .into_iter()
        .chain(body.iter().copied())
        .collect::<Vec<u8>>();
        let server = OneShotHttpServer::spawn(response);
        let endpoint = server.url.trim_end_matches("/image.gif").to_string();

        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.fetcher = true;
        register_plugin_module_with_executor(
            RuntimePluginModule::built_in("pixa.fetcher.s3", capabilities).with_routes(
                RuntimePluginRoutes {
                    fetcher_source_kinds: vec!["s3".to_string(), "s3-object".to_string()],
                    ..RuntimePluginRoutes::default()
                },
            ),
            Arc::new(crate::S3RuntimePluginExecutor),
        )
        .expect("S3 runtime fetcher should register with an executor");
        let mut request = bytes_request(RuntimeLimits::default());
        request.source = RuntimeSource::RuntimePlugin {
            source_kind: "s3".to_string(),
            locator: "s3://bucket/photos/cat.gif".to_string(),
        };
        request
            .headers
            .insert("x-pixa-s3-region".to_string(), "us-east-1".to_string());
        request.headers.insert(
            "x-pixa-s3-access-key-id".to_string(),
            "AKIDEXAMPLE".to_string(),
        );
        request.headers.insert(
            "x-pixa-s3-secret-access-key".to_string(),
            "SECRETEXAMPLE".to_string(),
        );
        request.headers.insert(
            "x-pixa-s3-session-token".to_string(),
            "SESSIONEXAMPLE".to_string(),
        );
        request
            .headers
            .insert("x-pixa-s3-endpoint".to_string(), endpoint);
        request
            .headers
            .insert("x-pixa-s3-force-path-style".to_string(), "true".to_string());

        let outcome = load_image("", request, None).expect("S3 fetcher should load object bytes");

        assert_eq!(outcome.bytes.as_ref(), body.as_slice());
        assert_eq!(outcome.source_label, "runtime-plugin:s3");
        let observed = server.join();
        assert!(
            observed.starts_with("GET /bucket/photos/cat.gif HTTP/1.1"),
            "unexpected request: {observed}"
        );
        assert!(observed.contains("authorization: AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/"));
        assert!(observed.contains("/us-east-1/s3/aws4_request"));
        assert!(observed
            .contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token"));
        assert!(observed.contains("x-amz-content-sha256: e3b0c44298fc1c149afbf4c8996fb924"));
        assert!(observed.contains("x-amz-security-token: SESSIONEXAMPLE"));
        assert!(!observed.contains("SECRETEXAMPLE"));
        clear_plugin_registry_for_test();
    }

    #[test]
    fn plugin_fetcher_executor_loads_bytes_through_host_runtime() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.fetcher = true;
        register_plugin_module_with_executor(
            RuntimePluginModule::built_in("pixa.fetcher.test", capabilities).with_routes(
                RuntimePluginRoutes {
                    fetcher_source_kinds: vec!["test-object".to_string()],
                    ..RuntimePluginRoutes::default()
                },
            ),
            Arc::new(StaticRuntimePluginExecutor::default()),
        )
        .expect("runtime fetcher executor should register");
        let mut request = bytes_request(RuntimeLimits::default());
        request.source = RuntimeSource::RuntimePlugin {
            source_kind: "test-object".to_string(),
            locator: "test://bucket/image.gif?signature=secret".to_string(),
        };

        let outcome = load_image("", request, None)
            .expect("runtime fetcher executor should produce decodable bytes");

        assert_eq!(outcome.bytes.as_ref(), minimal_gif(1, 0).as_slice());
        assert_eq!(outcome.source_label, "runtime-plugin:test-object");
        clear_plugin_registry_for_test();
    }

    #[test]
    fn plugin_decoder_executor_can_route_by_format_id() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.decoder = true;
        let executor = Arc::new(StaticRuntimePluginExecutor::default());
        register_plugin_module_with_executor(
            RuntimePluginModule::built_in("pixa.decoder.format.test", capabilities).with_routes(
                RuntimePluginRoutes {
                    decoder_format_ids: vec!["png".to_string()],
                    ..RuntimePluginRoutes::default()
                },
            ),
            executor.clone(),
        )
        .expect("runtime decoder format route should register");
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_key = "format-decoder-final".to_string();
        request.encoded_cache_key = "format-decoder-origin".to_string();

        let outcome = load_image("", request, Some(&minimal_png(1, 1)))
            .expect("runtime decoder should transcode by format id");

        assert_eq!(outcome.bytes.as_ref(), minimal_gif(1, 0).as_slice());
        assert_eq!(executor.decode_count.load(Ordering::Relaxed), 1);
        clear_plugin_registry_for_test();
    }

    #[test]
    fn plugin_decoder_executor_can_route_by_explicit_mime_hint() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.decoder = true;
        let executor = Arc::new(StaticRuntimePluginExecutor::default());
        register_plugin_module_with_executor(
            RuntimePluginModule::built_in("pixa.decoder.mime.test", capabilities).with_routes(
                RuntimePluginRoutes {
                    decoder_mime_types: vec!["image/x-pixa-test".to_string()],
                    ..RuntimePluginRoutes::default()
                },
            ),
            executor.clone(),
        )
        .expect("runtime decoder MIME route should register");
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_key = "mime-decoder-final".to_string();
        request.encoded_cache_key = "mime-decoder-origin".to_string();
        request.decoder_mime_type = Some("image/x-pixa-test".to_string());

        let outcome = load_image("", request, Some(b"\0\0\0\x18ftyp-pixa-test"))
            .expect("runtime decoder should transcode unsupported bytes by explicit MIME");

        assert_eq!(outcome.bytes.as_ref(), minimal_gif(1, 0).as_slice());
        assert_eq!(executor.decode_count.load(Ordering::Relaxed), 1);
        clear_plugin_registry_for_test();
    }

    #[test]
    fn plugin_decoder_executor_can_route_by_static_signature() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.decoder = true;
        let executor = Arc::new(StaticRuntimePluginExecutor::default());
        register_plugin_module_with_executor(
            RuntimePluginModule::built_in("pixa.decoder.signature.test", capabilities).with_routes(
                RuntimePluginRoutes {
                    decoder_signatures: vec![RuntimePluginDecoderSignature {
                        offset: 4,
                        magic: b"pixa".to_vec(),
                        mime_type: "image/x-pixa-signature".to_string(),
                        format_id: Some("pixa-signature".to_string()),
                    }],
                    ..RuntimePluginRoutes::default()
                },
            ),
            executor.clone(),
        )
        .expect("runtime decoder signature route should register");
        let mut request = bytes_request(RuntimeLimits::default());
        request.cache_key = "signature-decoder-final".to_string();
        request.encoded_cache_key = "signature-decoder-origin".to_string();

        let outcome = load_image("", request, Some(b"\0\0\0\0pixa-payload"))
            .expect("runtime decoder should transcode unsupported bytes by signature");

        assert_eq!(outcome.bytes.as_ref(), minimal_gif(1, 0).as_slice());
        assert_eq!(executor.decode_count.load(Ordering::Relaxed), 1);
        clear_plugin_registry_for_test();
    }

    struct StableRasterFixture {
        label: &'static str,
        bytes: Vec<u8>,
        width: u32,
        height: u32,
        expected_pixel: [u8; 4],
    }

    fn stable_raster_fixture_corpus() -> Vec<StableRasterFixture> {
        vec![
            StableRasterFixture {
                label: "tiff",
                bytes: tiff_rgba_1x1(),
                width: 1,
                height: 1,
                expected_pixel: [255, 0, 0, 255],
            },
            StableRasterFixture {
                label: "pnm",
                bytes: pnm_rgb_1x1(),
                width: 1,
                height: 1,
                expected_pixel: [255, 0, 0, 255],
            },
            StableRasterFixture {
                label: "qoi",
                bytes: qoi_rgba_1x1(),
                width: 1,
                height: 1,
                expected_pixel: [255, 0, 0, 255],
            },
            StableRasterFixture {
                label: "tga",
                bytes: tga_rgb_1x1(),
                width: 1,
                height: 1,
                expected_pixel: [255, 0, 0, 255],
            },
            StableRasterFixture {
                label: "dds",
                bytes: dds_dxt1_4x4(),
                width: 4,
                height: 4,
                expected_pixel: [255, 0, 0, 255],
            },
            StableRasterFixture {
                label: "hdr",
                bytes: hdr_rgb_1x1(),
                width: 1,
                height: 1,
                expected_pixel: [255, 0, 0, 255],
            },
            StableRasterFixture {
                label: "farbfeld",
                bytes: farbfeld_rgba_1x1(),
                width: 1,
                height: 1,
                expected_pixel: [255, 0, 0, 255],
            },
            StableRasterFixture {
                label: "pcx",
                bytes: pcx_rgb_1x1(),
                width: 1,
                height: 1,
                expected_pixel: [255, 0, 0, 255],
            },
            StableRasterFixture {
                label: "sgi",
                bytes: sgi_rgb_1x1(),
                width: 1,
                height: 1,
                expected_pixel: [255, 0, 0, 255],
            },
            StableRasterFixture {
                label: "xbm",
                bytes: xbm_1x1(),
                width: 1,
                height: 1,
                expected_pixel: [0, 0, 0, 255],
            },
            StableRasterFixture {
                label: "xpm",
                bytes: xpm_1x1(),
                width: 1,
                height: 1,
                expected_pixel: [255, 0, 0, 255],
            },
            StableRasterFixture {
                label: "wbmp",
                bytes: wbmp_image(1, 1),
                width: 1,
                height: 1,
                expected_pixel: [0, 0, 0, 255],
            },
        ]
    }

    fn bytes_request(limits: RuntimeLimits) -> RuntimeRequest {
        RuntimeRequest {
            source: RuntimeSource::Bytes {
                id: "gif-fixture".to_string(),
            },
            headers: BTreeMap::new(),
            namespace: "test".to_string(),
            cache_key: format!("gif-fixture-{}", limits.max_animation_frames),
            encoded_cache_key: "gif-fixture-encoded".to_string(),
            target_width: None,
            target_height: None,
            decoder_mime_type: None,
            decoder_format_id: None,
            cache_mode: CacheMode::NoStore,
            ttl_ms: None,
            private_cache: false,
            processors: Vec::new(),
            limits,
            redirect_policy: RuntimeRedirectPolicy::default(),
            priority: RuntimePriority::Normal,
            retry: RuntimeRetryPolicy::default(),
        }
    }

    fn network_request(uri: String, cache_key: &str) -> RuntimeRequest {
        RuntimeRequest {
            source: RuntimeSource::Network { uri },
            headers: BTreeMap::new(),
            namespace: "test".to_string(),
            cache_key: cache_key.to_string(),
            encoded_cache_key: format!("{cache_key}-encoded"),
            target_width: None,
            target_height: None,
            decoder_mime_type: None,
            decoder_format_id: None,
            cache_mode: CacheMode::NoStore,
            ttl_ms: None,
            private_cache: false,
            processors: Vec::new(),
            limits: RuntimeLimits::default(),
            redirect_policy: RuntimeRedirectPolicy::default(),
            priority: RuntimePriority::Normal,
            retry: RuntimeRetryPolicy::default(),
        }
    }

    fn video_frame_request(cache_key: &str) -> RuntimeRequest {
        RuntimeRequest {
            source: RuntimeSource::VideoFrame {
                locator: "file:///clips/sample.mp4?token=secret".to_string(),
                timestamp_micros: 1_500_000,
                exact: true,
                backend: Some("platform".to_string()),
            },
            headers: BTreeMap::new(),
            namespace: "test".to_string(),
            cache_key: cache_key.to_string(),
            encoded_cache_key: "video-frame-shared-origin".to_string(),
            target_width: None,
            target_height: None,
            decoder_mime_type: None,
            decoder_format_id: None,
            cache_mode: CacheMode::NoStore,
            ttl_ms: None,
            private_cache: false,
            processors: Vec::new(),
            limits: RuntimeLimits::default(),
            redirect_policy: RuntimeRedirectPolicy::default(),
            priority: RuntimePriority::Normal,
            retry: RuntimeRetryPolicy::default(),
        }
    }

    fn temp_cache_root(label: &str) -> String {
        let unique = TEST_ROOT_COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir()
            .join(format!("pixa-{label}-{}-{unique}", std::process::id()))
            .to_string_lossy()
            .into_owned()
    }

    struct SlowImageServer {
        url: String,
        stop: Arc<AtomicBool>,
        count: Arc<AtomicUsize>,
        handle: thread::JoinHandle<()>,
    }

    fn wait_for_inflight_participants<T>(
        inflight: &Mutex<HashMap<String, Arc<T>>>,
        key: &str,
        expected_strong_count: usize,
    ) {
        let started = Instant::now();
        loop {
            let participant_count = inflight
                .lock()
                .expect("inflight test lock should not be poisoned")
                .get(key)
                .map(Arc::strong_count)
                .unwrap_or(0);
            if participant_count >= expected_strong_count {
                return;
            }
            assert!(
                started.elapsed() < Duration::from_secs(2),
                "timed out waiting for {expected_strong_count} in-flight participants; observed {participant_count}"
            );
            thread::yield_now();
        }
    }

    fn finish_http_test_response(stream: &mut std::net::TcpStream) {
        let _ = stream.shutdown(Shutdown::Write);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
        let mut drain = [0_u8; 64];
        while stream.read(&mut drain).is_ok_and(|length| length > 0) {}
    }

    fn read_http_test_request(stream: &mut std::net::TcpStream, stop: &AtomicBool) -> bool {
        let mut request = Vec::new();
        let mut buffer = [0_u8; 256];
        loop {
            match stream.read(&mut buffer) {
                Ok(0) => return false,
                Ok(length) => {
                    request.extend_from_slice(&buffer[..length]);
                    if request.windows(4).any(|window| window == b"\r\n\r\n") {
                        return true;
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    if stop.load(Ordering::Relaxed) {
                        return false;
                    }
                }
                Err(_) => return false,
            }
        }
    }

    impl SlowImageServer {
        fn spawn(body: Vec<u8>) -> Self {
            Self::spawn_with_delay(body, Duration::from_millis(150))
        }

        fn spawn_with_delay(body: Vec<u8>, response_delay: Duration) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let address = listener.local_addr().unwrap();
            let stop = Arc::new(AtomicBool::new(false));
            let count = Arc::new(AtomicUsize::new(0));
            let thread_stop = stop.clone();
            let thread_count = count.clone();
            let handle = thread::spawn(move || {
                let started = Instant::now();
                while !thread_stop.load(Ordering::Relaxed)
                    && started.elapsed() < Duration::from_secs(5)
                {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            thread_count.fetch_add(1, Ordering::Relaxed);
                            let body = body.clone();
                            thread::spawn(move || {
                                let mut request = Vec::new();
                                let mut buffer = [0_u8; 256];
                                loop {
                                    match stream.read(&mut buffer) {
                                        Ok(0) => break,
                                        Ok(length) => {
                                            request.extend_from_slice(&buffer[..length]);
                                            if request
                                                .windows(4)
                                                .any(|window| window == b"\r\n\r\n")
                                            {
                                                break;
                                            }
                                        }
                                        Err(_) => break,
                                    }
                                }
                                thread::sleep(response_delay);
                                let response = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                    body.len()
                                );
                                let _ = stream.write_all(response.as_bytes());
                                let _ = stream.write_all(&body);
                                let _ = stream.flush();
                                finish_http_test_response(&mut stream);
                            });
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(5));
                        }
                        Err(_) => break,
                    }
                }
            });
            Self {
                url: format!("http://{address}/image.gif"),
                stop,
                count,
                handle,
            }
        }

        fn wait_for_requests(&self, expected: usize) {
            let started = Instant::now();
            while self.count.load(Ordering::Relaxed) < expected {
                assert!(
                    started.elapsed() < Duration::from_secs(2),
                    "timed out waiting for {expected} request(s)"
                );
                thread::sleep(Duration::from_millis(5));
            }
        }

        fn stop(self) -> usize {
            self.stop.store(true, Ordering::Relaxed);
            let _ = std::net::TcpStream::connect(self.url.trim_start_matches("http://"));
            self.handle.join().unwrap();
            self.count.load(Ordering::Relaxed)
        }
    }

    struct OneShotHttpServer {
        url: String,
        handle: thread::JoinHandle<String>,
    }

    impl OneShotHttpServer {
        fn spawn(response: impl Into<Vec<u8>>) -> Self {
            let response = response.into();
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let handle = thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = Vec::new();
                let mut buffer = [0_u8; 512];
                loop {
                    let length = stream.read(&mut buffer).unwrap_or(0);
                    if length == 0 {
                        break;
                    }
                    request.extend_from_slice(&buffer[..length]);
                    if request.windows(4).any(|window| window == b"\r\n\r\n") {
                        break;
                    }
                }
                let _ = stream.write_all(&response);
                let _ = stream.flush();
                finish_http_test_response(&mut stream);
                String::from_utf8_lossy(&request).to_string()
            });
            Self {
                url: format!("http://{address}/image.gif"),
                handle,
            }
        }

        fn join(self) -> String {
            self.handle.join().unwrap()
        }
    }

    struct FixedResponseServer {
        url: String,
        stop: Arc<AtomicBool>,
        count: Arc<AtomicUsize>,
        handle: thread::JoinHandle<()>,
    }

    impl FixedResponseServer {
        fn spawn(response: impl Into<Vec<u8>>) -> Self {
            let response = response.into();
            let header_end = response
                .windows(4)
                .position(|window| window == b"\r\n\r\n")
                .map(|index| index + 4)
                .unwrap_or(response.len());
            let closes_connection = String::from_utf8_lossy(&response[..header_end])
                .to_ascii_lowercase()
                .contains("\r\nconnection: close\r\n");
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let address = listener.local_addr().unwrap();
            let stop = Arc::new(AtomicBool::new(false));
            let count = Arc::new(AtomicUsize::new(0));
            let thread_stop = stop.clone();
            let thread_count = count.clone();
            let handle = thread::spawn(move || {
                let started = Instant::now();
                while !thread_stop.load(Ordering::Relaxed)
                    && started.elapsed() < Duration::from_secs(5)
                {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            let _ = stream.set_read_timeout(Some(Duration::from_millis(50)));
                            while !thread_stop.load(Ordering::Relaxed)
                                && read_http_test_request(&mut stream, &thread_stop)
                            {
                                thread_count.fetch_add(1, Ordering::Relaxed);
                                let _ = stream.write_all(&response);
                                let _ = stream.flush();
                                if closes_connection {
                                    finish_http_test_response(&mut stream);
                                    break;
                                }
                            }
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(5));
                        }
                        Err(_) => break,
                    }
                }
            });
            Self {
                url: format!("http://{address}/image.gif"),
                stop,
                count,
                handle,
            }
        }

        fn stop(self) -> usize {
            self.stop.store(true, Ordering::Relaxed);
            let _ = std::net::TcpStream::connect(self.url.trim_start_matches("http://"));
            self.handle.join().unwrap();
            self.count.load(Ordering::Relaxed)
        }
    }

    fn minimal_gif(frames: usize, delay_cs: u16) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"GIF89a");
        bytes.extend_from_slice(&[1, 0, 1, 0, 0x80, 0, 0]);
        bytes.extend_from_slice(&[0, 0, 0, 255, 255, 255]);
        for _ in 0..frames {
            bytes.extend_from_slice(&[0x21, 0xf9, 0x04, 0]);
            bytes.extend_from_slice(&delay_cs.to_le_bytes());
            bytes.extend_from_slice(&[0, 0]);
            bytes.extend_from_slice(&[0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0]);
            bytes.extend_from_slice(&[2, 2, 0x4c, 0x01, 0]);
        }
        bytes.push(0x3b);
        bytes
    }

    fn minimal_png(width: u32, height: u32) -> Vec<u8> {
        let image =
            image::DynamicImage::ImageRgba8(image::RgbaImage::from_fn(width, height, |x, y| {
                if (x + y) % 2 == 0 {
                    image::Rgba([255, 0, 0, 255])
                } else {
                    image::Rgba([0, 0, 255, 255])
                }
            }));
        let mut cursor = Cursor::new(Vec::new());
        image
            .write_to(&mut cursor, image::ImageFormat::Png)
            .expect("test PNG should encode");
        cursor.into_inner()
    }

    fn png_rgba_4x4() -> Vec<u8> {
        let image = image::DynamicImage::ImageRgba8(image::RgbaImage::from_fn(4, 4, |x, y| {
            image::Rgba([(x * 40) as u8, (y * 40) as u8, 0, 255])
        }));
        let mut cursor = Cursor::new(Vec::new());
        image
            .write_to(&mut cursor, image::ImageFormat::Png)
            .expect("test PNG should encode");
        cursor.into_inner()
    }

    fn pnm_header_only(width: u32, height: u32) -> Vec<u8> {
        format!("P6\n{width} {height}\n255\n").into_bytes()
    }

    fn pnm_rgb_1x1() -> Vec<u8> {
        let mut bytes = b"P6\n1 1\n255\n".to_vec();
        bytes.extend_from_slice(&[255, 0, 0]);
        bytes
    }

    fn tiff_rgba_1x1() -> Vec<u8> {
        let mut cursor = Cursor::new(Vec::new());
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

    fn farbfeld_rgba_4x4() -> Vec<u8> {
        let mut bytes = b"farbfeld".to_vec();
        bytes.extend_from_slice(&4_u32.to_be_bytes());
        bytes.extend_from_slice(&4_u32.to_be_bytes());
        for y in 0..4_u16 {
            for x in 0..4_u16 {
                let red = x * 40 * 257;
                let green = y * 40 * 257;
                bytes.extend_from_slice(&red.to_be_bytes());
                bytes.extend_from_slice(&green.to_be_bytes());
                bytes.extend_from_slice(&0_u16.to_be_bytes());
                bytes.extend_from_slice(&u16::MAX.to_be_bytes());
            }
        }
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

    fn bmp_rgb_4x4() -> Vec<u8> {
        let mut pixels = Vec::with_capacity(4 * 4 * 3);
        for y in 0..4_u8 {
            for x in 0..4_u8 {
                pixels.extend_from_slice(&[x * 40, y * 40, 0]);
            }
        }
        let mut bytes = Vec::new();
        image::codecs::bmp::BmpEncoder::new(&mut bytes)
            .encode(&pixels, 4, 4, image::ExtendedColorType::Rgb8)
            .expect("test BMP should encode");
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

    fn minimal_ico() -> Vec<u8> {
        vec![
            0, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 32, 0, 48, 0, 0, 0, 22, 0, 0, 0, 40, 0, 0, 0, 1, 0,
            0, 0, 2, 0, 0, 0, 1, 0, 32, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0,
        ]
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

    fn minimal_jpeg_with_orientation(width: u32, height: u32, orientation: u16) -> Vec<u8> {
        let image =
            image::DynamicImage::ImageRgb8(image::RgbImage::from_fn(width, height, |x, y| {
                if (x + y) % 2 == 0 {
                    image::Rgb([255, 0, 0])
                } else {
                    image::Rgb([0, 0, 255])
                }
            }));
        let mut jpeg = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 95)
            .encode_image(&image)
            .expect("test JPEG should encode");

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
        let mut with_exif = Vec::with_capacity(jpeg.len() + exif.len() + 4);
        with_exif.extend_from_slice(&jpeg[..2]);
        with_exif.extend_from_slice(&[0xff, 0xe1]);
        with_exif.extend_from_slice(&segment_len.to_be_bytes());
        with_exif.extend_from_slice(&exif);
        with_exif.extend_from_slice(&jpeg[2..]);
        with_exif
    }

    fn minimal_animated_webp(frames: usize, duration_ms: u32) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&0_u32.to_le_bytes());
        bytes.extend_from_slice(b"WEBP");
        bytes.extend_from_slice(b"VP8X");
        bytes.extend_from_slice(&10_u32.to_le_bytes());
        bytes.extend_from_slice(&[0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        for _ in 0..frames {
            bytes.extend_from_slice(b"ANMF");
            bytes.extend_from_slice(&16_u32.to_le_bytes());
            bytes.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
            bytes.push((duration_ms & 0xff) as u8);
            bytes.push(((duration_ms >> 8) & 0xff) as u8);
            bytes.push(((duration_ms >> 16) & 0xff) as u8);
            bytes.push(0);
        }
        let riff_payload_len = (bytes.len() - 8) as u32;
        bytes[4..8].copy_from_slice(&riff_payload_len.to_le_bytes());
        bytes
    }

    #[derive(Default)]
    struct StaticRuntimePluginExecutor {
        decode_count: AtomicUsize,
        process_count: AtomicUsize,
    }

    #[derive(Default)]
    struct OrientedTileRuntimePluginExecutor {
        observed: Mutex<Option<TileSpec>>,
    }

    #[derive(Debug, Eq, PartialEq)]
    struct ObservedVideoFrameFetch {
        source_kind: String,
        locator: String,
        timestamp_micros: i64,
        exact: bool,
        backend: Option<String>,
    }

    struct VideoFrameRuntimePluginExecutor {
        fetch_count: AtomicUsize,
        observed: Mutex<Vec<ObservedVideoFrameFetch>>,
        output_mime: Option<&'static str>,
    }

    impl Default for VideoFrameRuntimePluginExecutor {
        fn default() -> Self {
            Self {
                fetch_count: AtomicUsize::default(),
                observed: Mutex::default(),
                output_mime: Some("image/png"),
            }
        }
    }

    impl VideoFrameRuntimePluginExecutor {
        fn observed(&self) -> Vec<ObservedVideoFrameFetch> {
            self.observed
                .lock()
                .expect("video frame observations lock should not be poisoned")
                .iter()
                .map(|item| ObservedVideoFrameFetch {
                    source_kind: item.source_kind.clone(),
                    locator: item.locator.clone(),
                    timestamp_micros: item.timestamp_micros,
                    exact: item.exact,
                    backend: item.backend.clone(),
                })
                .collect()
        }
    }

    impl RuntimePluginExecutor for VideoFrameRuntimePluginExecutor {
        fn fetch(
            &self,
            request: RuntimePluginFetchRequest<'_>,
        ) -> RuntimeResult<Option<RuntimePluginOutput>> {
            let video_frame = request.video_frame.expect("video frame spec is required");
            assert_eq!(request.source_kind, "video-frame:platform");
            assert!(request.max_output_bytes >= 128);
            self.fetch_count.fetch_add(1, Ordering::Relaxed);
            self.observed
                .lock()
                .expect("video frame observations lock should not be poisoned")
                .push(ObservedVideoFrameFetch {
                    source_kind: request.source_kind.to_string(),
                    locator: request.locator.to_string(),
                    timestamp_micros: video_frame.timestamp_micros,
                    exact: video_frame.exact,
                    backend: video_frame.backend.map(str::to_string),
                });
            thread::sleep(Duration::from_millis(150));
            Ok(Some(RuntimePluginOutput::from_vec(
                minimal_png(4, 4),
                self.output_mime,
            )))
        }
    }

    impl RuntimePluginExecutor for StaticRuntimePluginExecutor {
        fn fetch(
            &self,
            request: RuntimePluginFetchRequest<'_>,
        ) -> RuntimeResult<Option<RuntimePluginOutput>> {
            assert_eq!(request.source_kind, "test-object");
            assert!(request.locator.starts_with("test://bucket/image.gif"));
            Ok(Some(RuntimePluginOutput::from_vec(
                minimal_gif(1, 0),
                Some("image/gif"),
            )))
        }

        fn decode(
            &self,
            request: RuntimePluginDecodeRequest<'_>,
        ) -> RuntimeResult<Option<RuntimePluginOutput>> {
            if request.format_id == Some("png") {
                assert_eq!(request.mime_type, "image/png");
                assert!(request
                    .bytes
                    .starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]));
            } else if request.format_id == Some("pixa-signature") {
                assert_eq!(request.mime_type, "image/x-pixa-signature");
                assert!(request.bytes.starts_with(b"\0\0\0\0pixa"));
            } else {
                assert_eq!(request.format_id, None);
                assert_eq!(request.mime_type, "image/x-pixa-test");
                assert!(request
                    .bytes
                    .starts_with(&[0, 0, 0, 24, b'f', b't', b'y', b'p']));
            }
            self.decode_count.fetch_add(1, Ordering::Relaxed);
            Ok(Some(RuntimePluginOutput::from_vec(
                minimal_gif(1, 0),
                Some("image/gif"),
            )))
        }

        fn process(
            &self,
            request: RuntimePluginProcessRequest<'_>,
        ) -> RuntimeResult<Option<RuntimePluginOutput>> {
            assert_eq!(request.operation, "tile:jpeg");
            assert!(request.descriptor.starts_with("tile("));
            assert_eq!(request.format_id, Some("jpeg"));
            assert_eq!(request.mime_type, Some("image/jpeg"));
            assert!(request.bytes.starts_with(&[0xff, 0xd8]));
            assert_eq!(request.max_decoded_pixels, 8_192);
            assert_eq!(request.max_output_bytes, 1_024);
            self.process_count.fetch_add(1, Ordering::Relaxed);
            Ok(Some(RuntimePluginOutput::from_vec(
                minimal_png(1, 1),
                Some("image/png"),
            )))
        }
    }

    impl RuntimePluginExecutor for OrientedTileRuntimePluginExecutor {
        fn process(
            &self,
            request: RuntimePluginProcessRequest<'_>,
        ) -> RuntimeResult<Option<RuntimePluginOutput>> {
            assert_eq!(request.operation, "tile:jpeg");
            let spec = parse_tile_processor_descriptor(request.descriptor)?
                .expect("orientation test descriptor should be a tile");
            *self
                .observed
                .lock()
                .expect("orientation observation lock should not be poisoned") = Some(spec);
            Ok(Some(RuntimePluginOutput::from_vec(
                minimal_png(spec.decoded_width, spec.decoded_height),
                Some("image/png"),
            )))
        }
    }
}
