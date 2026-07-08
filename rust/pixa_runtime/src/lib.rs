//! Runtime ABI entry points for the single Rust-backed Pixa runtime.

#![allow(clippy::not_unsafe_ptr_arg_deref)]

#[cfg(feature = "webp-roi")]
use libwebp_sys as _;
use pixa_core::cache::DiskCache;
use pixa_core::cache::SharedBytes;
use pixa_core::cancel::{
    cancel_token, cancel_token_handle, create_cancel_token, free_cancel_token,
};
use pixa_core::request::decode_binary_request;
use pixa_core::{
    cache_stats, configure, decode_image_to_png_variant, decode_image_to_rgba,
    disk_trim_to_configured_budget, image_analysis, image_metadata, load_image_with_cancel,
    load_image_with_cancel_and_progress, memory_clear, memory_clear_namespace, memory_contains,
    memory_get_processed, memory_pin, memory_put_processed, memory_remove, memory_trim_to_bytes,
    memory_unpin, plugin_registry_stats, register_plugin_module,
    register_plugin_module_with_executor, runtime_image_format_capabilities, ImageAnalysis,
    ImageMetadata, ImageMetadataFormat, RuntimeCacheStats, RuntimeError, RuntimePipelineConfig,
    RuntimePluginCacheClearNamespaceRequest as PluginCacheClearNamespaceRequest,
    RuntimePluginCacheReadRequest as PluginCacheReadRequest,
    RuntimePluginCacheReadResult as PluginCacheReadResult,
    RuntimePluginCacheRemoveRequest as PluginCacheRemoveRequest,
    RuntimePluginCacheWriteRequest as PluginCacheWriteRequest,
    RuntimePluginCapabilities as PluginCapabilities,
    RuntimePluginDecodeRequest as PluginDecodeRequest, RuntimePluginDeployment as PluginDeployment,
    RuntimePluginExecutor as PluginExecutor, RuntimePluginFetchRequest as PluginFetchRequest,
    RuntimePluginModule as PluginModule, RuntimePluginOutput as PluginOutput,
    RuntimePluginProcessRequest as PluginProcessRequest,
    RuntimePluginRegistryStats as PluginRegistryStats, RuntimePluginRoutes as PluginRoutes,
    RuntimeProgressEvent, RuntimeProgressSink, RuntimeProgressStage, RuntimeResult,
    S3RuntimePluginExecutor, S3_FETCHER_MODULE_ID,
};
use std::collections::{BTreeMap, VecDeque};
use std::ffi::c_void;
use std::slice;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
#[cfg(feature = "jpeg-turbo-roi")]
use turbojpeg_sys as _;

#[cfg(pixa_jpeg_turbo_processor)]
mod jpeg_turbo_processor;
#[cfg(pixa_mjpeg_video_frame)]
mod mjpeg_video_frame;
#[cfg(pixa_webp_processor)]
mod webp_processor;

const MAX_PROGRESS_EVENTS_PER_SESSION: usize = 1024;

static PROGRESS_SESSIONS: OnceLock<Mutex<BTreeMap<u64, ProgressSession>>> = OnceLock::new();
static NEXT_PROGRESS_SESSION_ID: AtomicU64 = AtomicU64::new(1);
static OWNED_BUFFER_HANDLES_CREATED: AtomicU64 = AtomicU64::new(0);
static OWNED_BUFFER_HANDLES_FREED: AtomicU64 = AtomicU64::new(0);
static OWNED_BUFFER_BYTES_EXPOSED: AtomicU64 = AtomicU64::new(0);
static PROGRESS_SESSIONS_CREATED: AtomicU64 = AtomicU64::new(0);
static PROGRESS_SESSIONS_FREED: AtomicU64 = AtomicU64::new(0);
static PROGRESS_EVENTS_EMITTED: AtomicU64 = AtomicU64::new(0);
static PROGRESS_EVENTS_DROPPED: AtomicU64 = AtomicU64::new(0);
static PROGRESS_EVENTS_DRAINED: AtomicU64 = AtomicU64::new(0);
static GENERATED_PLUGIN_REGISTRATION: OnceLock<RuntimeResult<()>> = OnceLock::new();
static QOI_DECODER_HOST_API: OnceLock<PixaPluginHostApiV1> = OnceLock::new();
static QOI_DECODER_OUTPUT_MIME: &[u8] = b"image/png";

type GeneratedPluginEntrypoint = unsafe extern "C" fn(
    host: *const PixaPluginHostApiV1,
    module: *mut PixaPluginModuleApiV1,
) -> i32;

type PixaPluginFetchFn = unsafe extern "C" fn(
    request: *const PixaPluginFetchRequestV1,
    output: *mut PixaPluginOutputV1,
) -> i32;

type PixaPluginDecodeFn = unsafe extern "C" fn(
    request: *const PixaPluginDecodeRequestV1,
    output: *mut PixaPluginOutputV1,
) -> i32;

type PixaPluginProcessFn = unsafe extern "C" fn(
    request: *const PixaPluginProcessRequestV1,
    output: *mut PixaPluginOutputV1,
) -> i32;

type PixaPluginCacheReadFn = unsafe extern "C" fn(
    request: *const PixaPluginCacheReadRequestV1,
    output: *mut PixaPluginCacheReadOutputV1,
) -> i32;

type PixaPluginCacheWriteFn =
    unsafe extern "C" fn(request: *const PixaPluginCacheWriteRequestV1) -> i32;

type PixaPluginCacheRemoveFn =
    unsafe extern "C" fn(request: *const PixaPluginCacheRemoveRequestV1) -> i32;

type PixaPluginCacheClearNamespaceFn =
    unsafe extern "C" fn(request: *const PixaPluginCacheClearNamespaceRequestV1) -> i32;

#[repr(C)]
#[derive(Clone, Copy)]
struct PixaPluginHostApiV1 {
    abi_version: u32,
    buffer_alloc: Option<unsafe extern "C" fn(len: usize) -> *mut c_void>,
    buffer_data: Option<unsafe extern "C" fn(handle: *mut c_void) -> *mut u8>,
    buffer_len: Option<unsafe extern "C" fn(handle: *const c_void) -> usize>,
    buffer_free: Option<unsafe extern "C" fn(handle: *mut c_void)>,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct PixaPluginModuleApiV1 {
    abi_version: u32,
    fetch: Option<PixaPluginFetchFn>,
    decode: Option<PixaPluginDecodeFn>,
    process: Option<PixaPluginProcessFn>,
    cache_read: Option<PixaPluginCacheReadFn>,
    cache_write: Option<PixaPluginCacheWriteFn>,
    cache_remove: Option<PixaPluginCacheRemoveFn>,
    cache_clear_namespace: Option<PixaPluginCacheClearNamespaceFn>,
}

#[repr(C)]
struct PixaPluginFetchRequestV1 {
    source_kind_ptr: *const u8,
    source_kind_len: usize,
    locator_ptr: *const u8,
    locator_len: usize,
    has_video_frame: bool,
    video_timestamp_micros: i64,
    video_exact: bool,
    video_backend_ptr: *const u8,
    video_backend_len: usize,
    max_output_bytes: usize,
}

#[repr(C)]
struct PixaPluginDecodeRequestV1 {
    mime_type_ptr: *const u8,
    mime_type_len: usize,
    format_id_ptr: *const u8,
    format_id_len: usize,
    bytes_ptr: *const u8,
    bytes_len: usize,
    target_width: u32,
    target_height: u32,
    max_decoded_pixels: u64,
    max_output_bytes: usize,
}

#[repr(C)]
struct PixaPluginProcessRequestV1 {
    operation_ptr: *const u8,
    operation_len: usize,
    descriptor_ptr: *const u8,
    descriptor_len: usize,
    format_id_ptr: *const u8,
    format_id_len: usize,
    mime_type_ptr: *const u8,
    mime_type_len: usize,
    bytes_ptr: *const u8,
    bytes_len: usize,
    max_decoded_pixels: u64,
    max_output_bytes: usize,
}

#[repr(C)]
struct PixaPluginOutputV1 {
    buffer: *mut c_void,
    mime_type_ptr: *const u8,
    mime_type_len: usize,
}

#[repr(C)]
struct PixaPluginCacheReadRequestV1 {
    namespace_ptr: *const u8,
    namespace_len: usize,
    key_ptr: *const u8,
    key_len: usize,
    allow_stale: bool,
    max_output_bytes: usize,
}

#[repr(C)]
struct PixaPluginCacheWriteRequestV1 {
    namespace_ptr: *const u8,
    namespace_len: usize,
    key_ptr: *const u8,
    key_len: usize,
    bytes_ptr: *const u8,
    bytes_len: usize,
    ttl_ms: i64,
    has_ttl: bool,
    private_entry: bool,
}

#[repr(C)]
struct PixaPluginCacheRemoveRequestV1 {
    namespace_ptr: *const u8,
    namespace_len: usize,
    key_ptr: *const u8,
    key_len: usize,
}

#[repr(C)]
struct PixaPluginCacheClearNamespaceRequestV1 {
    namespace_ptr: *const u8,
    namespace_len: usize,
}

#[repr(C)]
struct PixaPluginCacheReadOutputV1 {
    status: u8,
    is_stale: bool,
    payload: PixaPluginOutputV1,
}

#[derive(Clone, Copy)]
#[allow(dead_code)]
enum GeneratedPluginDeployment {
    BuiltInHost,
    HostLinkedPlugin,
    Asset,
}

#[derive(Clone, Copy)]
struct GeneratedPluginCapabilities {
    fetcher: bool,
    decoder: bool,
    processor: bool,
    cache_store: bool,
    host_managed_runtime: bool,
    binary_messages: bool,
    owned_buffers: bool,
    stream_handles: bool,
}

#[derive(Clone, Copy)]
struct GeneratedPluginModule {
    module_id: &'static str,
    abi_version: i64,
    deployment: GeneratedPluginDeployment,
    package_name: Option<&'static str>,
    implementation_language: Option<&'static str>,
    entrypoint_symbol: Option<&'static str>,
    entrypoint: Option<GeneratedPluginEntrypoint>,
    capabilities: GeneratedPluginCapabilities,
    routes: GeneratedPluginRoutes,
}

#[derive(Clone, Copy)]
struct GeneratedPluginRoutes {
    fetcher_source_kinds: &'static [&'static str],
    video_frame_output_mime_types: &'static [&'static str],
    decoder_format_ids: &'static [&'static str],
    decoder_mime_types: &'static [&'static str],
    decoder_signatures: &'static [GeneratedPluginDecoderSignature],
    processor_operations: &'static [&'static str],
    cache_store_namespaces: &'static [&'static str],
}

#[derive(Clone, Copy)]
struct GeneratedPluginDecoderSignature {
    offset: usize,
    magic: &'static [u8],
    mime_type: &'static str,
    format_id: Option<&'static str>,
}

include!(concat!(env!("OUT_DIR"), "/pixa_plugin_plan.rs"));

#[repr(C)]
struct OwnedBufferHandle {
    storage: OwnedBufferStorage,
}

enum OwnedBufferStorage {
    Boxed(Box<[u8]>),
    Shared(SharedBytes),
}

#[repr(C)]
struct PluginHostBuffer {
    bytes: Vec<u8>,
}

impl OwnedBufferHandle {
    fn bytes(&self) -> &[u8] {
        match &self.storage {
            OwnedBufferStorage::Boxed(bytes) => bytes,
            OwnedBufferStorage::Shared(bytes) => bytes.as_ref(),
        }
    }

    fn len(&self) -> usize {
        match &self.storage {
            OwnedBufferStorage::Boxed(bytes) => bytes.len(),
            OwnedBufferStorage::Shared(bytes) => bytes.len(),
        }
    }

    fn data(&self) -> *mut u8 {
        match &self.storage {
            OwnedBufferStorage::Boxed(bytes) => bytes.as_ptr() as *mut u8,
            OwnedBufferStorage::Shared(bytes) => bytes.as_ptr() as *mut u8,
        }
    }
}

fn ensure_generated_plugins_registered() -> RuntimeResult<()> {
    GENERATED_PLUGIN_REGISTRATION
        .get_or_init(register_generated_plugin_modules)
        .clone()
}

fn register_generated_plugin_modules() -> RuntimeResult<()> {
    for module in GENERATED_PLUGIN_MODULES {
        let runtime_module = plugin_module_from_generated(module)?;
        if let Some(entrypoint) = module.entrypoint {
            let executor = instantiate_host_linked_executor(module, entrypoint)?;
            register_plugin_module_with_executor(runtime_module, Arc::new(executor))?;
        } else if module.module_id == S3_FETCHER_MODULE_ID {
            register_plugin_module_with_executor(
                runtime_module,
                Arc::new(S3RuntimePluginExecutor),
            )?;
        } else {
            register_plugin_module(runtime_module)?;
        }
    }
    Ok(())
}

fn plugin_module_from_generated(module: &GeneratedPluginModule) -> RuntimeResult<PluginModule> {
    Ok(PluginModule {
        module_id: module.module_id.to_string(),
        abi_version: u32::try_from(module.abi_version).map_err(|_| {
            RuntimeError::new("plugin", false, "generated runtime plugin ABI overflow")
        })?,
        deployment: generated_deployment(module.deployment),
        package_name: module.package_name.map(str::to_string),
        implementation_language: module.implementation_language.map(str::to_string),
        entrypoint_symbol: module.entrypoint_symbol.map(str::to_string),
        capabilities: generated_capabilities(module.capabilities),
        routes: generated_routes(module.routes),
    })
}

fn generated_routes(routes: GeneratedPluginRoutes) -> PluginRoutes {
    PluginRoutes {
        fetcher_source_kinds: routes
            .fetcher_source_kinds
            .iter()
            .map(|value| (*value).to_string())
            .collect(),
        video_frame_output_mime_types: routes
            .video_frame_output_mime_types
            .iter()
            .map(|value| (*value).to_string())
            .collect(),
        decoder_format_ids: routes
            .decoder_format_ids
            .iter()
            .map(|value| (*value).to_string())
            .collect(),
        decoder_mime_types: routes
            .decoder_mime_types
            .iter()
            .map(|value| (*value).to_string())
            .collect(),
        decoder_signatures: routes
            .decoder_signatures
            .iter()
            .map(|signature| pixa_core::RuntimePluginDecoderSignature {
                offset: signature.offset,
                magic: signature.magic.to_vec(),
                mime_type: signature.mime_type.to_string(),
                format_id: signature.format_id.map(str::to_string),
            })
            .collect(),
        processor_operations: routes
            .processor_operations
            .iter()
            .map(|value| (*value).to_string())
            .collect(),
        cache_store_namespaces: routes
            .cache_store_namespaces
            .iter()
            .map(|value| (*value).to_string())
            .collect(),
    }
}

fn generated_deployment(deployment: GeneratedPluginDeployment) -> PluginDeployment {
    match deployment {
        GeneratedPluginDeployment::BuiltInHost => PluginDeployment::BuiltInHostModule,
        GeneratedPluginDeployment::HostLinkedPlugin => PluginDeployment::HostLinkedPluginModule,
        GeneratedPluginDeployment::Asset => PluginDeployment::AssetModule,
    }
}

fn generated_capabilities(capabilities: GeneratedPluginCapabilities) -> PluginCapabilities {
    PluginCapabilities {
        fetcher: capabilities.fetcher,
        decoder: capabilities.decoder,
        processor: capabilities.processor,
        cache_store: capabilities.cache_store,
        host_managed_runtime: capabilities.host_managed_runtime,
        binary_messages: capabilities.binary_messages,
        owned_buffers: capabilities.owned_buffers,
        stream_handles: capabilities.stream_handles,
    }
}

static PLUGIN_HOST_API_V1: PixaPluginHostApiV1 = PixaPluginHostApiV1 {
    abi_version: pixa_core::PIXA_PLUGIN_ABI_VERSION,
    buffer_alloc: Some(plugin_host_buffer_alloc),
    buffer_data: Some(plugin_host_buffer_data),
    buffer_len: Some(plugin_host_buffer_len),
    buffer_free: Some(plugin_host_buffer_free),
};

#[derive(Clone)]
struct HostLinkedPluginExecutor {
    module_id: &'static str,
    callbacks: PixaPluginModuleApiV1,
}

impl PluginExecutor for HostLinkedPluginExecutor {
    fn fetch(&self, request: PluginFetchRequest<'_>) -> RuntimeResult<Option<PluginOutput>> {
        let Some(fetch) = self.callbacks.fetch else {
            return Ok(None);
        };
        let abi_request = PixaPluginFetchRequestV1 {
            source_kind_ptr: request.source_kind.as_ptr(),
            source_kind_len: request.source_kind.len(),
            locator_ptr: request.locator.as_ptr(),
            locator_len: request.locator.len(),
            has_video_frame: request.video_frame.is_some(),
            video_timestamp_micros: request
                .video_frame
                .map(|frame| frame.timestamp_micros)
                .unwrap_or(0),
            video_exact: request.video_frame.is_some_and(|frame| frame.exact),
            video_backend_ptr: request
                .video_frame
                .and_then(|frame| frame.backend)
                .map(str::as_ptr)
                .unwrap_or(std::ptr::null()),
            video_backend_len: request
                .video_frame
                .and_then(|frame| frame.backend)
                .map(str::len)
                .unwrap_or(0),
            max_output_bytes: request.max_output_bytes,
        };
        let mut output = empty_plugin_output();
        let status = unsafe { fetch(&abi_request, &mut output) };
        take_plugin_output(
            self.module_id,
            "fetch",
            status,
            output,
            request.max_output_bytes,
        )
        .map(Some)
    }

    fn decode(&self, request: PluginDecodeRequest<'_>) -> RuntimeResult<Option<PluginOutput>> {
        let Some(decode) = self.callbacks.decode else {
            return Ok(None);
        };
        let (format_id_ptr, format_id_len) = request
            .format_id
            .map(|format_id| (format_id.as_ptr(), format_id.len()))
            .unwrap_or((std::ptr::null(), 0));
        let abi_request = PixaPluginDecodeRequestV1 {
            mime_type_ptr: request.mime_type.as_ptr(),
            mime_type_len: request.mime_type.len(),
            format_id_ptr,
            format_id_len,
            bytes_ptr: request.bytes.as_ptr(),
            bytes_len: request.bytes.len(),
            target_width: request.target_width.unwrap_or(0),
            target_height: request.target_height.unwrap_or(0),
            max_decoded_pixels: request.max_decoded_pixels,
            max_output_bytes: request.max_output_bytes,
        };
        let mut output = empty_plugin_output();
        let status = unsafe { decode(&abi_request, &mut output) };
        take_plugin_output(
            self.module_id,
            "decode",
            status,
            output,
            request.max_output_bytes,
        )
        .map(Some)
    }

    fn process(&self, request: PluginProcessRequest<'_>) -> RuntimeResult<Option<PluginOutput>> {
        let Some(process) = self.callbacks.process else {
            return Ok(None);
        };
        let (format_id_ptr, format_id_len) = request
            .format_id
            .map(|format_id| (format_id.as_ptr(), format_id.len()))
            .unwrap_or((std::ptr::null(), 0));
        let (mime_type_ptr, mime_type_len) = request
            .mime_type
            .map(|mime_type| (mime_type.as_ptr(), mime_type.len()))
            .unwrap_or((std::ptr::null(), 0));
        let abi_request = PixaPluginProcessRequestV1 {
            operation_ptr: request.operation.as_ptr(),
            operation_len: request.operation.len(),
            descriptor_ptr: request.descriptor.as_ptr(),
            descriptor_len: request.descriptor.len(),
            format_id_ptr,
            format_id_len,
            mime_type_ptr,
            mime_type_len,
            bytes_ptr: request.bytes.as_ptr(),
            bytes_len: request.bytes.len(),
            max_decoded_pixels: request.max_decoded_pixels,
            max_output_bytes: request.max_output_bytes,
        };
        let mut output = empty_plugin_output();
        let status = unsafe { process(&abi_request, &mut output) };
        take_plugin_output(
            self.module_id,
            "processor",
            status,
            output,
            request.max_output_bytes,
        )
        .map(Some)
    }

    fn cache_read(
        &self,
        request: PluginCacheReadRequest<'_>,
    ) -> RuntimeResult<Option<PluginCacheReadResult>> {
        let Some(cache_read) = self.callbacks.cache_read else {
            return Ok(None);
        };
        let abi_request = PixaPluginCacheReadRequestV1 {
            namespace_ptr: request.namespace.as_ptr(),
            namespace_len: request.namespace.len(),
            key_ptr: request.key.as_ptr(),
            key_len: request.key.len(),
            allow_stale: request.allow_stale,
            max_output_bytes: request.max_output_bytes,
        };
        let mut output = PixaPluginCacheReadOutputV1 {
            status: 0,
            is_stale: false,
            payload: empty_plugin_output(),
        };
        let status = unsafe { cache_read(&abi_request, &mut output) };
        if status != 0 {
            unsafe {
                plugin_host_buffer_free(output.payload.buffer);
            }
            return Err(RuntimeError::new(
                "cache",
                false,
                format!(
                    "runtime plugin module {} returned cache read status {status}",
                    self.module_id
                ),
            ));
        }
        match output.status {
            0 => {
                unsafe {
                    plugin_host_buffer_free(output.payload.buffer);
                }
                Ok(Some(PluginCacheReadResult::Miss))
            }
            1 => {
                let payload = take_plugin_output(
                    self.module_id,
                    "cache",
                    0,
                    output.payload,
                    request.max_output_bytes,
                )?;
                Ok(Some(PluginCacheReadResult::Hit {
                    output: payload,
                    is_stale: output.is_stale,
                }))
            }
            value => {
                unsafe {
                    plugin_host_buffer_free(output.payload.buffer);
                }
                Err(RuntimeError::new(
                    "cache",
                    false,
                    format!(
                        "runtime plugin module {} returned invalid cache read result {value}",
                        self.module_id
                    ),
                ))
            }
        }
    }

    fn cache_write(&self, request: PluginCacheWriteRequest<'_>) -> RuntimeResult<Option<()>> {
        let Some(cache_write) = self.callbacks.cache_write else {
            return Ok(None);
        };
        let abi_request = PixaPluginCacheWriteRequestV1 {
            namespace_ptr: request.namespace.as_ptr(),
            namespace_len: request.namespace.len(),
            key_ptr: request.key.as_ptr(),
            key_len: request.key.len(),
            bytes_ptr: request.bytes.as_ptr(),
            bytes_len: request.bytes.len(),
            ttl_ms: request.ttl_ms.unwrap_or(0),
            has_ttl: request.ttl_ms.is_some(),
            private_entry: request.private_entry,
        };
        callback_status_to_result("cache_write", self.module_id, unsafe {
            cache_write(&abi_request)
        })
        .map(Some)
    }

    fn cache_remove(&self, request: PluginCacheRemoveRequest<'_>) -> RuntimeResult<Option<()>> {
        let Some(cache_remove) = self.callbacks.cache_remove else {
            return Ok(None);
        };
        let abi_request = PixaPluginCacheRemoveRequestV1 {
            namespace_ptr: request.namespace.as_ptr(),
            namespace_len: request.namespace.len(),
            key_ptr: request.key.as_ptr(),
            key_len: request.key.len(),
        };
        callback_status_to_result("cache", self.module_id, unsafe {
            cache_remove(&abi_request)
        })
        .map(Some)
    }

    fn cache_clear_namespace(
        &self,
        request: PluginCacheClearNamespaceRequest<'_>,
    ) -> RuntimeResult<Option<()>> {
        let Some(cache_clear_namespace) = self.callbacks.cache_clear_namespace else {
            return Ok(None);
        };
        let abi_request = PixaPluginCacheClearNamespaceRequestV1 {
            namespace_ptr: request.namespace.as_ptr(),
            namespace_len: request.namespace.len(),
        };
        callback_status_to_result("cache", self.module_id, unsafe {
            cache_clear_namespace(&abi_request)
        })
        .map(Some)
    }
}

fn instantiate_host_linked_executor(
    module: &GeneratedPluginModule,
    entrypoint: GeneratedPluginEntrypoint,
) -> RuntimeResult<HostLinkedPluginExecutor> {
    let mut callbacks = PixaPluginModuleApiV1 {
        abi_version: 0,
        fetch: None,
        decode: None,
        process: None,
        cache_read: None,
        cache_write: None,
        cache_remove: None,
        cache_clear_namespace: None,
    };
    let status = unsafe { entrypoint(&PLUGIN_HOST_API_V1, &mut callbacks) };
    if status != 0 {
        return Err(RuntimeError::new(
            "plugin",
            false,
            format!(
                "runtime plugin module {} entrypoint failed",
                module.module_id
            ),
        ));
    }
    if callbacks.abi_version != pixa_core::PIXA_PLUGIN_ABI_VERSION {
        return Err(RuntimeError::new(
            "plugin",
            false,
            format!(
                "runtime plugin module {} returned unsupported ABI version {}",
                module.module_id, callbacks.abi_version
            ),
        ));
    }
    if module.capabilities.fetcher && callbacks.fetch.is_none() {
        return Err(RuntimeError::new(
            "plugin",
            false,
            format!(
                "runtime plugin module {} declared fetcher capability without fetch callback",
                module.module_id
            ),
        ));
    }
    if module.capabilities.decoder && callbacks.decode.is_none() {
        return Err(RuntimeError::new(
            "plugin",
            false,
            format!(
                "runtime plugin module {} declared decoder capability without decode callback",
                module.module_id
            ),
        ));
    }
    if module.capabilities.processor && callbacks.process.is_none() {
        return Err(RuntimeError::new(
            "plugin",
            false,
            format!(
                "runtime plugin module {} declared processor capability without process callback",
                module.module_id
            ),
        ));
    }
    if module.capabilities.cache_store
        && (callbacks.cache_read.is_none()
            || callbacks.cache_write.is_none()
            || callbacks.cache_remove.is_none()
            || callbacks.cache_clear_namespace.is_none())
    {
        return Err(RuntimeError::new(
            "plugin",
            false,
            format!(
                "runtime plugin module {} declared cache-store capability without full cache-store callbacks",
                module.module_id
            ),
        ));
    }
    Ok(HostLinkedPluginExecutor {
        module_id: module.module_id,
        callbacks,
    })
}

fn callback_status_to_result(
    stage: &'static str,
    module_id: &str,
    status: i32,
) -> RuntimeResult<()> {
    if status == 0 {
        Ok(())
    } else {
        Err(RuntimeError::new(
            stage,
            false,
            format!("runtime plugin module {module_id} returned status {status}"),
        ))
    }
}

fn empty_plugin_output() -> PixaPluginOutputV1 {
    PixaPluginOutputV1 {
        buffer: std::ptr::null_mut(),
        mime_type_ptr: std::ptr::null(),
        mime_type_len: 0,
    }
}

fn take_plugin_output(
    module_id: &str,
    stage: &'static str,
    status: i32,
    output: PixaPluginOutputV1,
    max_output_bytes: usize,
) -> RuntimeResult<PluginOutput> {
    if status != 0 {
        unsafe {
            plugin_host_buffer_free(output.buffer);
        }
        return Err(RuntimeError::new(
            stage,
            false,
            format!("runtime plugin module {module_id} returned status {status}"),
        ));
    }
    if output.buffer.is_null() {
        return Err(RuntimeError::new(
            stage,
            false,
            format!("runtime plugin module {module_id} returned no output buffer"),
        ));
    }
    let bytes = unsafe { take_plugin_host_buffer(output.buffer) };
    if bytes.len() > max_output_bytes {
        return Err(RuntimeError::new(
            stage,
            false,
            format!("runtime plugin module {module_id} output exceeds byte limit"),
        ));
    }
    let mime_type = plugin_output_mime_type(&output)?;
    Ok(PluginOutput::from_vec(bytes, mime_type.as_deref()))
}

fn plugin_output_mime_type(output: &PixaPluginOutputV1) -> RuntimeResult<Option<String>> {
    if output.mime_type_ptr.is_null() {
        if output.mime_type_len == 0 {
            return Ok(None);
        }
        return Err(RuntimeError::new(
            "plugin",
            false,
            "runtime plugin output MIME pointer is null",
        ));
    }
    let bytes = unsafe { bytes_from_ptr(output.mime_type_ptr, output.mime_type_len) }
        .ok_or_else(|| RuntimeError::new("plugin", false, "invalid runtime plugin MIME bytes"))?;
    let mime_type = std::str::from_utf8(bytes)
        .map_err(|_| RuntimeError::new("plugin", false, "runtime plugin MIME is not UTF-8"))?
        .trim();
    if mime_type.is_empty() {
        Ok(None)
    } else {
        Ok(Some(mime_type.to_string()))
    }
}

unsafe extern "C" fn plugin_host_buffer_alloc(len: usize) -> *mut c_void {
    let mut bytes = Vec::new();
    if bytes.try_reserve_exact(len).is_err() {
        return std::ptr::null_mut();
    }
    bytes.resize(len, 0);
    Box::into_raw(Box::new(PluginHostBuffer { bytes })).cast::<c_void>()
}

unsafe extern "C" fn plugin_host_buffer_data(handle: *mut c_void) -> *mut u8 {
    let Some(buffer) = (handle as *mut PluginHostBuffer).as_mut() else {
        return std::ptr::null_mut();
    };
    buffer.bytes.as_mut_ptr()
}

unsafe extern "C" fn plugin_host_buffer_len(handle: *const c_void) -> usize {
    let Some(buffer) = (handle as *const PluginHostBuffer).as_ref() else {
        return 0;
    };
    buffer.bytes.len()
}

unsafe extern "C" fn plugin_host_buffer_free(handle: *mut c_void) {
    if !handle.is_null() {
        drop(Box::from_raw(handle.cast::<PluginHostBuffer>()));
    }
}

unsafe fn take_plugin_host_buffer(handle: *mut c_void) -> Vec<u8> {
    Box::from_raw(handle.cast::<PluginHostBuffer>()).bytes
}

/// Built-in QOI decoder module linked through the same plugin ABI as third-party decoders.
///
/// # Safety
///
/// `host` must point to a valid `PixaPluginHostApiV1` for the duration of the
/// call and `module` must point to writable `PixaPluginModuleApiV1` storage.
#[allow(private_interfaces)]
#[no_mangle]
pub unsafe extern "C" fn pixa_qoi_decoder_plugin_init(
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
    let _ = QOI_DECODER_HOST_API.set(host_api);
    unsafe {
        (*module).abi_version = pixa_core::PIXA_PLUGIN_ABI_VERSION;
        (*module).decode = Some(pixa_qoi_decoder_plugin_decode);
    }
    0
}

unsafe extern "C" fn pixa_qoi_decoder_plugin_decode(
    request: *const PixaPluginDecodeRequestV1,
    output: *mut PixaPluginOutputV1,
) -> i32 {
    if request.is_null() || output.is_null() {
        return -1;
    }
    let request = unsafe { &*request };
    let Some(mime_type) = (unsafe { bytes_to_str(request.mime_type_ptr, request.mime_type_len) })
    else {
        return -2;
    };
    let format_id = unsafe { bytes_to_str(request.format_id_ptr, request.format_id_len) };
    let routed_by_format = format_id
        .map(|value| value.eq_ignore_ascii_case("qoi"))
        .unwrap_or(false);
    let routed_by_mime = mime_type.eq_ignore_ascii_case("image/qoi")
        || mime_type.eq_ignore_ascii_case("image/x-qoi");
    if !routed_by_format && !routed_by_mime {
        return -3;
    }
    let Some(input) = (unsafe { bytes_from_ptr(request.bytes_ptr, request.bytes_len) }) else {
        return -4;
    };
    let bytes = match decode_image_to_png_variant(
        input,
        request.max_decoded_pixels,
        request.max_output_bytes,
    ) {
        Ok(bytes) => bytes,
        Err(_) => return -5,
    };
    if bytes.len() > request.max_output_bytes {
        return -6;
    }
    let Some(host) = QOI_DECODER_HOST_API.get() else {
        return -7;
    };
    let Some(buffer_alloc) = host.buffer_alloc else {
        return -8;
    };
    let Some(buffer_data) = host.buffer_data else {
        return -9;
    };
    let Some(buffer_free) = host.buffer_free else {
        return -10;
    };
    let handle = unsafe { buffer_alloc(bytes.len()) };
    if handle.is_null() {
        return -11;
    }
    let data = unsafe { buffer_data(handle) };
    if data.is_null() {
        unsafe {
            buffer_free(handle);
        }
        return -12;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), data, bytes.len());
        (*output).buffer = handle;
        (*output).mime_type_ptr = QOI_DECODER_OUTPUT_MIME.as_ptr();
        (*output).mime_type_len = QOI_DECODER_OUTPUT_MIME.len();
    }
    0
}

/// Hashes a byte range using the Pixa runtime cache-key hash.
#[no_mangle]
pub extern "C" fn pixa_fnv1a64(ptr: *const u8, len: usize) -> u64 {
    let Some(bytes) = (unsafe { bytes_from_ptr(ptr, len) }) else {
        return 0;
    };
    pixa_core::fnv1a64(bytes)
}

/// Returns the runtime plugin host ABI version accepted by this runtime.
#[no_mangle]
pub extern "C" fn pixa_plugin_abi_version() -> u32 {
    pixa_core::PIXA_PLUGIN_ABI_VERSION
}

/// Returns binary encoded runtime plugin registry stats. Caller must free it.
#[no_mangle]
pub extern "C" fn pixa_plugin_registry_stats(out_len: *mut usize) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len = 0;
    }

    let result = ensure_generated_plugins_registered()
        .and_then(|()| plugin_registry_stats())
        .and_then(encode_plugin_registry_stats);
    match result {
        Ok(bytes) => write_success(bytes, out_len),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Hashes cache-key material once and returns primary and secondary hashes.
#[no_mangle]
pub extern "C" fn pixa_cache_key_hash_pair(
    ptr: *const u8,
    len: usize,
    out_primary: *mut u64,
    out_secondary: *mut u64,
) -> i32 {
    if out_primary.is_null() || out_secondary.is_null() {
        return -1;
    }
    let Some(bytes) = (unsafe { bytes_from_ptr(ptr, len) }) else {
        return -1;
    };
    unsafe {
        *out_primary = pixa_core::fnv1a64(bytes);
        *out_secondary = pixa_core::fnv1a64_with_prefix(b"material:", bytes);
    }
    0
}

/// Applies runtime configuration.
#[no_mangle]
pub extern "C" fn pixa_configure(
    memory_cache_bytes: usize,
    disk_cache_bytes: usize,
    network_concurrency: usize,
) -> i32 {
    match configure(RuntimePipelineConfig {
        memory_cache_bytes,
        disk_cache_bytes,
        network_concurrency,
    }) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// Creates a runtime cancellation token. Returns 0 on failure.
#[no_mangle]
pub extern "C" fn pixa_cancel_token_create() -> u64 {
    create_cancel_token().unwrap_or(0)
}

/// Requests cancellation for a runtime token.
#[no_mangle]
pub extern "C" fn pixa_cancel_token_cancel(token_id: u64) -> i32 {
    match cancel_token(token_id) {
        Ok(true) => 0,
        Ok(false) => 1,
        Err(_) => -1,
    }
}

/// Releases a runtime cancellation token.
#[no_mangle]
pub extern "C" fn pixa_cancel_token_free(token_id: u64) -> i32 {
    match free_cancel_token(token_id) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// Loads encoded image bytes through the Rust pipeline.
///
/// On success returns an owned byte buffer and writes its length to `out_len`.
/// On failure returns null and writes a compact binary error buffer into `out_error_ptr`.
#[no_mangle]
pub extern "C" fn pixa_load(
    root_ptr: *const u8,
    root_len: usize,
    request_ptr: *const u8,
    request_len: usize,
    inline_bytes_ptr: *const u8,
    inline_bytes_len: usize,
    out_len: *mut usize,
    out_error_ptr: *mut *mut u8,
    out_error_len: *mut usize,
) -> *mut u8 {
    pixa_load_with_cancel(
        root_ptr,
        root_len,
        request_ptr,
        request_len,
        inline_bytes_ptr,
        inline_bytes_len,
        0,
        out_len,
        out_error_ptr,
        out_error_len,
    )
}

/// Loads encoded image bytes with an optional cancellation token.
#[no_mangle]
pub extern "C" fn pixa_load_with_cancel(
    root_ptr: *const u8,
    root_len: usize,
    request_ptr: *const u8,
    request_len: usize,
    inline_bytes_ptr: *const u8,
    inline_bytes_len: usize,
    cancel_token_id: u64,
    out_len: *mut usize,
    out_error_ptr: *mut *mut u8,
    out_error_len: *mut usize,
) -> *mut u8 {
    pixa_load_with_cancel_and_progress(
        root_ptr,
        root_len,
        request_ptr,
        request_len,
        inline_bytes_ptr,
        inline_bytes_len,
        cancel_token_id,
        0,
        out_len,
        out_error_ptr,
        out_error_len,
    )
}

/// Loads encoded image bytes with optional cancellation and progress session.
#[no_mangle]
pub extern "C" fn pixa_load_with_cancel_and_progress(
    root_ptr: *const u8,
    root_len: usize,
    request_ptr: *const u8,
    request_len: usize,
    inline_bytes_ptr: *const u8,
    inline_bytes_len: usize,
    cancel_token_id: u64,
    progress_session_id: u64,
    out_len: *mut usize,
    out_error_ptr: *mut *mut u8,
    out_error_len: *mut usize,
) -> *mut u8 {
    reset_out(out_len, out_error_ptr, out_error_len);

    let result = (|| {
        ensure_generated_plugins_registered()?;
        let root = unsafe { bytes_to_str(root_ptr, root_len) }
            .ok_or_else(|| RuntimeError::new("runtime", false, "invalid cache root"))?;
        let request_bytes = unsafe { bytes_from_ptr(request_ptr, request_len) }
            .ok_or_else(|| RuntimeError::new("runtime", false, "invalid binary request"))?;
        let request = decode_binary_request(request_bytes)?;
        let inline_bytes = unsafe { bytes_from_ptr(inline_bytes_ptr, inline_bytes_len) };
        let cancel_token = cancel_token_handle(cancel_token_id)?;
        if progress_session_id == 0 {
            return load_image_with_cancel(root, request, inline_bytes, cancel_token);
        }
        let progress_sink = ProgressSessionSink {
            session_id: progress_session_id,
        };
        load_image_with_cancel_and_progress(
            root,
            request,
            inline_bytes,
            cancel_token,
            Some(&progress_sink),
        )
    })();

    match result {
        Ok(outcome) => write_success(outcome.bytes.to_vec(), out_len),
        Err(error) => {
            write_error(error, out_error_ptr, out_error_len);
            std::ptr::null_mut()
        }
    }
}

/// Loads encoded image bytes and returns an opaque owned buffer handle.
#[no_mangle]
pub extern "C" fn pixa_load_handle_with_cancel_and_progress(
    root_ptr: *const u8,
    root_len: usize,
    request_ptr: *const u8,
    request_len: usize,
    inline_bytes_ptr: *const u8,
    inline_bytes_len: usize,
    cancel_token_id: u64,
    progress_session_id: u64,
    out_len: *mut usize,
    out_error_ptr: *mut *mut u8,
    out_error_len: *mut usize,
) -> *mut c_void {
    reset_out(out_len, out_error_ptr, out_error_len);

    let result = (|| {
        ensure_generated_plugins_registered()?;
        let root = unsafe { bytes_to_str(root_ptr, root_len) }
            .ok_or_else(|| RuntimeError::new("runtime", false, "invalid cache root"))?;
        let request_bytes = unsafe { bytes_from_ptr(request_ptr, request_len) }
            .ok_or_else(|| RuntimeError::new("runtime", false, "invalid binary request"))?;
        let request = decode_binary_request(request_bytes)?;
        let inline_bytes = unsafe { bytes_from_ptr(inline_bytes_ptr, inline_bytes_len) };
        let cancel_token = cancel_token_handle(cancel_token_id)?;
        if progress_session_id == 0 {
            return load_image_with_cancel(root, request, inline_bytes, cancel_token);
        }
        let progress_sink = ProgressSessionSink {
            session_id: progress_session_id,
        };
        load_image_with_cancel_and_progress(
            root,
            request,
            inline_bytes,
            cancel_token,
            Some(&progress_sink),
        )
    })();

    match result {
        Ok(outcome) => write_success_handle(outcome.bytes, out_len),
        Err(error) => {
            write_error(error, out_error_ptr, out_error_len);
            std::ptr::null_mut()
        }
    }
}

/// Creates a runtime progress session. Returns 0 on failure.
#[no_mangle]
pub extern "C" fn pixa_progress_session_create() -> u64 {
    let session_id = NEXT_PROGRESS_SESSION_ID.fetch_add(1, Ordering::Relaxed);
    let Ok(mut sessions) = progress_sessions().lock() else {
        return 0;
    };
    sessions.insert(session_id, ProgressSession::default());
    PROGRESS_SESSIONS_CREATED.fetch_add(1, Ordering::Relaxed);
    session_id
}

/// Drains progress events as a compact binary buffer. Caller must release the buffer.
#[no_mangle]
pub extern "C" fn pixa_progress_session_drain(session_id: u64, out_len: *mut usize) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len = 0;
    }
    let result = (|| {
        let mut sessions = progress_sessions().lock().ok()?;
        let session = sessions.get_mut(&session_id)?;
        let events = session
            .events
            .drain(..)
            .collect::<Vec<RuntimeProgressEvent>>();
        PROGRESS_EVENTS_DRAINED.fetch_add(events.len() as u64, Ordering::Relaxed);
        let dropped_events = session.dropped_events;
        session.dropped_events = 0;
        encode_progress_drain(dropped_events, events).ok()
    })();
    match result {
        Some(bytes) => write_success(bytes, out_len),
        None => std::ptr::null_mut(),
    }
}

fn encode_progress_drain(
    dropped_events: u64,
    events: Vec<RuntimeProgressEvent>,
) -> RuntimeResult<Vec<u8>> {
    let count = u32::try_from(events.len())
        .map_err(|_| RuntimeError::new("progress", false, "too many progress events to encode"))?;
    let mut bytes = Vec::with_capacity(16 + events.len() * 32);
    bytes.extend_from_slice(b"PXP1");
    bytes.extend_from_slice(&dropped_events.to_le_bytes());
    bytes.extend_from_slice(&count.to_le_bytes());
    for event in events {
        bytes.push(progress_stage_code(event.stage));
        push_string(&mut bytes, &event.name)?;
        let mut flags = 0u8;
        if event.received_bytes.is_some() {
            flags |= 0x01;
        }
        if event.expected_bytes.is_some() {
            flags |= 0x02;
        }
        if event.message.is_some() {
            flags |= 0x04;
        }
        if event.preview_bytes.is_some() {
            flags |= 0x08;
        }
        bytes.push(flags);
        if let Some(value) = event.received_bytes {
            bytes.extend_from_slice(&(value as u64).to_le_bytes());
        }
        if let Some(value) = event.expected_bytes {
            bytes.extend_from_slice(&(value as u64).to_le_bytes());
        }
        bytes.extend_from_slice(&event.timestamp_ms.to_le_bytes());
        if let Some(message) = event.message.as_deref() {
            push_string(&mut bytes, message)?;
        }
        if let Some(preview) = event.preview_bytes {
            let len = preview.len();
            let handle = owned_buffer_handle(OwnedBufferStorage::Boxed(preview.into_boxed_slice()));
            bytes.extend_from_slice(&(handle as usize as u64).to_le_bytes());
            bytes.extend_from_slice(&(len as u64).to_le_bytes());
        }
    }
    Ok(bytes)
}

fn progress_stage_code(stage: RuntimeProgressStage) -> u8 {
    match stage {
        RuntimeProgressStage::Request => 0,
        RuntimeProgressStage::CacheLookup => 1,
        RuntimeProgressStage::Fetch => 2,
        RuntimeProgressStage::Decode => 3,
        RuntimeProgressStage::Process => 4,
        RuntimeProgressStage::CacheWrite => 5,
        RuntimeProgressStage::Complete => 6,
        RuntimeProgressStage::Cancel => 7,
    }
}

fn push_string(bytes: &mut Vec<u8>, value: &str) -> RuntimeResult<()> {
    let len = u32::try_from(value.len()).map_err(|_| {
        RuntimeError::new(
            "runtime",
            false,
            "runtime binary string exceeds length limit",
        )
    })?;
    bytes.extend_from_slice(&len.to_le_bytes());
    bytes.extend_from_slice(value.as_bytes());
    Ok(())
}

fn push_u64(bytes: &mut Vec<u8>, value: u64) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn push_u16(bytes: &mut Vec<u8>, value: u16) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn push_usize_as_u64(bytes: &mut Vec<u8>, value: usize, name: &'static str) -> RuntimeResult<()> {
    let value = u64::try_from(value).map_err(|_| {
        RuntimeError::new(
            "runtime",
            false,
            format!("runtime cache stats field {name} exceeds u64"),
        )
    })?;
    push_u64(bytes, value);
    Ok(())
}

/// Releases a runtime progress session.
#[no_mangle]
pub extern "C" fn pixa_progress_session_free(session_id: u64) -> i32 {
    let Ok(mut sessions) = progress_sessions().lock() else {
        return -1;
    };
    if sessions.remove(&session_id).is_some() {
        PROGRESS_SESSIONS_FREED.fetch_add(1, Ordering::Relaxed);
        0
    } else {
        1
    }
}

/// Writes a disk cache entry through Rust core cache.
#[no_mangle]
pub extern "C" fn pixa_disk_write(
    root_ptr: *const u8,
    root_len: usize,
    namespace_ptr: *const u8,
    namespace_len: usize,
    key_ptr: *const u8,
    key_len: usize,
    bytes_ptr: *const u8,
    bytes_len: usize,
    ttl_millis: i64,
) -> i32 {
    let result = (|| {
        let root = unsafe { bytes_to_str(root_ptr, root_len) }?;
        let namespace = unsafe { bytes_to_str(namespace_ptr, namespace_len) }?;
        let key = unsafe { bytes_to_str(key_ptr, key_len) }?;
        let bytes = unsafe { bytes_from_ptr(bytes_ptr, bytes_len) }?;
        DiskCache::new(root)
            .write(
                namespace,
                key,
                bytes,
                (ttl_millis >= 0).then_some(ttl_millis),
            )
            .and_then(|_| disk_trim_to_configured_budget(root))
            .ok()
    })();
    if result.is_some() {
        0
    } else {
        -1
    }
}

/// Reads a disk cache entry. The caller must release the returned buffer.
#[no_mangle]
pub extern "C" fn pixa_disk_read(
    root_ptr: *const u8,
    root_len: usize,
    namespace_ptr: *const u8,
    namespace_len: usize,
    key_ptr: *const u8,
    key_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len = 0;
    }

    let result = (|| {
        let root = unsafe { bytes_to_str(root_ptr, root_len) }?;
        let namespace = unsafe { bytes_to_str(namespace_ptr, namespace_len) }?;
        let key = unsafe { bytes_to_str(key_ptr, key_len) }?;
        DiskCache::new(root).read(namespace, key).ok().flatten()
    })();

    match result {
        Some(bytes) => write_success(bytes, out_len),
        None => std::ptr::null_mut(),
    }
}

/// Checks whether a disk cache entry exists without reading encoded bytes.
#[no_mangle]
pub extern "C" fn pixa_disk_contains(
    root_ptr: *const u8,
    root_len: usize,
    namespace_ptr: *const u8,
    namespace_len: usize,
    key_ptr: *const u8,
    key_len: usize,
    allow_stale: bool,
) -> i32 {
    let result = (|| {
        let root = unsafe { bytes_to_str(root_ptr, root_len) }?;
        let namespace = unsafe { bytes_to_str(namespace_ptr, namespace_len) }?;
        let key = unsafe { bytes_to_str(key_ptr, key_len) }?;
        DiskCache::new(root)
            .contains(namespace, key, allow_stale)
            .ok()
    })();
    match result {
        Some(true) => 0,
        Some(false) => 1,
        None => -1,
    }
}

/// Releases a buffer returned by runtime APIs.
#[no_mangle]
pub extern "C" fn pixa_buffer_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        unsafe {
            let _ = Vec::from_raw_parts(ptr, len, len);
        }
    }
}

/// Wraps an owned byte pointer into an opaque handle for Dart finalizers.
#[no_mangle]
pub extern "C" fn pixa_owned_buffer_create(ptr: *mut u8, len: usize) -> *mut c_void {
    if ptr.is_null() && len > 0 {
        return std::ptr::null_mut();
    }
    let bytes = if ptr.is_null() {
        Vec::new().into_boxed_slice()
    } else {
        unsafe { Vec::from_raw_parts(ptr, len, len).into_boxed_slice() }
    };
    owned_buffer_handle(OwnedBufferStorage::Boxed(bytes))
}

/// Returns the data pointer for an owned buffer handle.
#[no_mangle]
pub extern "C" fn pixa_owned_buffer_data(handle: *mut c_void) -> *mut u8 {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    unsafe { (*(handle.cast::<OwnedBufferHandle>())).data() }
}

/// Returns the byte length for an owned buffer handle.
#[no_mangle]
pub extern "C" fn pixa_owned_buffer_len(handle: *mut c_void) -> usize {
    if handle.is_null() {
        return 0;
    }
    unsafe { (*(handle.cast::<OwnedBufferHandle>())).len() }
}

/// Decodes an owned encoded buffer into Runtime-owned RGBA pixels.
#[no_mangle]
pub extern "C" fn pixa_decode_rgba_from_owned_buffer(
    handle: *mut c_void,
    max_decoded_pixels: u64,
    max_output_bytes: usize,
    out_width: *mut u32,
    out_height: *mut u32,
    out_row_bytes: *mut usize,
    out_len: *mut usize,
    out_error_ptr: *mut *mut u8,
    out_error_len: *mut usize,
) -> *mut c_void {
    reset_out(out_len, out_error_ptr, out_error_len);
    if !out_width.is_null() {
        unsafe {
            *out_width = 0;
        }
    }
    if !out_height.is_null() {
        unsafe {
            *out_height = 0;
        }
    }
    if !out_row_bytes.is_null() {
        unsafe {
            *out_row_bytes = 0;
        }
    }

    let result = (|| {
        if handle.is_null() {
            return Err(RuntimeError::new(
                "runtime",
                false,
                "encoded buffer handle is null",
            ));
        }
        if out_width.is_null() || out_height.is_null() || out_row_bytes.is_null() {
            return Err(RuntimeError::new(
                "runtime",
                false,
                "decode RGBA output pointer is null",
            ));
        }
        let input = unsafe { &*(handle.cast::<OwnedBufferHandle>()) };
        decode_image_to_rgba(input.bytes(), max_decoded_pixels, max_output_bytes)
    })();

    match result {
        Ok(image) => {
            unsafe {
                *out_width = image.width;
                *out_height = image.height;
                *out_row_bytes = image.row_bytes;
            }
            let length = image.bytes.len();
            if !out_len.is_null() {
                unsafe {
                    *out_len = length;
                }
            }
            owned_buffer_handle(OwnedBufferStorage::Boxed(image.bytes.into_boxed_slice()))
        }
        Err(error) => {
            write_error(error, out_error_ptr, out_error_len);
            std::ptr::null_mut()
        }
    }
}

/// Releases an owned buffer handle and its bytes.
#[no_mangle]
pub extern "C" fn pixa_owned_buffer_free(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    OWNED_BUFFER_HANDLES_FREED.fetch_add(1, Ordering::Relaxed);
    unsafe {
        let _ = Box::from_raw(handle.cast::<OwnedBufferHandle>());
    }
}

/// Removes one disk cache entry.
#[no_mangle]
pub extern "C" fn pixa_disk_remove(
    root_ptr: *const u8,
    root_len: usize,
    namespace_ptr: *const u8,
    namespace_len: usize,
    key_ptr: *const u8,
    key_len: usize,
) -> i32 {
    let result = (|| {
        let root = unsafe { bytes_to_str(root_ptr, root_len) }?;
        let namespace = unsafe { bytes_to_str(namespace_ptr, namespace_len) }?;
        let key = unsafe { bytes_to_str(key_ptr, key_len) }?;
        DiskCache::new(root).remove(namespace, key).ok()
    })();
    if result.is_some() {
        0
    } else {
        -1
    }
}

/// Clears one namespace.
#[no_mangle]
pub extern "C" fn pixa_disk_clear_namespace(
    root_ptr: *const u8,
    root_len: usize,
    namespace_ptr: *const u8,
    namespace_len: usize,
) -> i32 {
    let result = (|| {
        let root = unsafe { bytes_to_str(root_ptr, root_len) }?;
        let namespace = unsafe { bytes_to_str(namespace_ptr, namespace_len) }?;
        DiskCache::new(root).clear_namespace(namespace).ok()
    })();
    if result.is_some() {
        0
    } else {
        -1
    }
}

/// Clears the full Pixa disk cache.
#[no_mangle]
pub extern "C" fn pixa_disk_clear_all(root_ptr: *const u8, root_len: usize) -> i32 {
    let result = (|| {
        let root = unsafe { bytes_to_str(root_ptr, root_len) }?;
        DiskCache::new(root).clear_all().ok()
    })();
    if result.is_some() {
        0
    } else {
        -1
    }
}

/// Removes one encoded memory cache entry.
#[no_mangle]
pub extern "C" fn pixa_memory_remove(key_ptr: *const u8, key_len: usize) -> i32 {
    let result = (|| {
        let key = unsafe { bytes_to_str(key_ptr, key_len) }?;
        memory_remove(key).ok()
    })();
    if result.is_some() {
        0
    } else {
        -1
    }
}

/// Checks whether encoded memory contains a fresh entry.
#[no_mangle]
pub extern "C" fn pixa_memory_contains(key_ptr: *const u8, key_len: usize) -> i32 {
    let result = (|| {
        let key = unsafe { bytes_to_str(key_ptr, key_len) }?;
        memory_contains(key).ok()
    })();
    match result {
        Some(true) => 0,
        Some(false) => 1,
        None => -1,
    }
}

/// Reads one processed variant from encoded memory cache.
#[no_mangle]
pub extern "C" fn pixa_memory_read_processed(
    key_ptr: *const u8,
    key_len: usize,
    out_len: *mut usize,
) -> *mut c_void {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len = 0;
    }
    let result = (|| {
        let key = unsafe { bytes_to_str(key_ptr, key_len) }?;
        memory_get_processed(key).ok().flatten()
    })();
    match result {
        Some(bytes) => write_success_handle(bytes, out_len),
        None => std::ptr::null_mut(),
    }
}

/// Writes one processed variant into encoded memory cache.
#[no_mangle]
pub extern "C" fn pixa_memory_write_processed(
    namespace_ptr: *const u8,
    namespace_len: usize,
    key_ptr: *const u8,
    key_len: usize,
    bytes_ptr: *const u8,
    bytes_len: usize,
    ttl_millis: i64,
) -> i32 {
    let result = (|| {
        let namespace = unsafe { bytes_to_str(namespace_ptr, namespace_len) }?;
        let key = unsafe { bytes_to_str(key_ptr, key_len) }?;
        let bytes = unsafe { bytes_from_ptr(bytes_ptr, bytes_len) }?;
        memory_put_processed(
            namespace,
            key,
            bytes,
            (ttl_millis >= 0).then_some(ttl_millis),
        )
        .ok()
    })();
    if result.is_some() {
        0
    } else {
        -1
    }
}

/// Pins one encoded memory cache entry. Returns 1 when the entry is absent.
#[no_mangle]
pub extern "C" fn pixa_memory_pin(key_ptr: *const u8, key_len: usize) -> i32 {
    let result = (|| {
        let key = unsafe { bytes_to_str(key_ptr, key_len) }?;
        memory_pin(key).ok()
    })();
    match result {
        Some(true) => 0,
        Some(false) => 1,
        None => -1,
    }
}

/// Releases one active encoded memory pin. Returns 1 when no pin was held.
#[no_mangle]
pub extern "C" fn pixa_memory_unpin(key_ptr: *const u8, key_len: usize) -> i32 {
    let result = (|| {
        let key = unsafe { bytes_to_str(key_ptr, key_len) }?;
        memory_unpin(key).ok()
    })();
    match result {
        Some(true) => 0,
        Some(false) => 1,
        None => -1,
    }
}

/// Clears all encoded memory cache entries.
#[no_mangle]
pub extern "C" fn pixa_memory_clear() -> i32 {
    match memory_clear() {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// Clears encoded memory cache entries in one namespace.
#[no_mangle]
pub extern "C" fn pixa_memory_clear_namespace(
    namespace_ptr: *const u8,
    namespace_len: usize,
) -> i32 {
    let result = (|| {
        let namespace = unsafe { bytes_to_str(namespace_ptr, namespace_len) }?;
        memory_clear_namespace(namespace).ok()
    })();
    if result.is_some() {
        0
    } else {
        -1
    }
}

/// Trims encoded memory cache to a target byte budget.
#[no_mangle]
pub extern "C" fn pixa_memory_trim_to_bytes(target_bytes: usize) -> i32 {
    match memory_trim_to_bytes(target_bytes) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// Returns a binary encoded cache stats snapshot. Caller must free the buffer.
#[no_mangle]
pub extern "C" fn pixa_cache_stats(out_len: *mut usize) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len = 0;
    }

    let result = cache_stats().and_then(encode_cache_stats);
    match result {
        Ok(bytes) => write_success(bytes, out_len),
        Err(_) => std::ptr::null_mut(),
    }
}

fn encode_cache_stats(stats: RuntimeCacheStats) -> RuntimeResult<Vec<u8>> {
    let mut bytes = Vec::with_capacity(4 + 30 * 8);
    bytes.extend_from_slice(b"PXS1");
    push_usize_as_u64(&mut bytes, stats.memory_entries, "memory_entries")?;
    push_usize_as_u64(&mut bytes, stats.memory_bytes, "memory_bytes")?;
    push_u64(&mut bytes, stats.memory_hits);
    push_u64(&mut bytes, stats.memory_misses);
    push_u64(&mut bytes, stats.disk_hits);
    push_u64(&mut bytes, stats.disk_misses);
    push_u64(&mut bytes, stats.disk_writes);
    push_u64(&mut bytes, stats.disk_corruption_recoveries);
    push_u64(&mut bytes, stats.evictions);
    push_u64(&mut bytes, stats.stale_revalidates_started);
    push_u64(&mut bytes, stats.stale_revalidates_completed);
    push_u64(&mut bytes, stats.stale_revalidates_failed);
    push_u64(&mut bytes, stats.stale_revalidates_skipped);
    push_u64(&mut bytes, stats.stale_revalidates_in_flight);
    push_u64(&mut bytes, stats.processed_memory_hits);
    push_u64(&mut bytes, stats.processed_memory_misses);
    push_u64(&mut bytes, stats.processed_memory_evictions);
    push_u64(&mut bytes, stats.processed_disk_hits);
    push_u64(&mut bytes, stats.processed_disk_misses);
    push_u64(&mut bytes, stats.processed_disk_stale_hits);
    push_u64(&mut bytes, stats.processed_disk_writes);
    push_u64(&mut bytes, stats.processed_disk_corruption_recoveries);
    push_u64(
        &mut bytes,
        OWNED_BUFFER_HANDLES_CREATED.load(Ordering::Relaxed),
    );
    push_u64(
        &mut bytes,
        OWNED_BUFFER_HANDLES_FREED.load(Ordering::Relaxed),
    );
    push_u64(
        &mut bytes,
        OWNED_BUFFER_BYTES_EXPOSED.load(Ordering::Relaxed),
    );
    push_u64(
        &mut bytes,
        PROGRESS_SESSIONS_CREATED.load(Ordering::Relaxed),
    );
    push_u64(&mut bytes, PROGRESS_SESSIONS_FREED.load(Ordering::Relaxed));
    push_u64(&mut bytes, PROGRESS_EVENTS_EMITTED.load(Ordering::Relaxed));
    push_u64(&mut bytes, PROGRESS_EVENTS_DROPPED.load(Ordering::Relaxed));
    push_u64(&mut bytes, PROGRESS_EVENTS_DRAINED.load(Ordering::Relaxed));
    Ok(bytes)
}

fn encode_plugin_registry_stats(stats: PluginRegistryStats) -> RuntimeResult<Vec<u8>> {
    let mut bytes = Vec::with_capacity(4 + 11 * 8);
    bytes.extend_from_slice(b"PXM1");
    push_usize_as_u64(&mut bytes, stats.modules, "modules")?;
    push_usize_as_u64(&mut bytes, stats.built_in_modules, "built_in_modules")?;
    push_usize_as_u64(&mut bytes, stats.host_linked_modules, "host_linked_modules")?;
    push_usize_as_u64(&mut bytes, stats.runtime_asset_modules, "asset_modules")?;
    push_usize_as_u64(&mut bytes, stats.linkable_modules, "linkable_modules")?;
    push_usize_as_u64(&mut bytes, stats.fetchers, "fetchers")?;
    push_usize_as_u64(
        &mut bytes,
        stats.video_frame_fetchers,
        "video_frame_fetchers",
    )?;
    push_usize_as_u64(
        &mut bytes,
        stats.video_frame_encoded_output_fetchers,
        "video_frame_encoded_output_fetchers",
    )?;
    push_usize_as_u64(&mut bytes, stats.decoders, "decoders")?;
    push_usize_as_u64(&mut bytes, stats.processors, "processors")?;
    push_usize_as_u64(&mut bytes, stats.cache_stores, "cache_stores")?;
    push_string_list(
        &mut bytes,
        &stats.video_frame_source_kinds,
        "video_frame_source_kinds",
    )?;
    push_string_list(
        &mut bytes,
        &stats.video_frame_output_mime_types,
        "video_frame_output_mime_types",
    )?;
    Ok(bytes)
}

fn push_string_list(bytes: &mut Vec<u8>, values: &[String], label: &str) -> RuntimeResult<()> {
    let count = u32::try_from(values.len()).map_err(|_| {
        RuntimeError::new("runtime", false, format!("{label} count exceeds ABI limit"))
    })?;
    bytes.extend_from_slice(&count.to_le_bytes());
    for value in values {
        push_string(bytes, value)?;
    }
    Ok(())
}

fn encode_image_format_capabilities() -> RuntimeResult<Vec<u8>> {
    let capabilities = runtime_image_format_capabilities();
    let count = u16::try_from(capabilities.len()).map_err(|_| {
        RuntimeError::new(
            "runtime",
            false,
            "runtime image format capability count exceeds u16",
        )
    })?;
    let mut bytes = Vec::with_capacity(6 + capabilities.len() * 3);
    bytes.extend_from_slice(b"PXF1");
    push_u16(&mut bytes, count);
    for capability in capabilities {
        bytes.push(capability.format.code());
        push_u16(&mut bytes, capability.flags.bits());
    }
    Ok(bytes)
}

/// Returns binary encoded runtime image format capabilities. Caller must free it.
#[no_mangle]
pub extern "C" fn pixa_image_format_capabilities(out_len: *mut usize) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len = 0;
    }

    match encode_image_format_capabilities() {
        Ok(bytes) => write_success(bytes, out_len),
        Err(_) => std::ptr::null_mut(),
    }
}

fn encode_image_metadata(metadata: ImageMetadata) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(14);
    bytes.extend_from_slice(b"PXI1");
    bytes.extend_from_slice(&metadata.width.to_le_bytes());
    bytes.extend_from_slice(&metadata.height.to_le_bytes());
    bytes.push(match metadata.format {
        ImageMetadataFormat::Jpeg => 1,
        ImageMetadataFormat::Png => 2,
        ImageMetadataFormat::Gif => 3,
        ImageMetadataFormat::Webp => 4,
        ImageMetadataFormat::Bmp => 5,
        ImageMetadataFormat::Wbmp => 6,
        ImageMetadataFormat::Ico => 7,
        ImageMetadataFormat::Tiff => 8,
        ImageMetadataFormat::Pnm => 9,
        ImageMetadataFormat::Qoi => 10,
        ImageMetadataFormat::Tga => 11,
        ImageMetadataFormat::Dds => 12,
        ImageMetadataFormat::Hdr => 13,
        ImageMetadataFormat::Farbfeld => 14,
        ImageMetadataFormat::Pcx => 15,
        ImageMetadataFormat::Sgi => 16,
        ImageMetadataFormat::Xbm => 17,
        ImageMetadataFormat::Xpm => 18,
    });
    let mut flags = 0_u8;
    if metadata.progressive {
        flags |= 0x01;
    }
    if metadata.animated {
        flags |= 0x02;
    }
    bytes.push(flags);
    bytes
}

fn encode_image_analysis(analysis: ImageAnalysis) -> Vec<u8> {
    let palette_len = analysis.palette_argb.len().min(u8::MAX as usize);
    let mut bytes = Vec::with_capacity(21 + palette_len * 4);
    bytes.extend_from_slice(b"PXA1");
    bytes.extend_from_slice(&analysis.width.to_le_bytes());
    bytes.extend_from_slice(&analysis.height.to_le_bytes());
    bytes.extend_from_slice(&analysis.average_argb.to_be_bytes());
    bytes.extend_from_slice(&analysis.dominant_argb.to_be_bytes());
    bytes.push(palette_len as u8);
    for color in analysis.palette_argb.iter().take(palette_len) {
        bytes.extend_from_slice(&color.to_be_bytes());
    }
    bytes
}

/// Returns binary encoded image metadata parsed without full decode. Caller must free it.
#[no_mangle]
pub extern "C" fn pixa_image_metadata(
    bytes_ptr: *const u8,
    bytes_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len = 0;
    }
    let Some(bytes) = (unsafe { bytes_from_ptr(bytes_ptr, bytes_len) }) else {
        return std::ptr::null_mut();
    };
    match image_metadata(bytes) {
        Ok(metadata) => write_success(encode_image_metadata(metadata), out_len),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Returns binary encoded image color analysis. Caller must free it.
#[no_mangle]
pub extern "C" fn pixa_image_analysis(
    bytes_ptr: *const u8,
    bytes_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len = 0;
    }
    let Some(bytes) = (unsafe { bytes_from_ptr(bytes_ptr, bytes_len) }) else {
        return std::ptr::null_mut();
    };
    match image_analysis(bytes, 4096) {
        Ok(analysis) => write_success(encode_image_analysis(analysis), out_len),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Parses JPEG EXIF orientation. Returns 0 when found, 1 when absent, -1 on error.
#[no_mangle]
pub extern "C" fn pixa_jpeg_exif_orientation(
    bytes_ptr: *const u8,
    bytes_len: usize,
    out_orientation: *mut u16,
) -> i32 {
    if out_orientation.is_null() {
        return -1;
    }
    unsafe {
        *out_orientation = 0;
    }
    let Some(bytes) = (unsafe { bytes_from_ptr(bytes_ptr, bytes_len) }) else {
        return -1;
    };
    match pixa_core::jpeg_exif_orientation(bytes) {
        Ok(Some(orientation)) => {
            unsafe {
                *out_orientation = orientation;
            }
            0
        }
        Ok(None) => 1,
        Err(_) => -1,
    }
}

/// Returns runtime capabilities as a stable bitset.
#[no_mangle]
pub extern "C" fn pixa_capability_bits() -> u8 {
    let capabilities = pixa_core::RuntimeCapabilities::conservative();
    (capabilities.disk_cache as u8)
        | ((capabilities.http_transport as u8) << 1)
        | ((capabilities.exif_parser as u8) << 2)
        | ((capabilities.pixel_processors as u8) << 3)
}

#[derive(Default)]
struct ProgressSession {
    events: VecDeque<RuntimeProgressEvent>,
    dropped_events: u64,
}

struct ProgressSessionSink {
    session_id: u64,
}

impl RuntimeProgressSink for ProgressSessionSink {
    fn emit(&self, event: RuntimeProgressEvent) {
        push_progress_event(self.session_id, event);
    }
}

fn progress_sessions() -> &'static Mutex<BTreeMap<u64, ProgressSession>> {
    PROGRESS_SESSIONS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

fn push_progress_event(session_id: u64, event: RuntimeProgressEvent) {
    PROGRESS_EVENTS_EMITTED.fetch_add(1, Ordering::Relaxed);
    let Ok(mut sessions) = progress_sessions().lock() else {
        return;
    };
    let Some(session) = sessions.get_mut(&session_id) else {
        return;
    };
    if session.events.len() >= MAX_PROGRESS_EVENTS_PER_SESSION {
        session.events.pop_front();
        session.dropped_events = session.dropped_events.saturating_add(1);
        PROGRESS_EVENTS_DROPPED.fetch_add(1, Ordering::Relaxed);
    }
    session.events.push_back(event);
}

fn reset_out(out_len: *mut usize, out_error_ptr: *mut *mut u8, out_error_len: *mut usize) {
    unsafe {
        if !out_len.is_null() {
            *out_len = 0;
        }
        if !out_error_ptr.is_null() {
            *out_error_ptr = std::ptr::null_mut();
        }
        if !out_error_len.is_null() {
            *out_error_len = 0;
        }
    }
}

fn write_success(bytes: Vec<u8>, out_len: *mut usize) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    let mut bytes = bytes.into_boxed_slice();
    let len = bytes.len();
    let ptr = bytes.as_mut_ptr();
    std::mem::forget(bytes);
    unsafe {
        *out_len = len;
    }
    ptr
}

fn write_success_handle(bytes: SharedBytes, out_len: *mut usize) -> *mut c_void {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len = bytes.len();
    }
    owned_buffer_handle(OwnedBufferStorage::Shared(bytes))
}

fn owned_buffer_handle(storage: OwnedBufferStorage) -> *mut c_void {
    let handle = OwnedBufferHandle { storage };
    let len = handle.len();
    OWNED_BUFFER_HANDLES_CREATED.fetch_add(1, Ordering::Relaxed);
    OWNED_BUFFER_BYTES_EXPOSED.fetch_add(len as u64, Ordering::Relaxed);
    Box::into_raw(Box::new(handle)).cast::<c_void>()
}

fn write_error(error: RuntimeError, out_error_ptr: *mut *mut u8, out_error_len: *mut usize) {
    if out_error_ptr.is_null() || out_error_len.is_null() {
        return;
    }
    let mut bytes = encode_error(error).into_boxed_slice();
    let len = bytes.len();
    let ptr = bytes.as_mut_ptr();
    std::mem::forget(bytes);
    unsafe {
        *out_error_ptr = ptr;
        *out_error_len = len;
    }
}

fn encode_error(error: RuntimeError) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(6 + 4 + error.message.len());
    bytes.extend_from_slice(b"PXE1");
    bytes.push(error_stage_code(error.stage));
    bytes.push(u8::from(error.retryable));
    if push_string(&mut bytes, &error.message).is_err() {
        const FALLBACK: &[u8] = b"runtime error message exceeds limit";
        bytes.truncate(6);
        bytes.extend_from_slice(&(FALLBACK.len() as u32).to_le_bytes());
        bytes.extend_from_slice(FALLBACK);
    }
    bytes
}

fn error_stage_code(stage: &str) -> u8 {
    match stage {
        "cache" | "cache_key" | "disk_cache" | "memory_cache" => 1,
        "fetch" => 2,
        "decode" => 3,
        "process" => 4,
        "cache_write" => 5,
        "complete" => 6,
        "cancel" => 7,
        _ => 0,
    }
}

unsafe fn bytes_to_str<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    let bytes = bytes_from_ptr(ptr, len)?;
    std::str::from_utf8(bytes).ok()
}

unsafe fn bytes_from_ptr<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if ptr.is_null() {
        return if len == 0 { Some(&[]) } else { None };
    }
    Some(slice::from_raw_parts(ptr, len))
}

#[cfg(test)]
mod tests {
    use super::*;
    use pixa_core::{RuntimeProgressStage, PIXA_PLUGIN_ABI_VERSION, S3_FETCHER_MODULE_ID};

    #[test]
    fn exposes_plugin_host_abi_version() {
        assert_eq!(pixa_plugin_abi_version(), PIXA_PLUGIN_ABI_VERSION);
    }

    #[test]
    fn generated_video_frame_routes_keep_output_mime_contract() {
        let module = GeneratedPluginModule {
            module_id: "pixa.video_frame.test",
            abi_version: i64::from(PIXA_PLUGIN_ABI_VERSION),
            deployment: GeneratedPluginDeployment::BuiltInHost,
            package_name: Some("pixa"),
            implementation_language: Some("rust"),
            entrypoint_symbol: None,
            entrypoint: None,
            capabilities: GeneratedPluginCapabilities {
                fetcher: true,
                decoder: false,
                processor: false,
                cache_store: false,
                host_managed_runtime: true,
                binary_messages: true,
                owned_buffers: true,
                stream_handles: true,
            },
            routes: GeneratedPluginRoutes {
                fetcher_source_kinds: &["video-frame:platform"],
                video_frame_output_mime_types: &["image/png"],
                decoder_format_ids: &[],
                decoder_mime_types: &[],
                decoder_signatures: &[],
                processor_operations: &[],
                cache_store_namespaces: &[],
            },
        };

        let runtime_module =
            plugin_module_from_generated(&module).expect("generated module should project");

        assert_eq!(
            runtime_module.routes.video_frame_output_mime_types,
            vec!["image/png".to_string()]
        );
    }

    #[test]
    fn owned_buffer_handle_exposes_len_and_data() {
        let mut bytes = vec![1_u8, 2, 3].into_boxed_slice();
        let ptr = bytes.as_mut_ptr();
        std::mem::forget(bytes);

        let handle = pixa_owned_buffer_create(ptr, 3);

        assert!(!handle.is_null());
        assert_eq!(pixa_owned_buffer_len(handle), 3);
        let data = pixa_owned_buffer_data(handle);
        assert!(!data.is_null());
        let view = unsafe { slice::from_raw_parts(data, 3) };
        assert_eq!(view, &[1, 2, 3]);
        pixa_owned_buffer_free(handle);
    }

    #[test]
    fn processed_memory_cache_returns_owned_handle() {
        let namespace = b"runtime-test";
        let key = b"runtime-processed-memory-cache";
        let bytes = b"processed";

        assert_eq!(
            pixa_memory_write_processed(
                namespace.as_ptr(),
                namespace.len(),
                key.as_ptr(),
                key.len(),
                bytes.as_ptr(),
                bytes.len(),
                -1,
            ),
            0
        );

        let mut out_len = 0_usize;
        let handle = pixa_memory_read_processed(key.as_ptr(), key.len(), &mut out_len);

        assert!(!handle.is_null());
        assert_eq!(out_len, bytes.len());
        let data = pixa_owned_buffer_data(handle);
        assert!(!data.is_null());
        let view = unsafe { slice::from_raw_parts(data, out_len) };
        assert_eq!(view, bytes);
        pixa_owned_buffer_free(handle);
        assert_eq!(pixa_memory_remove(key.as_ptr(), key.len()), 0);
    }

    #[test]
    fn progress_session_drains_events_and_reports_drops() {
        let session_id = pixa_progress_session_create();
        assert_ne!(session_id, 0);
        let sink = ProgressSessionSink { session_id };

        for index in 0..(MAX_PROGRESS_EVENTS_PER_SESSION + 1) {
            sink.emit(
                RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.progress")
                    .with_bytes(index, Some(MAX_PROGRESS_EVENTS_PER_SESSION + 1)),
            );
        }

        let mut out_len = 0_usize;
        let ptr = pixa_progress_session_drain(session_id, &mut out_len);
        assert!(!ptr.is_null());
        let bytes = unsafe { slice::from_raw_parts(ptr, out_len) };
        assert_eq!(&bytes[0..4], b"PXP1");
        assert_eq!(u64::from_le_bytes(bytes[4..12].try_into().unwrap()), 1);
        assert_eq!(
            u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize,
            MAX_PROGRESS_EVENTS_PER_SESSION
        );
        pixa_buffer_free(ptr, out_len);
        assert_eq!(pixa_progress_session_free(session_id), 0);
    }

    #[test]
    fn load_uses_binary_request_payload() {
        let root = b"";
        let request = binary_request_fixture();
        let image = minimal_gif();
        let mut out_len = 0usize;
        let mut error_ptr = std::ptr::null_mut();
        let mut error_len = 0usize;

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

        assert!(!ptr.is_null());
        assert_eq!(out_len, image.len());
        assert!(error_ptr.is_null());
        assert_eq!(error_len, 0);
        let loaded = unsafe { slice::from_raw_parts(ptr, out_len) };
        assert_eq!(loaded, image.as_slice());
        pixa_buffer_free(ptr, out_len);
    }

    #[test]
    fn load_handle_uses_binary_request_payload() {
        let root = b"";
        let request = binary_request_fixture();
        let image = minimal_gif();
        let mut out_len = 0usize;
        let mut error_ptr = std::ptr::null_mut();
        let mut error_len = 0usize;

        let handle = pixa_load_handle_with_cancel_and_progress(
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

        assert!(!handle.is_null());
        assert_eq!(out_len, image.len());
        assert!(error_ptr.is_null());
        assert_eq!(error_len, 0);
        assert_eq!(pixa_owned_buffer_len(handle), image.len());
        let data = pixa_owned_buffer_data(handle);
        assert!(!data.is_null());
        let loaded = unsafe { slice::from_raw_parts(data, out_len) };
        assert_eq!(loaded, image.as_slice());
        pixa_owned_buffer_free(handle);
    }

    #[test]
    fn load_handle_accepts_ico_inline_bytes() {
        let root = b"";
        let request = binary_request_fixture();
        let image = minimal_ico();
        let mut out_len = 0usize;
        let mut error_ptr = std::ptr::null_mut();
        let mut error_len = 0usize;

        let handle = pixa_load_handle_with_cancel_and_progress(
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

        assert!(!handle.is_null());
        assert_eq!(out_len, image.len());
        assert!(error_ptr.is_null());
        assert_eq!(error_len, 0);
        assert_eq!(pixa_owned_buffer_len(handle), image.len());
        pixa_owned_buffer_free(handle);
    }

    #[test]
    fn decode_rgba_from_owned_buffer_returns_owned_pixels() {
        let mut image = minimal_gif().into_boxed_slice();
        let image_len = image.len();
        let image_ptr = image.as_mut_ptr();
        std::mem::forget(image);
        let input = pixa_owned_buffer_create(image_ptr, image_len);
        assert!(!input.is_null());
        let mut width = 0_u32;
        let mut height = 0_u32;
        let mut row_bytes = 0_usize;
        let mut out_len = 0_usize;
        let mut error_ptr = std::ptr::null_mut();
        let mut error_len = 0_usize;

        let output = pixa_decode_rgba_from_owned_buffer(
            input,
            1,
            4,
            &mut width,
            &mut height,
            &mut row_bytes,
            &mut out_len,
            &mut error_ptr,
            &mut error_len,
        );

        assert!(!output.is_null());
        assert_eq!(width, 1);
        assert_eq!(height, 1);
        assert_eq!(row_bytes, 4);
        assert_eq!(out_len, 4);
        assert!(error_ptr.is_null());
        assert_eq!(error_len, 0);
        let data = pixa_owned_buffer_data(output);
        assert!(!data.is_null());
        assert_eq!(unsafe { slice::from_raw_parts(data, out_len) }.len(), 4);
        pixa_owned_buffer_free(output);
        pixa_owned_buffer_free(input);
    }

    #[test]
    fn decode_rgba_from_owned_ico_buffer_returns_owned_pixels() {
        let mut image = minimal_ico().into_boxed_slice();
        let image_len = image.len();
        let image_ptr = image.as_mut_ptr();
        std::mem::forget(image);
        let input = pixa_owned_buffer_create(image_ptr, image_len);
        assert!(!input.is_null());
        let mut width = 0_u32;
        let mut height = 0_u32;
        let mut row_bytes = 0_usize;
        let mut out_len = 0_usize;
        let mut error_ptr = std::ptr::null_mut();
        let mut error_len = 0_usize;

        let output = pixa_decode_rgba_from_owned_buffer(
            input,
            1,
            4,
            &mut width,
            &mut height,
            &mut row_bytes,
            &mut out_len,
            &mut error_ptr,
            &mut error_len,
        );

        assert!(!output.is_null());
        assert_eq!(width, 1);
        assert_eq!(height, 1);
        assert_eq!(row_bytes, 4);
        assert_eq!(out_len, 4);
        assert!(error_ptr.is_null());
        assert_eq!(error_len, 0);
        pixa_owned_buffer_free(output);
        pixa_owned_buffer_free(input);
    }

    #[test]
    fn decode_rgba_from_owned_buffer_reports_typed_error() {
        let mut image = minimal_gif().into_boxed_slice();
        let image_len = image.len();
        let image_ptr = image.as_mut_ptr();
        std::mem::forget(image);
        let input = pixa_owned_buffer_create(image_ptr, image_len);
        assert!(!input.is_null());
        let mut width = 7_u32;
        let mut height = 8_u32;
        let mut row_bytes = 9_usize;
        let mut out_len = 10_usize;
        let mut error_ptr = std::ptr::null_mut();
        let mut error_len = 0_usize;

        let output = pixa_decode_rgba_from_owned_buffer(
            input,
            1,
            3,
            &mut width,
            &mut height,
            &mut row_bytes,
            &mut out_len,
            &mut error_ptr,
            &mut error_len,
        );

        assert!(output.is_null());
        assert_eq!(width, 0);
        assert_eq!(height, 0);
        assert_eq!(row_bytes, 0);
        assert_eq!(out_len, 0);
        assert!(!error_ptr.is_null());
        let error = unsafe { slice::from_raw_parts(error_ptr, error_len) };
        assert_eq!(&error[0..4], b"PXE1");
        pixa_buffer_free(error_ptr, error_len);
        pixa_owned_buffer_free(input);
    }

    #[test]
    fn cache_stats_use_binary_payload() {
        let mut out_len = 0_usize;

        let ptr = pixa_cache_stats(&mut out_len);

        assert!(!ptr.is_null());
        let bytes = unsafe { slice::from_raw_parts(ptr, out_len) };
        assert_eq!(&bytes[0..4], b"PXS1");
        assert_eq!(out_len, 4 + 30 * 8);
        pixa_buffer_free(ptr, out_len);
    }

    #[test]
    fn plugin_registry_stats_use_binary_payload() {
        let mut out_len = 0_usize;

        let ptr = pixa_plugin_registry_stats(&mut out_len);

        assert!(!ptr.is_null());
        let bytes = unsafe { slice::from_raw_parts(ptr, out_len) };
        assert_eq!(&bytes[0..4], b"PXM1");
        assert_eq!(out_len, 4 + 11 * 8 + 4 + 4);
        assert_eq!(read_le_u64(bytes, 4), 3);
        assert_eq!(read_le_u64(bytes, 12), 2);
        assert_eq!(read_le_u64(bytes, 20), 1);
        assert_eq!(read_le_u64(bytes, 28), 0);
        assert_eq!(read_le_u64(bytes, 36), 3);
        assert_eq!(read_le_u64(bytes, 44), 1);
        assert_eq!(read_le_u64(bytes, 52), 0);
        assert_eq!(read_le_u64(bytes, 60), 0);
        assert_eq!(read_le_u64(bytes, 68), 1);
        assert_eq!(read_le_u64(bytes, 76), 0);
        assert_eq!(read_le_u64(bytes, 84), 1);
        assert_eq!(read_le_u32(bytes, 92), 0);
        assert_eq!(read_le_u32(bytes, 96), 0);
        pixa_buffer_free(ptr, out_len);
    }

    #[test]
    fn generated_s3_fetcher_module_registers_builtin_executor() {
        ensure_generated_plugins_registered().expect("generated runtime plugins should register");

        let (module, _) = pixa_core::runtime_fetcher_executor_for_source_kind("s3")
            .expect("runtime fetcher registry lookup should not fail")
            .expect("S3 fetcher should have a built-in executor");
        let (alias_module, _) = pixa_core::runtime_fetcher_executor_for_source_kind("s3-object")
            .expect("runtime fetcher registry lookup should not fail")
            .expect("S3 object alias should have a built-in executor");

        assert_eq!(module.module_id, S3_FETCHER_MODULE_ID);
        assert_eq!(alias_module.module_id, S3_FETCHER_MODULE_ID);
    }

    #[test]
    fn image_format_capabilities_use_binary_payload() {
        let mut out_len = 0_usize;

        let ptr = pixa_image_format_capabilities(&mut out_len);

        assert!(!ptr.is_null());
        let bytes = unsafe { slice::from_raw_parts(ptr, out_len) };
        assert_eq!(&bytes[0..4], b"PXF1");
        assert_eq!(u16::from_le_bytes([bytes[4], bytes[5]]), 18);
        assert_eq!(out_len, 6 + 18 * 3);
        assert_eq!(bytes[6], 1);
        assert_eq!(read_le_u16(bytes, 7) & 0x0004, 0x0004);
        let ico_offset = 6 + 6 * 3;
        assert_eq!(bytes[ico_offset], 7);
        assert_eq!(read_le_u16(bytes, ico_offset + 1) & 0x0040, 0x0040);
        pixa_buffer_free(ptr, out_len);
    }

    #[test]
    fn image_metadata_uses_binary_payload() {
        let image = jpeg_with_sof(0xc2, 4096, 2048);
        let mut out_len = 0_usize;

        let ptr = pixa_image_metadata(image.as_ptr(), image.len(), &mut out_len);

        assert!(!ptr.is_null());
        let bytes = unsafe { slice::from_raw_parts(ptr, out_len) };
        assert_eq!(&bytes[0..4], b"PXI1");
        assert_eq!(out_len, 14);
        assert_eq!(read_le_u32(bytes, 4), 4096);
        assert_eq!(read_le_u32(bytes, 8), 2048);
        assert_eq!(bytes[12], 1);
        assert_eq!(bytes[13] & 0x01, 0x01);
        pixa_buffer_free(ptr, out_len);

        let image = bmp_info_header(800, -600);
        let ptr = pixa_image_metadata(image.as_ptr(), image.len(), &mut out_len);

        assert!(!ptr.is_null());
        let bytes = unsafe { slice::from_raw_parts(ptr, out_len) };
        assert_eq!(&bytes[0..4], b"PXI1");
        assert_eq!(out_len, 14);
        assert_eq!(read_le_u32(bytes, 4), 800);
        assert_eq!(read_le_u32(bytes, 8), 600);
        assert_eq!(bytes[12], 5);
        assert_eq!(bytes[13], 0);
        pixa_buffer_free(ptr, out_len);

        let image = wbmp_image(17, 9);
        let ptr = pixa_image_metadata(image.as_ptr(), image.len(), &mut out_len);

        assert!(!ptr.is_null());
        let bytes = unsafe { slice::from_raw_parts(ptr, out_len) };
        assert_eq!(&bytes[0..4], b"PXI1");
        assert_eq!(out_len, 14);
        assert_eq!(read_le_u32(bytes, 4), 17);
        assert_eq!(read_le_u32(bytes, 8), 9);
        assert_eq!(bytes[12], 6);
        assert_eq!(bytes[13], 0);
        pixa_buffer_free(ptr, out_len);
    }

    #[test]
    fn image_analysis_uses_binary_payload() {
        use image::ImageEncoder;

        let mut image = Vec::new();
        image::codecs::png::PngEncoder::new(&mut image)
            .write_image(
                &[255, 0, 0, 255, 0, 0, 255, 255],
                2,
                1,
                image::ExtendedColorType::Rgba8,
            )
            .expect("fixture PNG should encode");
        let mut out_len = 0_usize;

        let ptr = pixa_image_analysis(image.as_ptr(), image.len(), &mut out_len);

        assert!(!ptr.is_null());
        let bytes = unsafe { slice::from_raw_parts(ptr, out_len) };
        assert_eq!(&bytes[0..4], b"PXA1");
        assert_eq!(out_len, 29);
        assert_eq!(read_le_u32(bytes, 4), 2);
        assert_eq!(read_le_u32(bytes, 8), 1);
        assert_eq!(read_be_u32(bytes, 12), 0xff7f007f);
        assert_eq!(read_be_u32(bytes, 16), 0xffff0000);
        assert_eq!(bytes[20], 2);
        pixa_buffer_free(ptr, out_len);
    }

    #[test]
    fn cache_key_hash_pair_uses_one_input_buffer() {
        let input = b"pixa";
        let mut primary = 0_u64;
        let mut secondary = 0_u64;

        let status =
            pixa_cache_key_hash_pair(input.as_ptr(), input.len(), &mut primary, &mut secondary);

        assert_eq!(status, 0);
        assert_eq!(primary, 0xbef3f60dc4ff7eed);
        assert_eq!(secondary, 0x668135a3077b3346);
    }

    #[test]
    fn load_writes_binary_error_payload() {
        let root = b"";
        let request = b"not-binary";
        let image = minimal_gif();
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

        assert!(ptr.is_null());
        assert_eq!(out_len, 0);
        assert!(!error_ptr.is_null());
        let error = unsafe { slice::from_raw_parts(error_ptr, error_len) };
        assert_eq!(&error[0..4], b"PXE1");
        assert_eq!(error[4], 0);
        assert_eq!(error[5], 0);
        pixa_buffer_free(error_ptr, error_len);
    }

    #[test]
    fn host_linked_executor_decodes_with_host_owned_buffer() {
        let module = GeneratedPluginModule {
            module_id: "pixa.decoder.test.runtime",
            abi_version: i64::from(PIXA_PLUGIN_ABI_VERSION),
            deployment: GeneratedPluginDeployment::HostLinkedPlugin,
            package_name: Some("pixa_decoder_test"),
            implementation_language: Some("c"),
            entrypoint_symbol: Some("pixa_plugin_test_init"),
            entrypoint: Some(test_plugin_entrypoint),
            capabilities: GeneratedPluginCapabilities {
                fetcher: false,
                decoder: true,
                processor: false,
                cache_store: false,
                host_managed_runtime: true,
                binary_messages: true,
                owned_buffers: true,
                stream_handles: true,
            },
            routes: GeneratedPluginRoutes {
                fetcher_source_kinds: &[],
                video_frame_output_mime_types: &[],
                decoder_format_ids: &[],
                decoder_mime_types: &["image/x-pixa-test"],
                decoder_signatures: &[],
                processor_operations: &[],
                cache_store_namespaces: &[],
            },
        };
        let executor =
            instantiate_host_linked_executor(&module, module.entrypoint.expect("test entrypoint"))
                .expect("host-linked executor should instantiate");

        let output = executor
            .decode(PluginDecodeRequest {
                mime_type: "image/x-pixa-test",
                format_id: None,
                bytes: b"fake-decoder-input",
                target_width: Some(64),
                target_height: Some(32),
                max_decoded_pixels: 2048,
                max_output_bytes: 4096,
            })
            .expect("decode callback should succeed")
            .expect("decode callback should be present");

        assert_eq!(output.bytes.as_ref(), minimal_gif().as_slice());
        assert_eq!(output.mime_type.as_deref(), Some("image/gif"));
    }

    #[test]
    fn generated_qoi_decoder_module_transcodes_via_host_registry() {
        ensure_generated_plugins_registered().expect("generated runtime plugins should register");
        let (module, executor) = pixa_core::runtime_decoder_executor_for_mime_type("image/qoi")
            .expect("runtime decoder registry lookup should not fail")
            .expect("QOI decoder module should be registered");

        let output = executor
            .decode(PluginDecodeRequest {
                mime_type: "image/qoi",
                format_id: None,
                bytes: &qoi_rgba_1x1(),
                target_width: None,
                target_height: None,
                max_decoded_pixels: 1,
                max_output_bytes: 4096,
            })
            .expect("QOI decoder callback should succeed")
            .expect("QOI decoder callback should return bytes");
        let metadata =
            image_metadata(output.bytes.as_ref()).expect("decoder output metadata should parse");

        assert_eq!(module.module_id, "pixa.decoder.qoi");
        assert_eq!(output.mime_type.as_deref(), Some("image/png"));
        assert_eq!(metadata.format, ImageMetadataFormat::Png);
        assert_eq!((metadata.width, metadata.height), (1, 1));
    }

    #[test]
    fn host_linked_executor_processes_with_host_owned_buffer() {
        let module = GeneratedPluginModule {
            module_id: "pixa.processor.test.runtime",
            abi_version: i64::from(PIXA_PLUGIN_ABI_VERSION),
            deployment: GeneratedPluginDeployment::HostLinkedPlugin,
            package_name: Some("pixa_processor_test"),
            implementation_language: Some("c"),
            entrypoint_symbol: Some("pixa_plugin_test_processor_init"),
            entrypoint: Some(test_processor_entrypoint),
            capabilities: GeneratedPluginCapabilities {
                fetcher: false,
                decoder: false,
                processor: true,
                cache_store: false,
                host_managed_runtime: true,
                binary_messages: true,
                owned_buffers: true,
                stream_handles: true,
            },
            routes: GeneratedPluginRoutes {
                fetcher_source_kinds: &[],
                video_frame_output_mime_types: &[],
                decoder_format_ids: &[],
                decoder_mime_types: &[],
                decoder_signatures: &[],
                processor_operations: &["tile:jpeg"],
                cache_store_namespaces: &[],
            },
        };
        let executor =
            instantiate_host_linked_executor(&module, module.entrypoint.expect("test entrypoint"))
                .expect("processor executor should instantiate");

        let output = executor
            .process(PluginProcessRequest {
                operation: "tile:jpeg",
                descriptor:
                    "tile(x=0,y=0,width=16,height=16,decodedWidth=1,decodedHeight=1,filter=nearest)",
                format_id: Some("jpeg"),
                mime_type: Some("image/jpeg"),
                bytes: b"fake-jpeg-input",
                max_decoded_pixels: 256,
                max_output_bytes: 4096,
            })
            .expect("process callback should succeed")
            .expect("process callback should be present");

        assert_eq!(output.bytes.as_ref(), minimal_gif().as_slice());
        assert_eq!(output.mime_type.as_deref(), Some("image/gif"));
    }

    #[test]
    fn host_linked_executor_runs_cache_store_callbacks() {
        let module = GeneratedPluginModule {
            module_id: "pixa.cache_store.test.runtime",
            abi_version: i64::from(PIXA_PLUGIN_ABI_VERSION),
            deployment: GeneratedPluginDeployment::HostLinkedPlugin,
            package_name: Some("pixa_cache_store_test"),
            implementation_language: Some("c"),
            entrypoint_symbol: Some("pixa_plugin_test_cache_store_init"),
            entrypoint: Some(test_cache_store_entrypoint),
            capabilities: GeneratedPluginCapabilities {
                fetcher: false,
                decoder: false,
                processor: false,
                cache_store: true,
                host_managed_runtime: true,
                binary_messages: true,
                owned_buffers: true,
                stream_handles: true,
            },
            routes: GeneratedPluginRoutes {
                fetcher_source_kinds: &[],
                video_frame_output_mime_types: &[],
                decoder_format_ids: &[],
                decoder_mime_types: &[],
                decoder_signatures: &[],
                processor_operations: &[],
                cache_store_namespaces: &["plugin-cache"],
            },
        };
        let executor =
            instantiate_host_linked_executor(&module, module.entrypoint.expect("test entrypoint"))
                .expect("cache-store executor should instantiate");

        let read = executor
            .cache_read(PluginCacheReadRequest {
                namespace: "plugin-cache",
                key: "0123456789abcdef",
                allow_stale: false,
                max_output_bytes: 4096,
            })
            .expect("cache read callback should succeed")
            .expect("cache read callback should be present");

        match read {
            PluginCacheReadResult::Hit { output, is_stale } => {
                assert!(!is_stale);
                assert_eq!(output.bytes.as_ref(), b"runtime-cache-hit");
                assert_eq!(
                    output.mime_type.as_deref(),
                    Some("application/octet-stream")
                );
            }
            PluginCacheReadResult::Miss => panic!("test cache store should hit"),
        }
        assert!(executor
            .cache_write(PluginCacheWriteRequest {
                namespace: "plugin-cache",
                key: "0123456789abcdef",
                bytes: b"runtime-cache-hit",
                ttl_ms: Some(500),
                private_entry: true,
            })
            .expect("cache write callback should succeed")
            .is_some());
        assert!(executor
            .cache_remove(PluginCacheRemoveRequest {
                namespace: "plugin-cache",
                key: "0123456789abcdef",
            })
            .expect("cache remove callback should succeed")
            .is_some());
        assert!(executor
            .cache_clear_namespace(PluginCacheClearNamespaceRequest {
                namespace: "plugin-cache",
            })
            .expect("cache clear callback should succeed")
            .is_some());
    }

    static TEST_PLUGIN_MIME: &[u8] = b"image/gif";
    static TEST_CACHE_STORE_MIME: &[u8] = b"application/octet-stream";

    unsafe extern "C" fn test_plugin_entrypoint(
        host: *const PixaPluginHostApiV1,
        module: *mut PixaPluginModuleApiV1,
    ) -> i32 {
        if host.is_null() || module.is_null() {
            return -1;
        }
        let host = unsafe { &*host };
        assert_eq!(host.abi_version, PIXA_PLUGIN_ABI_VERSION);
        assert!(host.buffer_alloc.is_some());
        unsafe {
            (*module).abi_version = PIXA_PLUGIN_ABI_VERSION;
            (*module).decode = Some(test_plugin_decode);
        }
        0
    }

    unsafe extern "C" fn test_cache_store_entrypoint(
        host: *const PixaPluginHostApiV1,
        module: *mut PixaPluginModuleApiV1,
    ) -> i32 {
        if host.is_null() || module.is_null() {
            return -1;
        }
        let host = unsafe { &*host };
        assert_eq!(host.abi_version, PIXA_PLUGIN_ABI_VERSION);
        unsafe {
            (*module).abi_version = PIXA_PLUGIN_ABI_VERSION;
            (*module).cache_read = Some(test_cache_store_read);
            (*module).cache_write = Some(test_cache_store_write);
            (*module).cache_remove = Some(test_cache_store_remove);
            (*module).cache_clear_namespace = Some(test_cache_store_clear_namespace);
        }
        0
    }

    unsafe extern "C" fn test_processor_entrypoint(
        host: *const PixaPluginHostApiV1,
        module: *mut PixaPluginModuleApiV1,
    ) -> i32 {
        if host.is_null() || module.is_null() {
            return -1;
        }
        let host = unsafe { &*host };
        assert_eq!(host.abi_version, PIXA_PLUGIN_ABI_VERSION);
        assert!(host.buffer_alloc.is_some());
        unsafe {
            (*module).abi_version = PIXA_PLUGIN_ABI_VERSION;
            (*module).process = Some(test_plugin_process);
        }
        0
    }

    unsafe extern "C" fn test_cache_store_read(
        request: *const PixaPluginCacheReadRequestV1,
        output: *mut PixaPluginCacheReadOutputV1,
    ) -> i32 {
        if request.is_null() || output.is_null() {
            return -1;
        }
        let request = unsafe { &*request };
        let namespace =
            unsafe { slice::from_raw_parts(request.namespace_ptr, request.namespace_len) };
        let key = unsafe { slice::from_raw_parts(request.key_ptr, request.key_len) };
        assert_eq!(namespace, b"plugin-cache");
        assert_eq!(key, b"0123456789abcdef");
        assert!(!request.allow_stale);
        let bytes = b"runtime-cache-hit";
        if bytes.len() > request.max_output_bytes {
            return -2;
        }
        let handle = unsafe { plugin_host_buffer_alloc(bytes.len()) };
        if handle.is_null() {
            return -3;
        }
        let data = unsafe { plugin_host_buffer_data(handle) };
        if data.is_null() {
            unsafe {
                plugin_host_buffer_free(handle);
            }
            return -4;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), data, bytes.len());
            (*output).status = 1;
            (*output).is_stale = false;
            (*output).payload.buffer = handle;
            (*output).payload.mime_type_ptr = TEST_CACHE_STORE_MIME.as_ptr();
            (*output).payload.mime_type_len = TEST_CACHE_STORE_MIME.len();
        }
        0
    }

    unsafe extern "C" fn test_cache_store_write(
        request: *const PixaPluginCacheWriteRequestV1,
    ) -> i32 {
        if request.is_null() {
            return -1;
        }
        let request = unsafe { &*request };
        let namespace =
            unsafe { slice::from_raw_parts(request.namespace_ptr, request.namespace_len) };
        let bytes = unsafe { slice::from_raw_parts(request.bytes_ptr, request.bytes_len) };
        assert_eq!(namespace, b"plugin-cache");
        assert_eq!(bytes, b"runtime-cache-hit");
        assert!(request.has_ttl);
        assert_eq!(request.ttl_ms, 500);
        assert!(request.private_entry);
        0
    }

    unsafe extern "C" fn test_cache_store_remove(
        request: *const PixaPluginCacheRemoveRequestV1,
    ) -> i32 {
        if request.is_null() {
            return -1;
        }
        let request = unsafe { &*request };
        let key = unsafe { slice::from_raw_parts(request.key_ptr, request.key_len) };
        assert_eq!(key, b"0123456789abcdef");
        0
    }

    unsafe extern "C" fn test_cache_store_clear_namespace(
        request: *const PixaPluginCacheClearNamespaceRequestV1,
    ) -> i32 {
        if request.is_null() {
            return -1;
        }
        let request = unsafe { &*request };
        let namespace =
            unsafe { slice::from_raw_parts(request.namespace_ptr, request.namespace_len) };
        assert_eq!(namespace, b"plugin-cache");
        0
    }

    unsafe extern "C" fn test_plugin_decode(
        request: *const PixaPluginDecodeRequestV1,
        output: *mut PixaPluginOutputV1,
    ) -> i32 {
        if request.is_null() || output.is_null() {
            return -1;
        }
        let request = unsafe { &*request };
        let mime = unsafe { slice::from_raw_parts(request.mime_type_ptr, request.mime_type_len) };
        assert_eq!(mime, b"image/x-pixa-test");
        assert!(request.format_id_ptr.is_null());
        assert_eq!(request.format_id_len, 0);
        assert_eq!(request.target_width, 64);
        assert_eq!(request.target_height, 32);
        assert_eq!(request.max_decoded_pixels, 2048);
        let bytes = minimal_gif();
        if bytes.len() > request.max_output_bytes {
            return -2;
        }
        let handle = unsafe { plugin_host_buffer_alloc(bytes.len()) };
        if handle.is_null() {
            return -3;
        }
        let data = unsafe { plugin_host_buffer_data(handle) };
        if data.is_null() {
            unsafe {
                plugin_host_buffer_free(handle);
            }
            return -4;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), data, bytes.len());
            (*output).buffer = handle;
            (*output).mime_type_ptr = TEST_PLUGIN_MIME.as_ptr();
            (*output).mime_type_len = TEST_PLUGIN_MIME.len();
        }
        0
    }

    unsafe extern "C" fn test_plugin_process(
        request: *const PixaPluginProcessRequestV1,
        output: *mut PixaPluginOutputV1,
    ) -> i32 {
        if request.is_null() || output.is_null() {
            return -1;
        }
        let request = unsafe { &*request };
        let operation =
            unsafe { slice::from_raw_parts(request.operation_ptr, request.operation_len) };
        let descriptor =
            unsafe { slice::from_raw_parts(request.descriptor_ptr, request.descriptor_len) };
        let format_id =
            unsafe { slice::from_raw_parts(request.format_id_ptr, request.format_id_len) };
        let mime_type =
            unsafe { slice::from_raw_parts(request.mime_type_ptr, request.mime_type_len) };
        let bytes = unsafe { slice::from_raw_parts(request.bytes_ptr, request.bytes_len) };
        assert_eq!(operation, b"tile:jpeg");
        assert!(descriptor.starts_with(b"tile("));
        assert_eq!(format_id, b"jpeg");
        assert_eq!(mime_type, b"image/jpeg");
        assert_eq!(bytes, b"fake-jpeg-input");
        assert_eq!(request.max_decoded_pixels, 256);
        let output_bytes = minimal_gif();
        if output_bytes.len() > request.max_output_bytes {
            return -2;
        }
        let handle = unsafe { plugin_host_buffer_alloc(output_bytes.len()) };
        if handle.is_null() {
            return -3;
        }
        let data = unsafe { plugin_host_buffer_data(handle) };
        if data.is_null() {
            unsafe {
                plugin_host_buffer_free(handle);
            }
            return -4;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(output_bytes.as_ptr(), data, output_bytes.len());
            (*output).buffer = handle;
            (*output).mime_type_ptr = TEST_PLUGIN_MIME.as_ptr();
            (*output).mime_type_len = TEST_PLUGIN_MIME.len();
        }
        0
    }

    fn binary_request_fixture() -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"PXR1");
        push_u8(&mut bytes, 2);
        push_string(&mut bytes, "inline");
        push_u32(&mut bytes, 0);
        push_string(&mut bytes, "test");
        push_string(&mut bytes, "runtime-binary-request");
        push_string(&mut bytes, "runtime-binary-request-encoded");
        push_u32(&mut bytes, 0);
        push_u32(&mut bytes, 0);
        push_u8(&mut bytes, 0);
        push_u8(&mut bytes, 1);
        push_u8(&mut bytes, 0);
        push_u8(&mut bytes, 0);
        push_i64(&mut bytes, 0);
        push_u64(&mut bytes, 4096);
        push_u64(&mut bytes, 4096);
        push_u64(&mut bytes, 24);
        push_u64(&mut bytes, 3000);
        push_u64(&mut bytes, 8192);
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
        push_u32(&mut bytes, 0);
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

    fn qoi_rgba_1x1() -> Vec<u8> {
        let mut bytes = b"qoif".to_vec();
        bytes.extend_from_slice(&1_u32.to_be_bytes());
        bytes.extend_from_slice(&1_u32.to_be_bytes());
        bytes.extend_from_slice(&[4, 0, 0xfe, 255, 0, 0]);
        bytes.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 1]);
        bytes
    }

    fn minimal_ico() -> Vec<u8> {
        vec![
            0, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 32, 0, 48, 0, 0, 0, 22, 0, 0, 0, 40, 0, 0, 0, 1, 0,
            0, 0, 2, 0, 0, 0, 1, 0, 32, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0,
        ]
    }

    fn jpeg_with_sof(marker: u8, width: u16, height: u16) -> Vec<u8> {
        let mut jpeg = vec![0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00];
        jpeg.extend_from_slice(&[0xff, marker, 0x00, 0x11, 0x08]);
        jpeg.extend_from_slice(&height.to_be_bytes());
        jpeg.extend_from_slice(&width.to_be_bytes());
        jpeg.extend_from_slice(&[0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
        jpeg
    }

    fn bmp_info_header(width: i32, height: i32) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"BM");
        bytes.extend_from_slice(&54_u32.to_le_bytes());
        bytes.extend_from_slice(&[0; 4]);
        bytes.extend_from_slice(&54_u32.to_le_bytes());
        bytes.extend_from_slice(&40_u32.to_le_bytes());
        bytes.extend_from_slice(&width.to_le_bytes());
        bytes.extend_from_slice(&height.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&24_u16.to_le_bytes());
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

    fn read_le_u32(bytes: &[u8], offset: usize) -> u32 {
        u32::from_le_bytes(bytes[offset..offset + 4].try_into().expect("u32 range"))
    }

    fn read_be_u32(bytes: &[u8], offset: usize) -> u32 {
        u32::from_be_bytes(bytes[offset..offset + 4].try_into().expect("u32 range"))
    }

    fn read_le_u16(bytes: &[u8], offset: usize) -> u16 {
        u16::from_le_bytes(bytes[offset..offset + 2].try_into().expect("u16 range"))
    }

    fn read_le_u64(bytes: &[u8], offset: usize) -> u64 {
        u64::from_le_bytes(bytes[offset..offset + 8].try_into().expect("u64 range"))
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
