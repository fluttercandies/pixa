import 'dart:io';

import 'package:code_assets/code_assets.dart';
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

  test('Windows Cargo target directory avoids the CMake object path limit', () {
    final Uri systemTemp = Uri.directory(
      r'C:\Users\runneradmin\AppData\Local\Temp',
      windows: true,
    );
    final Uri firstOutput = Uri.directory(
      r'D:\a\pixa\pixa\.dart_tool\pixa_platform_probe\windows\.dart_tool\hooks_runner\shared\pixa\build\de88d493ac',
      windows: true,
    );
    final Uri secondOutput = Uri.directory(
      r'D:\a\other\other\.dart_tool\hooks_runner\shared\pixa\build\de88d493ac',
      windows: true,
    );

    final Uri first = pixaCargoTargetDirectory(
      firstOutput,
      windows: true,
      systemTemp: systemTemp,
    );
    final Uri repeated = pixaCargoTargetDirectory(
      firstOutput,
      windows: true,
      systemTemp: systemTemp,
    );
    final Uri second = pixaCargoTargetDirectory(
      secondOutput,
      windows: true,
      systemTemp: systemTemp,
    );

    expect(first, repeated);
    expect(first, isNot(second));
    expect(
      first.toFilePath(windows: true),
      startsWith(r'C:\Users\runneradmin\AppData\Local\Temp\pixa_'),
    );
    expect(first.toString(), matches(RegExp(r'/pixa_[0-9a-f]{16}/$')));
    expect(first.toFilePath(windows: true).length, lessThan(80));
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

  test('64-bit Android Cargo linking uses 16 KB ELF page alignment', () {
    for (final String targetTriple in <String>[
      'aarch64-linux-android',
      'x86_64-linux-android',
    ]) {
      final Map<String, String> environment = <String, String>{};

      pixaConfigureAndroidPageSizeEnvironment(environment, targetTriple);

      final String target = targetTriple.toUpperCase().replaceAll('-', '_');
      expect(
        environment['CARGO_TARGET_${target}_RUSTFLAGS'],
        '-C link-arg=-Wl,-z,max-page-size=16384',
      );
    }
  });

  test('32-bit Android Cargo linking keeps its platform page alignment', () {
    final Map<String, String> environment = <String, String>{};

    pixaConfigureAndroidPageSizeEnvironment(
      environment,
      'armv7-linux-androideabi',
    );

    expect(
      environment['CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_RUSTFLAGS'],
      isNull,
    );
  });

  test('Windows native build imports the developer prompt environment', () async {
    final Map<String, String> environment = <String, String>{
      'ComSpec': r'C:\Windows\System32\cmd.exe',
      'PATH': r'C:\base',
    };
    String? executable;
    List<String>? arguments;
    String? wrapperPath;
    String? wrapperContents;

    await pixaApplyWindowsDeveloperCommandPromptEnvironment(
      environment,
      DeveloperCommandPrompt(
        script: Uri.file(
          r'C:\Program Files\Microsoft Visual Studio\18\Enterprise\Common7\Tools\VsDevCmd.bat',
          windows: true,
        ),
        arguments: const <String>['-arch=x64', '-host_arch=x64'],
      ),
      runProcess:
          (
            String command,
            List<String> commandArguments, {
            String? workingDirectory,
            Map<String, String>? environment,
          }) async {
            executable = command;
            arguments = commandArguments;
            wrapperPath = commandArguments.last;
            wrapperContents = File(wrapperPath!).readAsStringSync();
            return ProcessResult(
              1,
              0,
              'INCLUDE=C:\\VC\\include\r\n'
                  'LIB=C:\\VC\\lib\r\n'
                  'Path=C:\\VC\\bin;C:\\base\r\n'
                  '=C:=C:\\repo\r\n',
              '',
            );
          },
    );

    expect(executable, r'C:\Windows\System32\cmd.exe');
    expect(arguments, hasLength(4));
    expect(arguments!.take(3), <String>['/d', '/s', '/c']);
    expect(
      wrapperContents,
      contains(
        'call "C:\\Program Files\\Microsoft Visual Studio\\18\\Enterprise'
        '\\Common7\\Tools\\VsDevCmd.bat" "-arch=x64" '
        '"-host_arch=x64" >nul',
      ),
    );
    expect(wrapperPath, endsWith('pixa_windows_toolchain.cmd'));
    expect(File(wrapperPath!).existsSync(), isFalse);
    expect(environment['INCLUDE'], r'C:\VC\include');
    expect(environment['LIB'], r'C:\VC\lib');
    expect(environment['Path'], r'C:\VC\bin;C:\base');
    expect(environment, isNot(contains('PATH')));
    expect(environment, isNot(contains('=C:')));
  });

  test('Windows developer prompt failures are actionable', () async {
    await expectLater(
      pixaApplyWindowsDeveloperCommandPromptEnvironment(
        <String, String>{'ComSpec': r'C:\Windows\System32\cmd.exe'},
        DeveloperCommandPrompt(
          script: Uri.file(r'C:\VS\VsDevCmd.bat', windows: true),
          arguments: const <String>['-arch=x64'],
        ),
        runProcess:
            (
              String executable,
              List<String> arguments, {
              String? workingDirectory,
              Map<String, String>? environment,
            }) async => ProcessResult(1, 1, '', 'compiler setup failed'),
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          allOf(contains('VsDevCmd.bat'), contains('compiler setup failed')),
        ),
      ),
    );
  });

  test('Windows TurboJPEG maps supported MSVC targets to CMake processors', () {
    expect(
      pixaWindowsTurboJpegCmakeSystemProcessor('x86_64-pc-windows-msvc'),
      'AMD64',
    );
    expect(
      pixaWindowsTurboJpegCmakeSystemProcessor('aarch64-pc-windows-msvc'),
      'ARM64',
    );
    expect(
      pixaWindowsTurboJpegCmakeSystemProcessor('x86_64-unknown-linux-gnu'),
      isNull,
    );
  });

  test('Windows TurboJPEG toolchain only supplies the missing processor', () {
    final Directory output = Directory.systemTemp.createTempSync(
      'pixa_windows_cmake_test_',
    );
    addTearDown(() => output.deleteSync(recursive: true));
    final Map<String, String> environment = <String, String>{};

    pixaConfigureWindowsTurboJpegCmakeEnvironment(
      environment,
      targetTriple: 'x86_64-pc-windows-msvc',
      outputDirectory: output.uri,
    );

    final String path =
        environment['CMAKE_TOOLCHAIN_FILE_x86_64-pc-windows-msvc']!;
    expect(environment['CMAKE_TOOLCHAIN_FILE_x86_64_pc_windows_msvc'], path);
    expect(environment['TARGET_CMAKE_TOOLCHAIN_FILE'], path);
    final String toolchain = File(path).readAsStringSync();
    expect(
      toolchain,
      contains(
        'set(CMAKE_SYSTEM_PROCESSOR "AMD64" CACHE STRING '
        '"Pixa target processor for libjpeg-turbo" FORCE)',
      ),
    );
    expect(toolchain, isNot(contains('CMAKE_SYSTEM_NAME')));
    expect(toolchain, isNot(contains('CMAKE_C_COMPILER')));
    expect(toolchain, isNot(contains('CMAKE_GENERATOR')));
  });

  test('Windows TurboJPEG rejects stale or incomplete CMake caches', () {
    const String current = '''
CMAKE_C_COMPILER:FILEPATH=C:/Visual Studio/VC/Tools/MSVC/bin/cl.exe
CMAKE_SYSTEM_PROCESSOR:STRING=AMD64
CMAKE_TOOLCHAIN_FILE:FILEPATH=C:/temp/pixa_windows_turbojpeg_processor.cmake
''';

    expect(pixaWindowsTurboJpegCmakeCacheIsCurrent(current), isTrue);
    expect(
      pixaWindowsTurboJpegCmakeCacheIsCurrent(
        current.replaceAll(
          'pixa_windows_turbojpeg_processor.cmake',
          'pixa_windows_turbojpeg_toolchain.cmake',
        ),
      ),
      isFalse,
    );
    expect(
      pixaWindowsTurboJpegCmakeCacheIsCurrent(
        current.replaceAll('CMAKE_SYSTEM_PROCESSOR:STRING=AMD64\n', ''),
      ),
      isFalse,
    );
    expect(
      pixaWindowsTurboJpegCmakeCacheIsCurrent(
        current.replaceAll(
          'C:/Visual Studio/VC/Tools/MSVC/bin/cl.exe',
          'CMAKE_C_COMPILER-NOTFOUND',
        ),
      ),
      isFalse,
    );
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
