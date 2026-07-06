use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::process;

mod build_json;
mod build_render;

use build_json::{JsonParser, JsonValue};
use build_render::render_generated_source;

const ABI_VERSION: i64 = 1;
const DEFAULT_MANIFEST_RELATIVE_PATH: &str = "../../packages/pixa/plugins/pixa_plugins.json";
const JPEG_TURBO_PROCESSOR_ENTRYPOINT: &str = "pixa_jpeg_turbo_processor_plugin_init";
const WEBP_PROCESSOR_ENTRYPOINT: &str = "pixa_webp_processor_plugin_init";
const SUPPORTED_VIDEO_FRAME_OUTPUT_MIME_TYPES: &[&str] = &[
    "image/jpeg",
    "image/jpg",
    "image/pjpeg",
    "image/png",
    "image/gif",
    "image/webp",
    "image/bmp",
    "image/x-bmp",
    "image/x-ms-bmp",
    "image/vnd.wap.wbmp",
    "image/x-icon",
    "image/vnd.microsoft.icon",
    "image/tiff",
    "image/tiff-fx",
    "image/x-portable-anymap",
    "image/x-portable-arbitrarymap",
    "image/x-portable-bitmap",
    "image/x-portable-graymap",
    "image/x-portable-pixmap",
    "image/qoi",
    "image/x-qoi",
    "image/tga",
    "image/x-tga",
    "application/x-tga",
    "image/vnd.ms-dds",
    "image/vnd-ms.dds",
    "image/x-dds",
    "image/vnd.radiance",
    "image/x-hdr",
    "image/x-radiance",
    "image/hdr",
    "image/x-farbfeld",
    "image/x-pcx",
    "image/vnd.zbrush.pcx",
    "image/sgi",
    "image/x-sgi",
    "image/x-rgb",
    "image/x-xbitmap",
    "image/x-xbm",
    "image/x-xpixmap",
    "image/x-xpm",
];

fn main() {
    if let Err(error) = run() {
        eprintln!("Pixa runtime plugin plan build failed: {error}");
        process::exit(1);
    }
}

fn run() -> Result<(), String> {
    println!("cargo:rerun-if-env-changed=PIXA_PLUGIN_PLAN");
    let manifest_dir = PathBuf::from(
        env::var("CARGO_MANIFEST_DIR")
            .map_err(|_| "CARGO_MANIFEST_DIR is not available".to_string())?,
    );
    let plan_path = match env::var_os("PIXA_PLUGIN_PLAN") {
        Some(value) if !value.is_empty() => PathBuf::from(value),
        _ => manifest_dir.join(DEFAULT_MANIFEST_RELATIVE_PATH),
    };
    println!("cargo:rerun-if-changed={}", plan_path.display());

    let plan_text = fs::read_to_string(&plan_path)
        .map_err(|error| format!("failed to read {}: {error}", plan_path.display()))?;
    let json = JsonParser::new(&plan_text).parse()?;
    let modules = load_modules(&json)?;
    emit_official_module_cfgs(&modules)?;
    emit_link_directives(&modules);

    let out_dir =
        PathBuf::from(env::var("OUT_DIR").map_err(|_| "OUT_DIR is not available".to_string())?);
    fs::write(
        out_dir.join("pixa_plugin_plan.rs"),
        render_generated_source(&modules),
    )
    .map_err(|error| format!("failed to write generated plugin plan: {error}"))?;
    Ok(())
}

#[derive(Clone, Debug)]
pub(crate) struct ModulePlan {
    pub(crate) module_id: String,
    pub(crate) abi_version: i64,
    pub(crate) deployment: Deployment,
    pub(crate) package_name: Option<String>,
    pub(crate) implementation_language: Option<String>,
    pub(crate) entrypoint_symbol: Option<String>,
    pub(crate) capabilities: Capabilities,
    pub(crate) routes: RouteClaims,
    pub(crate) link: LinkPlan,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Deployment {
    BuiltInHost,
    HostLinkedPlugin,
    Asset,
}

impl Deployment {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "builtInHostModule" => Ok(Self::BuiltInHost),
            "hostLinkedPluginModule" => Ok(Self::HostLinkedPlugin),
            "assetModule" => Ok(Self::Asset),
            _ => Err(format!("unsupported runtime plugin deployment {value:?}")),
        }
    }

    pub(crate) fn rust_variant(self) -> &'static str {
        match self {
            Self::BuiltInHost => "BuiltInHost",
            Self::HostLinkedPlugin => "HostLinkedPlugin",
            Self::Asset => "Asset",
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Capabilities {
    pub(crate) fetcher: bool,
    pub(crate) decoder: bool,
    pub(crate) processor: bool,
    pub(crate) cache_store: bool,
    pub(crate) host_managed_runtime: bool,
    pub(crate) binary_messages: bool,
    pub(crate) owned_buffers: bool,
    pub(crate) stream_handles: bool,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct LinkPlan {
    search_paths: Vec<String>,
    static_libraries: Vec<String>,
    dynamic_libraries: Vec<String>,
    frameworks: Vec<String>,
    link_args: Vec<String>,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct RouteClaims {
    pub(crate) fetcher_source_kinds: Vec<String>,
    pub(crate) video_frame_output_mime_types: Vec<String>,
    pub(crate) decoder_format_ids: Vec<String>,
    pub(crate) decoder_mime_types: Vec<String>,
    pub(crate) decoder_signatures: Vec<DecoderSignaturePlan>,
    pub(crate) processor_operations: Vec<String>,
    pub(crate) cache_store_namespaces: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct DecoderSignaturePlan {
    pub(crate) offset: usize,
    pub(crate) magic: Vec<u8>,
    pub(crate) mime_type: String,
    pub(crate) format_id: Option<String>,
}

fn load_modules(json: &JsonValue) -> Result<Vec<ModulePlan>, String> {
    let root = json
        .as_object()
        .ok_or_else(|| "runtime plugin plan root must be an object".to_string())?;
    expect_i64(root, "schema", ABI_VERSION)?;
    if root.contains_key("abiVersion") {
        expect_i64(root, "abiVersion", ABI_VERSION)?;
    }
    let raw_modules = root
        .get("modules")
        .and_then(JsonValue::as_array)
        .ok_or_else(|| "runtime plugin plan modules must be an array".to_string())?;

    let mut modules = Vec::with_capacity(raw_modules.len());
    for raw_module in raw_modules {
        let object = raw_module
            .as_object()
            .ok_or_else(|| "runtime plugin module must be an object".to_string())?;
        let module = parse_module(object)?;
        validate_module(&module)?;
        modules.push(module);
    }
    modules.sort_by(|left, right| left.module_id.cmp(&right.module_id));
    for pair in modules.windows(2) {
        if pair[0].module_id == pair[1].module_id {
            return Err(format!(
                "duplicate runtime plugin module {}",
                pair[0].module_id
            ));
        }
    }
    validate_unique_route_claims(
        &modules,
        |module| &module.routes.fetcher_source_kinds,
        "fetcher source kind",
    )?;
    validate_unique_route_claims(
        &modules,
        |module| &module.routes.decoder_mime_types,
        "decoder MIME type",
    )?;
    validate_unique_route_claims(
        &modules,
        |module| &module.routes.decoder_format_ids,
        "decoder format id",
    )?;
    validate_unique_decoder_signatures(&modules)?;
    validate_unique_route_claims(
        &modules,
        |module| &module.routes.processor_operations,
        "processor operation",
    )?;
    validate_unique_route_claims(
        &modules,
        |module| &module.routes.cache_store_namespaces,
        "cache store namespace",
    )?;
    Ok(modules)
}

fn parse_module(object: &BTreeMap<String, JsonValue>) -> Result<ModulePlan, String> {
    let capabilities = parse_capabilities(
        string_array_field(object, "capabilities")?,
        bool_field(object, "hostManagedRuntime")?.unwrap_or(true),
        bool_field(object, "binaryMessages")?.unwrap_or(true),
        bool_field(object, "ownedBuffers")?.unwrap_or(true),
        bool_field(object, "streamHandles")?.unwrap_or(true),
    );
    Ok(ModulePlan {
        module_id: string_field(object, "moduleId")?,
        abi_version: i64_field(object, "abiVersion")?.unwrap_or(ABI_VERSION),
        deployment: Deployment::parse(&string_field(object, "deployment")?)?,
        package_name: optional_string_field(object, "packageName")?,
        implementation_language: optional_string_field(object, "implementationLanguage")?,
        entrypoint_symbol: optional_string_field(object, "entrypointSymbol")?,
        capabilities,
        routes: parse_routes(object)?,
        link: parse_link(object)?,
    })
}

fn parse_capabilities(
    values: Vec<String>,
    host_managed_runtime: bool,
    binary_messages: bool,
    owned_buffers: bool,
    stream_handles: bool,
) -> Capabilities {
    let mut capabilities = Capabilities {
        host_managed_runtime,
        binary_messages,
        owned_buffers,
        stream_handles,
        ..Capabilities::default()
    };
    for value in values {
        match value.as_str() {
            "fetcher" => capabilities.fetcher = true,
            "decoder" => capabilities.decoder = true,
            "processor" => capabilities.processor = true,
            "cacheStore" => capabilities.cache_store = true,
            _ => {}
        }
    }
    capabilities
}

fn parse_link(object: &BTreeMap<String, JsonValue>) -> Result<LinkPlan, String> {
    let Some(link) = object.get("link") else {
        return Ok(LinkPlan::default());
    };
    let link = link
        .as_object()
        .ok_or_else(|| "runtime plugin link metadata must be an object".to_string())?;
    Ok(LinkPlan {
        search_paths: optional_string_array_field(link, "searchPaths")?,
        static_libraries: optional_string_array_field(link, "staticLibraries")?,
        dynamic_libraries: optional_string_array_field(link, "dynamicLibraries")?,
        frameworks: optional_string_array_field(link, "frameworks")?,
        link_args: optional_string_array_field(link, "linkArgs")?,
    })
}

fn parse_routes(object: &BTreeMap<String, JsonValue>) -> Result<RouteClaims, String> {
    Ok(RouteClaims {
        fetcher_source_kinds: optional_string_array_field(object, "fetcherSourceKinds")?,
        video_frame_output_mime_types: optional_string_array_field(
            object,
            "videoFrameOutputMimeTypes",
        )?,
        decoder_format_ids: optional_string_array_field(object, "decoderFormatIds")?,
        decoder_mime_types: optional_string_array_field(object, "decoderMimeTypes")?,
        decoder_signatures: optional_decoder_signatures(object)?,
        processor_operations: optional_string_array_field(object, "processorOperations")?,
        cache_store_namespaces: optional_string_array_field(object, "cacheStoreNamespaces")?,
    })
}

fn validate_module(module: &ModulePlan) -> Result<(), String> {
    validate_value(&module.module_id, "moduleId")?;
    if module.abi_version != ABI_VERSION {
        return Err(format!(
            "unsupported runtime plugin ABI version {}",
            module.abi_version
        ));
    }
    if !(module.capabilities.fetcher
        || module.capabilities.decoder
        || module.capabilities.processor
        || module.capabilities.cache_store)
    {
        return Err(format!(
            "runtime plugin module {} exposes no pipeline capability",
            module.module_id
        ));
    }
    if !module.capabilities.host_managed_runtime
        || !module.capabilities.binary_messages
        || !module.capabilities.owned_buffers
        || !module.capabilities.stream_handles
    {
        return Err(format!(
            "runtime plugin module {} must use host runtime, binary messages, owned buffers and stream handles",
            module.module_id
        ));
    }
    if matches!(
        module.deployment,
        Deployment::HostLinkedPlugin | Deployment::Asset
    ) && module
        .entrypoint_symbol
        .as_deref()
        .is_none_or(|symbol| symbol.trim().is_empty())
    {
        return Err(format!(
            "runtime plugin module {} requires an entrypoint symbol",
            module.module_id
        ));
    }
    validate_link_values(&module.link.search_paths, "link.searchPaths")?;
    validate_link_values(&module.link.static_libraries, "link.staticLibraries")?;
    validate_link_values(&module.link.dynamic_libraries, "link.dynamicLibraries")?;
    validate_link_values(&module.link.frameworks, "link.frameworks")?;
    validate_link_values(&module.link.link_args, "link.linkArgs")?;
    validate_route_values(
        module.capabilities.fetcher,
        &module.routes.fetcher_source_kinds,
        "fetcherSourceKinds",
    )?;
    validate_video_frame_route_values(
        module.capabilities.fetcher,
        &module.routes.fetcher_source_kinds,
        &module.routes.video_frame_output_mime_types,
    )?;
    validate_decoder_route_values(
        module.capabilities.decoder,
        &module.routes.decoder_mime_types,
        &module.routes.decoder_format_ids,
        &module.routes.decoder_signatures,
    )?;
    validate_route_values(
        module.capabilities.processor,
        &module.routes.processor_operations,
        "processorOperations",
    )?;
    validate_route_values(
        module.capabilities.cache_store,
        &module.routes.cache_store_namespaces,
        "cacheStoreNamespaces",
    )?;
    Ok(())
}

fn emit_link_directives(modules: &[ModulePlan]) {
    for module in modules {
        if !matches!(
            module.deployment,
            Deployment::BuiltInHost | Deployment::HostLinkedPlugin
        ) {
            continue;
        }
        for path in &module.link.search_paths {
            println!("cargo:rustc-link-search=native={path}");
        }
        for library in &module.link.static_libraries {
            println!("cargo:rustc-link-lib=static={library}");
        }
        for library in &module.link.dynamic_libraries {
            println!("cargo:rustc-link-lib=dylib={library}");
        }
        for framework in &module.link.frameworks {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        for arg in &module.link.link_args {
            println!("cargo:rustc-link-arg={arg}");
        }
    }
}

fn emit_official_module_cfgs(modules: &[ModulePlan]) -> Result<(), String> {
    println!("cargo:rustc-check-cfg=cfg(pixa_jpeg_turbo_processor)");
    println!("cargo:rustc-check-cfg=cfg(pixa_webp_processor)");
    for module in modules {
        match module.entrypoint_symbol.as_deref() {
            Some(JPEG_TURBO_PROCESSOR_ENTRYPOINT) => {
                validate_official_processor_module(module, "JPEG Turbo ROI", "tile:jpeg")?;
                println!("cargo:rustc-cfg=pixa_jpeg_turbo_processor");
                if module.link.dynamic_libraries.is_empty()
                    && module.link.static_libraries.is_empty()
                    && module.link.frameworks.is_empty()
                {
                    require_cargo_feature(&module.module_id, "JPEG Turbo ROI", "jpeg-turbo-roi")?;
                }
            }
            Some(WEBP_PROCESSOR_ENTRYPOINT) => {
                validate_official_processor_module(module, "WebP ROI", "tile:webp")?;
                println!("cargo:rustc-cfg=pixa_webp_processor");
                if module.link.dynamic_libraries.is_empty()
                    && module.link.static_libraries.is_empty()
                    && module.link.frameworks.is_empty()
                {
                    require_cargo_feature(&module.module_id, "WebP ROI", "webp-roi")?;
                }
            }
            _ => {}
        }
    }
    Ok(())
}

fn require_cargo_feature(module_id: &str, label: &str, feature: &str) -> Result<(), String> {
    let env_name = format!(
        "CARGO_FEATURE_{}",
        feature.replace('-', "_").to_ascii_uppercase()
    );
    if env::var_os(&env_name).is_some() {
        Ok(())
    } else {
        Err(format!(
            "official {label} module {module_id} requires Cargo feature {feature} \
             when no explicit link metadata is provided"
        ))
    }
}

fn validate_official_processor_module(
    module: &ModulePlan,
    label: &str,
    operation: &str,
) -> Result<(), String> {
    if !module.capabilities.processor {
        return Err(format!(
            "official {label} module {} must declare processor capability",
            module.module_id
        ));
    }
    if !module
        .routes
        .processor_operations
        .iter()
        .any(|value| value.eq_ignore_ascii_case(operation))
    {
        return Err(format!(
            "official {label} module {} must claim processor operation {operation}",
            module.module_id
        ));
    }
    Ok(())
}

fn expect_i64(
    object: &BTreeMap<String, JsonValue>,
    field: &str,
    expected: i64,
) -> Result<(), String> {
    let value = i64_field(object, field)?
        .ok_or_else(|| format!("runtime plugin plan field {field} is missing"))?;
    if value != expected {
        return Err(format!(
            "runtime plugin plan field {field} must be {expected}, got {value}"
        ));
    }
    Ok(())
}

fn string_field(object: &BTreeMap<String, JsonValue>, field: &str) -> Result<String, String> {
    let value = optional_string_field(object, field)?
        .ok_or_else(|| format!("runtime plugin field {field} is missing"))?;
    validate_value(&value, field)?;
    Ok(value)
}

fn optional_string_field(
    object: &BTreeMap<String, JsonValue>,
    field: &str,
) -> Result<Option<String>, String> {
    match object.get(field) {
        Some(JsonValue::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(format!("runtime plugin field {field} must be a string")),
        None => Ok(None),
    }
}

fn i64_field(object: &BTreeMap<String, JsonValue>, field: &str) -> Result<Option<i64>, String> {
    match object.get(field) {
        Some(JsonValue::Number(value)) => Ok(Some(*value)),
        Some(_) => Err(format!("runtime plugin field {field} must be an integer")),
        None => Ok(None),
    }
}

fn bool_field(object: &BTreeMap<String, JsonValue>, field: &str) -> Result<Option<bool>, String> {
    match object.get(field) {
        Some(JsonValue::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(format!("runtime plugin field {field} must be a boolean")),
        None => Ok(None),
    }
}

fn string_array_field(
    object: &BTreeMap<String, JsonValue>,
    field: &str,
) -> Result<Vec<String>, String> {
    object
        .get(field)
        .ok_or_else(|| format!("runtime plugin field {field} is missing"))
        .and_then(|value| string_array(value, field))
}

fn optional_string_array_field(
    object: &BTreeMap<String, JsonValue>,
    field: &str,
) -> Result<Vec<String>, String> {
    match object.get(field) {
        Some(value) => string_array(value, field),
        None => Ok(Vec::new()),
    }
}

fn optional_decoder_signatures(
    object: &BTreeMap<String, JsonValue>,
) -> Result<Vec<DecoderSignaturePlan>, String> {
    let Some(value) = object.get("decoderSignatures") else {
        return Ok(Vec::new());
    };
    let array = value
        .as_array()
        .ok_or_else(|| "runtime plugin field decoderSignatures must be an array".to_string())?;
    let mut signatures = Vec::with_capacity(array.len());
    for item in array {
        let object = item
            .as_object()
            .ok_or_else(|| "runtime plugin decoder signature must be an object".to_string())?;
        signatures.push(parse_decoder_signature(object)?);
    }
    signatures.sort_by_key(decoder_signature_key);
    Ok(signatures)
}

fn parse_decoder_signature(
    object: &BTreeMap<String, JsonValue>,
) -> Result<DecoderSignaturePlan, String> {
    let offset = i64_field(object, "offset")?
        .ok_or_else(|| "runtime plugin decoder signature offset is missing".to_string())?;
    if offset < 0 {
        return Err("runtime plugin decoder signature offset must be non-negative".to_string());
    }
    let magic = parse_hex_bytes(&string_field(object, "magicHex")?)?;
    if magic.len() > 64 {
        return Err("runtime plugin decoder signature must be at most 64 bytes".to_string());
    }
    let offset = usize::try_from(offset)
        .map_err(|_| "runtime plugin decoder signature offset overflows".to_string())?;
    if offset.saturating_add(magic.len()) > 4096 {
        return Err(
            "runtime plugin decoder signature must fit in the first 4096 header bytes".to_string(),
        );
    }
    let mime_type = string_field(object, "mimeType")?
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    validate_value(&mime_type, "decoderSignatures.mimeType")?;
    let format_id = optional_string_field(object, "formatId")?
        .map(|value| value.trim().to_ascii_lowercase())
        .map(|value| {
            if value.is_empty() {
                Err("runtime plugin decoder signature formatId must not be empty".to_string())
            } else {
                Ok(value)
            }
        })
        .transpose()?;
    Ok(DecoderSignaturePlan {
        offset,
        magic,
        mime_type,
        format_id,
    })
}

fn parse_hex_bytes(value: &str) -> Result<Vec<u8>, String> {
    let normalized: String = value
        .chars()
        .filter(|character| !character.is_ascii_whitespace())
        .map(|character| character.to_ascii_lowercase())
        .collect();
    if normalized.is_empty() || !normalized.len().is_multiple_of(2) {
        return Err(
            "runtime plugin decoder signature magicHex must contain full bytes".to_string(),
        );
    }
    let mut bytes = Vec::with_capacity(normalized.len() / 2);
    for index in (0..normalized.len()).step_by(2) {
        let byte = u8::from_str_radix(&normalized[index..index + 2], 16)
            .map_err(|_| "runtime plugin decoder signature magicHex must be hex".to_string())?;
        bytes.push(byte);
    }
    Ok(bytes)
}

fn string_array(value: &JsonValue, field: &str) -> Result<Vec<String>, String> {
    let array = value
        .as_array()
        .ok_or_else(|| format!("runtime plugin field {field} must be a string array"))?;
    let mut output = Vec::with_capacity(array.len());
    for item in array {
        let JsonValue::String(value) = item else {
            return Err(format!(
                "runtime plugin field {field} contains a non-string value"
            ));
        };
        validate_value(value, field)?;
        output.push(value.clone());
    }
    Ok(output)
}

fn validate_value(value: &str, field: &str) -> Result<(), String> {
    if value.trim().is_empty()
        || value.contains('\n')
        || value.contains('\r')
        || value.contains('\0')
    {
        return Err(format!(
            "runtime plugin field {field} contains an invalid value"
        ));
    }
    Ok(())
}

fn validate_link_values(values: &[String], field: &str) -> Result<(), String> {
    for value in values {
        validate_value(value, field)?;
    }
    Ok(())
}

fn validate_route_values(
    capability_enabled: bool,
    claims: &[String],
    field: &str,
) -> Result<(), String> {
    if !capability_enabled && !claims.is_empty() {
        return Err(format!(
            "runtime plugin route field {field} requires matching capability"
        ));
    }
    validate_link_values(claims, field)
}

fn validate_video_frame_route_values(
    fetcher_enabled: bool,
    source_kinds: &[String],
    output_mime_types: &[String],
) -> Result<(), String> {
    let claims_video_frame = source_kinds
        .iter()
        .any(|value| is_video_frame_source_kind(value));
    if !output_mime_types.is_empty() && (!fetcher_enabled || !claims_video_frame) {
        return Err(
            "runtime plugin video-frame output MIME contract requires a video-frame fetcher route"
                .to_string(),
        );
    }
    if claims_video_frame && output_mime_types.is_empty() {
        return Err(
            "runtime plugin video-frame fetcher routes require videoFrameOutputMimeTypes"
                .to_string(),
        );
    }
    validate_link_values(output_mime_types, "videoFrameOutputMimeTypes")?;
    for mime_type in output_mime_types {
        let normalized = normalize_mime_type(mime_type);
        if !SUPPORTED_VIDEO_FRAME_OUTPUT_MIME_TYPES.contains(&normalized.as_str()) {
            return Err(format!(
                "runtime plugin video-frame output MIME {mime_type:?} is not in the supported display format matrix"
            ));
        }
    }
    Ok(())
}

fn is_video_frame_source_kind(source_kind: &str) -> bool {
    let normalized = source_kind.trim().to_ascii_lowercase();
    normalized == "video-frame" || normalized.starts_with("video-frame:")
}

fn normalize_mime_type(mime_type: &str) -> String {
    mime_type
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase()
}

fn validate_decoder_route_values(
    capability_enabled: bool,
    mime_types: &[String],
    format_ids: &[String],
    signatures: &[DecoderSignaturePlan],
) -> Result<(), String> {
    if !capability_enabled
        && (!mime_types.is_empty() || !format_ids.is_empty() || !signatures.is_empty())
    {
        return Err("runtime plugin decoder routes require decoder capability".to_string());
    }
    if capability_enabled && mime_types.is_empty() && format_ids.is_empty() && signatures.is_empty()
    {
        return Err(
            "runtime plugin decoder routes must declare MIME types, format ids or signatures"
                .to_string(),
        );
    }
    validate_link_values(mime_types, "decoderMimeTypes")?;
    validate_link_values(format_ids, "decoderFormatIds")?;
    for signature in signatures {
        validate_value(&signature.mime_type, "decoderSignatures.mimeType")?;
        if let Some(format_id) = &signature.format_id {
            validate_value(format_id, "decoderSignatures.formatId")?;
        }
    }
    Ok(())
}

fn validate_unique_route_claims(
    modules: &[ModulePlan],
    claims_for: impl Fn(&ModulePlan) -> &[String],
    label: &str,
) -> Result<(), String> {
    let mut owners = BTreeMap::<String, &str>::new();
    for module in modules {
        for claim in claims_for(module) {
            let normalized = claim.trim().to_ascii_lowercase();
            if let Some(existing) = owners.insert(normalized, module.module_id.as_str()) {
                return Err(format!(
                    "duplicate runtime plugin {label} {claim:?} from {existing} and {}",
                    module.module_id
                ));
            }
        }
    }
    Ok(())
}

fn validate_unique_decoder_signatures(modules: &[ModulePlan]) -> Result<(), String> {
    let mut owners = BTreeMap::<String, &str>::new();
    for module in modules {
        for signature in &module.routes.decoder_signatures {
            let key = decoder_signature_key(signature);
            if let Some(existing) = owners.insert(key.clone(), module.module_id.as_str()) {
                return Err(format!(
                    "duplicate runtime plugin decoder signature {key:?} from {existing} and {}",
                    module.module_id
                ));
            }
        }
    }
    Ok(())
}

fn decoder_signature_key(signature: &DecoderSignaturePlan) -> String {
    let mut key = format!("{}:", signature.offset);
    for byte in &signature.magic {
        key.push_str(&format!("{byte:02x}"));
    }
    key
}
