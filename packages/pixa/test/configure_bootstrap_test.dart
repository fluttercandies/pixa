import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  test('Pixa.configure initializes the Flutter binding', () async {
    final Directory cacheRoot = Directory.systemTemp.createTempSync(
      'pixa-configure-bootstrap-',
    );
    addTearDown(() => cacheRoot.deleteSync(recursive: true));

    await Pixa.configure(PixaConfig(cacheRootPath: cacheRoot.path));

    expect(WidgetsBinding.instance, isA<WidgetsBinding>());
  });
}
