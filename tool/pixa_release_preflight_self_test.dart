import 'dart:io';

import 'pixa_release_preflight.dart';

Future<void> main() async {
  _requiresHostedPlatformEvidenceForExecution();
  _rejectsStaleOrDirtyReleaseEvidence();
  final ReleasePreflightPlan plan = _buildsTheReleaseContract();
  await _stopsAtTheFirstFailedCommand(plan);
  _usesThePinnedRustToolchain(plan);
  _usesCleanPublishCandidates(plan);
  _configuresEveryDartdocWarningAsAnError();
  _pinsCiActionsAndRustToolchain();
  stdout.writeln('Pixa release preflight self-test passed.');
}

const String _headCommit = '0123456789abcdef0123456789abcdef01234567';

void _rejectsStaleOrDirtyReleaseEvidence() {
  _expectThrows(
    () => ReleasePreflightOptions.parse(
      const <String>[
        '--dry-run',
        '--git-commit=ffffffffffffffffffffffffffffffffffffffff',
      ],
      currentGitCommit: _headCommit,
      currentGitTreeClean: true,
    ),
    'current HEAD',
  );
  _expectThrows(
    () => ReleasePreflightOptions.parse(
      const <String>[
        '--platform-reports=/tmp/pixa-platform-reports',
        '--native-assets-log=/tmp/pixa-macos-profile.log',
        '--profile-input=/tmp/pixa-profile-current.json',
        '--profile-baseline=/tmp/pixa-profile-baseline.json',
      ],
      currentGitCommit: _headCommit,
      currentGitTreeClean: false,
    ),
    'clean Git worktree',
  );
}

void _requiresHostedPlatformEvidenceForExecution() {
  _expectThrows(
    () => ReleasePreflightOptions.parse(const <String>[]),
    '--platform-reports',
  );

  final ReleasePreflightOptions dryRun = ReleasePreflightOptions.parse(
    const <String>['--dry-run'],
  );
  _expect(dryRun.dryRun, 'dry-run should not require evidence files');
}

ReleasePreflightPlan _buildsTheReleaseContract() {
  final ReleasePreflightOptions options = ReleasePreflightOptions.parse(
    const <String>[
      '--platform-reports=/tmp/pixa-platform-reports',
      '--native-assets-log=/tmp/pixa-macos-profile.log',
      '--profile-input=/tmp/pixa-profile-current.json',
      '--profile-baseline=/tmp/pixa-profile-baseline.json',
      '--git-commit=$_headCommit',
    ],
    currentGitCommit: _headCommit,
    currentGitTreeClean: true,
  );
  final ReleasePreflightPlan plan = ReleasePreflightPlan.create(options);
  final Map<String, ReleasePreflightStep> steps =
      <String, ReleasePreflightStep>{
        for (final ReleasePreflightStep step in plan.steps) step.id: step,
      };

  for (final String required in <String>[
    'dartdoc',
    'rust-audit',
    'release-preflight-self-test',
    'guard-self-test',
    'profile-report-self-test',
    'profile-acceptance-self-test',
    'profile-evidence',
    'gallery-tests',
    'pub-dependency-smoke',
    'publish-dry-run-pixa',
    'publish-dry-run-s3',
    'publish-dry-run-mjpeg',
    'native-assets-log',
    'platform-evidence',
    'git-diff-check',
  ]) {
    _expect(
      steps.containsKey(required),
      'release preflight is missing $required',
    );
  }

  final ReleasePreflightStep dartdoc = steps['dartdoc']!;
  _expect(dartdoc.executable == 'dart', 'dartdoc should use the Dart SDK');
  _expect(dartdoc.arguments.first == 'doc', 'dartdoc should run dart doc');
  _expect(
    dartdoc.arguments.contains('--validate-links'),
    'dartdoc should validate links before publication',
  );
  _expect(
    dartdoc.workingDirectory == 'packages/pixa',
    'dartdoc should run against the published core package',
  );

  final ReleasePreflightStep evidence = steps['platform-evidence']!;
  _expect(
    evidence.arguments.contains('--reports=/tmp/pixa-platform-reports'),
    'platform evidence should use the explicit hosted report directory',
  );
  _expect(
    evidence.arguments.contains(
      '--require-platforms=android,ios,linux,macos,windows',
    ),
    'release evidence should require all supported native platforms',
  );
  _expect(
    evidence.arguments.contains(
      '--require-native-modules=jpeg-turbo-roi,webp-roi',
    ),
    'release evidence should require both native ROI modules',
  );
  _expect(
    evidence.arguments.contains('--require-git-commit=$_headCommit'),
    'release evidence should be tied to the requested commit',
  );
  final ReleasePreflightStep nativeAssets = steps['native-assets-log']!;
  _expect(
    nativeAssets.arguments.contains('--log=/tmp/pixa-macos-profile.log'),
    'preflight should inspect the supplied profile build log',
  );
  _expect(
    nativeAssets.arguments.contains('--require-git-commit=$_headCommit') &&
        nativeAssets.arguments.contains('--require-mode=profile'),
    'Native Assets evidence should be bound to profile mode and current HEAD',
  );
  final ReleasePreflightStep profileEvidence = steps['profile-evidence']!;
  _expect(
    profileEvidence.arguments.contains(
      '--input=/tmp/pixa-profile-current.json',
    ),
    'preflight should validate the supplied current profile evidence',
  );
  _expect(
    profileEvidence.arguments.contains(
      '--baseline=/tmp/pixa-profile-baseline.json',
    ),
    'preflight should compare the supplied profile baseline',
  );
  _expect(
    profileEvidence.arguments.contains('--require-live-network'),
    'release profile evidence must include the seeded Picsum corpus',
  );
  _expect(
    plan.steps.last.id == 'git-diff-check',
    'diff validation should close the release plan',
  );
  return plan;
}

void _usesThePinnedRustToolchain(ReleasePreflightPlan plan) {
  final Map<String, ReleasePreflightStep> steps =
      <String, ReleasePreflightStep>{
        for (final ReleasePreflightStep step in plan.steps) step.id: step,
      };
  for (final String id in <String>[
    'rust-format',
    'rust-clippy',
    'rust-audit',
    'rust-tests',
  ]) {
    final ReleasePreflightStep step = steps[id]!;
    _expect(step.executable == 'rustup', '$id should execute through rustup');
    _expect(
      step.arguments.take(3).join(' ') == 'run 1.89.0 cargo',
      '$id should use the packaged Rust 1.89.0 toolchain',
    );
  }
}

void _usesCleanPublishCandidates(ReleasePreflightPlan plan) {
  final Iterable<ReleasePreflightStep> publishSteps = plan.steps.where(
    (ReleasePreflightStep step) => step.id.startsWith('publish-dry-run-'),
  );
  _expect(publishSteps.length == 3, 'all three packages need a clean dry-run');
  for (final ReleasePreflightStep step in publishSteps) {
    _expect(
      step.arguments.contains(
        '--dry-run-package=${step.id.substring('publish-dry-run-'.length)}',
      ),
      '${step.id} should stage a clean publish candidate',
    );
    _expect(
      step.workingDirectory == null,
      '${step.id} should not publish from the dirty source package',
    );
  }
}

void _configuresEveryDartdocWarningAsAnError() {
  final String options = File(
    'packages/pixa/dartdoc_options.yaml',
  ).readAsStringSync();
  for (final String warning in <String>[
    'ambiguous-doc-reference',
    'ambiguous-reexport',
    'broken-link',
    'internal-error',
    'no-library-level-docs',
    'unresolved-doc-reference',
    'tool-error',
  ]) {
    _expect(
      options.contains('- $warning'),
      'dartdoc warning $warning should be promoted to an error',
    );
  }
}

Future<void> _stopsAtTheFirstFailedCommand(ReleasePreflightPlan plan) async {
  final List<String> executed = <String>[];
  var invocation = 0;
  final ReleasePreflightExecutor executor = ReleasePreflightExecutor(
    plan: plan,
    runner: (ReleasePreflightStep step) async {
      executed.add(step.id);
      invocation += 1;
      return invocation == 2 ? 17 : 0;
    },
  );

  try {
    await executor.run();
    throw StateError('preflight should fail when a command exits non-zero');
  } on ReleasePreflightFailure catch (failure) {
    _expect(failure.exitCode == 17, 'failure should retain the exit code');
    _expect(
      failure.step.id == plan.steps[1].id,
      'failure should identify the command that failed',
    );
  }
  _expect(
    executed.length == 2,
    'preflight should stop after the first failure',
  );
}

void _pinsCiActionsAndRustToolchain() {
  final String workflow = File('.github/workflows/ci.yml').readAsStringSync();
  for (final String pinned in <String>[
    'actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0',
    'subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2',
    'android-actions/setup-android@9fc6c4e9069bf8d3d10b2204b1fb8f6ef7065407',
    'reactivecircus/android-emulator-runner@a421e43855164a8197daf9d8d40fe71c6996bb0d',
    'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02',
    'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093',
  ]) {
    _expect(workflow.contains(pinned), 'CI action is not pinned: $pinned');
  }
  _expect(
    !RegExp(r'uses:\s+[^\s#]+@v\d+').hasMatch(workflow),
    'CI actions should not use mutable major-version tags',
  );
  _expect(
    workflow.contains('rustup toolchain install 1.89.0 --profile minimal'),
    'CI should install the packaged Rust toolchain',
  );
  _expect(
    !workflow.contains('rustup toolchain install stable'),
    'CI should not float on the Rust stable channel',
  );
  _expect(
    workflow.contains(r'--require-git-commit=${{ github.sha }}'),
    'CI must reject platform evidence from any non-current commit',
  );
}

void _expectThrows(void Function() action, String messagePart) {
  try {
    action();
  } on Object catch (error) {
    _expect(
      error.toString().contains(messagePart),
      'expected error to mention $messagePart, got $error',
    );
    return;
  }
  throw StateError('expected an error mentioning $messagePart');
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
