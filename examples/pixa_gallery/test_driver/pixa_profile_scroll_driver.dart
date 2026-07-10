import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  await integrationDriver(
    responseDataCallback: (Map<String, dynamic>? data) {
      return writeResponseData(
        data,
        testOutputFilename: 'pixa_profile_scroll_raw',
        destinationDirectory: '../../build/reports',
      );
    },
    writeResponseOnFailure: true,
  );
}
