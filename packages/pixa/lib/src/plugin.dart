import 'registry.dart';

/// Pixa plugin contract.
abstract interface class PixaPlugin {
  /// Stable plugin id.
  String get id;

  /// Compatible core package versions.
  PixaVersionConstraint get compatiblePixaVersions;

  /// Registers plugin handlers.
  void register(PixaRegistry registry);
}

/// Small semver-compatible constraint used to avoid depending on pub_semver.
final class PixaVersionConstraint {
  /// Creates a version constraint.
  const PixaVersionConstraint({this.minimumInclusive, this.maximumExclusive});

  /// Accepts all versions.
  const PixaVersionConstraint.any() : this();

  /// Minimum inclusive version.
  final String? minimumInclusive;

  /// Maximum exclusive version.
  final String? maximumExclusive;

  /// Returns whether [version] is allowed.
  bool allows(String version) {
    final List<int> current = _parse(version);
    final String? min = minimumInclusive;
    if (min != null && _compare(current, _parse(min)) < 0) {
      return false;
    }
    final String? max = maximumExclusive;
    if (max != null && _compare(current, _parse(max)) >= 0) {
      return false;
    }
    return true;
  }
}

List<int> _parse(String version) {
  final String core = version.split('-').first;
  final List<int> parts =
      core.split('.').map((String part) => int.tryParse(part) ?? 0).toList();
  return <int>[
    parts.isNotEmpty ? parts[0] : 0,
    parts.length > 1 ? parts[1] : 0,
    parts.length > 2 ? parts[2] : 0,
  ];
}

int _compare(List<int> left, List<int> right) {
  for (int index = 0; index < 3; index++) {
    final int delta = left[index].compareTo(right[index]);
    if (delta != 0) {
      return delta;
    }
  }
  return 0;
}
