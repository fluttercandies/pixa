import 'dart:io';

import 'pixa_guard.dart';

void main() {
  _detectsDartCompatibleUpdates();
  _detectsCargoCompatibleUpdates();
  _enforcesDependencyOnlyReadmeInstall();
  _enforcesAndroid16KbCiEvidence();
  _enforcesSdkCompatibilityContract();
  _selectsDartDependencyCurrencyGate();
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

void _enforcesAndroid16KbCiEvidence() {
  const String complete = '''
api-level: 35
target: google_apis_ps16k
bash tool/pixa_android_platform_ci.sh
set -euo pipefail
adb -s emulator-5554 shell getconf PAGE_SIZE
16384
zipalign -c -P 16
lib/x86_64/libpixa_runtime.so
llvm-readelf -lW
0x4000
''';
  _expect(
    pixaAndroid16KbCiFailures(complete).isEmpty,
    'complete Android 16 KB CI evidence should pass',
  );

  const String legacy = '''
api-level: 30
target: google_atd
dart run tool/pixa_platform_build.dart --platform=android
''';
  final List<String> failures = pixaAndroid16KbCiFailures(legacy);
  _expect(
    failures.length == 10,
    'legacy 4 KB Android CI should miss every 16 KB evidence gate',
  );
}

void _enforcesSdkCompatibilityContract() {
  final Map<String, String> compatible = <String, String>{
    'pubspec.yaml': '''
environment:
  sdk: ">=3.10.0 <4.0.0"
''',
    'packages/pixa/pubspec.yaml': '''
environment:
  sdk: ">=3.10.0 <4.0.0"
  flutter: ">=3.38.1"
dependencies:
  code_assets: ^1.2.1
  hooks: ^2.0.2
''',
    for (final String path in <String>[
      'packages/pixa_fetcher_s3/pubspec.yaml',
      'packages/pixa_video_frame_mjpeg/pubspec.yaml',
      'examples/pixa_gallery/pubspec.yaml',
    ])
      path: '''
environment:
  sdk: ">=3.10.0 <4.0.0"
  flutter: ">=3.38.1"
''',
    'tool/pixa_platform_build.dart': 'sdk: ">=3.10.0 <4.0.0"',
    'tool/pixa_pub_dependency_smoke.dart': 'sdk: ">=3.10.0 <4.0.0"',
    'packages/pixa/PLUGIN_AUTHORING.md': '''
environment:
  sdk: ">=3.10.0 <4.0.0"
  flutter: ">=3.38.1"
''',
    '.github/workflows/ci.yml': '''
name: Flutter 3.38 Linux
flutter-version: "3.38.1"
run: dart run tool/pixa_guard.dart --skip-dart-dependency-currency
''',
  };
  _expect(
    pixaSdkCompatibilityFailures(compatible).isEmpty,
    'Flutter 3.38.1 and Dart 3.10 compatibility contract should pass',
  );

  final Map<String, String> stale = <String, String>{
    ...compatible,
    'packages/pixa/pubspec.yaml': '''
environment:
  sdk: ">=3.11.0 <4.0.0"
  flutter: ">=3.41.9"
dependencies:
  code_assets: ^1.0.0
  hooks: ">=1.0.0 <3.0.0"
''',
    '.github/workflows/ci.yml': '''
name: Flutter 3.41 Linux
flutter-version: "3.41.9"
run: dart run tool/pixa_guard.dart --skip-dart-dependency-currency
''',
  };
  final List<String> failures = pixaSdkCompatibilityFailures(stale);
  _expect(
    failures.length == 6,
    'stale core and CI constraints should fail every compatibility gate',
  );
  _expect(
    failures.any((String failure) => failure.contains('code_assets')),
    'code_assets compatibility drift should be explicit',
  );
  _expect(
    failures.any((String failure) => failure.contains('Flutter 3.38.1')),
    'minimum Flutter CI drift should be explicit',
  );
}

void _selectsDartDependencyCurrencyGate() {
  _expect(
    pixaShouldCheckDartDependencyCurrency(const <String>[]),
    'full guard should check Dart dependency currency by default',
  );
  _expect(
    !pixaShouldCheckDartDependencyCurrency(const <String>[
      '--skip-dart-dependency-currency',
    ]),
    'minimum-SDK guard should explicitly skip Dart dependency currency',
  );
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
