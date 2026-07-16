import 'dart:convert';
import 'dart:io';

import 'package:cockpit/cockpit.dart' as cockpit;

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  final platform = options.platform ?? _hostDesktopPlatform();
  final deviceId = options.deviceId ?? _defaultDeviceId(platform);
  final launchTimeoutSeconds =
      options.launchTimeoutSeconds ??
      defaultLaunchTimeoutSecondsForPlatform(platform);
  final projectDir = Directory(options.projectDir).absolute;
  final workflowFile = File(options.workflow).absolute;
  final outputRoot = Directory(
    options.outputRoot ?? 'build/reports/pixa_gallery_cockpit_$platform',
  ).absolute;
  final File? prebuiltAndroidApk = options.prebuiltAndroidApk == null
      ? null
      : File(options.prebuiltAndroidApk!).absolute;

  if (!projectDir.existsSync()) {
    throw StateError(
      'Gallery example directory does not exist: ${projectDir.path}',
    );
  }
  if (!workflowFile.existsSync()) {
    throw StateError(
      'Cockpit workflow file does not exist: ${workflowFile.path}',
    );
  }
  if (prebuiltAndroidApk != null && platform != 'android') {
    throw ArgumentError(
      '--prebuilt-android-apk is only valid when --platform=android.',
    );
  }
  if (prebuiltAndroidApk != null &&
      (!prebuiltAndroidApk.existsSync() ||
          prebuiltAndroidApk.lengthSync() == 0)) {
    throw StateError(
      'Prebuilt Android Cockpit APK is missing or empty: '
      '${prebuiltAndroidApk.path}',
    );
  }

  outputRoot.createSync(recursive: true);

  if (!options.skipPubGet) {
    final pubGetCode = await _run(
      flutterExecutableForPlatform(),
      const <String>['pub', 'get'],
      workingDirectory: projectDir.path,
    );
    if (pubGetCode != 0) {
      exit(pubGetCode);
    }
  }

  final workflow = workflowForAcceptance(
    workflowFile.readAsStringSync(),
    platform,
  );
  final configFile = File(
    '${outputRoot.path}${Platform.pathSeparator}validate_task.yaml',
  );
  configFile.writeAsStringSync(
    validateTaskConfig(
      projectDir: projectDir.path,
      platform: platform,
      deviceId: deviceId,
      sessionPort: options.sessionPort,
      launchTimeoutSeconds: launchTimeoutSeconds,
      outputRoot: outputRoot.path,
      scriptPath:
          '${outputRoot.path}${Platform.pathSeparator}pixa_gallery_acceptance.yaml',
      workflow: workflow,
    ),
  );

  stdout.writeln('Pixa gallery cockpit acceptance');
  stdout.writeln('  platform: $platform');
  stdout.writeln('  deviceId: $deviceId');
  stdout.writeln('  config: ${configFile.path}');

  final result = usesRemoteOnlyHostCaptureForPlatform(platform)
      ? await _runValidationWithRemoteOnlyHostCapture(
          projectDir: projectDir.path,
          platform: platform,
          deviceId: deviceId,
          sessionPort: options.sessionPort,
          launchTimeoutSeconds: launchTimeoutSeconds,
          outputRoot: outputRoot.path,
          scriptPath:
              '${outputRoot.path}${Platform.pathSeparator}pixa_gallery_acceptance.yaml',
          workflow: workflow,
          prebuiltAndroidApk: prebuiltAndroidApk,
          prebuiltAndroidLaunchId: options.prebuiltAndroidLaunchId,
        )
      : await _runCockpitValidateTaskCli(
          configFile: configFile,
          workingDirectory: projectDir.path,
        );
  final stdoutText = result.stdout;
  final stderrText = result.stderr;
  stderr.write(stderrText);

  File? resultFile;
  Map<String, Object?>? decoded;
  if (stdoutText.trim().isNotEmpty) {
    resultFile = writeValidationResult(
      outputRoot: outputRoot,
      stdoutText: stdoutText,
    );
    try {
      decoded = _decodeValidationResult(stdoutText);
    } on FormatException {
      stdout.write(stdoutText);
      if (result.exitCode != 0) {
        exit(result.exitCode);
      }
      rethrow;
    }
  }

  if (resultFile != null) {
    stdout.writeln('  result: ${resultFile.path}');
  }
  final classification = decoded?['classification'];
  final next = decoded?['recommendedNextStep'];
  if (classification != null) {
    stdout.writeln('  classification: $classification');
  }
  if (next != null) {
    stdout.writeln('  next: $next');
  }

  if (result.exitCode != 0) {
    _writeFailureSummary(decoded);
    if (stdoutText.trim().isNotEmpty && decoded == null) {
      stdout.write(stdoutText);
    }
    exit(result.exitCode);
  }

  if (decoded == null) {
    throw const FormatException(
      'Cockpit validation result must be a JSON map.',
    );
  }
  if (classification != 'completed') {
    _writeFailureSummary(decoded);
    exit(1);
  }
}

Future<int> _run(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

Future<ProcessResult> _runCaptured(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) {
  return Process.run(executable, arguments, workingDirectory: workingDirectory);
}

Future<_ValidationCommandResult> _runCockpitValidateTaskCli({
  required File configFile,
  required String workingDirectory,
}) async {
  final result = await _runCaptured(Platform.resolvedExecutable, <String>[
    'run',
    'cockpit',
    'validate-task',
    '--config',
    configFile.path,
    '--stdout-format',
    'json',
  ], workingDirectory: workingDirectory);
  return _ValidationCommandResult(
    exitCode: result.exitCode,
    stdout: result.stdout as String,
    stderr: result.stderr as String,
  );
}

Future<_ValidationCommandResult> _runValidationWithRemoteOnlyHostCapture({
  required String projectDir,
  required String platform,
  required String deviceId,
  required int sessionPort,
  required int launchTimeoutSeconds,
  required String outputRoot,
  required String scriptPath,
  required String workflow,
  required File? prebuiltAndroidApk,
  required String? prebuiltAndroidLaunchId,
}) async {
  try {
    final File? androidRemoteCommandTrace = platform == 'android'
        ? File(
            '$outputRoot${Platform.pathSeparator}android-diagnostics'
            '${Platform.pathSeparator}remote-command-timeline.ndjson',
          )
        : null;
    if (androidRemoteCommandTrace != null) {
      androidRemoteCommandTrace.parent.createSync(recursive: true);
      androidRemoteCommandTrace.writeAsStringSync('');
    }
    final launchService = cockpit.CockpitLaunchRemoteSessionService(
      launcher: prebuiltAndroidApk == null
          ? null
          : _prebuiltAndroidCockpitLauncher(
              prebuiltAndroidApk: prebuiltAndroidApk,
              prebuiltAndroidLaunchId: prebuiltAndroidLaunchId!,
            ),
    );
    final runScriptService = cockpit.CockpitRunRemoteControlScriptService(
      captureStrategyResolver: _remoteOnlyAndroidCaptureStrategyResolver(),
    );
    final service = cockpit.CockpitValidateTaskService(
      runTaskService: cockpit.CockpitRunTaskService(
        launch: _launchWithAndroidRemoteCommandSurfaceStabilization(
          launchService,
          traceFile: androidRemoteCommandTrace,
        ),
        runScriptService: runScriptService,
      ),
    );
    final result = await service.validate(
      cockpit.CockpitValidateTaskRequest(
        runTask: cockpit.CockpitRunTaskRequest(
          launch: cockpit.CockpitRunTaskLaunchRequest(
            projectDir: projectDir,
            target: 'cockpit/main.dart',
            platform: platform,
            deviceId: deviceId,
            sessionPort: sessionPort,
            launchTimeout: Duration(seconds: launchTimeoutSeconds),
            launchConfiguration: cockpitLaunchConfigurationForPlatform(
              platform,
            ),
          ),
          outputRoot: outputRoot,
          persistScriptPath: scriptPath,
          liveRunDisplayName: 'Pixa gallery cockpit acceptance',
          baseline: cockpit.CockpitRunTaskBaselineRequest(
            captureScreenshot: baselineCaptureScreenshotForPlatform(platform),
            screenshotName: 'pixa-gallery-baseline',
            includeSnapshot: true,
          ),
          requirements: const cockpit.CockpitRunTaskEvidenceRequirements(
            requireScreenshotEvidence: true,
          ),
          script: cockpit.cockpitControlScriptFromText(workflow),
        ),
        validation: const cockpit.CockpitValidateTaskRequirements(
          expectedClassification:
              cockpit.CockpitRunTaskClassification.completed,
          requirePrimaryScreenshot: true,
          requireArtifactFiles: true,
        ),
      ),
    );
    return _ValidationCommandResult(
      exitCode: 0,
      stdout: const JsonEncoder.withIndent('  ').convert(result.toJson()),
      stderr: '',
    );
  } on Object catch (error, stackTrace) {
    return _ValidationCommandResult(
      exitCode: 1,
      stdout: '',
      stderr: '$error\n$stackTrace\n',
    );
  }
}

cockpit.CockpitRemoteSessionLauncher _prebuiltAndroidCockpitLauncher({
  required File prebuiltAndroidApk,
  required String prebuiltAndroidLaunchId,
}) {
  final delegate = cockpit.CockpitAndroidRemoteSessionLauncher(
    processRunner: (executable, arguments, {workingDirectory, environment}) {
      if (isCockpitAndroidBuildApkCommand(executable, arguments)) {
        if (!prebuiltAndroidApk.existsSync() ||
            prebuiltAndroidApk.lengthSync() == 0) {
          return Future<ProcessResult>.value(
            ProcessResult(
              0,
              1,
              '',
              'Prebuilt Android Cockpit APK is missing or empty: '
                  '${prebuiltAndroidApk.path}',
            ),
          );
        }
        stdout.writeln(
          '  android build: using prebuilt APK ${prebuiltAndroidApk.path}',
        );
        return Future<ProcessResult>.value(
          ProcessResult(
            0,
            0,
            'Using prebuilt Android Cockpit APK: '
                '${prebuiltAndroidApk.path}',
            '',
          ),
        );
      }
      return Process.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    },
    buildArtifactResolver:
        ({required projectDir, required buildDirectory, flavor}) async {
          final applicationId =
              await cockpit
                  .CockpitAndroidRemoteSessionLauncher.resolveApplicationId(
                projectDir: projectDir,
              );
          if (applicationId == null) {
            throw StateError(
              'Unable to resolve Android applicationId from $projectDir.',
            );
          }
          return cockpit.CockpitAndroidBuildArtifact(
            applicationId: applicationId,
            apkPath: prebuiltAndroidApk.path,
          );
        },
  );
  return _AndroidPrebuiltLaunchIdLauncher(
    delegate: delegate,
    launchId: prebuiltAndroidLaunchId,
  );
}

bool isCockpitAndroidBuildApkCommand(
  String executable,
  List<String> arguments,
) {
  final executableName = executable
      .replaceAll('\\', '/')
      .split('/')
      .last
      .toLowerCase();
  return (executableName == 'flutter' || executableName == 'flutter.bat') &&
      arguments.length >= 2 &&
      arguments[0] == 'build' &&
      arguments[1] == 'apk';
}

final class _AndroidPrebuiltLaunchIdLauncher
    implements cockpit.CockpitRemoteSessionLauncher {
  const _AndroidPrebuiltLaunchIdLauncher({
    required this.delegate,
    required this.launchId,
  });

  final cockpit.CockpitRemoteSessionLauncher delegate;
  final String launchId;

  @override
  Future<cockpit.CockpitRemoteSessionHandle> launch(
    cockpit.CockpitRemoteSessionLaunchOptions options,
  ) {
    return delegate.launch(
      cockpit.CockpitRemoteSessionLaunchOptions(
        projectDir: options.projectDir,
        target: options.target,
        platform: options.platform,
        deviceId: options.deviceId,
        sessionPort: options.sessionPort,
        flavor: options.flavor,
        launchTimeout: options.launchTimeout,
        flutterVersion: options.flutterVersion,
        flutterExecutable: options.flutterExecutable,
        launchId: launchId,
        launchConfiguration: options.launchConfiguration,
      ),
    );
  }
}

bool usesRemoteOnlyHostCaptureForPlatform(String platform) {
  return platform == 'android';
}

cockpit.CockpitFlutterLaunchConfiguration cockpitLaunchConfigurationForPlatform(
  String platform,
) {
  if (platform != 'android') {
    return cockpit.CockpitFlutterLaunchConfiguration.empty;
  }
  return cockpit.CockpitFlutterLaunchConfiguration(
    flutterArgs: const <String>['--target-platform=android-arm64'],
  );
}

const int androidRemoteCommandSurfaceStableSeconds = 20;
const int androidRemoteCommandSurfaceTimeoutSeconds = 180;
const int androidRemoteCommandSurfacePollMilliseconds = 1000;
const int _androidRemoteCommandSurfaceRequestTimeoutSeconds = 5;

cockpit.CockpitLaunchTaskFunction
_launchWithAndroidRemoteCommandSurfaceStabilization(
  cockpit.CockpitLaunchRemoteSessionService launchService, {
  File? traceFile,
}) {
  return (request) async {
    final result = await launchService.launch(request);
    if (request.platform == 'android') {
      stdout.writeln(
        '  android remote command surface: waiting for stable readiness',
      );
      await waitForAndroidRemoteCommandSurface(
        result.sessionHandle,
        traceFile: traceFile,
      );
      stdout.writeln('  android remote command surface: stable');
    }
    return result;
  };
}

Future<void> waitForAndroidRemoteCommandSurface(
  cockpit.CockpitRemoteSessionHandle sessionHandle, {
  Duration stableWindow = const Duration(
    seconds: androidRemoteCommandSurfaceStableSeconds,
  ),
  Duration timeout = const Duration(
    seconds: androidRemoteCommandSurfaceTimeoutSeconds,
  ),
  Duration pollInterval = const Duration(
    milliseconds: androidRemoteCommandSurfacePollMilliseconds,
  ),
  File? traceFile,
}) async {
  final client = cockpit.CockpitRemoteSessionClient(
    baseUri: sessionHandle.baseUri,
    requestTimeout: const Duration(
      seconds: _androidRemoteCommandSurfaceRequestTimeoutSeconds,
    ),
  );
  final deadline = DateTime.now().toUtc().add(timeout);
  DateTime? stableSince;
  var attempts = 0;
  Object? lastError;

  while (true) {
    attempts += 1;
    _writeAndroidRemoteCommandTrace(
      traceFile: traceFile,
      attempt: attempts,
      command: 'attempt',
      phase: 'start',
    );
    try {
      final ready = await _androidRemoteCommandSurfaceReady(
        client,
        attempt: attempts,
        traceFile: traceFile,
      );
      final now = DateTime.now().toUtc();
      _writeAndroidRemoteCommandTrace(
        traceFile: traceFile,
        attempt: attempts,
        command: 'attempt',
        phase: 'success',
        result: ready ? 'ready' : 'not_ready',
      );
      if (ready) {
        stableSince ??= now;
        if (now.difference(stableSince) >= stableWindow) {
          return;
        }
      } else {
        stableSince = null;
      }
    } on Object catch (error) {
      stableSince = null;
      lastError = error;
      _writeAndroidRemoteCommandTrace(
        traceFile: traceFile,
        attempt: attempts,
        command: 'attempt',
        phase: 'failure',
        error: error,
      );
    }

    final now = DateTime.now().toUtc();
    if (!now.isBefore(deadline)) {
      throw cockpit.CockpitApplicationServiceException(
        code: 'androidRemoteCommandSurfaceUnstable',
        message:
            'Android remote command surface did not stay stable before workflow execution.',
        details: <String, Object?>{
          'baseUrl': sessionHandle.baseUrl,
          'attempts': attempts,
          'stableWindowMs': stableWindow.inMilliseconds,
          'timeoutMs': timeout.inMilliseconds,
          if (lastError != null) 'lastError': lastError.toString(),
        },
      );
    }

    final remaining = deadline.difference(now);
    final delay = remaining < pollInterval ? remaining : pollInterval;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
  }
}

Future<bool> _androidRemoteCommandSurfaceReady(
  cockpit.CockpitRemoteSessionClient client, {
  required int attempt,
  required File? traceFile,
}) async {
  final ping = await _traceAndroidRemoteCommand(
    traceFile: traceFile,
    attempt: attempt,
    command: 'ping',
    action: client.ping,
  );
  if (!ping) {
    return false;
  }
  final ready = await _traceAndroidRemoteCommand(
    traceFile: traceFile,
    attempt: attempt,
    command: 'ready',
    action: client.ready,
  );
  if (!ready) {
    return false;
  }
  final status = await _traceAndroidRemoteCommand(
    traceFile: traceFile,
    attempt: attempt,
    command: 'readStatus',
    action: client.readStatus,
    summarize: (_) => 'status_received',
  );
  final statusJson = status.toJson();
  final capabilities = statusJson['capabilities'];
  if (capabilities is! Map<String, Object?>) {
    return false;
  }
  final commands = capabilities['supportedCommands'];
  if (commands is! List<Object?> ||
      !commands.contains('assertText') ||
      !commands.contains('captureScreenshot')) {
    _writeAndroidRemoteCommandTrace(
      traceFile: traceFile,
      attempt: attempt,
      command: 'validateCapabilities',
      phase: 'failure',
      result: 'required_commands_missing',
    );
    return false;
  }
  _writeAndroidRemoteCommandTrace(
    traceFile: traceFile,
    attempt: attempt,
    command: 'validateCapabilities',
    phase: 'success',
    result: 'required_commands_available',
  );
  await _traceAndroidRemoteCommand(
    traceFile: traceFile,
    attempt: attempt,
    command: 'readSnapshot',
    action: client.readSnapshot,
    summarize: (_) => 'snapshot_received',
  );
  return _traceAndroidRemoteCommand(
    traceFile: traceFile,
    attempt: attempt,
    command: 'waitForUiIdle',
    action: () => client.waitForUiIdle(
      timeout: const Duration(milliseconds: 1200),
      includeNetworkIdle: false,
    ),
  );
}

Future<T> _traceAndroidRemoteCommand<T>({
  required File? traceFile,
  required int attempt,
  required String command,
  required Future<T> Function() action,
  Object? Function(T result)? summarize,
}) async {
  _writeAndroidRemoteCommandTrace(
    traceFile: traceFile,
    attempt: attempt,
    command: command,
    phase: 'start',
  );
  try {
    final result = await action();
    _writeAndroidRemoteCommandTrace(
      traceFile: traceFile,
      attempt: attempt,
      command: command,
      phase: 'success',
      result: summarize?.call(result) ?? result,
    );
    return result;
  } on Object catch (error) {
    _writeAndroidRemoteCommandTrace(
      traceFile: traceFile,
      attempt: attempt,
      command: command,
      phase: 'failure',
      error: error,
    );
    rethrow;
  }
}

void _writeAndroidRemoteCommandTrace({
  required File? traceFile,
  required int attempt,
  required String command,
  required String phase,
  Object? result,
  Object? error,
}) {
  final line = androidRemoteCommandTraceLine(
    timestamp: DateTime.now().toUtc(),
    attempt: attempt,
    command: command,
    phase: phase,
    result: result,
    error: error,
  );
  stdout.writeln('  android remote command trace: $line');
  traceFile?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

String androidRemoteCommandTraceLine({
  required DateTime timestamp,
  required int attempt,
  required String command,
  required String phase,
  Object? result,
  Object? error,
}) {
  return jsonEncode(<String, Object?>{
    'timestampUtc': timestamp.toUtc().toIso8601String(),
    'attempt': attempt,
    'command': command,
    'phase': phase,
    'result': ?result,
    if (error != null) 'error': error.toString(),
  });
}

cockpit.CockpitCaptureStrategyResolver
_remoteOnlyAndroidCaptureStrategyResolver() {
  cockpit.CockpitCaptureAdapter? remoteAdapter;
  return cockpit.CockpitCaptureStrategyResolver(
    remoteAdapterFactory: (client) {
      final adapter = cockpit.CockpitRemoteCaptureAdapter(client: client);
      remoteAdapter = adapter;
      return adapter;
    },
    adbAdapterFactory: (_) {
      final adapter = remoteAdapter;
      if (adapter == null) {
        throw StateError('Remote capture adapter was not initialized.');
      }
      return adapter;
    },
  );
}

String flutterExecutableForPlatform({
  Map<String, String>? environment,
  bool? isWindows,
}) {
  final resolvedEnvironment = environment ?? Platform.environment;
  final resolvedIsWindows = isWindows ?? Platform.isWindows;
  final flutterRoot = resolvedEnvironment['FLUTTER_ROOT'];
  if (resolvedIsWindows) {
    if (flutterRoot != null && flutterRoot.trim().isNotEmpty) {
      return '${flutterRoot.replaceAll(r'\', '/')}/bin/flutter.bat';
    }
    return 'flutter.bat';
  }
  if (flutterRoot != null && flutterRoot.trim().isNotEmpty) {
    return '$flutterRoot/bin/flutter';
  }
  return 'flutter';
}

File writeValidationResult({
  required Directory outputRoot,
  required String stdoutText,
}) {
  outputRoot.createSync(recursive: true);
  final resultFile = File(
    '${outputRoot.path}${Platform.pathSeparator}validation_result.json',
  );
  resultFile.writeAsStringSync(stdoutText);
  return resultFile;
}

final class _ValidationCommandResult {
  const _ValidationCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

int defaultLaunchTimeoutSecondsForPlatform(String platform) {
  return switch (platform) {
    'android' || 'ios' => 2160,
    'macos' => 600,
    _ => 240,
  };
}

Map<String, Object?> _decodeValidationResult(String stdoutText) {
  final decoded = const JsonDecoder().convert(stdoutText);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException(
      'Cockpit validation result must be a JSON map.',
    );
  }
  return decoded;
}

void _writeFailureSummary(Map<String, Object?>? decoded) {
  if (decoded == null) {
    return;
  }
  final failureSummary = validationFailureSummary(decoded);
  if (failureSummary != null) {
    stderr.writeln('Cockpit acceptance failed: $failureSummary');
  }
}

String? validationFailureSummary(Map<String, Object?> result) {
  final parts = <String>[];
  void addPart(Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      parts.add(value.trim());
    }
  }

  addPart(_manifestFailureSummary(result));
  addPart(_readString(result, 'blockedReason'));

  final runTaskResult = result['runTaskResult'];
  if (runTaskResult is Map<String, Object?>) {
    final blockedReason = _readString(runTaskResult, 'blockedReason');
    if (blockedReason != _readString(result, 'blockedReason')) {
      addPart(blockedReason);
    }
    _appendGateSummary(parts, runTaskResult['bundleSummary']);
  }

  final validationFailures = result['validationFailures'];
  if (validationFailures is List<Object?>) {
    for (final failure in validationFailures.take(5)) {
      if (failure is Map<String, Object?>) {
        final code = _readString(failure, 'code');
        final message = _readString(failure, 'message');
        if (code != null || message != null) {
          parts.add(<String>[?code, ?message].join(': '));
        }
      }
    }
  }

  return parts.isEmpty ? null : parts.join(' | ');
}

String? _manifestFailureSummary(Map<String, Object?> result) {
  final runTaskResult = result['runTaskResult'];
  if (runTaskResult is! Map<String, Object?>) {
    return null;
  }
  final bundleSummary = runTaskResult['bundleSummary'];
  if (bundleSummary is! Map<String, Object?>) {
    return null;
  }
  final manifest = bundleSummary['manifest'];
  if (manifest is! Map<String, Object?>) {
    return null;
  }
  final summary = manifest['failureSummary'];
  return summary is String && summary.isNotEmpty ? summary : null;
}

void _appendGateSummary(List<String> parts, Object? bundleSummary) {
  if (bundleSummary is! Map<String, Object?>) {
    return;
  }
  final gateSummary = bundleSummary['gateSummary'];
  if (gateSummary is! Map<String, Object?>) {
    return;
  }
  final gates = gateSummary['gates'];
  if (gates is Map<String, Object?>) {
    final failedGates = <String>[
      for (final entry in gates.entries)
        if (entry.value == false) '${entry.key}=false',
    ];
    if (failedGates.isNotEmpty) {
      parts.add('failed gates: ${failedGates.join(', ')}');
    }
  }
  final failureCodes = gateSummary['failureCodes'];
  if (failureCodes is Map<String, Object?>) {
    final gateCodes = <String>[
      for (final entry in failureCodes.entries)
        if (_formatFailureCodes(entry.value) != null)
          '${entry.key}=${_formatFailureCodes(entry.value)}',
    ];
    if (gateCodes.isNotEmpty) {
      parts.add('gate failure codes: ${gateCodes.join(', ')}');
    }
  }
}

String? _formatFailureCodes(Object? value) {
  if (value is List<Object?>) {
    final values = <String>[
      for (final item in value)
        if (item is String && item.isNotEmpty) item,
    ];
    return values.isEmpty ? null : values.join('+');
  }
  return value is String && value.isNotEmpty ? value : null;
}

String? _readString(Map<String, Object?> value, String key) {
  final raw = value[key];
  return raw is String && raw.isNotEmpty ? raw : null;
}

String workflowForAcceptance(String source, String platform) {
  return manualBaselineCaptureWorkflowForPlatform(
    workflowForPlatform(source, platform),
    platform,
  );
}

String workflowForPlatform(String source, String platform) {
  final platformPattern = RegExp(r'^platform:\s*\S+\s*$', multiLine: true);
  if (!platformPattern.hasMatch(source)) {
    throw const FormatException('Cockpit workflow must declare a platform.');
  }
  return source.replaceFirst(platformPattern, 'platform: $platform');
}

bool baselineCaptureScreenshotForPlatform(String platform) {
  return platform != 'android';
}

String manualBaselineCaptureWorkflowForPlatform(
  String source,
  String platform,
) {
  if (baselineCaptureScreenshotForPlatform(platform)) {
    return source;
  }
  if (source.contains('commandId: baseline_capture')) {
    return source;
  }

  final waitStep = RegExp(
    r'^  - stepId: wait-gallery-workbench\s*$',
    multiLine: true,
  ).firstMatch(source);
  if (waitStep == null) {
    throw const FormatException(
      'Android cockpit workflow must wait for Gallery Workbench before baseline.',
    );
  }
  final nextStepMatches = RegExp(
    r'^  - stepId: ',
    multiLine: true,
  ).allMatches(source, waitStep.end);
  final nextStep = nextStepMatches.isEmpty ? null : nextStepMatches.first;
  if (nextStep == null) {
    throw const FormatException(
      'Android cockpit workflow must contain a step after Gallery Workbench.',
    );
  }

  return source.replaceRange(nextStep.start, nextStep.start, '''
  - stepId: baseline_capture
    stepType: retry
    maxAttempts: 6
    delayMs: 1000
    step:
      stepType: command
      command:
        commandId: baseline_capture
        commandType: captureScreenshot
        screenshotRequest:
          reason: baseline
          name: pixa-gallery-baseline
          includeSnapshot: true
          attachToStep: true

''');
}

String validateTaskConfig({
  required String projectDir,
  required String platform,
  required String deviceId,
  required int sessionPort,
  required int launchTimeoutSeconds,
  required String outputRoot,
  required String scriptPath,
  required String workflow,
}) {
  final launchConfiguration = cockpitLaunchConfigurationForPlatform(platform);
  final launchConfigurationYaml = launchConfiguration.isEmpty
      ? ''
      : '''
    launchConfiguration:
      flutterArgs:
${launchConfiguration.flutterArgs.map((argument) => '        - ${_yaml(argument)}').join('\n')}
''';
  return '''
runTask:
  launch:
    projectDir: ${_yaml(projectDir)}
    target: cockpit/main.dart
    platform: ${_yaml(platform)}
    deviceId: ${_yaml(deviceId)}
    sessionPort: $sessionPort
    launchTimeoutSeconds: $launchTimeoutSeconds
$launchConfigurationYaml
  outputRoot: ${_yaml(outputRoot)}
  persistScriptPath: ${_yaml(scriptPath)}
  liveRunDisplayName: Pixa gallery cockpit acceptance
  baseline:
    captureScreenshot: ${baselineCaptureScreenshotForPlatform(platform)}
    screenshotName: pixa-gallery-baseline
    includeSnapshot: true
  requirements:
    requireScreenshotEvidence: true
  script:
${_indent(workflow, 4)}
validation:
  expectedClassification: completed
  requirePrimaryScreenshot: true
  requireArtifactFiles: true
''';
}

String _indent(String value, int spaces) {
  final prefix = ' ' * spaces;
  return value
      .split('\n')
      .map((line) => line.isEmpty ? prefix : '$prefix$line')
      .join('\n');
}

String _yaml(String value) => "'${value.replaceAll("'", "''")}'";

String _hostDesktopPlatform() {
  if (Platform.isMacOS) {
    return 'macos';
  }
  if (Platform.isLinux) {
    return 'linux';
  }
  if (Platform.isWindows) {
    return 'windows';
  }
  throw UnsupportedError(
    'Pass --platform and --device-id for this host platform.',
  );
}

String _defaultDeviceId(String platform) {
  return switch (platform) {
    'linux' || 'macos' || 'windows' => platform,
    _ => throw ArgumentError(
      '--device-id is required when --platform=$platform.',
    ),
  };
}

final class _Options {
  const _Options({
    required this.help,
    required this.projectDir,
    required this.workflow,
    required this.platform,
    required this.deviceId,
    required this.outputRoot,
    required this.sessionPort,
    required this.launchTimeoutSeconds,
    required this.skipPubGet,
    required this.prebuiltAndroidApk,
    required this.prebuiltAndroidLaunchId,
  });

  final bool help;
  final String projectDir;
  final String workflow;
  final String? platform;
  final String? deviceId;
  final String? outputRoot;
  final int sessionPort;
  final int? launchTimeoutSeconds;
  final bool skipPubGet;
  final String? prebuiltAndroidApk;
  final String? prebuiltAndroidLaunchId;

  factory _Options.parse(List<String> args) {
    final values = <String, String>{};
    var help = false;
    var skipPubGet = false;
    for (final arg in args) {
      if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg == '--skip-pub-get') {
        skipPubGet = true;
      } else if (arg.startsWith('--') && arg.contains('=')) {
        final separator = arg.indexOf('=');
        values[arg.substring(2, separator)] = arg.substring(separator + 1);
      } else {
        throw ArgumentError('Unknown argument: $arg');
      }
    }
    final prebuiltAndroidApk = values['prebuilt-android-apk'];
    final prebuiltAndroidLaunchId = values['prebuilt-android-launch-id'];
    if ((prebuiltAndroidApk == null) != (prebuiltAndroidLaunchId == null)) {
      throw ArgumentError(
        '--prebuilt-android-apk and --prebuilt-android-launch-id '
        'must be provided together.',
      );
    }
    if (prebuiltAndroidApk?.trim().isEmpty == true ||
        prebuiltAndroidLaunchId?.trim().isEmpty == true) {
      throw ArgumentError('Prebuilt Android Cockpit values cannot be empty.');
    }
    return _Options(
      help: help,
      projectDir: values['project-dir'] ?? 'examples/pixa_gallery',
      workflow:
          values['workflow'] ??
          'examples/pixa_gallery/cockpit/pixa_gallery_acceptance.yaml',
      platform: values['platform'],
      deviceId: values['device-id'],
      outputRoot: values['output-root'],
      sessionPort: int.parse(values['session-port'] ?? '47331'),
      launchTimeoutSeconds: values.containsKey('launch-timeout-seconds')
          ? int.parse(values['launch-timeout-seconds']!)
          : null,
      skipPubGet: skipPubGet,
      prebuiltAndroidApk: prebuiltAndroidApk,
      prebuiltAndroidLaunchId: prebuiltAndroidLaunchId,
    );
  }
}

const _usage = '''
Usage: dart run tool/pixa_gallery_cockpit_acceptance.dart [options]

Runs the gallery example cockpit acceptance workflow through validate-task.

Options:
  --platform=<platform>                android, ios, linux, macos, or windows.
  --device-id=<id>                     Required for android and ios.
  --project-dir=<path>                 Defaults to examples/pixa_gallery.
  --workflow=<path>                    Defaults to the committed acceptance YAML.
  --output-root=<path>                 Defaults to build/reports/pixa_gallery_cockpit_<platform>.
  --session-port=<port>                Defaults to 47331.
  --launch-timeout-seconds=<seconds>   Defaults to 2160 on Android/iOS, 240 elsewhere.
  --prebuilt-android-apk=<path>        Reuse an APK built before the CI emulator starts.
  --prebuilt-android-launch-id=<id>    Launch id embedded in the prebuilt Android APK.
  --skip-pub-get                       Do not run flutter pub get first.
''';
