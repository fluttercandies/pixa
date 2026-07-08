import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'request.dart';
import 'source.dart';

/// One candidate in a responsive Pixa source set.
@immutable
final class PixaSourceSetCandidate {
  /// Creates a responsive source candidate.
  const PixaSourceSetCandidate({
    required this.source,
    required this.width,
    this.height,
    this.mimeType,
    this.id,
  }) : assert(width > 0),
       assert(height == null || height > 0);

  /// Creates a network candidate.
  factory PixaSourceSetCandidate.network(
    String url, {
    required int width,
    int? height,
    String? mimeType,
    String? id,
  }) {
    return PixaSourceSetCandidate(
      source: PixaSource.network(Uri.parse(url)),
      width: width,
      height: height,
      mimeType: mimeType,
      id: id,
    );
  }

  /// Candidate image source.
  final PixaSource source;

  /// Physical candidate width in encoded pixels.
  final int width;

  /// Optional physical candidate height in encoded pixels.
  final int? height;

  /// Optional encoded MIME type for format preference selection.
  final String? mimeType;

  /// Optional stable candidate id for diagnostics.
  final String? id;

  String? get _normalizedMimeType {
    final String? value = mimeType?.split(';').first.trim().toLowerCase();
    return value == null || value.isEmpty ? null : value;
  }
}

/// Responsive image source set selection model.
@immutable
final class PixaSourceSet {
  /// Creates a source set from ordered candidates.
  PixaSourceSet(Iterable<PixaSourceSetCandidate> candidates)
    : candidates = List<PixaSourceSetCandidate>.unmodifiable(candidates) {
    if (this.candidates.isEmpty) {
      throw ArgumentError.value(candidates, 'candidates', 'must not be empty');
    }
  }

  /// Available candidates.
  final List<PixaSourceSetCandidate> candidates;

  /// Selects the smallest candidate that can satisfy [logicalWidth] at [devicePixelRatio].
  PixaSourceSetCandidate select({
    required double logicalWidth,
    double devicePixelRatio = 1.0,
    Iterable<String> acceptedMimeTypes = const <String>[],
  }) {
    final int targetWidth = _targetPixels(logicalWidth, devicePixelRatio);
    final List<String> mimePreference = acceptedMimeTypes
        .map((String value) => value.split(';').first.trim().toLowerCase())
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
    final List<PixaSourceSetCandidate> pool = _mimeCompatibleCandidates(
      mimePreference,
    );
    final List<PixaSourceSetCandidate> sorted = pool.toList()
      ..sort((PixaSourceSetCandidate a, PixaSourceSetCandidate b) {
        final int mimeRank = _mimeRank(
          a,
          mimePreference,
        ).compareTo(_mimeRank(b, mimePreference));
        if (mimeRank != 0) {
          return mimeRank;
        }
        return a.width.compareTo(b.width);
      });

    for (final PixaSourceSetCandidate candidate in sorted) {
      if (candidate.width >= targetWidth) {
        return candidate;
      }
    }
    return sorted.last;
  }

  /// Selects a source and projects it into a [PixaRequest].
  PixaRequest selectRequest({
    required double logicalWidth,
    double? logicalHeight,
    double devicePixelRatio = 1.0,
    Iterable<String> acceptedMimeTypes = const <String>[],
    PixaRequest? baseRequest,
    BoxFit? fit,
  }) {
    final PixaSourceSetCandidate candidate = select(
      logicalWidth: logicalWidth,
      devicePixelRatio: devicePixelRatio,
      acceptedMimeTypes: acceptedMimeTypes,
    );
    final PixaRequest base =
        baseRequest ?? PixaRequest(source: candidate.source);
    return base.copyWith(
      source: candidate.source,
      targetSize: PixaTargetSize(
        width: _targetPixels(logicalWidth, devicePixelRatio),
        height: logicalHeight == null
            ? null
            : _targetPixels(logicalHeight, devicePixelRatio),
      ),
      fit: fit ?? base.fit,
    );
  }

  List<PixaSourceSetCandidate> _mimeCompatibleCandidates(
    List<String> mimePreference,
  ) {
    if (mimePreference.isEmpty) {
      return candidates;
    }
    final List<PixaSourceSetCandidate> exact = candidates
        .where((PixaSourceSetCandidate candidate) {
          final String? mimeType = candidate._normalizedMimeType;
          return mimeType == null || mimePreference.contains(mimeType);
        })
        .toList(growable: false);
    return exact.isEmpty ? candidates : exact;
  }

  int _mimeRank(PixaSourceSetCandidate candidate, List<String> preference) {
    final String? mimeType = candidate._normalizedMimeType;
    if (mimeType == null || preference.isEmpty) {
      return preference.length;
    }
    final int index = preference.indexOf(mimeType);
    return index < 0 ? preference.length : index;
  }
}

int _targetPixels(double logicalSize, double devicePixelRatio) {
  if (!logicalSize.isFinite || logicalSize <= 0) {
    throw RangeError.value(
      logicalSize,
      'logicalSize',
      'must be finite and greater than zero',
    );
  }
  if (!devicePixelRatio.isFinite || devicePixelRatio <= 0) {
    throw RangeError.value(
      devicePixelRatio,
      'devicePixelRatio',
      'must be finite and greater than zero',
    );
  }
  return math.max(1, (logicalSize * devicePixelRatio).ceil());
}
