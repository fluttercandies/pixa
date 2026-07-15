import 'package:flutter/foundation.dart';
import 'package:flutter_cockpit/flutter_cockpit_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../cockpit/main.dart' as cockpit_entry;

void main() {
  test('Android cockpit acceptance uses Flutter view capture', () async {
    final CockpitNativeCapture? androidCapture = cockpit_entry
        .pixaCockpitNativeCaptureOverride(TargetPlatform.android);
    final FlutterCockpitBinding binding = FlutterCockpitBinding(
      FlutterCockpitConfiguration(nativeCapture: androidCapture),
    );

    expect(androidCapture, isNotNull);
    expect(await binding.queryNativeCaptureAvailability(), isFalse);
  });

  test('non-Android cockpit acceptance preserves native capture', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    ]) {
      expect(cockpit_entry.pixaCockpitNativeCaptureOverride(platform), isNull);
    }
  });
}
