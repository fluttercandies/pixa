import 'dart:io';

import 'pixa_guard.dart';

void main() {
  _detectsDartCompatibleUpdates();
  _detectsCargoCompatibleUpdates();
  _enforcesDependencyOnlyReadmeInstall();
  stdout.writeln('Pixa guard self-test passed.');
}

void _detectsDartCompatibleUpdates() {
  final List<String> stale = pixaDartDependencyCurrencyFailures(
    <String, Object?>{
      'packages': <Object?>[
        <String, Object?>{
          'package': 'melos',
          'current': <String, Object?>{'version': '8.1.0'},
          'upgradable': <String, Object?>{'version': '8.2.0'},
        },
        <String, Object?>{
          'package': 'meta',
          'current': <String, Object?>{'version': '1.18.0'},
          'upgradable': <String, Object?>{'version': '1.18.0'},
        },
      ],
    },
  );
  _expect(stale.length == 1, 'one Dart compatible update should fail');
  _expect(
    stale.single.contains('melos 8.1.0 -> 8.2.0'),
    'versions should be reported',
  );

  final List<String> current = pixaDartDependencyCurrencyFailures(
    <String, Object?>{
      'packages': <Object?>[
        <String, Object?>{
          'package': 'melos',
          'current': <String, Object?>{'version': '8.2.0'},
          'upgradable': <String, Object?>{'version': '8.2.0'},
        },
      ],
    },
  );
  _expect(current.isEmpty, 'current Dart dependencies should pass');
}

void _detectsCargoCompatibleUpdates() {
  _expect(
    pixaCargoUpdateDryRunHasCompatibleUpdates(
      'Locking 7 packages to latest compatible versions',
    ),
    'Cargo compatible updates should be detected',
  );
  _expect(
    !pixaCargoUpdateDryRunHasCompatibleUpdates(
      'Locking 0 packages to latest compatible versions',
    ),
    'a current Cargo lockfile should pass',
  );
}

void _enforcesDependencyOnlyReadmeInstall() {
  final Map<String, String> dependencyOnly = <String, String>{
    'README.md': 'dependencies:\n  pixa: ^1.0.0\n',
    'README_ZH.md': 'dependencies:\n  pixa: ^1.0.0\n',
    'packages/pixa/README.md': 'dependencies:\n  pixa: ^1.0.0\n',
    'packages/pixa/README_ZH.md': 'dependencies:\n  pixa: ^1.0.0\n',
    'packages/pixa_fetcher_s3/README.md':
        'dependencies:\n  pixa_fetcher_s3: ^1.0.0\n',
    'packages/pixa_video_frame_mjpeg/README.md':
        'dependencies:\n  pixa_video_frame_mjpeg: ^1.0.0\n',
  };
  _expect(
    pixaReadmeDependencyInstallFailures(dependencyOnly).isEmpty,
    'version-only pub dependencies should pass README install guard',
  );

  final Map<String, String> pathOverride = <String, String>{
    ...dependencyOnly,
    'packages/pixa_video_frame_mjpeg/README.md': '''
dependencies:
  pixa_video_frame_mjpeg: ^1.0.0
  pixa:
    path: ../pixa_video_frame_mjpeg
dependency_overrides:
  pixa:
    path: ../pixa
''',
  };
  final List<String> failures = pixaReadmeDependencyInstallFailures(
    pathOverride,
  );
  _expect(failures.length == 2, 'path installs and overrides should both fail');
  _expect(
    failures.any((String failure) => failure.contains('path dependency')),
    'path dependency failure should be explicit',
  );
  _expect(
    failures.any((String failure) => failure.contains('dependency_overrides')),
    'dependency override failure should be explicit',
  );
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
