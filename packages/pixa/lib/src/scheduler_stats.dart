/// Snapshot of Dart listener/control scheduler behavior.
final class PixaSchedulerStats {
  /// Creates a scheduler stats snapshot.
  const PixaSchedulerStats({
    required this.maxConcurrentRuntimeLoads,
    required this.maxQueuedRuntimeLoads,
    required this.activeRuntimeLoads,
    required this.queueDepth,
    required this.inflightRequests,
    required this.listeners,
    required this.totalQueued,
    required this.totalStarted,
    required this.totalCoalesced,
    required this.totalCompleted,
    required this.totalFailed,
    required this.totalCancelled,
    required this.totalBackpressureDropped,
    required this.runtimeProgressEvents,
    required this.runtimeProgressEventsDropped,
    required this.observerEventsDroppedBySampling,
    this.dartToRuntimeInputCopies = 0,
    this.dartToRuntimeInputBytesCopied = 0,
  });

  /// Configured Dart isolate entries into runtime load calls.
  final int maxConcurrentRuntimeLoads;

  /// Configured root runtime loads allowed to wait behind active work.
  final int maxQueuedRuntimeLoads;

  /// runtime loads currently active.
  final int activeRuntimeLoads;

  /// Queued root requests.
  final int queueDepth;

  /// In-flight root requests, including queued and active.
  final int inflightRequests;

  /// Active listeners attached to in-flight requests.
  final int listeners;

  /// Total root requests queued.
  final int totalQueued;

  /// Total root requests started.
  final int totalStarted;

  /// Total listeners coalesced onto existing root requests.
  final int totalCoalesced;

  /// Total listeners completed successfully.
  final int totalCompleted;

  /// Total listeners failed.
  final int totalFailed;

  /// Total listeners cancelled.
  final int totalCancelled;

  /// Total root/listener work dropped or rejected by scheduler backpressure.
  final int totalBackpressureDropped;

  /// runtime progress events delivered to listeners.
  final int runtimeProgressEvents;

  /// runtime progress events reported dropped by runtime bounded buffering.
  final int runtimeProgressEventsDropped;

  /// Observer events dropped by Dart sampling policy.
  final int observerEventsDroppedBySampling;

  /// Number of Dart-owned input buffers copied into runtime call memory.
  final int dartToRuntimeInputCopies;

  /// Total bytes copied from Dart-owned input buffers into runtime call memory.
  final int dartToRuntimeInputBytesCopied;

  /// JSON-like representation for debug UIs.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'maxConcurrentRuntimeLoads': maxConcurrentRuntimeLoads,
      'maxQueuedRuntimeLoads': maxQueuedRuntimeLoads,
      'activeRuntimeLoads': activeRuntimeLoads,
      'queueDepth': queueDepth,
      'inflightRequests': inflightRequests,
      'listeners': listeners,
      'totalQueued': totalQueued,
      'totalStarted': totalStarted,
      'totalCoalesced': totalCoalesced,
      'totalCompleted': totalCompleted,
      'totalFailed': totalFailed,
      'totalCancelled': totalCancelled,
      'totalBackpressureDropped': totalBackpressureDropped,
      'runtimeProgressEvents': runtimeProgressEvents,
      'runtimeProgressEventsDropped': runtimeProgressEventsDropped,
      'observerEventsDroppedBySampling': observerEventsDroppedBySampling,
      'dartToRuntimeInputCopies': dartToRuntimeInputCopies,
      'dartToRuntimeInputBytesCopied': dartToRuntimeInputBytesCopied,
    };
  }
}
