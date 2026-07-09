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

  test('Windows TurboJPEG CMake processor is explicit for MSVC targets', () {
    expect(
      pixaWindowsTurboJpegCmakeSystemProcessor('x86_64-pc-windows-msvc'),
      'AMD64',
    );
    expect(
      pixaWindowsTurboJpegCmakeSystemProcessor('aarch64-pc-windows-msvc'),
      'ARM64',
    );
    expect(
      pixaWindowsTurboJpegCmakeSystemProcessor('i686-pc-windows-msvc'),
      'X86',
    );
    expect(
      pixaWindowsTurboJpegCmakeSystemProcessor('x86_64-unknown-linux-gnu'),
      isNull,
    );
  });

  test('Windows TurboJPEG toolchain defines system processor', () {
    final String toolchain = pixaWindowsTurboJpegCmakeToolchain('AMD64');

    expect(
      toolchain,
      contains(
        'set(CMAKE_SYSTEM_PROCESSOR "AMD64" CACHE STRING '
        '"Pixa target processor for libjpeg-turbo" FORCE)',
      ),
    );
    expect(toolchain, contains('set(CMAKE_SYSTEM_NAME Windows)'));
  });
}
