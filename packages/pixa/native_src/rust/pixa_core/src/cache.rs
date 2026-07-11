use crate::{fnv1a64, RuntimeError, RuntimeResult};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};
use std::fmt::Write as FmtWrite;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

type DiskEntryLocks = HashMap<String, std::sync::Weak<Mutex<()>>>;
pub type SharedBytes = Arc<[u8]>;

static DISK_MAINTENANCE_LOCK: OnceLock<RwLock<()>> = OnceLock::new();
static DISK_ENTRY_LOCKS: OnceLock<Mutex<DiskEntryLocks>> = OnceLock::new();
static DISK_ACCESS_TIMES: OnceLock<Mutex<HashMap<String, i64>>> = OnceLock::new();

/// Byte-limited encoded memory LRU owned by Rust.
#[derive(Debug)]
pub struct MemoryCache {
    max_bytes: usize,
    current_bytes: usize,
    processed_entries: usize,
    processed_bytes: usize,
    entries: HashMap<String, MemoryEntry>,
    order: VecDeque<String>,
    hits: u64,
    misses: u64,
    evictions: u64,
    processed_hits: u64,
    processed_misses: u64,
    processed_evictions: u64,
}

impl MemoryCache {
    /// Creates a memory cache.
    pub fn new(max_bytes: usize) -> Self {
        Self {
            max_bytes,
            current_bytes: 0,
            processed_entries: 0,
            processed_bytes: 0,
            entries: HashMap::new(),
            order: VecDeque::new(),
            hits: 0,
            misses: 0,
            evictions: 0,
            processed_hits: 0,
            processed_misses: 0,
            processed_evictions: 0,
        }
    }

    /// Reads one entry and updates recency.
    pub fn get(&mut self, key: &str) -> Option<SharedBytes> {
        self.get_entry_with_kind(key, MemoryEntryKind::Encoded)
            .map(|entry| entry.bytes)
    }

    /// Reads one processed variant entry and updates recency.
    pub fn get_processed(&mut self, key: &str) -> Option<SharedBytes> {
        self.get_entry_with_kind(key, MemoryEntryKind::Processed)
            .map(|entry| entry.bytes)
    }

    pub(crate) fn get_entry(&mut self, key: &str) -> Option<MemoryCacheValue> {
        self.get_entry_with_kind(key, MemoryEntryKind::Encoded)
    }

    pub(crate) fn get_processed_entry(&mut self, key: &str) -> Option<MemoryCacheValue> {
        self.get_entry_with_kind(key, MemoryEntryKind::Processed)
    }

    fn get_entry_with_kind(
        &mut self,
        key: &str,
        requested_kind: MemoryEntryKind,
    ) -> Option<MemoryCacheValue> {
        match self.entries.get(key) {
            Some(entry) if entry.is_expired() => {
                self.remove_entry(key, true);
                self.record_miss(requested_kind);
                None
            }
            Some(entry) if entry.kind == requested_kind => {
                let value = MemoryCacheValue {
                    bytes: entry.bytes.clone(),
                    http: entry.http.clone(),
                    expires_ms: entry.expires_ms,
                };
                self.record_hit(requested_kind);
                self.touch(key);
                Some(value)
            }
            Some(_) | None => {
                self.record_miss(requested_kind);
                None
            }
        }
    }

    /// Writes one entry.
    pub fn put(&mut self, namespace: &str, key: String, bytes: SharedBytes, ttl_ms: Option<i64>) {
        self.put_with_kind(
            namespace,
            key,
            bytes,
            ttl_ms,
            MemoryEntryKind::Encoded,
            None,
        );
    }

    pub(crate) fn put_with_http_metadata(
        &mut self,
        namespace: &str,
        key: String,
        bytes: SharedBytes,
        ttl_ms: Option<i64>,
        http: Option<DiskCacheHttpMetadata>,
    ) {
        self.put_with_kind(
            namespace,
            key,
            bytes,
            ttl_ms,
            MemoryEntryKind::Encoded,
            http,
        );
    }

    /// Writes one processed variant entry.
    pub fn put_processed(
        &mut self,
        namespace: &str,
        key: String,
        bytes: SharedBytes,
        ttl_ms: Option<i64>,
    ) {
        self.put_with_kind(
            namespace,
            key,
            bytes,
            ttl_ms,
            MemoryEntryKind::Processed,
            None,
        );
    }

    pub(crate) fn put_processed_with_http_metadata(
        &mut self,
        namespace: &str,
        key: String,
        bytes: SharedBytes,
        ttl_ms: Option<i64>,
        http: Option<DiskCacheHttpMetadata>,
    ) {
        self.put_with_kind(
            namespace,
            key,
            bytes,
            ttl_ms,
            MemoryEntryKind::Processed,
            http,
        );
    }

    fn put_with_kind(
        &mut self,
        namespace: &str,
        key: String,
        bytes: SharedBytes,
        ttl_ms: Option<i64>,
        kind: MemoryEntryKind,
        http: Option<DiskCacheHttpMetadata>,
    ) {
        if bytes.len() > self.max_bytes {
            return;
        }
        self.remove_entry(&key, false);
        self.current_bytes += bytes.len();
        if kind == MemoryEntryKind::Processed {
            self.processed_entries += 1;
            self.processed_bytes += bytes.len();
        }
        self.order.push_back(key.clone());
        self.entries.insert(
            key,
            MemoryEntry {
                namespace: namespace.to_string(),
                bytes,
                expires_ms: ttl_ms.map(|ttl| now_millis().saturating_add(ttl)),
                pins: 0,
                kind,
                http,
            },
        );
        self.trim();
    }

    /// Pins an existing entry so memory-pressure trim keeps it resident.
    pub fn pin(&mut self, key: &str) -> bool {
        let Some(entry) = self.entries.get_mut(key) else {
            return false;
        };
        if entry.is_expired() {
            self.remove_entry(key, true);
            return false;
        }
        entry.pins = entry.pins.saturating_add(1);
        true
    }

    /// Releases one active pin for an entry.
    pub fn unpin(&mut self, key: &str) -> bool {
        let Some(entry) = self.entries.get_mut(key) else {
            return false;
        };
        if entry.pins == 0 {
            return false;
        }
        entry.pins -= 1;
        self.trim();
        true
    }

    /// Returns whether a fresh entry exists without cloning its bytes.
    pub fn contains(&mut self, key: &str) -> bool {
        if self.entries.get(key).is_some_and(MemoryEntry::is_expired) {
            self.remove_entry(key, true);
            return false;
        }
        self.entries.contains_key(key)
    }

    /// Removes one entry.
    pub fn remove(&mut self, key: &str) -> bool {
        self.remove_entry(key, true)
    }

    /// Clears all entries.
    pub fn clear(&mut self) {
        let processed_entries = self
            .entries
            .values()
            .filter(|entry| entry.kind == MemoryEntryKind::Processed)
            .count();
        self.evictions += self.entries.len() as u64;
        self.processed_evictions += processed_entries as u64;
        self.entries.clear();
        self.order.clear();
        self.current_bytes = 0;
        self.processed_entries = 0;
        self.processed_bytes = 0;
    }

    /// Clears all entries for one namespace.
    pub fn clear_namespace(&mut self, namespace: &str) -> usize {
        let keys: Vec<String> = self
            .entries
            .iter()
            .filter_map(|(key, entry)| (entry.namespace == namespace).then_some(key.clone()))
            .collect();
        let removed = keys.len();
        for key in keys {
            self.remove_entry(&key, true);
        }
        removed
    }

    /// Updates the byte budget and trims if necessary.
    pub fn set_max_bytes(&mut self, max_bytes: usize) {
        self.max_bytes = max_bytes;
        self.trim();
    }

    /// Trims entries until the cache is no larger than `target_bytes`.
    pub fn trim_to_bytes(&mut self, target_bytes: usize) {
        let previous_max = self.max_bytes;
        self.max_bytes = target_bytes.min(previous_max);
        self.trim();
        self.max_bytes = previous_max;
    }

    /// Returns a stats snapshot.
    pub fn stats(&self) -> MemoryCacheStats {
        MemoryCacheStats {
            entries: self.entries.len(),
            bytes: self.current_bytes,
            processed_entries: self.processed_entries,
            processed_bytes: self.processed_bytes,
            hits: self.hits,
            misses: self.misses,
            evictions: self.evictions,
            processed_hits: self.processed_hits,
            processed_misses: self.processed_misses,
            processed_evictions: self.processed_evictions,
        }
    }

    fn remove_entry(&mut self, key: &str, count_eviction: bool) -> bool {
        if let Some(entry) = self.entries.remove(key) {
            self.current_bytes = self.current_bytes.saturating_sub(entry.bytes.len());
            if entry.kind == MemoryEntryKind::Processed {
                self.processed_entries = self.processed_entries.saturating_sub(1);
                self.processed_bytes = self.processed_bytes.saturating_sub(entry.bytes.len());
            }
            self.order.retain(|candidate| candidate != key);
            if count_eviction {
                self.evictions += 1;
                if entry.kind == MemoryEntryKind::Processed {
                    self.processed_evictions += 1;
                }
            }
            return true;
        }
        false
    }

    fn record_hit(&mut self, kind: MemoryEntryKind) {
        self.hits += 1;
        if kind == MemoryEntryKind::Processed {
            self.processed_hits += 1;
        }
    }

    fn record_miss(&mut self, kind: MemoryEntryKind) {
        self.misses += 1;
        if kind == MemoryEntryKind::Processed {
            self.processed_misses += 1;
        }
    }

    fn touch(&mut self, key: &str) {
        self.order.retain(|candidate| candidate != key);
        self.order.push_back(key.to_string());
    }

    fn trim(&mut self) {
        let mut pinned_skips = 0usize;
        while self.current_bytes > self.max_bytes && !self.order.is_empty() {
            let Some(key) = self.order.pop_front() else {
                return;
            };
            let Some(entry) = self.entries.get(&key) else {
                pinned_skips = 0;
                continue;
            };
            if entry.pins > 0 {
                self.order.push_back(key);
                pinned_skips += 1;
                if pinned_skips >= self.order.len() {
                    return;
                }
                continue;
            }
            if let Some(entry) = self.entries.remove(&key) {
                self.current_bytes = self.current_bytes.saturating_sub(entry.bytes.len());
                if entry.kind == MemoryEntryKind::Processed {
                    self.processed_entries = self.processed_entries.saturating_sub(1);
                    self.processed_bytes = self.processed_bytes.saturating_sub(entry.bytes.len());
                }
                self.evictions += 1;
                if entry.kind == MemoryEntryKind::Processed {
                    self.processed_evictions += 1;
                }
                pinned_skips = 0;
            }
        }
    }
}

/// Encoded memory cache stats.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MemoryCacheStats {
    pub entries: usize,
    pub bytes: usize,
    pub processed_entries: usize,
    pub processed_bytes: usize,
    pub hits: u64,
    pub misses: u64,
    pub evictions: u64,
    pub processed_hits: u64,
    pub processed_misses: u64,
    pub processed_evictions: u64,
}

#[derive(Debug)]
struct MemoryEntry {
    namespace: String,
    bytes: SharedBytes,
    expires_ms: Option<i64>,
    pins: usize,
    kind: MemoryEntryKind,
    http: Option<DiskCacheHttpMetadata>,
}

#[derive(Clone, Debug)]
pub(crate) struct MemoryCacheValue {
    pub(crate) bytes: SharedBytes,
    pub(crate) http: Option<DiskCacheHttpMetadata>,
    pub(crate) expires_ms: Option<i64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MemoryEntryKind {
    Encoded,
    Processed,
}

impl MemoryEntry {
    fn is_expired(&self) -> bool {
        self.expires_ms
            .is_some_and(|expires| expires >= 0 && expires <= now_millis())
    }
}

/// Rust-backed encoded disk cache.
#[derive(Clone, Debug)]
pub struct DiskCache {
    root: PathBuf,
}

/// HTTP metadata persisted with an encoded disk cache entry.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct DiskCacheHttpMetadata {
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    pub cache_control: Option<String>,
    pub date: Option<String>,
    pub expires: Option<String>,
    pub age: Option<String>,
    pub vary: Option<String>,
    pub vary_request_key: Option<String>,
    pub fetched_at_ms: Option<i64>,
}

/// Encoded disk cache entry plus parsed metadata.
#[derive(Clone, Debug)]
pub struct DiskCacheEntry {
    pub bytes: Vec<u8>,
    pub expires_ms: i64,
    pub is_expired: bool,
    pub http: Box<DiskCacheHttpMetadata>,
}

/// Result of a disk cache lookup.
#[derive(Clone, Debug)]
pub enum DiskCacheRead {
    Hit(DiskCacheEntry),
    Miss,
    RecoveredCorruption,
}

impl DiskCache {
    /// Creates a disk cache under the platform cache root.
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// Reads one cache entry.
    pub fn read(&self, namespace: &str, key: &str) -> RuntimeResult<Option<Vec<u8>>> {
        match self.read_entry(namespace, key)? {
            DiskCacheRead::Hit(entry) => {
                if entry.is_expired {
                    self.remove(namespace, key)?;
                    return Ok(None);
                }
                Ok(Some(entry.bytes))
            }
            DiskCacheRead::Miss | DiskCacheRead::RecoveredCorruption => Ok(None),
        }
    }

    /// Reads one cache entry even when stale, preserving parsed metadata.
    pub fn read_entry(&self, namespace: &str, key: &str) -> RuntimeResult<DiskCacheRead> {
        self.read_entry_with_limit(namespace, key, None)
    }

    pub(crate) fn read_entry_limited(
        &self,
        namespace: &str,
        key: &str,
        max_bytes: usize,
        stage: &'static str,
        message: &'static str,
    ) -> RuntimeResult<DiskCacheRead> {
        self.read_entry_with_limit(
            namespace,
            key,
            Some(DiskCacheReadLimit {
                max_bytes,
                stage,
                message,
            }),
        )
    }

    fn read_entry_with_limit(
        &self,
        namespace: &str,
        key: &str,
        limit: Option<DiskCacheReadLimit>,
    ) -> RuntimeResult<DiskCacheRead> {
        let paths = self.entry_paths(namespace, key)?;
        let _maintenance_guard = disk_maintenance_read()?;
        let entry_lock = disk_entry_lock(namespace, key)?;
        let _entry_guard = entry_lock
            .lock()
            .map_err(|_| RuntimeError::new("disk_cache", true, "disk entry lock poisoned"))?;
        if !paths.data.exists() || !paths.meta.exists() {
            return Ok(DiskCacheRead::Miss);
        }

        let Some(metadata) = self.read_metadata(&paths.meta)? else {
            remove_entry_paths(&paths)?;
            return Ok(DiskCacheRead::RecoveredCorruption);
        };
        let Some(required) = parse_required_disk_metadata(&metadata) else {
            remove_entry_paths(&paths)?;
            return Ok(DiskCacheRead::RecoveredCorruption);
        };
        if let Some(limit) = limit {
            if required.length > limit.max_bytes {
                return Err(RuntimeError::new(limit.stage, false, limit.message));
            }
        }
        let actual_length = fs::metadata(&paths.data)
            .map_err(|error| {
                RuntimeError::new(
                    "disk_cache",
                    true,
                    format!("failed to stat disk cache: {error}"),
                )
            })?
            .len();
        if usize::try_from(actual_length).ok() != Some(required.length) {
            remove_entry_paths(&paths)?;
            return Ok(DiskCacheRead::RecoveredCorruption);
        }
        let bytes = read_cache_data(&paths.data, limit)?;
        if bytes.len() != required.length || fnv1a64(&bytes) != required.checksum {
            remove_entry_paths(&paths)?;
            return Ok(DiskCacheRead::RecoveredCorruption);
        }
        if required.expires_ms < 0 || required.expires_ms > now_millis() {
            record_disk_access(namespace, key)?;
        }
        Ok(DiskCacheRead::Hit(DiskCacheEntry {
            bytes,
            expires_ms: required.expires_ms,
            is_expired: required.expires_ms >= 0 && required.expires_ms <= now_millis(),
            http: Box::new(parse_http_metadata(&metadata)),
        }))
    }

    /// Returns whether an entry can be used without reading encoded bytes.
    pub fn contains(&self, namespace: &str, key: &str, allow_stale: bool) -> RuntimeResult<bool> {
        let paths = self.entry_paths(namespace, key)?;
        let _maintenance_guard = disk_maintenance_read()?;
        let entry_lock = disk_entry_lock(namespace, key)?;
        let _entry_guard = entry_lock
            .lock()
            .map_err(|_| RuntimeError::new("disk_cache", true, "disk entry lock poisoned"))?;
        if !paths.data.exists() || !paths.meta.exists() {
            return Ok(false);
        }

        let Some(metadata) = self.read_metadata(&paths.meta)? else {
            remove_entry_paths(&paths)?;
            return Ok(false);
        };
        let Some(required) = parse_required_disk_metadata(&metadata) else {
            remove_entry_paths(&paths)?;
            return Ok(false);
        };
        let actual_length = fs::metadata(&paths.data)
            .ok()
            .map(|metadata| metadata.len());
        if actual_length.and_then(|length| usize::try_from(length).ok()) != Some(required.length) {
            remove_entry_paths(&paths)?;
            return Ok(false);
        }

        let is_expired = required.expires_ms >= 0 && required.expires_ms <= now_millis();
        if is_expired && !allow_stale {
            return Ok(false);
        }
        record_disk_access(namespace, key)?;
        Ok(true)
    }

    /// Writes one cache entry atomically.
    pub fn write(
        &self,
        namespace: &str,
        key: &str,
        bytes: &[u8],
        ttl_ms: Option<i64>,
    ) -> RuntimeResult<()> {
        self.write_with_http_metadata(namespace, key, bytes, ttl_ms, None)
    }

    /// Writes one cache entry atomically with HTTP metadata.
    pub fn write_with_http_metadata(
        &self,
        namespace: &str,
        key: &str,
        bytes: &[u8],
        ttl_ms: Option<i64>,
        http: Option<&DiskCacheHttpMetadata>,
    ) -> RuntimeResult<()> {
        let paths = self.entry_paths(namespace, key)?;
        let _maintenance_guard = disk_maintenance_read()?;
        let entry_lock = disk_entry_lock(namespace, key)?;
        let _entry_guard = entry_lock
            .lock()
            .map_err(|_| RuntimeError::new("disk_cache", true, "disk entry lock poisoned"))?;
        let now = now_millis();
        let expires = ttl_ms.map_or(-1, |ttl| now.saturating_add(ttl));
        let checksum = fnv1a64(bytes);
        let mut metadata = format!(
            "version=1\ncreated_ms={now}\nlast_access_ms={now}\nexpires_ms={expires}\nlength={}\nchecksum={checksum:016x}\n",
            bytes.len()
        );
        if let Some(http) = http {
            append_metadata_line(&mut metadata, "http_etag", http.etag.as_deref());
            append_metadata_line(
                &mut metadata,
                "http_last_modified",
                http.last_modified.as_deref(),
            );
            append_metadata_line(
                &mut metadata,
                "http_cache_control",
                http.cache_control.as_deref(),
            );
            append_metadata_line(&mut metadata, "http_date", http.date.as_deref());
            append_metadata_line(&mut metadata, "http_expires", http.expires.as_deref());
            append_metadata_line(&mut metadata, "http_age", http.age.as_deref());
            append_metadata_line(&mut metadata, "http_vary", http.vary.as_deref());
            append_metadata_line(
                &mut metadata,
                "http_vary_request_key",
                http.vary_request_key.as_deref(),
            );
            if let Some(fetched_at_ms) = http.fetched_at_ms {
                metadata.push_str(&format!("http_fetched_at_ms={fetched_at_ms}\n"));
            }
        }
        atomic_write(&paths.data, bytes)?;
        atomic_write(&paths.meta, metadata.as_bytes())?;
        record_disk_access(namespace, key)?;
        Ok(())
    }

    /// Removes one cache entry.
    pub fn remove(&self, namespace: &str, key: &str) -> RuntimeResult<()> {
        let paths = self.entry_paths(namespace, key)?;
        let _maintenance_guard = disk_maintenance_read()?;
        let entry_lock = disk_entry_lock(namespace, key)?;
        let _entry_guard = entry_lock
            .lock()
            .map_err(|_| RuntimeError::new("disk_cache", true, "disk entry lock poisoned"))?;
        remove_entry_paths(&paths)
    }

    /// Clears one namespace.
    pub fn clear_namespace(&self, namespace: &str) -> RuntimeResult<()> {
        let _maintenance_guard = disk_maintenance_write()?;
        let path = self.root.join("pixa").join(namespace_directory(namespace));
        match fs::remove_dir_all(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(RuntimeError::new(
                "disk_cache",
                true,
                format!("failed to clear namespace: {error}"),
            )),
        }
    }

    /// Clears the full Pixa disk cache root.
    pub fn clear_all(&self) -> RuntimeResult<()> {
        let _maintenance_guard = disk_maintenance_write()?;
        let path = self.root.join("pixa");
        match fs::remove_dir_all(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(RuntimeError::new(
                "disk_cache",
                true,
                format!("failed to clear disk cache: {error}"),
            )),
        }
    }

    /// Trims disk cache entries until total encoded bytes fit the budget.
    pub fn trim_to_bytes(&self, max_bytes: usize) -> RuntimeResult<()> {
        let _maintenance_guard = disk_maintenance_write()?;
        let root = self.root.join("pixa");
        if !root.exists() {
            return Ok(());
        }
        let mut entries = Vec::<DiskEntryInfo>::new();
        collect_disk_entries(&root, &mut entries)?;
        let mut total_bytes = entries.iter().map(|entry| entry.length).sum::<usize>();
        if total_bytes <= max_bytes {
            return Ok(());
        }
        entries.sort_by_key(|entry| (entry.last_access_ms, entry.created_ms));
        for entry in entries {
            if total_bytes <= max_bytes {
                break;
            }
            remove_file_if_exists(&entry.data)?;
            remove_file_if_exists(&entry.meta)?;
            total_bytes = total_bytes.saturating_sub(entry.length);
        }
        Ok(())
    }

    pub(crate) fn entry_paths(&self, namespace: &str, key: &str) -> RuntimeResult<EntryPaths> {
        let safe_key = sanitize_key(key)?;
        let prefix = safe_key.get(0..2).unwrap_or("xx");
        let directory = self
            .root
            .join("pixa")
            .join(namespace_directory(namespace))
            .join(prefix);
        Ok(EntryPaths {
            data: directory.join(format!("{safe_key}.bin")),
            meta: directory.join(format!("{safe_key}.meta")),
        })
    }

    fn read_metadata(&self, meta_path: &Path) -> RuntimeResult<Option<String>> {
        match fs::read_to_string(meta_path) {
            Ok(metadata) => Ok(Some(metadata)),
            Err(error) if error.kind() == std::io::ErrorKind::InvalidData => Ok(None),
            Err(error) => Err(RuntimeError::new(
                "disk_cache",
                true,
                format!("failed to read metadata: {error}"),
            )),
        }
    }
}

#[derive(Clone, Copy)]
struct RequiredDiskMetadata {
    length: usize,
    checksum: u64,
    created_ms: i64,
    last_access_ms: i64,
    expires_ms: i64,
}

#[derive(Clone, Copy)]
struct DiskCacheReadLimit {
    max_bytes: usize,
    stage: &'static str,
    message: &'static str,
}

#[derive(Debug)]
pub(crate) struct EntryPaths {
    pub(crate) data: PathBuf,
    pub(crate) meta: PathBuf,
}

fn read_cache_data(path: &Path, limit: Option<DiskCacheReadLimit>) -> RuntimeResult<Vec<u8>> {
    let Some(limit) = limit else {
        return fs::read(path).map_err(|error| {
            RuntimeError::new(
                "disk_cache",
                true,
                format!("failed to read disk cache: {error}"),
            )
        });
    };
    let file = File::open(path).map_err(|error| {
        RuntimeError::new(
            "disk_cache",
            true,
            format!("failed to open disk cache: {error}"),
        )
    })?;
    let read_limit = u64::try_from(limit.max_bytes)
        .unwrap_or(u64::MAX)
        .saturating_add(1);
    let mut bytes = Vec::with_capacity(limit.max_bytes.min(64 * 1024));
    file.take(read_limit)
        .read_to_end(&mut bytes)
        .map_err(|error| {
            RuntimeError::new(
                "disk_cache",
                true,
                format!("failed to read disk cache: {error}"),
            )
        })?;
    if bytes.len() > limit.max_bytes {
        return Err(RuntimeError::new(limit.stage, false, limit.message));
    }
    Ok(bytes)
}

#[derive(Debug)]
struct DiskEntryInfo {
    data: PathBuf,
    meta: PathBuf,
    length: usize,
    created_ms: i64,
    last_access_ms: i64,
}

fn collect_disk_entries(path: &Path, entries: &mut Vec<DiskEntryInfo>) -> RuntimeResult<()> {
    for entry in fs::read_dir(path).map_err(|error| {
        RuntimeError::new(
            "disk_cache",
            true,
            format!("failed to scan disk cache: {error}"),
        )
    })? {
        let entry = entry.map_err(|error| {
            RuntimeError::new(
                "disk_cache",
                true,
                format!("failed to scan disk cache entry: {error}"),
            )
        })?;
        let path = entry.path();
        if path.is_dir() {
            collect_disk_entries(&path, entries)?;
            continue;
        }
        if is_temp_cache_file(&path) {
            remove_file_if_exists(&path)?;
            continue;
        }
        if path.extension().and_then(|value| value.to_str()) != Some("bin") {
            continue;
        }
        let paths = EntryPaths {
            meta: path.with_extension("meta"),
            data: path,
        };
        let metadata = match fs::read_to_string(&paths.meta) {
            Ok(metadata) => metadata,
            Err(_) => {
                remove_entry_paths(&paths)?;
                continue;
            }
        };
        let Some(required) = parse_required_disk_metadata(&metadata) else {
            remove_entry_paths(&paths)?;
            continue;
        };
        let last_access_ms = path_disk_access_time(&paths.data).unwrap_or(required.last_access_ms);
        entries.push(DiskEntryInfo {
            data: paths.data,
            meta: paths.meta,
            length: required.length,
            created_ms: required.created_ms,
            last_access_ms,
        });
    }
    Ok(())
}

fn is_temp_cache_file(path: &Path) -> bool {
    let is_tmp = path.extension().and_then(|value| value.to_str()) == Some("tmp");
    let is_hidden = path
        .file_name()
        .and_then(|value| value.to_str())
        .is_some_and(|name| name.starts_with('.'));
    is_tmp && is_hidden
}

fn append_metadata_line(metadata: &mut String, key: &str, value: Option<&str>) {
    let Some(value) = value else {
        return;
    };
    metadata.push_str(key);
    metadata.push('=');
    metadata.push_str(&escape_metadata_value(value));
    metadata.push('\n');
}

fn escape_metadata_value(value: &str) -> String {
    value
        .chars()
        .flat_map(|ch| match ch {
            '\\' => "\\\\".chars().collect::<Vec<char>>(),
            '\n' => "\\n".chars().collect::<Vec<char>>(),
            '\r' => "\\r".chars().collect::<Vec<char>>(),
            _ => vec![ch],
        })
        .collect()
}

fn parse_http_metadata(metadata: &str) -> DiskCacheHttpMetadata {
    DiskCacheHttpMetadata {
        etag: metadata_value(metadata, "http_etag").map(unescape_metadata_value),
        last_modified: metadata_value(metadata, "http_last_modified").map(unescape_metadata_value),
        cache_control: metadata_value(metadata, "http_cache_control").map(unescape_metadata_value),
        date: metadata_value(metadata, "http_date").map(unescape_metadata_value),
        expires: metadata_value(metadata, "http_expires").map(unescape_metadata_value),
        age: metadata_value(metadata, "http_age").map(unescape_metadata_value),
        vary: metadata_value(metadata, "http_vary").map(unescape_metadata_value),
        vary_request_key: metadata_value(metadata, "http_vary_request_key")
            .map(unescape_metadata_value),
        fetched_at_ms: metadata_value(metadata, "http_fetched_at_ms")
            .and_then(|value| value.parse::<i64>().ok()),
    }
}

fn unescape_metadata_value(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(ch) = chars.next() {
        if ch != '\\' {
            result.push(ch);
            continue;
        }
        match chars.next() {
            Some('n') => result.push('\n'),
            Some('r') => result.push('\r'),
            Some('\\') => result.push('\\'),
            Some(other) => {
                result.push('\\');
                result.push(other);
            }
            None => result.push('\\'),
        }
    }
    result
}

fn sanitize_key(key: &str) -> RuntimeResult<String> {
    if key.len() < 8 || !key.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(RuntimeError::new("cache_key", false, "invalid cache key"));
    }
    Ok(key.to_ascii_lowercase())
}

fn namespace_directory(namespace: &str) -> String {
    let digest = Sha256::digest(namespace.as_bytes());
    let mut directory = String::with_capacity(3 + digest.len() * 2);
    directory.push_str("v2-");
    for byte in digest {
        write!(&mut directory, "{byte:02x}").expect("writing to a String cannot fail");
    }
    directory
}

fn atomic_write(path: &Path, bytes: &[u8]) -> RuntimeResult<()> {
    let parent = path
        .parent()
        .ok_or_else(|| RuntimeError::new("disk_cache", false, "invalid cache path"))?;
    fs::create_dir_all(parent).map_err(|error| {
        RuntimeError::new(
            "disk_cache",
            true,
            format!("failed to create cache directory: {error}"),
        )
    })?;
    let temp = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("entry"),
        now_millis()
    ));
    {
        let mut file = File::create(&temp).map_err(|error| {
            RuntimeError::new(
                "disk_cache",
                true,
                format!("failed to create temp file: {error}"),
            )
        })?;
        file.write_all(bytes).map_err(|error| {
            RuntimeError::new(
                "disk_cache",
                true,
                format!("failed to write cache file: {error}"),
            )
        })?;
        file.sync_all().map_err(|error| {
            RuntimeError::new(
                "disk_cache",
                true,
                format!("failed to sync cache file: {error}"),
            )
        })?;
    }
    fs::rename(&temp, path).map_err(|error| {
        RuntimeError::new(
            "disk_cache",
            true,
            format!("failed to commit cache file: {error}"),
        )
    })?;
    sync_parent_directory(parent)?;
    Ok(())
}

#[cfg(unix)]
fn sync_parent_directory(parent: &Path) -> RuntimeResult<()> {
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| {
            RuntimeError::new(
                "disk_cache",
                true,
                format!("failed to sync cache directory: {error}"),
            )
        })
}

#[cfg(not(unix))]
fn sync_parent_directory(_parent: &Path) -> RuntimeResult<()> {
    Ok(())
}

fn remove_file_if_exists(path: &Path) -> RuntimeResult<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(RuntimeError::new(
            "disk_cache",
            true,
            format!("failed to remove cache file: {error}"),
        )),
    }
}

fn remove_entry_paths(paths: &EntryPaths) -> RuntimeResult<()> {
    remove_file_if_exists(&paths.data)?;
    remove_file_if_exists(&paths.meta)?;
    Ok(())
}

fn disk_maintenance_lock() -> &'static RwLock<()> {
    DISK_MAINTENANCE_LOCK.get_or_init(|| RwLock::new(()))
}

fn disk_maintenance_read() -> RuntimeResult<std::sync::RwLockReadGuard<'static, ()>> {
    disk_maintenance_lock()
        .read()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk maintenance lock poisoned"))
}

fn disk_maintenance_write() -> RuntimeResult<std::sync::RwLockWriteGuard<'static, ()>> {
    disk_maintenance_lock()
        .write()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk maintenance lock poisoned"))
}

fn disk_entry_lock(namespace: &str, key: &str) -> RuntimeResult<Arc<Mutex<()>>> {
    let lock_key = disk_access_key(namespace, key)?;
    let mut locks = DISK_ENTRY_LOCKS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk lock map poisoned"))?;
    if locks.len() > 4096 {
        locks.retain(|_, lock| lock.strong_count() > 0);
    }
    if let Some(lock) = locks.get(&lock_key).and_then(std::sync::Weak::upgrade) {
        return Ok(lock);
    }
    let lock = Arc::new(Mutex::new(()));
    locks.insert(lock_key, Arc::downgrade(&lock));
    Ok(lock)
}

fn disk_access_times() -> &'static Mutex<HashMap<String, i64>> {
    DISK_ACCESS_TIMES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn record_disk_access(namespace: &str, key: &str) -> RuntimeResult<()> {
    let access_key = disk_access_key(namespace, key)?;
    let mut access_times = disk_access_times()
        .lock()
        .map_err(|_| RuntimeError::new("disk_cache", true, "disk access map poisoned"))?;
    if access_times.len() > 16_384 {
        access_times.clear();
    }
    access_times.insert(access_key, now_millis());
    Ok(())
}

fn path_disk_access_time(path: &Path) -> Option<i64> {
    let key = path.file_stem()?.to_str()?;
    let namespace = path.parent()?.parent()?.file_name()?.to_str()?;
    let access_key = format!("{namespace}:{key}");
    disk_access_times()
        .lock()
        .ok()
        .and_then(|access_times| access_times.get(&access_key).copied())
}

fn disk_access_key(namespace: &str, key: &str) -> RuntimeResult<String> {
    Ok(format!(
        "{}:{}",
        namespace_directory(namespace),
        sanitize_key(key)?
    ))
}

fn parse_required_disk_metadata(metadata: &str) -> Option<RequiredDiskMetadata> {
    if metadata_value(metadata, "version")? != "1" {
        return None;
    }
    let created_ms = metadata_value(metadata, "created_ms")?
        .parse::<i64>()
        .ok()?;
    let last_access_ms = metadata_value(metadata, "last_access_ms")?
        .parse::<i64>()
        .ok()?;
    let expires_ms = metadata_value(metadata, "expires_ms")?
        .parse::<i64>()
        .ok()?;
    let length = metadata_value(metadata, "length")?.parse::<usize>().ok()?;
    let checksum = u64::from_str_radix(metadata_value(metadata, "checksum")?, 16).ok()?;
    Some(RequiredDiskMetadata {
        length,
        checksum,
        created_ms,
        last_access_ms,
        expires_ms,
    })
}

fn metadata_value<'a>(metadata: &'a str, key: &str) -> Option<&'a str> {
    metadata
        .lines()
        .find_map(|line| line.strip_prefix(key)?.strip_prefix('='))
}

pub(crate) fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::thread;
    use std::time::Duration;

    static TEST_ROOT_COUNTER: AtomicUsize = AtomicUsize::new(0);

    #[test]
    fn memory_trim_skips_pinned_active_entry() {
        let mut cache = MemoryCache::new(8);
        cache.put("default", "a".to_string(), vec![1, 2, 3, 4].into(), None);
        cache.put("default", "b".to_string(), vec![5, 6, 7, 8].into(), None);

        assert!(cache.pin("a"));
        cache.trim_to_bytes(4);

        assert!(cache.get("a").is_some());
        assert!(cache.get("b").is_none());
    }

    #[test]
    fn memory_unpin_allows_lru_trim_to_evict_entry() {
        let mut cache = MemoryCache::new(8);
        cache.put("default", "a".to_string(), vec![1, 2, 3, 4].into(), None);
        cache.put("default", "b".to_string(), vec![5, 6, 7, 8].into(), None);

        assert!(cache.pin("a"));
        cache.trim_to_bytes(4);
        assert!(cache.unpin("a"));
        cache.trim_to_bytes(0);

        assert!(cache.get("a").is_none());
        assert!(cache.get("b").is_none());
    }

    #[test]
    fn memory_contains_checks_fresh_entry_without_cloning_bytes() {
        let mut cache = MemoryCache::new(8);
        cache.put(
            "default",
            "a".to_string(),
            vec![1, 2, 3, 4].into(),
            Some(60_000),
        );

        assert!(cache.contains("a"));
        assert!(cache.get("a").is_some());
        assert!(!cache.contains("missing"));
    }

    #[test]
    fn memory_processed_lookup_does_not_return_encoded_entry_with_same_key() {
        let mut cache = MemoryCache::new(8);
        cache.put("default", "same".to_string(), vec![1, 2, 3, 4].into(), None);

        assert!(cache.get_processed("same").is_none());
        assert_eq!(cache.get("same").as_deref(), Some(&[1, 2, 3, 4][..]));
        assert_eq!(cache.stats().processed_misses, 1);

        cache.put_processed("default", "same".to_string(), vec![5, 6].into(), None);

        assert!(cache.get("same").is_none());
        assert_eq!(cache.get_processed("same").as_deref(), Some(&[5, 6][..]));
        assert_eq!(cache.stats().misses, 2);
    }

    #[test]
    fn memory_stats_report_processed_entries_and_retained_bytes() {
        let mut cache = MemoryCache::new(16);
        cache.put(
            "default",
            "encoded".to_string(),
            vec![1, 2, 3, 4].into(),
            None,
        );
        cache.put_processed(
            "default",
            "processed".to_string(),
            vec![5, 6, 7].into(),
            None,
        );

        let stats = cache.stats();
        assert_eq!(stats.entries, 2);
        assert_eq!(stats.bytes, 7);
        assert_eq!(stats.processed_entries, 1);
        assert_eq!(stats.processed_bytes, 3);
    }

    #[test]
    fn disk_cache_serializes_concurrent_same_key_writes() {
        let root = temp_cache_root("disk-concurrent-write");
        let cache = DiskCache::new(&root);
        let first_cache = cache.clone();
        let second_cache = cache.clone();
        let key = "abcdef0123456789";
        let first_bytes = b"first image bytes".to_vec();
        let second_bytes = b"second image bytes".to_vec();
        let first_expected = first_bytes.clone();
        let second_expected = second_bytes.clone();

        let first = thread::spawn(move || {
            for _ in 0..64 {
                first_cache
                    .write("default", key, &first_bytes, Some(60_000))
                    .expect("first writer should complete");
            }
        });
        let second = thread::spawn(move || {
            for _ in 0..64 {
                second_cache
                    .write("default", key, &second_bytes, Some(60_000))
                    .expect("second writer should complete");
            }
        });

        first.join().unwrap();
        second.join().unwrap();
        let entry = match cache
            .read_entry("default", key)
            .expect("concurrent writes should leave a readable entry")
        {
            DiskCacheRead::Hit(entry) => entry,
            other => panic!("expected disk hit after concurrent writes, got {other:?}"),
        };
        let _ = std::fs::remove_dir_all(root);

        assert!(entry.bytes == first_expected || entry.bytes == second_expected);
    }

    #[test]
    fn disk_cache_removes_entries_namespaces_and_global_state() {
        let root = temp_cache_root("disk-clear");
        let cache = DiskCache::new(&root);
        cache
            .write("avatars", "aaaaaaaaaaaaaaaa", b"avatar-a", Some(60_000))
            .expect("first entry should be written");
        cache
            .write("avatars", "bbbbbbbbbbbbbbbb", b"avatar-b", Some(60_000))
            .expect("second entry should be written");
        cache
            .write("banners", "cccccccccccccccc", b"banner", Some(60_000))
            .expect("third entry should be written");

        cache
            .remove("avatars", "aaaaaaaaaaaaaaaa")
            .expect("entry remove should succeed");
        assert!(matches!(
            cache.read_entry("avatars", "aaaaaaaaaaaaaaaa").unwrap(),
            DiskCacheRead::Miss
        ));

        cache
            .clear_namespace("avatars")
            .expect("namespace clear should succeed");
        assert!(matches!(
            cache.read_entry("avatars", "bbbbbbbbbbbbbbbb").unwrap(),
            DiskCacheRead::Miss
        ));
        assert!(matches!(
            cache.read_entry("banners", "cccccccccccccccc").unwrap(),
            DiskCacheRead::Hit(_)
        ));

        cache.clear_all().expect("global clear should succeed");
        assert!(matches!(
            cache.read_entry("banners", "cccccccccccccccc").unwrap(),
            DiskCacheRead::Miss
        ));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn disk_cache_namespace_identity_is_collision_and_case_safe() {
        let root = temp_cache_root("namespace-identity");
        let cache = DiskCache::new(&root);
        let key = "abcdabcdabcdabcd";
        let fixtures = [
            ("a/b", b"slash".as_slice()),
            ("a?b", b"question".as_slice()),
            ("Gallery", b"upper".as_slice()),
            ("gallery", b"lower".as_slice()),
        ];
        for (namespace, bytes) in fixtures {
            cache
                .write(namespace, key, bytes, Some(60_000))
                .expect("namespace entry should write");
        }

        for (namespace, expected) in fixtures {
            let actual = cache
                .read(namespace, key)
                .expect("namespace entry should read")
                .expect("namespace entry should remain isolated");
            assert_eq!(actual, expected, "namespace {namespace}");
        }

        cache
            .clear_namespace("a/b")
            .expect("slash namespace should clear independently");
        assert!(cache.read("a/b", key).unwrap().is_none());
        assert_eq!(
            cache.read("a?b", key).unwrap().as_deref(),
            Some(b"question".as_slice())
        );
        cache
            .clear_namespace("Gallery")
            .expect("case-distinct namespace should clear independently");
        assert!(cache.read("Gallery", key).unwrap().is_none());
        assert_eq!(
            cache.read("gallery", key).unwrap().as_deref(),
            Some(b"lower".as_slice())
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn disk_cache_recovers_invalid_utf8_metadata() {
        let root = temp_cache_root("invalid-utf8-metadata");
        let cache = DiskCache::new(&root);
        let key = "abcdabcdabcdabce";
        cache
            .write("default", key, b"cached", Some(60_000))
            .expect("cache entry should write");
        let paths = cache.entry_paths("default", key).unwrap();
        std::fs::write(&paths.meta, [0xff, 0xfe]).expect("metadata should corrupt");

        assert!(matches!(
            cache.read_entry("default", key),
            Ok(DiskCacheRead::RecoveredCorruption)
        ));
        assert!(!paths.data.exists());
        assert!(!paths.meta.exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn disk_cache_recovers_truncated_metadata_before_limit_checks() {
        let root = temp_cache_root("truncated-metadata");
        let cache = DiskCache::new(&root);
        let key = "abcdabcdabcdabcf";
        cache
            .write("default", key, b"cached", Some(60_000))
            .expect("cache entry should write");
        let paths = cache.entry_paths("default", key).unwrap();
        std::fs::write(&paths.meta, b"version=1\nlength=999999\n")
            .expect("metadata should truncate");

        assert!(matches!(
            cache.read_entry_limited("default", key, 1, "decode", "limit"),
            Ok(DiskCacheRead::RecoveredCorruption)
        ));
        assert!(!paths.data.exists());
        assert!(!paths.meta.exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn disk_cache_trim_removes_the_full_invalid_metadata_pair() {
        let root = temp_cache_root("trim-invalid-metadata");
        let cache = DiskCache::new(&root);
        let key = "abcdabcdabcdabd0";
        cache
            .write("default", key, b"cached", Some(60_000))
            .expect("cache entry should write");
        let paths = cache.entry_paths("default", key).unwrap();
        std::fs::write(&paths.meta, [0xff, 0xfe]).expect("metadata should corrupt");

        cache
            .trim_to_bytes(usize::MAX)
            .expect("maintenance scan should recover invalid metadata");

        assert!(!paths.data.exists());
        assert!(!paths.meta.exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn disk_cache_contains_uses_metadata_without_reading_bytes() {
        let root = temp_cache_root("disk-contains");
        let cache = DiskCache::new(&root);
        let key = "dddddddddddddddd";
        cache
            .write("default", key, b"image-bytes", Some(60_000))
            .expect("entry should be written");

        assert!(cache
            .contains("default", key, false)
            .expect("contains should succeed"));

        let paths = cache.entry_paths("default", key).unwrap();
        std::fs::write(paths.data, b"short").expect("test should corrupt data length");

        assert!(!cache
            .contains("default", key, false)
            .expect("contains should recover corrupt length"));
        assert!(matches!(
            cache.read_entry("default", key).unwrap(),
            DiskCacheRead::Miss
        ));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn disk_cache_round_trips_varied_values_and_recovers_corruption() {
        let root = temp_cache_root("disk-property-roundtrip");
        let cache = DiskCache::new(&root);
        let mut seed = 0x9e37_79b9_7f4a_7c15_u64;

        for index in 0..48_u64 {
            let key = format!("{:016x}", 0x3000_u64 + index);
            let length = 1 + usize::from(next_pseudo_random_byte(&mut seed)) * 3;
            let bytes = pseudo_random_bytes(&mut seed, length);
            cache
                .write("property", &key, &bytes, Some(60_000))
                .expect("property entry should write");
            let entry = match cache
                .read_entry("property", &key)
                .expect("property entry should read")
            {
                DiskCacheRead::Hit(entry) => entry,
                other => panic!("expected property disk hit, got {other:?}"),
            };
            assert_eq!(entry.bytes, bytes);

            if index % 7 == 0 {
                let paths = cache
                    .entry_paths("property", &key)
                    .expect("entry paths should resolve");
                std::fs::write(&paths.data, b"corrupt")
                    .expect("test should overwrite data with corruption");
                assert!(matches!(
                    cache.read_entry("property", &key).unwrap(),
                    DiskCacheRead::RecoveredCorruption
                ));
                assert!(matches!(
                    cache.read_entry("property", &key).unwrap(),
                    DiskCacheRead::Miss
                ));
            }
        }
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn metadata_escape_round_trips_varied_control_char_values() {
        let mut seed = 0xa24b_aed4_963e_e407_u64;
        let fixed = ["plain", "line\nfeed", "carriage\rreturn", r"slash\value"];
        for value in fixed {
            assert_eq!(
                unescape_metadata_value(&escape_metadata_value(value)),
                value
            );
        }
        for length in 0..128 {
            let bytes = pseudo_random_bytes(&mut seed, length);
            let value: String = bytes
                .into_iter()
                .map(|byte| match byte % 5 {
                    0 => '\n',
                    1 => '\r',
                    2 => '\\',
                    3 => '=',
                    _ => char::from(b'a' + (byte % 26)),
                })
                .collect();
            assert_eq!(
                unescape_metadata_value(&escape_metadata_value(&value)),
                value
            );
        }
    }

    #[test]
    fn disk_cache_trims_by_last_access_time() {
        let root = temp_cache_root("disk-lru-trim");
        let cache = DiskCache::new(&root);
        cache
            .write("default", "aaaaaaaaaaaaaaaa", b"first", Some(60_000))
            .expect("first entry should be written");
        thread::sleep(Duration::from_millis(2));
        cache
            .write("default", "bbbbbbbbbbbbbbbb", b"second", Some(60_000))
            .expect("second entry should be written");
        thread::sleep(Duration::from_millis(2));

        assert!(matches!(
            cache.read_entry("default", "aaaaaaaaaaaaaaaa").unwrap(),
            DiskCacheRead::Hit(_)
        ));
        cache
            .trim_to_bytes(5)
            .expect("disk trim should use last access metadata");

        assert!(matches!(
            cache.read_entry("default", "aaaaaaaaaaaaaaaa").unwrap(),
            DiskCacheRead::Hit(_)
        ));
        assert!(matches!(
            cache.read_entry("default", "bbbbbbbbbbbbbbbb").unwrap(),
            DiskCacheRead::Miss
        ));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn disk_cache_trim_removes_stale_temp_files() {
        let root = temp_cache_root("disk-temp-cleanup");
        let temp_path = PathBuf::from(&root)
            .join("pixa")
            .join("default")
            .join("aa")
            .join(".aaaaaaaaaaaaaaaa.bin.123.tmp");
        std::fs::create_dir_all(temp_path.parent().unwrap())
            .expect("test temp cache directory should be created");
        std::fs::write(&temp_path, b"partial").expect("test temp file should be written");

        DiskCache::new(&root)
            .trim_to_bytes(usize::MAX)
            .expect("maintenance scan should succeed");

        assert!(!temp_path.exists());
        let _ = std::fs::remove_dir_all(root);
    }

    fn temp_cache_root(label: &str) -> String {
        let unique = TEST_ROOT_COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir()
            .join(format!(
                "pixa-cache-{label}-{}-{unique}",
                std::process::id()
            ))
            .to_string_lossy()
            .into_owned()
    }

    fn pseudo_random_bytes(seed: &mut u64, length: usize) -> Vec<u8> {
        (0..length).map(|_| next_pseudo_random_byte(seed)).collect()
    }

    fn next_pseudo_random_byte(seed: &mut u64) -> u8 {
        *seed ^= *seed << 13;
        *seed ^= *seed >> 7;
        *seed ^= *seed << 17;
        (*seed & 0xff) as u8
    }
}
