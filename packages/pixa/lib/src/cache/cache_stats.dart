/// Snapshot of Pixa cache behavior.
final class PixaCacheStats {
  /// Creates a cache stats snapshot.
  const PixaCacheStats({
    required this.memoryEntries,
    required this.memoryBytes,
    required this.memoryHits,
    required this.memoryMisses,
    required this.diskHits,
    required this.diskMisses,
    required this.diskWrites,
    this.diskCorruptionRecoveries = 0,
    required this.evictions,
    this.staleRevalidatesStarted = 0,
    this.staleRevalidatesCompleted = 0,
    this.staleRevalidatesFailed = 0,
    this.staleRevalidatesSkipped = 0,
    this.staleRevalidatesInFlight = 0,
    this.processedMemoryEntries = 0,
    this.processedMemoryBytes = 0,
    this.processedMemoryHits = 0,
    this.processedMemoryMisses = 0,
    this.processedMemoryEvictions = 0,
    this.processedDiskHits = 0,
    this.processedDiskMisses = 0,
    this.processedDiskStaleHits = 0,
    this.processedDiskWrites = 0,
    this.processedDiskCorruptionRecoveries = 0,
    this.ownedBufferHandlesCreated = 0,
    this.ownedBufferHandlesFreed = 0,
    this.ownedBufferBytesExposed = 0,
    this.progressSessionsCreated = 0,
    this.progressSessionsFreed = 0,
    this.progressEventsEmitted = 0,
    this.progressEventsDropped = 0,
    this.progressEventsDrained = 0,
  });

  /// Total entries retained by the shared encoded and processed memory LRU.
  final int memoryEntries;

  /// Total bytes retained by the shared encoded and processed memory LRU.
  final int memoryBytes;

  /// Encoded memory cache hits.
  final int memoryHits;

  /// Encoded memory cache misses.
  final int memoryMisses;

  /// Encoded disk cache hits.
  final int diskHits;

  /// Encoded disk cache misses.
  final int diskMisses;

  /// Encoded disk cache writes.
  final int diskWrites;

  /// Corrupt encoded disk entries removed and recovered as cache misses.
  final int diskCorruptionRecoveries;

  /// Encoded memory evictions.
  final int evictions;

  /// Stale-while-revalidate background refreshes started.
  final int staleRevalidatesStarted;

  /// Stale-while-revalidate background refreshes completed.
  final int staleRevalidatesCompleted;

  /// Stale-while-revalidate background refreshes failed.
  final int staleRevalidatesFailed;

  /// Stale-while-revalidate refreshes skipped by policy, dedupe, or backpressure.
  final int staleRevalidatesSkipped;

  /// Stale-while-revalidate refreshes currently in flight.
  final int staleRevalidatesInFlight;

  /// Processed variant entries retained in the shared memory LRU.
  final int processedMemoryEntries;

  /// Processed variant bytes retained in the shared memory LRU.
  final int processedMemoryBytes;

  /// Processed variant encoded memory hits.
  final int processedMemoryHits;

  /// Processed variant encoded memory misses.
  final int processedMemoryMisses;

  /// Processed variant encoded memory evictions.
  final int processedMemoryEvictions;

  /// Processed variant disk cache hits.
  final int processedDiskHits;

  /// Processed variant disk cache misses.
  final int processedDiskMisses;

  /// Stale processed variant disk entries encountered.
  final int processedDiskStaleHits;

  /// Processed variant disk writes.
  final int processedDiskWrites;

  /// Corrupt processed variant disk entries recovered as misses.
  final int processedDiskCorruptionRecoveries;

  /// owned buffer handles created at the runtime boundary.
  final int ownedBufferHandlesCreated;

  /// owned buffer handles released at the runtime boundary.
  final int ownedBufferHandlesFreed;

  /// Total encoded bytes exposed through owned buffers.
  final int ownedBufferBytesExposed;

  /// runtime progress sessions created.
  final int progressSessionsCreated;

  /// runtime progress sessions released.
  final int progressSessionsFreed;

  /// runtime progress events emitted.
  final int progressEventsEmitted;

  /// runtime progress events dropped by bounded buffering.
  final int progressEventsDropped;

  /// runtime progress events drained by Dart.
  final int progressEventsDrained;

  /// Hit rate across memory and disk cache lookups.
  double get hitRate {
    final int hits = memoryHits + diskHits;
    final int total = hits + memoryMisses + diskMisses;
    if (total == 0) {
      return 0;
    }
    return hits / total;
  }

  /// Hit rate for processed variant cache lookups only.
  double get processedHitRate {
    final int hits = processedMemoryHits + processedDiskHits;
    final int total = hits + processedMemoryMisses + processedDiskMisses;
    if (total == 0) {
      return 0;
    }
    return hits / total;
  }

  /// Encoded source entries retained in the shared memory LRU.
  int get encodedMemoryEntries => memoryEntries - processedMemoryEntries;

  /// Encoded source bytes retained in the shared memory LRU.
  int get encodedMemoryBytes => memoryBytes - processedMemoryBytes;

  /// Owned runtime buffers that have not been released yet.
  int get liveOwnedBufferHandles {
    return ownedBufferHandlesCreated - ownedBufferHandlesFreed;
  }

  /// runtime progress sessions that have not been released yet.
  int get liveProgressSessions {
    return progressSessionsCreated - progressSessionsFreed;
  }
}

/// Snapshot of Flutter decoded image cache behavior.
final class PixaDecodedCacheStats {
  /// Creates a decoded cache stats snapshot.
  const PixaDecodedCacheStats({
    required this.currentSize,
    required this.currentSizeBytes,
    required this.maximumSize,
    required this.maximumSizeBytes,
    required this.liveImageCount,
  });

  /// Current decoded keep-alive entry count.
  final int currentSize;

  /// Current decoded keep-alive bytes.
  final int currentSizeBytes;

  /// Maximum decoded keep-alive entry count.
  final int maximumSize;

  /// Maximum decoded keep-alive bytes.
  final int maximumSizeBytes;

  /// Decoded images with active listeners.
  final int liveImageCount;

  /// Current byte usage over the configured decoded byte budget.
  double get byteUtilization {
    if (maximumSizeBytes <= 0) {
      return 0;
    }
    return currentSizeBytes / maximumSizeBytes;
  }
}
