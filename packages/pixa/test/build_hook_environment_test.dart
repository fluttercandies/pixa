import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../hook/build.dart';

void main() {
  test('Rust workspace resolves inside the published package', () {
    final Uri packageRoot = Uri.file('/pub-cache/pixa-1.0.0/');

    expect(
      pixaRustWorkspaceRoot(packageRoot).toString(),
      'file:///pub-cache/pixa-1.0.0/native_src/rust/',
    );
  });

  test('Cargo target directory resolves inside Native Assets output', () {
    final Uri outputDirectory = Uri.file('/tmp/native-assets/pixa/');

    expect(
      pixaCargoTargetDirectory(outputDirectory).toString(),
      'file:///tmp/native-assets/pixa/cargo_target/',
    );
  });

  test('iOS Cargo environment isolates host build scripts from target SDK', () {
    final Map<String, String> environment = <String, String>{
      'SDKROOT': '/Xcode/Platforms/iPhoneSimulator.sdk',
    };

    pixaConfigureAppleCrossCompileEnvironment(
      environment,
      targetTriple: 'aarch64-apple-ios-sim',
      hostSdkRoot: '/Xcode/Platforms/MacOSX.sdk',
      sdkRoot: '/Xcode/Platforms/iPhoneSimulator.sdk',
      clang: '/Xcode/usr/bin/clang',
      ar: '/Xcode/usr/bin/ar',
    );

    expect(environment['SDKROOT'], '/Xcode/Platforms/MacOSX.sdk');
    expect(
      environment['CARGO_TARGET_AARCH64_APPLE_IOS_SIM_LINKER'],
      '/Xcode/usr/bin/clang',
    );
    expect(
      environment['CFLAGS_AARCH64_APPLE_IOS_SIM'],
      '-isysroot /Xcode/Platforms/iPhoneSimulator.sdk',
    );
    expect(
      environment['CARGO_TARGET_AARCH64_APPLE_IOS_SIM_RUSTFLAGS'],
      '-C link-arg=-isysroot '
      '-C link-arg=/Xcode/Platforms/iPhoneSimulator.sdk',
    );
  });

  test('Windows TurboJPEG delegates native compiler discovery to cmake-rs', () {
    final String hook = File('hook/build.dart').readAsStringSync();

    expect(hook, isNot(contains('pixaWindowsTurboJpegCmakeToolchain')));
    expect(hook, isNot(contains('_configureWindowsTurboJpegCmakeEnvironment')));
    expect(hook, isNot(contains('set(CMAKE_SYSTEM_NAME Windows)')));
  });

  test('published Rust workspace pins its toolchain and MSRV', () {
    final String toolchain = File(
      'native_src/rust/rust-toolchain.toml',
    ).readAsStringSync();
    final String workspace = File(
      'native_src/rust/Cargo.toml',
    ).readAsStringSync();
    final String core = File(
      'native_src/rust/pixa_core/Cargo.toml',
    ).readAsStringSync();
    final String runtime = File(
      'native_src/rust/pixa_runtime/Cargo.toml',
    ).readAsStringSync();

    expect(toolchain, contains('channel = "1.89.0"'));
    expect(workspace, contains('rust-version = "1.89"'));
    expect(core, contains('rust-version.workspace = true'));
    expect(runtime, contains('rust-version.workspace = true'));
  });

  test(
    'Rust prerequisite failure explains the pinned install and target',
    () async {
      final List<String> commands = <String>[];

      await expectLater(
        pixaValidateRustToolchain(
          cargo: 'cargo',
          rustc: 'rustc',
          rustWorkspace: Uri.file('/tmp/pixa-rust/'),
          environment: const <String, String>{},
          targetTriple: 'x86_64-pc-windows-msvc',
          runProcess:
              (
                String executable,
                List<String> arguments, {
                String? workingDirectory,
                Map<String, String>? environment,
              }) async {
                commands.add('$executable ${arguments.join(' ')}');
                if (executable == 'cargo') {
                  return ProcessResult(1, 0, 'cargo 1.89.0', '');
                }
                return ProcessResult(2, 0, 'rustc 1.88.0', '');
              },
        ),
        throwsA(
          isA<StateError>()
              .having(
                (StateError error) => error.message,
                'message',
                contains('rustup toolchain install 1.89.0 --profile minimal'),
              )
              .having(
                (StateError error) => error.message,
                'message',
                contains(
                  'rustup target add x86_64-pc-windows-msvc '
                  '--toolchain 1.89.0',
                ),
              )
              .having(
                (StateError error) => error.message,
                'message',
                contains('Desktop development with C++'),
              )
              .having(
                (StateError error) => error.message,
                'message',
                contains('NASM'),
              ),
        ),
      );
      expect(commands, <String>['cargo --version', 'rustc --version']);
    },
  );
}
