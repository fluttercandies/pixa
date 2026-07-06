import 'dart:convert';
import 'dart:io';

import 'image_source_factory.dart';

/// Fetches JSON metadata for the example source layer.
Future<Object?> fetchJson(
  Uri uri, {
  Map<String, String> headers = const <String, String>{},
}) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final HttpClientRequest request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.userAgentHeader, 'Pixa Gallery Example');
    for (final MapEntry<String, String> header in headers.entries) {
      request.headers.set(header.key, header.value);
    }
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 20),
    );
    final String body = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw ImageSourceException('HTTP ${response.statusCode}');
    }
    return const JsonDecoder().convert(body);
  } finally {
    client.close(force: true);
  }
}
