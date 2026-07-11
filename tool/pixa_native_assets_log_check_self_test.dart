import 'dart:io';

import 'pixa_native_assets_log_check.dart';

void main() {
  _recordsKnownThirdPartyFrameworkCollision();
  _recordsKnownPixaFrameworkCollision();
  _rejectsUnexpectedPixaFrameworkMismatch();
  _rejectsUnexpectedExternalFrameworkMismatch();
  _rejectsBareRuntimeText();
  _rejectsFailedOrIncompleteBuilds();
  _rejectsStaleOrDirtyEvidence();
  stdout.writeln('Pixa native-assets log check self-test passed.');
}

const String _commit = '0123456789abcdef0123456789abcdef01234567';

void _recordsKnownThirdPartyFrameworkCollision() {
  final NativeAssetFrameworkWarningReport report =
      NativeAssetFrameworkWarningReport.parse(
        _successfulLog('''
warning: Code asset "package:objective_c/objective_c.dylib" has different framework names for different architectures. Picking "objective_c.framework" and ignoring "objective_c1.framework". This is likely an issue in the package providing the asset.
'''),
      );

  _expect(
    report.failures.isEmpty,
    'the known objective_c collision should be classified',
  );
  _expect(
    report.warnings.length == 1,
    'the objective_c warning should be recorded',
  );
  _expect(
    report.warnings.single.classification ==
        'flutter-3.44-framework-name-collision',
    'the objective_c warning should retain its toolchain classification',
  );
  _expect(
    report.toJson()['warnings'] is List<Object?>,
    'warning evidence should be serializable',
  );
}

void _recordsKnownPixaFrameworkCollision() {
  final NativeAssetFrameworkWarningReport report =
      NativeAssetFrameworkWarningReport.parse(
        _successfulLog('''
warning: Code asset "package:pixa/pixa_runtime" has different framework names for different architectures. Picking "pixa_runtime.framework" and ignoring "pixa_runtime1.framework". This is likely an issue in the package providing the asset.
'''),
      );

  _expect(
    report.failures.isEmpty,
    'the Flutter 3.44 Pixa framework collision should be classified',
  );
  _expect(
    report.warnings.length == 1,
    'the observed Pixa framework warning should be recorded',
  );
  _expect(
    report.warnings.single.classification ==
        'flutter-3.44-framework-name-collision',
    'the Pixa warning should retain its toolchain classification',
  );
}

void _rejectsUnexpectedPixaFrameworkMismatch() {
  final NativeAssetFrameworkWarningReport report =
      NativeAssetFrameworkWarningReport.parse(
        _successfulLog('''
Code asset "package:pixa/pixa_runtime" has different framework names for different architectures. Picking "pixa_runtime.framework" and ignoring "pixa_arm64.framework".
'''),
      );

  _expect(report.failures.isNotEmpty, 'unexpected Pixa mismatch should fail');
  _expect(
    report.failures.single.contains('package:pixa/pixa_runtime'),
    'failure should identify the Pixa asset',
  );
}

void _rejectsUnexpectedExternalFrameworkMismatch() {
  final NativeAssetFrameworkWarningReport report =
      NativeAssetFrameworkWarningReport.parse(
        _successfulLog('''
Code asset "package:other/runtime" has different framework names for different architectures. Picking "runtime.framework" and ignoring "runtime2.framework".
'''),
      );

  _expect(
    report.failures.isNotEmpty,
    'unknown dependency mismatch should fail',
  );
  _expect(
    report.failures.single.contains('package:other/runtime'),
    'failure should identify the dependency asset',
  );
}

void _rejectsBareRuntimeText() {
  final NativeAssetFrameworkWarningReport report =
      NativeAssetFrameworkWarningReport.parse('libpixa_runtime.dylib');
  _expect(!report.passed, 'a runtime substring is not build evidence');
  _expect(
    report.failures.any((String failure) => failure.contains('buildStart')),
    'bare logs should report the missing structured start event',
  );
}

void _rejectsFailedOrIncompleteBuilds() {
  final NativeAssetFrameworkWarningReport failed =
      NativeAssetFrameworkWarningReport.parse(
        _successfulLog('BUILD FAILED', completeStatus: 'failed'),
      );
  _expect(!failed.passed, 'failed builds must not pass evidence validation');

  final NativeAssetFrameworkWarningReport incomplete =
      NativeAssetFrameworkWarningReport.parse(
        _successfulLog('', includeComplete: false),
      );
  _expect(!incomplete.passed, 'incomplete builds must not pass');
}

void _rejectsStaleOrDirtyEvidence() {
  final NativeAssetFrameworkWarningReport stale =
      NativeAssetFrameworkWarningReport.parse(
        _successfulLog(
          '',
          gitCommit: 'ffffffffffffffffffffffffffffffffffffffff',
        ),
        requiredGitCommit: _commit,
      );
  _expect(!stale.passed, 'non-HEAD build evidence must fail');

  final NativeAssetFrameworkWarningReport dirty =
      NativeAssetFrameworkWarningReport.parse(
        _successfulLog('', gitTreeState: 'dirty'),
      );
  _expect(!dirty.passed, 'dirty-tree build evidence must fail');
}

String _successfulLog(
  String body, {
  String gitCommit = _commit,
  String gitTreeState = 'clean',
  String completeStatus = 'succeeded',
  bool includeComplete = true,
}) {
  return '''
PIXA_NATIVE_ASSETS_EVIDENCE_JSON:{"schema":1,"event":"buildStart","platform":"macos","mode":"profile","gitCommit":"$gitCommit","gitTreeState":"$gitTreeState"}
$body
PIXA_NATIVE_ASSETS_EVIDENCE_JSON:{"schema":1,"event":"artifact","asset":"package:pixa/pixa_runtime","path":"/tmp/libpixa_runtime.dylib","bytes":4096,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
${includeComplete ? 'PIXA_NATIVE_ASSETS_EVIDENCE_JSON:{"schema":1,"event":"buildComplete","status":"$completeStatus","exitCode":${completeStatus == 'succeeded' ? 0 : 1}}' : ''}
''';
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
