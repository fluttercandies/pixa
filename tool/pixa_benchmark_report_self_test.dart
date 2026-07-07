import 'dart:io';

import 'pixa_benchmark_report.dart' as report;

void main() {
  final Set<String> coverage = report.requiredBenchmarkCoverageNames().toSet();
  for (final String requiredName in <String>[
    'scroll_prefetch_planning',
    'scroll_prefetch_rapid_overlap',
    'scroll_prefetch_recent_eviction',
    'image_completion_frame_gate_burst',
    'request_cache_key_memoized_hot_path',
    'format_route_capability_lookup',
  ]) {
    _expect(
      coverage.contains(requiredName),
      'required benchmark coverage is missing $requiredName',
    );
  }
  stdout.writeln('Pixa benchmark report self-test passed.');
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
