use crate::cache::SharedBytes;
use crate::{RuntimeError, RuntimeResult};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::sync::{Arc, Mutex, OnceLock};

/// Stable ABI version accepted by the Pixa runtime plugin host.
pub const PIXA_PLUGIN_ABI_VERSION: u32 = 1;

static RUNTIME_PLUGIN_REGISTRY: OnceLock<Mutex<RuntimePluginRegistry>> = OnceLock::new();

#[cfg(test)]
static RUNTIME_PLUGIN_REGISTRY_TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

/// Shared runtime plugin executor object.
pub type RuntimePluginExecutorRef = Arc<dyn RuntimePluginExecutor>;

/// Request passed to a runtime fetcher executor.
#[derive(Clone, Copy, Debug)]
pub struct RuntimePluginFetchRequest<'a> {
    pub source_kind: &'a str,
    pub locator: &'a str,
    pub max_output_bytes: usize,
}

/// Request passed to a runtime decoder executor.
#[derive(Clone, Copy, Debug)]
pub struct RuntimePluginDecodeRequest<'a> {
    pub mime_type: &'a str,
    pub format_id: Option<&'a str>,
    pub bytes: &'a [u8],
    pub target_width: Option<u32>,
    pub target_height: Option<u32>,
    pub max_decoded_pixels: u64,
    pub max_output_bytes: usize,
}

/// Request passed to a runtime processor executor.
#[derive(Clone, Copy, Debug)]
pub struct RuntimePluginProcessRequest<'a> {
    pub operation: &'a str,
    pub descriptor: &'a str,
    pub format_id: Option<&'a str>,
    pub mime_type: Option<&'a str>,
    pub bytes: &'a [u8],
    pub max_decoded_pixels: u64,
    pub max_output_bytes: usize,
}

/// Request passed to a runtime cache-store read executor.
#[derive(Clone, Copy, Debug)]
pub struct RuntimePluginCacheReadRequest<'a> {
    pub namespace: &'a str,
    pub key: &'a str,
    pub allow_stale: bool,
    pub max_output_bytes: usize,
}

/// Request passed to a runtime cache-store write executor.
#[derive(Clone, Copy, Debug)]
pub struct RuntimePluginCacheWriteRequest<'a> {
    pub namespace: &'a str,
    pub key: &'a str,
    pub bytes: &'a [u8],
    pub ttl_ms: Option<i64>,
    pub private_entry: bool,
}

/// Request passed to a runtime cache-store remove executor.
#[derive(Clone, Copy, Debug)]
pub struct RuntimePluginCacheRemoveRequest<'a> {
    pub namespace: &'a str,
    pub key: &'a str,
}

/// Request passed to a runtime cache-store namespace clear executor.
#[derive(Clone, Copy, Debug)]
pub struct RuntimePluginCacheClearNamespaceRequest<'a> {
    pub namespace: &'a str,
}

/// runtime plugin byte output owned by the Rust host.
#[derive(Clone, Debug)]
pub struct RuntimePluginOutput {
    pub bytes: SharedBytes,
    pub mime_type: Option<String>,
}

impl RuntimePluginOutput {
    /// Creates Runtime-owned output bytes from a vector without an extra copy.
    pub fn from_vec(bytes: Vec<u8>, mime_type: Option<&str>) -> Self {
        Self {
            bytes: Arc::<[u8]>::from(bytes.into_boxed_slice()),
            mime_type: mime_type.map(str::to_string),
        }
    }
}

/// runtime cache-store lookup result.
#[derive(Clone, Debug)]
pub enum RuntimePluginCacheReadResult {
    Hit {
        output: RuntimePluginOutput,
        is_stale: bool,
    },
    Miss,
}

/// Safe Rust-side executor contract used by the host pipeline.
pub trait RuntimePluginExecutor: Send + Sync {
    fn fetch(
        &self,
        _request: RuntimePluginFetchRequest<'_>,
    ) -> RuntimeResult<Option<RuntimePluginOutput>> {
        Ok(None)
    }

    fn decode(
        &self,
        _request: RuntimePluginDecodeRequest<'_>,
    ) -> RuntimeResult<Option<RuntimePluginOutput>> {
        Ok(None)
    }

    fn process(
        &self,
        _request: RuntimePluginProcessRequest<'_>,
    ) -> RuntimeResult<Option<RuntimePluginOutput>> {
        Ok(None)
    }

    fn cache_read(
        &self,
        _request: RuntimePluginCacheReadRequest<'_>,
    ) -> RuntimeResult<Option<RuntimePluginCacheReadResult>> {
        Ok(None)
    }

    fn cache_write(
        &self,
        _request: RuntimePluginCacheWriteRequest<'_>,
    ) -> RuntimeResult<Option<()>> {
        Ok(None)
    }

    fn cache_remove(
        &self,
        _request: RuntimePluginCacheRemoveRequest<'_>,
    ) -> RuntimeResult<Option<()>> {
        Ok(None)
    }

    fn cache_clear_namespace(
        &self,
        _request: RuntimePluginCacheClearNamespaceRequest<'_>,
    ) -> RuntimeResult<Option<()>> {
        Ok(None)
    }
}

/// Runtime module deployment shape.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimePluginDeployment {
    /// Module compiled directly into Pixa's runtime host.
    BuiltInHostModule,
    /// Third-party module linked into the same final runtime host binary.
    HostLinkedPluginModule,
    /// Asset module loaded through an explicit dynamic boundary.
    AssetModule,
    /// External process or platform service. Not allowed on default hot paths.
    External,
}

impl RuntimePluginDeployment {
    /// Returns true when the module can share Pixa's final runtime binary.
    pub const fn can_link_into_host_binary(self) -> bool {
        matches!(self, Self::BuiltInHostModule | Self::HostLinkedPluginModule)
    }
}

/// Capabilities a runtime plugin module may expose.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RuntimePluginCapabilities {
    pub fetcher: bool,
    pub decoder: bool,
    pub processor: bool,
    pub cache_store: bool,
    pub host_managed_runtime: bool,
    pub binary_messages: bool,
    pub owned_buffers: bool,
    pub stream_handles: bool,
}

impl RuntimePluginCapabilities {
    /// Capability defaults required for production hot-path modules.
    pub const fn hot_path() -> Self {
        Self {
            fetcher: false,
            decoder: false,
            processor: false,
            cache_store: false,
            host_managed_runtime: true,
            binary_messages: true,
            owned_buffers: true,
            stream_handles: true,
        }
    }

    fn exposes_pipeline_capability(self) -> bool {
        self.fetcher || self.decoder || self.processor || self.cache_store
    }
}

/// Route claims exposed by a runtime plugin module.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RuntimePluginRoutes {
    pub fetcher_source_kinds: Vec<String>,
    pub decoder_format_ids: Vec<String>,
    pub decoder_mime_types: Vec<String>,
    pub decoder_signatures: Vec<RuntimePluginDecoderSignature>,
    pub processor_operations: Vec<String>,
    pub cache_store_namespaces: Vec<String>,
}

/// Static bounded-header signature route for a runtime decoder module.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimePluginDecoderSignature {
    pub offset: usize,
    pub magic: Vec<u8>,
    pub mime_type: String,
    pub format_id: Option<String>,
}

/// runtime plugin module metadata used by the host linker/dispatcher.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimePluginModule {
    pub module_id: String,
    pub abi_version: u32,
    pub deployment: RuntimePluginDeployment,
    pub package_name: Option<String>,
    pub implementation_language: Option<String>,
    pub entrypoint_symbol: Option<String>,
    pub capabilities: RuntimePluginCapabilities,
    pub routes: RuntimePluginRoutes,
}

impl RuntimePluginModule {
    /// Creates a built-in module that ships inside Pixa's runtime host.
    pub fn built_in(module_id: impl Into<String>, capabilities: RuntimePluginCapabilities) -> Self {
        Self {
            module_id: module_id.into(),
            abi_version: PIXA_PLUGIN_ABI_VERSION,
            deployment: RuntimePluginDeployment::BuiltInHostModule,
            package_name: None,
            implementation_language: Some("rust".to_string()),
            entrypoint_symbol: None,
            capabilities,
            routes: RuntimePluginRoutes::default(),
        }
    }

    /// Creates a third-party module that will be linked into the host binary.
    pub fn host_linked(
        module_id: impl Into<String>,
        entrypoint_symbol: impl Into<String>,
        implementation_language: impl Into<String>,
        capabilities: RuntimePluginCapabilities,
    ) -> Self {
        Self {
            module_id: module_id.into(),
            abi_version: PIXA_PLUGIN_ABI_VERSION,
            deployment: RuntimePluginDeployment::HostLinkedPluginModule,
            package_name: None,
            implementation_language: Some(implementation_language.into()),
            entrypoint_symbol: Some(entrypoint_symbol.into()),
            capabilities,
            routes: RuntimePluginRoutes::default(),
        }
    }

    /// Returns a module with explicit route claims.
    pub fn with_routes(mut self, routes: RuntimePluginRoutes) -> Self {
        self.routes = routes;
        self
    }
}

/// Counts describing the runtime plugin host registry.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct RuntimePluginRegistryStats {
    pub modules: usize,
    pub built_in_modules: usize,
    pub host_linked_modules: usize,
    pub runtime_asset_modules: usize,
    pub linkable_modules: usize,
    pub fetchers: usize,
    pub decoders: usize,
    pub processors: usize,
    pub cache_stores: usize,
}

/// runtime plugin host registry.
#[derive(Clone, Default)]
pub struct RuntimePluginRegistry {
    modules: BTreeMap<String, RuntimePluginModule>,
    executors: BTreeMap<String, RuntimePluginExecutorRef>,
}

impl fmt::Debug for RuntimePluginRegistry {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RuntimePluginRegistry")
            .field("modules", &self.modules)
            .field("executors", &self.executors.len())
            .finish()
    }
}

impl RuntimePluginRegistry {
    /// Registers one runtime module after validating ABI and ownership rules.
    pub fn register(&mut self, module: RuntimePluginModule) -> RuntimeResult<()> {
        self.register_internal(module, None)
    }

    /// Registers one runtime module with a host-managed executor.
    pub fn register_with_executor(
        &mut self,
        module: RuntimePluginModule,
        executor: RuntimePluginExecutorRef,
    ) -> RuntimeResult<()> {
        self.register_internal(module, Some(executor))
    }

    fn register_internal(
        &mut self,
        module: RuntimePluginModule,
        executor: Option<RuntimePluginExecutorRef>,
    ) -> RuntimeResult<()> {
        validate_plugin_module(&module)?;
        if module.deployment == RuntimePluginDeployment::External {
            return Err(RuntimeError::new(
                "plugin",
                false,
                "external plugin modules cannot join the runtime host registry",
            ));
        }
        if self.modules.contains_key(&module.module_id) {
            return Err(RuntimeError::new(
                "plugin",
                false,
                format!("duplicate runtime plugin module {}", module.module_id),
            ));
        }
        validate_unique_routes(self.modules.values(), &module)?;
        if let Some(executor) = executor {
            self.executors.insert(module.module_id.clone(), executor);
        }
        self.modules.insert(module.module_id.clone(), module);
        Ok(())
    }

    /// Returns one module by id.
    pub fn module(&self, module_id: &str) -> Option<&RuntimePluginModule> {
        self.modules.get(module_id)
    }

    /// Returns the runtime fetcher module for a source kind.
    pub fn fetcher_for_source_kind(&self, source_kind: &str) -> Option<&RuntimePluginModule> {
        let normalized = normalize_route_claim(source_kind);
        self.modules.values().find(|module| {
            module.capabilities.fetcher
                && module
                    .routes
                    .fetcher_source_kinds
                    .iter()
                    .any(|claim| normalize_route_claim(claim) == normalized)
        })
    }

    /// Returns the runtime decoder module for a MIME type.
    pub fn decoder_for_mime_type(&self, mime_type: &str) -> Option<&RuntimePluginModule> {
        let normalized = normalize_route_claim(mime_type);
        self.modules.values().find(|module| {
            module.capabilities.decoder
                && module
                    .routes
                    .decoder_mime_types
                    .iter()
                    .any(|claim| normalize_route_claim(claim) == normalized)
        })
    }

    /// Returns the runtime decoder module for a stable format id.
    pub fn decoder_for_format_id(&self, format_id: &str) -> Option<&RuntimePluginModule> {
        let normalized = normalize_route_claim(format_id);
        self.modules.values().find(|module| {
            module.capabilities.decoder
                && module
                    .routes
                    .decoder_format_ids
                    .iter()
                    .any(|claim| normalize_route_claim(claim) == normalized)
        })
    }

    /// Returns the runtime decoder module for a bounded static byte signature.
    pub fn decoder_for_signature(
        &self,
        bytes: &[u8],
    ) -> Option<(&RuntimePluginModule, &RuntimePluginDecoderSignature)> {
        self.modules.values().find_map(|module| {
            if !module.capabilities.decoder {
                return None;
            }
            module
                .routes
                .decoder_signatures
                .iter()
                .find(|signature| signature_matches(signature, bytes))
                .map(|signature| (module, signature))
        })
    }

    /// Returns the runtime cache-store module for a namespace.
    pub fn cache_store_for_namespace(&self, namespace: &str) -> Option<&RuntimePluginModule> {
        let normalized = normalize_route_claim(namespace);
        self.modules.values().find(|module| {
            module.capabilities.cache_store
                && module
                    .routes
                    .cache_store_namespaces
                    .iter()
                    .any(|claim| normalize_route_claim(claim) == normalized)
        })
    }

    /// Returns the runtime processor module for an operation.
    pub fn processor_for_operation(&self, operation: &str) -> Option<&RuntimePluginModule> {
        let normalized = normalize_route_claim(operation);
        self.modules.values().find(|module| {
            module.capabilities.processor
                && module
                    .routes
                    .processor_operations
                    .iter()
                    .any(|claim| normalize_route_claim(claim) == normalized)
        })
    }

    /// Returns the runtime fetcher executor for a source kind.
    pub fn fetcher_executor_for_source_kind(
        &self,
        source_kind: &str,
    ) -> Option<(&RuntimePluginModule, RuntimePluginExecutorRef)> {
        let module = self.fetcher_for_source_kind(source_kind)?;
        self.executors
            .get(&module.module_id)
            .cloned()
            .map(|executor| (module, executor))
    }

    /// Returns the runtime decoder executor for a MIME type.
    pub fn decoder_executor_for_mime_type(
        &self,
        mime_type: &str,
    ) -> Option<(&RuntimePluginModule, RuntimePluginExecutorRef)> {
        let module = self.decoder_for_mime_type(mime_type)?;
        self.executors
            .get(&module.module_id)
            .cloned()
            .map(|executor| (module, executor))
    }

    /// Returns the runtime decoder executor for a stable format id.
    pub fn decoder_executor_for_format_id(
        &self,
        format_id: &str,
    ) -> Option<(&RuntimePluginModule, RuntimePluginExecutorRef)> {
        let module = self.decoder_for_format_id(format_id)?;
        self.executors
            .get(&module.module_id)
            .cloned()
            .map(|executor| (module, executor))
    }

    /// Returns the runtime decoder executor for a bounded static byte signature.
    pub fn decoder_executor_for_signature(
        &self,
        bytes: &[u8],
    ) -> Option<(
        &RuntimePluginModule,
        &RuntimePluginDecoderSignature,
        RuntimePluginExecutorRef,
    )> {
        let (module, signature) = self.decoder_for_signature(bytes)?;
        self.executors
            .get(&module.module_id)
            .cloned()
            .map(|executor| (module, signature, executor))
    }

    /// Returns the runtime cache-store executor for a namespace.
    pub fn cache_store_executor_for_namespace(
        &self,
        namespace: &str,
    ) -> Option<(&RuntimePluginModule, RuntimePluginExecutorRef)> {
        let module = self.cache_store_for_namespace(namespace)?;
        self.executors
            .get(&module.module_id)
            .cloned()
            .map(|executor| (module, executor))
    }

    /// Returns the runtime processor executor for an operation.
    pub fn processor_executor_for_operation(
        &self,
        operation: &str,
    ) -> Option<(&RuntimePluginModule, RuntimePluginExecutorRef)> {
        let module = self.processor_for_operation(operation)?;
        self.executors
            .get(&module.module_id)
            .cloned()
            .map(|executor| (module, executor))
    }

    /// Returns a stable module snapshot sorted by id.
    pub fn modules(&self) -> Vec<RuntimePluginModule> {
        self.modules.values().cloned().collect()
    }

    /// Returns registry counters for diagnostics and runtime snapshots.
    pub fn stats(&self) -> RuntimePluginRegistryStats {
        let mut stats = RuntimePluginRegistryStats {
            modules: self.modules.len(),
            ..RuntimePluginRegistryStats::default()
        };
        for module in self.modules.values() {
            match module.deployment {
                RuntimePluginDeployment::BuiltInHostModule => {
                    stats.built_in_modules += 1;
                }
                RuntimePluginDeployment::HostLinkedPluginModule => {
                    stats.host_linked_modules += 1;
                }
                RuntimePluginDeployment::AssetModule => {
                    stats.runtime_asset_modules += 1;
                }
                RuntimePluginDeployment::External => {}
            }
            if module.deployment.can_link_into_host_binary() {
                stats.linkable_modules += 1;
            }
            if module.capabilities.fetcher {
                stats.fetchers += 1;
            }
            if module.capabilities.decoder {
                stats.decoders += 1;
            }
            if module.capabilities.processor {
                stats.processors += 1;
            }
            if module.capabilities.cache_store {
                stats.cache_stores += 1;
            }
        }
        stats
    }
}

/// Registers one module in the global runtime plugin host registry.
pub fn register_plugin_module(module: RuntimePluginModule) -> RuntimeResult<()> {
    plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .register(module)
}

/// Registers one module and its host-managed executor in the global registry.
pub fn register_plugin_module_with_executor(
    module: RuntimePluginModule,
    executor: RuntimePluginExecutorRef,
) -> RuntimeResult<()> {
    plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .register_with_executor(module, executor)
}

/// Returns a stable global registry snapshot.
pub fn plugin_modules() -> RuntimeResult<Vec<RuntimePluginModule>> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .modules())
}

/// Returns the runtime fetcher module registered for a source kind.
pub fn runtime_fetcher_for_source_kind(
    source_kind: &str,
) -> RuntimeResult<Option<RuntimePluginModule>> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .fetcher_for_source_kind(source_kind)
        .cloned())
}

/// Returns the runtime decoder module registered for a MIME type.
pub fn runtime_decoder_for_mime_type(
    mime_type: &str,
) -> RuntimeResult<Option<RuntimePluginModule>> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .decoder_for_mime_type(mime_type)
        .cloned())
}

/// Returns the runtime decoder module registered for a stable format id.
pub fn runtime_decoder_for_format_id(
    format_id: &str,
) -> RuntimeResult<Option<RuntimePluginModule>> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .decoder_for_format_id(format_id)
        .cloned())
}

/// Returns the runtime decoder module registered for a bounded static byte signature.
pub fn runtime_decoder_for_signature(
    bytes: &[u8],
) -> RuntimeResult<Option<(RuntimePluginModule, RuntimePluginDecoderSignature)>> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .decoder_for_signature(bytes)
        .map(|(module, signature)| (module.clone(), signature.clone())))
}

/// Returns the runtime cache-store module registered for a namespace.
pub fn runtime_cache_store_for_namespace(
    namespace: &str,
) -> RuntimeResult<Option<RuntimePluginModule>> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .cache_store_for_namespace(namespace)
        .cloned())
}

/// Returns the runtime processor module registered for an operation.
pub fn runtime_processor_for_operation(
    operation: &str,
) -> RuntimeResult<Option<RuntimePluginModule>> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .processor_for_operation(operation)
        .cloned())
}

/// Returns the runtime fetcher module and executor registered for a source kind.
pub fn runtime_fetcher_executor_for_source_kind(
    source_kind: &str,
) -> RuntimeResult<Option<(RuntimePluginModule, RuntimePluginExecutorRef)>> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .fetcher_executor_for_source_kind(source_kind)
        .map(|(module, executor)| (module.clone(), executor)))
}

/// Returns the runtime decoder module and executor registered for a MIME type.
pub fn runtime_decoder_executor_for_mime_type(
    mime_type: &str,
) -> RuntimeResult<Option<(RuntimePluginModule, RuntimePluginExecutorRef)>> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .decoder_executor_for_mime_type(mime_type)
        .map(|(module, executor)| (module.clone(), executor)))
}

/// Returns the runtime decoder module and executor registered for a stable format id.
pub fn runtime_decoder_executor_for_format_id(
    format_id: &str,
) -> RuntimeResult<Option<(RuntimePluginModule, RuntimePluginExecutorRef)>> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .decoder_executor_for_format_id(format_id)
        .map(|(module, executor)| (module.clone(), executor)))
}

/// Returns the runtime decoder module, signature route and executor for bounded header bytes.
pub fn runtime_decoder_executor_for_signature(
    bytes: &[u8],
) -> RuntimeResult<
    Option<(
        RuntimePluginModule,
        RuntimePluginDecoderSignature,
        RuntimePluginExecutorRef,
    )>,
> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .decoder_executor_for_signature(bytes)
        .map(|(module, signature, executor)| (module.clone(), signature.clone(), executor)))
}

/// Returns the runtime cache-store module and executor registered for a namespace.
pub fn runtime_cache_store_executor_for_namespace(
    namespace: &str,
) -> RuntimeResult<Option<(RuntimePluginModule, RuntimePluginExecutorRef)>> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .cache_store_executor_for_namespace(namespace)
        .map(|(module, executor)| (module.clone(), executor)))
}

/// Returns the runtime processor module and executor registered for an operation.
pub fn runtime_processor_executor_for_operation(
    operation: &str,
) -> RuntimeResult<Option<(RuntimePluginModule, RuntimePluginExecutorRef)>> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .processor_executor_for_operation(operation)
        .map(|(module, executor)| (module.clone(), executor)))
}

/// Executes one runtime processor through a registered executor.
pub fn runtime_process(
    request: RuntimePluginProcessRequest<'_>,
) -> RuntimeResult<Option<RuntimePluginOutput>> {
    let Some(module) = runtime_processor_for_operation(request.operation)? else {
        return Ok(None);
    };
    let Some((module, executor)) = runtime_processor_executor_for_operation(request.operation)?
    else {
        return Err(plugin_entrypoint_missing_error(
            "processor",
            "processor",
            &module.module_id,
            request.operation,
        ));
    };
    executor
        .process(request)?
        .ok_or_else(|| {
            plugin_entrypoint_missing_error(
                "processor",
                "processor",
                &module.module_id,
                request.operation,
            )
        })
        .map(Some)
}

/// Executes one runtime cache-store read through a registered executor.
pub fn runtime_cache_store_read(
    request: RuntimePluginCacheReadRequest<'_>,
) -> RuntimeResult<Option<RuntimePluginCacheReadResult>> {
    let Some(module) = runtime_cache_store_for_namespace(request.namespace)? else {
        return Ok(None);
    };
    let Some((module, executor)) = runtime_cache_store_executor_for_namespace(request.namespace)?
    else {
        return Err(plugin_entrypoint_missing_error(
            "cache",
            "cache store",
            &module.module_id,
            request.namespace,
        ));
    };
    executor
        .cache_read(request)?
        .ok_or_else(|| {
            plugin_entrypoint_missing_error(
                "cache",
                "cache store",
                &module.module_id,
                request.namespace,
            )
        })
        .map(Some)
}

/// Executes one runtime cache-store write through a registered executor.
pub fn runtime_cache_store_write(
    request: RuntimePluginCacheWriteRequest<'_>,
) -> RuntimeResult<Option<()>> {
    let Some(module) = runtime_cache_store_for_namespace(request.namespace)? else {
        return Ok(None);
    };
    let Some((module, executor)) = runtime_cache_store_executor_for_namespace(request.namespace)?
    else {
        return Err(plugin_entrypoint_missing_error(
            "cache_write",
            "cache store",
            &module.module_id,
            request.namespace,
        ));
    };
    executor
        .cache_write(request)?
        .ok_or_else(|| {
            plugin_entrypoint_missing_error(
                "cache_write",
                "cache store",
                &module.module_id,
                request.namespace,
            )
        })
        .map(Some)
}

/// Executes one runtime cache-store remove through a registered executor.
pub fn runtime_cache_store_remove(
    request: RuntimePluginCacheRemoveRequest<'_>,
) -> RuntimeResult<Option<()>> {
    let Some(module) = runtime_cache_store_for_namespace(request.namespace)? else {
        return Ok(None);
    };
    let Some((module, executor)) = runtime_cache_store_executor_for_namespace(request.namespace)?
    else {
        return Err(plugin_entrypoint_missing_error(
            "cache",
            "cache store",
            &module.module_id,
            request.namespace,
        ));
    };
    executor
        .cache_remove(request)?
        .ok_or_else(|| {
            plugin_entrypoint_missing_error(
                "cache",
                "cache store",
                &module.module_id,
                request.namespace,
            )
        })
        .map(Some)
}

/// Executes one runtime cache-store namespace clear through a registered executor.
pub fn runtime_cache_store_clear_namespace(
    request: RuntimePluginCacheClearNamespaceRequest<'_>,
) -> RuntimeResult<Option<()>> {
    let Some(module) = runtime_cache_store_for_namespace(request.namespace)? else {
        return Ok(None);
    };
    let Some((module, executor)) = runtime_cache_store_executor_for_namespace(request.namespace)?
    else {
        return Err(plugin_entrypoint_missing_error(
            "cache",
            "cache store",
            &module.module_id,
            request.namespace,
        ));
    };
    executor
        .cache_clear_namespace(request)?
        .ok_or_else(|| {
            plugin_entrypoint_missing_error(
                "cache",
                "cache store",
                &module.module_id,
                request.namespace,
            )
        })
        .map(Some)
}

/// Returns global registry counters.
pub fn plugin_registry_stats() -> RuntimeResult<RuntimePluginRegistryStats> {
    Ok(plugin_registry()
        .lock()
        .map_err(|_| RuntimeError::new("plugin", true, "runtime plugin registry lock poisoned"))?
        .stats())
}

fn plugin_registry() -> &'static Mutex<RuntimePluginRegistry> {
    RUNTIME_PLUGIN_REGISTRY.get_or_init(|| Mutex::new(RuntimePluginRegistry::default()))
}

#[cfg(test)]
pub(crate) fn clear_plugin_registry_for_test() {
    if let Ok(mut registry) = plugin_registry().lock() {
        *registry = RuntimePluginRegistry::default();
    }
}

#[cfg(test)]
pub(crate) fn plugin_registry_test_guard() -> std::sync::MutexGuard<'static, ()> {
    RUNTIME_PLUGIN_REGISTRY_TEST_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .expect("runtime plugin registry test lock should not be poisoned")
}

/// Validates a runtime plugin module before it can join the host registry.
pub fn validate_plugin_module(module: &RuntimePluginModule) -> RuntimeResult<()> {
    if module.module_id.trim().is_empty() {
        return Err(RuntimeError::new(
            "plugin",
            false,
            "runtime plugin module id must not be empty",
        ));
    }
    if module.abi_version != PIXA_PLUGIN_ABI_VERSION {
        return Err(RuntimeError::new(
            "plugin",
            false,
            format!(
                "unsupported runtime plugin ABI version {}",
                module.abi_version
            ),
        ));
    }
    if !module.capabilities.exposes_pipeline_capability() {
        return Err(RuntimeError::new(
            "plugin",
            false,
            "runtime plugin module must expose at least one pipeline capability",
        ));
    }
    if !module.capabilities.host_managed_runtime
        || !module.capabilities.binary_messages
        || !module.capabilities.owned_buffers
        || !module.capabilities.stream_handles
    {
        return Err(RuntimeError::new(
            "plugin",
            false,
            "runtime hot-path plugin must use Pixa host runtime, binary messages, owned buffers and stream handles",
        ));
    }
    if matches!(
        module.deployment,
        RuntimePluginDeployment::HostLinkedPluginModule | RuntimePluginDeployment::AssetModule
    ) && module
        .entrypoint_symbol
        .as_deref()
        .is_none_or(|symbol| symbol.trim().is_empty())
    {
        return Err(RuntimeError::new(
            "plugin",
            false,
            "runtime plugin module entrypoint symbol must not be empty",
        ));
    }
    validate_route_group(
        module.capabilities.fetcher,
        &module.routes.fetcher_source_kinds,
        "fetcher source kind",
    )?;
    validate_decoder_routes(
        module.capabilities.decoder,
        &module.routes.decoder_mime_types,
        &module.routes.decoder_format_ids,
        &module.routes.decoder_signatures,
    )?;
    validate_route_group(
        module.capabilities.processor,
        &module.routes.processor_operations,
        "processor operation",
    )?;
    validate_route_group(
        module.capabilities.cache_store,
        &module.routes.cache_store_namespaces,
        "cache store namespace",
    )?;
    Ok(())
}

fn validate_route_group(
    capability_enabled: bool,
    claims: &[String],
    label: &'static str,
) -> RuntimeResult<()> {
    if !capability_enabled && !claims.is_empty() {
        return Err(RuntimeError::new(
            "plugin",
            false,
            format!("runtime plugin {label} route requires matching capability"),
        ));
    }
    for claim in claims {
        if normalize_route_claim(claim).is_empty() {
            return Err(RuntimeError::new(
                "plugin",
                false,
                format!("runtime plugin {label} route must not be empty"),
            ));
        }
    }
    Ok(())
}

fn validate_unique_routes<'a>(
    existing_modules: impl Iterator<Item = &'a RuntimePluginModule>,
    next: &RuntimePluginModule,
) -> RuntimeResult<()> {
    for existing in existing_modules {
        validate_no_route_overlap(
            existing,
            next,
            &existing.routes.fetcher_source_kinds,
            &next.routes.fetcher_source_kinds,
            "fetcher source kind",
        )?;
        validate_no_route_overlap(
            existing,
            next,
            &existing.routes.decoder_mime_types,
            &next.routes.decoder_mime_types,
            "decoder MIME type",
        )?;
        validate_no_route_overlap(
            existing,
            next,
            &existing.routes.decoder_format_ids,
            &next.routes.decoder_format_ids,
            "decoder format id",
        )?;
        validate_no_decoder_signature_overlap(existing, next)?;
        validate_no_route_overlap(
            existing,
            next,
            &existing.routes.processor_operations,
            &next.routes.processor_operations,
            "processor operation",
        )?;
        validate_no_route_overlap(
            existing,
            next,
            &existing.routes.cache_store_namespaces,
            &next.routes.cache_store_namespaces,
            "cache store namespace",
        )?;
    }
    Ok(())
}

fn validate_decoder_routes(
    capability_enabled: bool,
    mime_types: &[String],
    format_ids: &[String],
    signatures: &[RuntimePluginDecoderSignature],
) -> RuntimeResult<()> {
    if !capability_enabled
        && (!mime_types.is_empty() || !format_ids.is_empty() || !signatures.is_empty())
    {
        return Err(RuntimeError::new(
            "plugin",
            false,
            "runtime plugin decoder route requires matching capability",
        ));
    }
    validate_route_values(mime_types, "decoder MIME type")?;
    validate_route_values(format_ids, "decoder format id")?;
    let mut seen_signatures = BTreeSet::<String>::new();
    for signature in signatures {
        validate_decoder_signature(signature)?;
        let key = decoder_signature_key(signature);
        if !seen_signatures.insert(key.clone()) {
            return Err(RuntimeError::new(
                "plugin",
                false,
                format!("duplicate runtime plugin decoder signature {key:?}"),
            ));
        }
    }
    Ok(())
}

fn validate_route_values(claims: &[String], label: &'static str) -> RuntimeResult<()> {
    for claim in claims {
        if normalize_route_claim(claim).is_empty() {
            return Err(RuntimeError::new(
                "plugin",
                false,
                format!("runtime plugin {label} route must not be empty"),
            ));
        }
    }
    Ok(())
}

fn validate_decoder_signature(signature: &RuntimePluginDecoderSignature) -> RuntimeResult<()> {
    if signature.magic.is_empty() {
        return Err(RuntimeError::new(
            "plugin",
            false,
            "runtime plugin decoder signature magic must not be empty",
        ));
    }
    if signature.magic.len() > 64 {
        return Err(RuntimeError::new(
            "plugin",
            false,
            "runtime plugin decoder signature magic must be at most 64 bytes",
        ));
    }
    if signature.offset.saturating_add(signature.magic.len()) > 4096 {
        return Err(RuntimeError::new(
            "plugin",
            false,
            "runtime plugin decoder signature must fit in first 4096 bytes",
        ));
    }
    if normalize_route_claim(&signature.mime_type).is_empty() {
        return Err(RuntimeError::new(
            "plugin",
            false,
            "runtime plugin decoder signature MIME type must not be empty",
        ));
    }
    if signature
        .format_id
        .as_deref()
        .is_some_and(|format_id| normalize_route_claim(format_id).is_empty())
    {
        return Err(RuntimeError::new(
            "plugin",
            false,
            "runtime plugin decoder signature format id must not be empty",
        ));
    }
    Ok(())
}

fn validate_no_route_overlap(
    existing: &RuntimePluginModule,
    next: &RuntimePluginModule,
    existing_claims: &[String],
    next_claims: &[String],
    label: &'static str,
) -> RuntimeResult<()> {
    for next_claim in next_claims {
        let normalized_next = normalize_route_claim(next_claim);
        if existing_claims
            .iter()
            .any(|claim| normalize_route_claim(claim) == normalized_next)
        {
            return Err(RuntimeError::new(
                "plugin",
                false,
                format!(
                    "duplicate runtime plugin {label} {next_claim} from {} and {}",
                    existing.module_id, next.module_id
                ),
            ));
        }
    }
    Ok(())
}

fn validate_no_decoder_signature_overlap(
    existing: &RuntimePluginModule,
    next: &RuntimePluginModule,
) -> RuntimeResult<()> {
    for existing_signature in &existing.routes.decoder_signatures {
        for next_signature in &next.routes.decoder_signatures {
            if decoder_signature_key(existing_signature) == decoder_signature_key(next_signature) {
                return Err(RuntimeError::new(
                    "plugin",
                    false,
                    format!(
                        "runtime plugin decoder signature {:?} is already registered by {}",
                        decoder_signature_key(next_signature),
                        existing.module_id
                    ),
                ));
            }
        }
    }
    Ok(())
}

fn signature_matches(signature: &RuntimePluginDecoderSignature, bytes: &[u8]) -> bool {
    bytes.get(signature.offset..signature.offset.saturating_add(signature.magic.len()))
        == Some(signature.magic.as_slice())
}

fn decoder_signature_key(signature: &RuntimePluginDecoderSignature) -> String {
    let mut key = format!("{}:", signature.offset);
    for byte in &signature.magic {
        key.push_str(&format!("{byte:02x}"));
    }
    key
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

fn normalize_route_claim(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_linked_module_can_share_single_binary() {
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.decoder = true;
        let module = RuntimePluginModule::host_linked(
            "third.party.decoder.test",
            "pixa_plugin_init",
            "zig",
            capabilities,
        );

        validate_plugin_module(&module).expect("host-linked module should be valid");
        assert_eq!(
            module.deployment,
            RuntimePluginDeployment::HostLinkedPluginModule
        );
        assert!(module.deployment.can_link_into_host_binary());
        assert_eq!(module.implementation_language.as_deref(), Some("zig"));
    }

    #[test]
    fn rejects_hot_path_module_without_host_owned_buffers() {
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.processor = true;
        capabilities.owned_buffers = false;
        let module = RuntimePluginModule::host_linked(
            "bad.processor",
            "pixa_plugin_init",
            "c",
            capabilities,
        );

        let error = validate_plugin_module(&module)
            .expect_err("hot-path modules must keep runtime ownership");
        assert_eq!(error.stage, "plugin");
    }

    #[test]
    fn rejects_hot_path_module_without_stream_handles() {
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.fetcher = true;
        capabilities.stream_handles = false;
        let module =
            RuntimePluginModule::host_linked("bad.fetcher", "pixa_plugin_init", "c", capabilities);

        let error =
            validate_plugin_module(&module).expect_err("hot-path modules must use stream handles");
        assert_eq!(error.stage, "plugin");
    }

    #[test]
    fn registry_tracks_capability_counts_without_extra_runtime() {
        let mut registry = RuntimePluginRegistry::default();
        let mut decoder = RuntimePluginCapabilities::hot_path();
        decoder.decoder = true;
        let mut fetcher = RuntimePluginCapabilities::hot_path();
        fetcher.fetcher = true;

        registry
            .register(RuntimePluginModule::built_in("pixa.decoder.test", decoder))
            .expect("built-in module should register");
        registry
            .register(RuntimePluginModule::host_linked(
                "third.party.fetcher",
                "pixa_plugin_init",
                "c",
                fetcher,
            ))
            .expect("host-linked module should register");

        let stats = registry.stats();
        assert_eq!(stats.modules, 2);
        assert_eq!(stats.built_in_modules, 1);
        assert_eq!(stats.host_linked_modules, 1);
        assert_eq!(stats.linkable_modules, 2);
        assert_eq!(stats.fetchers, 1);
        assert_eq!(stats.decoders, 1);
        assert!(registry.module("pixa.decoder.test").is_some());
    }

    #[test]
    fn registry_resolves_route_claims_without_dart_registry() {
        let mut registry = RuntimePluginRegistry::default();
        let mut decoder = RuntimePluginCapabilities::hot_path();
        decoder.decoder = true;
        let decoder_module = RuntimePluginModule::built_in("pixa.decoder.test", decoder)
            .with_routes(RuntimePluginRoutes {
                decoder_format_ids: vec!["pixa-test".to_string()],
                decoder_mime_types: vec!["image/x-pixa-test".to_string()],
                ..RuntimePluginRoutes::default()
            });
        registry
            .register(decoder_module)
            .expect("decoder route should register");

        assert_eq!(
            registry
                .decoder_for_mime_type("IMAGE/X-PIXA-TEST")
                .map(|module| module.module_id.as_str()),
            Some("pixa.decoder.test")
        );
        assert_eq!(
            registry
                .decoder_for_format_id("PIXA-TEST")
                .map(|module| module.module_id.as_str()),
            Some("pixa.decoder.test")
        );
        assert!(registry.fetcher_for_source_kind("s3").is_none());
    }

    #[test]
    fn registry_resolves_decoder_signature_routes() {
        let mut registry = RuntimePluginRegistry::default();
        let mut decoder = RuntimePluginCapabilities::hot_path();
        decoder.decoder = true;
        let decoder_module = RuntimePluginModule::built_in("pixa.decoder.signature", decoder)
            .with_routes(RuntimePluginRoutes {
                decoder_signatures: vec![RuntimePluginDecoderSignature {
                    offset: 4,
                    magic: b"pixa".to_vec(),
                    mime_type: "image/x-pixa-signature".to_string(),
                    format_id: Some("pixa-signature".to_string()),
                }],
                ..RuntimePluginRoutes::default()
            });
        registry
            .register(decoder_module)
            .expect("decoder signature route should register");

        let (module, signature) = registry
            .decoder_for_signature(b"\0\0\0\0pixa-data")
            .expect("decoder signature route should match");

        assert_eq!(module.module_id, "pixa.decoder.signature");
        assert_eq!(signature.mime_type, "image/x-pixa-signature");
        assert_eq!(signature.format_id.as_deref(), Some("pixa-signature"));
    }

    #[test]
    fn registry_rejects_duplicate_route_claims() {
        let mut registry = RuntimePluginRegistry::default();
        let mut fetcher = RuntimePluginCapabilities::hot_path();
        fetcher.fetcher = true;
        let first = RuntimePluginModule::built_in("first.fetcher", fetcher).with_routes(
            RuntimePluginRoutes {
                fetcher_source_kinds: vec!["s3".to_string()],
                ..RuntimePluginRoutes::default()
            },
        );
        let second = RuntimePluginModule::built_in("second.fetcher", fetcher).with_routes(
            RuntimePluginRoutes {
                fetcher_source_kinds: vec!["S3".to_string()],
                ..RuntimePluginRoutes::default()
            },
        );

        registry
            .register(first)
            .expect("first route should register");
        let error = registry
            .register(second)
            .expect_err("duplicate runtime route must fail fast");
        assert_eq!(error.stage, "plugin");
    }

    #[test]
    fn registry_rejects_duplicate_decoder_format_claims() {
        let mut registry = RuntimePluginRegistry::default();
        let mut decoder = RuntimePluginCapabilities::hot_path();
        decoder.decoder = true;
        let first = RuntimePluginModule::built_in("first.decoder", decoder).with_routes(
            RuntimePluginRoutes {
                decoder_format_ids: vec!["third-party".to_string()],
                decoder_mime_types: vec!["image/a".to_string()],
                ..RuntimePluginRoutes::default()
            },
        );
        let second = RuntimePluginModule::built_in("second.decoder", decoder).with_routes(
            RuntimePluginRoutes {
                decoder_format_ids: vec!["THIRD-PARTY".to_string()],
                decoder_mime_types: vec!["image/b".to_string()],
                ..RuntimePluginRoutes::default()
            },
        );

        registry
            .register(first)
            .expect("first decoder route should register");
        let error = registry
            .register(second)
            .expect_err("duplicate decoder format route must fail fast");
        assert_eq!(error.stage, "plugin");
    }

    #[test]
    fn global_registry_rejects_duplicates_and_external_modules() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.decoder = true;
        let module = RuntimePluginModule::built_in("dup.decoder", capabilities);

        register_plugin_module(module.clone()).expect("first module should register");
        let duplicate = register_plugin_module(module).expect_err("duplicate id must fail fast");
        assert_eq!(duplicate.stage, "plugin");

        let external = RuntimePluginModule {
            module_id: "external.decoder".to_string(),
            abi_version: PIXA_PLUGIN_ABI_VERSION,
            deployment: RuntimePluginDeployment::External,
            package_name: None,
            implementation_language: Some("dart".to_string()),
            entrypoint_symbol: None,
            capabilities,
            routes: RuntimePluginRoutes::default(),
        };
        let error = register_plugin_module(external)
            .expect_err("external module must not join host registry");
        assert_eq!(error.stage, "plugin");
        clear_plugin_registry_for_test();
    }

    #[test]
    fn runtime_cache_store_executor_runs_for_claimed_namespace() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.cache_store = true;
        register_plugin_module_with_executor(
            RuntimePluginModule::built_in("pixa.cache_store.test", capabilities).with_routes(
                RuntimePluginRoutes {
                    cache_store_namespaces: vec!["plugin-cache".to_string()],
                    ..RuntimePluginRoutes::default()
                },
            ),
            Arc::new(TestCacheStoreExecutor),
        )
        .expect("cache store executor should register");

        let read = runtime_cache_store_read(RuntimePluginCacheReadRequest {
            namespace: "PLUGIN-CACHE",
            key: "0123456789abcdef",
            allow_stale: false,
            max_output_bytes: 64,
        })
        .expect("cache store read should execute")
        .expect("claimed namespace should select cache store");

        match read {
            RuntimePluginCacheReadResult::Hit { output, is_stale } => {
                assert!(!is_stale);
                assert_eq!(output.bytes.as_ref(), b"cached-by-plugin");
                assert_eq!(output.mime_type.as_deref(), Some("image/test"));
            }
            RuntimePluginCacheReadResult::Miss => panic!("test cache store should hit"),
        }
        assert!(runtime_cache_store_read(RuntimePluginCacheReadRequest {
            namespace: "unclaimed",
            key: "0123456789abcdef",
            allow_stale: false,
            max_output_bytes: 64,
        })
        .expect("unclaimed namespace should not fail")
        .is_none());
        assert!(runtime_cache_store_write(RuntimePluginCacheWriteRequest {
            namespace: "plugin-cache",
            key: "0123456789abcdef",
            bytes: b"value",
            ttl_ms: Some(1000),
            private_entry: true,
        })
        .expect("cache write should execute")
        .is_some());
        assert!(runtime_cache_store_remove(RuntimePluginCacheRemoveRequest {
            namespace: "plugin-cache",
            key: "0123456789abcdef",
        })
        .expect("cache remove should execute")
        .is_some());
        assert!(
            runtime_cache_store_clear_namespace(RuntimePluginCacheClearNamespaceRequest {
                namespace: "plugin-cache",
            })
            .expect("cache clear should execute")
            .is_some()
        );
        clear_plugin_registry_for_test();
    }

    #[test]
    fn runtime_cache_store_claim_without_executor_fails_fast() {
        let _registry_guard = plugin_registry_test_guard();
        clear_plugin_registry_for_test();
        let mut capabilities = RuntimePluginCapabilities::hot_path();
        capabilities.cache_store = true;
        register_plugin_module(
            RuntimePluginModule::built_in("pixa.cache_store.missing", capabilities).with_routes(
                RuntimePluginRoutes {
                    cache_store_namespaces: vec!["missing-cache".to_string()],
                    ..RuntimePluginRoutes::default()
                },
            ),
        )
        .expect("cache store route should register");

        let error = runtime_cache_store_read(RuntimePluginCacheReadRequest {
            namespace: "missing-cache",
            key: "0123456789abcdef",
            allow_stale: false,
            max_output_bytes: 64,
        })
        .expect_err("claimed cache store without executor must fail fast");

        assert_eq!(error.stage, "cache");
        assert!(error.message.contains("pixa.cache_store.missing"));
        clear_plugin_registry_for_test();
    }

    struct TestCacheStoreExecutor;

    impl RuntimePluginExecutor for TestCacheStoreExecutor {
        fn cache_read(
            &self,
            request: RuntimePluginCacheReadRequest<'_>,
        ) -> RuntimeResult<Option<RuntimePluginCacheReadResult>> {
            assert_eq!(request.namespace, "PLUGIN-CACHE");
            assert_eq!(request.key, "0123456789abcdef");
            assert!(!request.allow_stale);
            assert!(request.max_output_bytes >= b"cached-by-plugin".len());
            Ok(Some(RuntimePluginCacheReadResult::Hit {
                output: RuntimePluginOutput::from_vec(
                    b"cached-by-plugin".to_vec(),
                    Some("image/test"),
                ),
                is_stale: false,
            }))
        }

        fn cache_write(
            &self,
            request: RuntimePluginCacheWriteRequest<'_>,
        ) -> RuntimeResult<Option<()>> {
            assert_eq!(request.namespace, "plugin-cache");
            assert_eq!(request.key, "0123456789abcdef");
            assert_eq!(request.bytes, b"value");
            assert_eq!(request.ttl_ms, Some(1000));
            assert!(request.private_entry);
            Ok(Some(()))
        }

        fn cache_remove(
            &self,
            request: RuntimePluginCacheRemoveRequest<'_>,
        ) -> RuntimeResult<Option<()>> {
            assert_eq!(request.namespace, "plugin-cache");
            assert_eq!(request.key, "0123456789abcdef");
            Ok(Some(()))
        }

        fn cache_clear_namespace(
            &self,
            request: RuntimePluginCacheClearNamespaceRequest<'_>,
        ) -> RuntimeResult<Option<()>> {
            assert_eq!(request.namespace, "plugin-cache");
            Ok(Some(()))
        }
    }
}
