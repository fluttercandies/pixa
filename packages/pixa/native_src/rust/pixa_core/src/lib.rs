//! Runtime primitives shared by Pixa platform bindings.

use sha2::{Digest, Sha256};

pub mod analysis;
pub mod cache;
pub mod cancel;
pub mod error;
pub mod image_format;
pub mod metadata;
pub mod pipeline;
pub mod plugin_host;
pub mod progress;
pub mod request;

mod http_transport;
mod s3_fetcher;

pub use analysis::{image_analysis, ImageAnalysis};
pub use error::{RuntimeError, RuntimeResult};
pub use image_format::{
    runtime_image_format_capabilities, RuntimeImageFormat, RuntimeImageFormatCapability,
    RuntimeImageFormatCapabilityFlags,
};
pub use metadata::{
    image_metadata, jpeg_exif_orientation, jpeg_exif_thumbnail, jpeg_exif_thumbnail_from_reader,
    ImageMetadata, ImageMetadataFormat,
};
pub use pipeline::{
    cache_stats, configure, decode_image_to_png_variant, decode_image_to_rgba,
    disk_trim_to_configured_budget, load_image, load_image_with_cancel,
    load_image_with_cancel_and_progress, memory_clear, memory_clear_namespace, memory_contains,
    memory_get_processed, memory_pin, memory_put_processed, memory_remove, memory_trim_to_bytes,
    memory_unpin, LoadOutcome, RuntimeCacheStats, RuntimePipelineConfig, RuntimeRgbaImage,
};
pub use plugin_host::{
    plugin_modules, plugin_registry_stats, register_plugin_module,
    register_plugin_module_with_executor, runtime_cache_store_clear_namespace,
    runtime_cache_store_executor_for_namespace, runtime_cache_store_for_namespace,
    runtime_cache_store_read, runtime_cache_store_remove, runtime_cache_store_write,
    runtime_decoder_executor_for_format_id, runtime_decoder_executor_for_mime_type,
    runtime_decoder_executor_for_signature, runtime_decoder_for_format_id,
    runtime_decoder_for_mime_type, runtime_decoder_for_signature,
    runtime_fetcher_executor_for_source_kind, runtime_fetcher_for_source_kind, runtime_process,
    runtime_processor_executor_for_operation, runtime_processor_for_operation,
    validate_plugin_module, RuntimePluginCacheClearNamespaceRequest, RuntimePluginCacheReadRequest,
    RuntimePluginCacheReadResult, RuntimePluginCacheRemoveRequest, RuntimePluginCacheWriteRequest,
    RuntimePluginCapabilities, RuntimePluginDecodeRequest, RuntimePluginDecoderSignature,
    RuntimePluginDeployment, RuntimePluginExecutor, RuntimePluginExecutorRef,
    RuntimePluginFetchContext, RuntimePluginFetchRequest, RuntimePluginModule, RuntimePluginOutput,
    RuntimePluginProcessRequest, RuntimePluginRegistryStats, RuntimePluginRoutes,
    RuntimePluginVideoFrameSpec, PIXA_PLUGIN_ABI_VERSION,
};
pub use progress::{RuntimeProgressEvent, RuntimeProgressSink, RuntimeProgressStage};
pub use request::{CacheMode, RuntimeRequest, RuntimeSource};
pub use s3_fetcher::{S3RuntimePluginExecutor, S3_FETCHER_MODULE_ID};

/// Returns a stable FNV-1a 64-bit checksum retained for compatibility.
pub fn fnv1a64(input: &[u8]) -> u64 {
    fnv1a64_continue(0xcbf29ce484222325, input)
}

/// Returns a prefixed FNV-1a checksum without allocating.
pub fn fnv1a64_with_prefix(prefix: &[u8], input: &[u8]) -> u64 {
    const OFFSET: u64 = 0xcbf29ce484222325;

    let prefixed = fnv1a64_continue(OFFSET, prefix);
    fnv1a64_continue(prefixed, input)
}

fn fnv1a64_continue(hash: u64, input: &[u8]) -> u64 {
    const PRIME: u64 = 0x100000001b3;

    input.iter().fold(hash, |hash, byte| {
        let mixed = hash ^ u64::from(*byte);
        mixed.wrapping_mul(PRIME)
    })
}

/// Returns the first 128 bits of SHA-256 as two big-endian lanes.
pub fn sha256_hash_pair(input: &[u8]) -> (u64, u64) {
    let digest = Sha256::digest(input);
    let mut primary = [0_u8; 8];
    let mut secondary = [0_u8; 8];
    primary.copy_from_slice(&digest[..8]);
    secondary.copy_from_slice(&digest[8..16]);
    (u64::from_be_bytes(primary), u64::from_be_bytes(secondary))
}

/// Runtime platform capability snapshot.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeCapabilities {
    pub disk_cache: bool,
    pub http_transport: bool,
    pub exif_parser: bool,
    pub pixel_processors: bool,
}

impl RuntimeCapabilities {
    /// Conservative capabilities that are valid before platform probing.
    pub const fn conservative() -> Self {
        Self {
            disk_cache: true,
            http_transport: true,
            exif_parser: true,
            pixel_processors: true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv_hash_is_stable() {
        assert_eq!(fnv1a64(b"pixa"), 0xbef3f60dc4ff7eed);
        assert_eq!(
            fnv1a64_with_prefix(b"material:", b"pixa"),
            0x668135a3077b3346
        );
    }

    #[test]
    fn fnv_prefix_hash_matches_concatenated_material_for_varied_inputs() {
        let mut seed = 0x517c_c1b7_2722_0a95_u64;
        for length in 0..128 {
            let input = pseudo_random_bytes(&mut seed, length);
            let mut concatenated = b"material:".to_vec();
            concatenated.extend_from_slice(&input);

            assert_eq!(
                fnv1a64_with_prefix(b"material:", &input),
                fnv1a64(&concatenated)
            );
        }
    }

    #[test]
    fn sha256_hash_pair_uses_the_first_128_digest_bits() {
        assert_eq!(
            sha256_hash_pair(b"pixa"),
            (0x164fb963c3f92416, 0xbf647e7f0875c5ab)
        );
    }

    #[test]
    fn image_analysis_reports_average_dominant_and_palette() {
        use image::ImageEncoder;

        let mut png = Vec::new();
        image::codecs::png::PngEncoder::new(&mut png)
            .write_image(
                &[255, 0, 0, 255, 0, 0, 255, 255],
                2,
                1,
                image::ExtendedColorType::Rgba8,
            )
            .expect("fixture PNG should encode");

        let analysis = image_analysis(&png, 8).expect("analysis should decode");

        assert_eq!((analysis.width, analysis.height), (2, 1));
        assert_eq!(analysis.average_argb, 0xff7f007f);
        assert_eq!(analysis.dominant_argb, 0xffff0000);
        assert!(analysis.palette_argb.contains(&0xffff0000));
        assert!(analysis.palette_argb.contains(&0xff0000ff));
    }

    fn pseudo_random_bytes(seed: &mut u64, length: usize) -> Vec<u8> {
        (0..length)
            .map(|_| {
                *seed ^= *seed << 13;
                *seed ^= *seed >> 7;
                *seed ^= *seed << 17;
                (*seed & 0xff) as u8
            })
            .collect()
    }
}
