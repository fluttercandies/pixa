part of 'plugin_plan.dart';

_PixaRuntimePluginManifestInput _readManifestInput(Uri uri) {
  final File file = File.fromUri(uri);
  if (!file.existsSync()) {
    throw StateError(
      'Pixa runtime plugin manifest does not exist: ${file.path}',
    );
  }
  final Object? decoded = json.decode(file.readAsStringSync());
  if (decoded is! Map<Object?, Object?>) {
    throw StateError('Pixa runtime plugin manifest must be an object.');
  }
  return _PixaRuntimePluginManifestInput(
    _stringMap(decoded),
    baseUri: uri.resolve('.'),
  );
}

Map<String, Object?> _stringMap(Map<Object?, Object?> raw) {
  return raw.map((Object? key, Object? value) {
    if (key is! String) {
      throw StateError('Pixa runtime plugin manifest keys must be strings.');
    }
    return MapEntry<String, Object?>(key, value);
  });
}

String _requiredString(Map<String, Object?> json, String key) {
  final String? value = _optionalString(json, key);
  if (value == null || value.trim().isEmpty) {
    throw StateError('Pixa runtime plugin "$key" must be a non-empty string.');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw StateError('Pixa runtime plugin "$key" must be a string.');
  }
  return value;
}

int? _optionalInt(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! int) {
    throw StateError('Pixa runtime plugin "$key" must be an integer.');
  }
  return value;
}

bool? _optionalBool(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! bool) {
    throw StateError('Pixa runtime plugin "$key" must be a boolean.');
  }
  return value;
}

Map<String, Object?>? _optionalObjectMap(
  Map<String, Object?> json,
  String key,
) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! Map<Object?, Object?>) {
    throw StateError('Pixa runtime plugin "$key" must be an object.');
  }
  return _stringMap(value);
}

List<String> _optionalStringList(Map<String, Object?> json, String key) {
  final Object? raw = json[key];
  if (raw == null) {
    return const <String>[];
  }
  if (raw is! List<Object?>) {
    throw StateError('Pixa runtime plugin "$key" must be a string list.');
  }
  final List<String> values = <String>[];
  for (final Object? value in raw) {
    if (value is! String || value.trim().isEmpty) {
      throw StateError('Pixa runtime plugin "$key" contains an invalid value.');
    }
    values.add(value);
  }
  return List<String>.unmodifiable(values);
}

Set<String> _optionalStringSet(Map<String, Object?> json, String key) {
  return Set<String>.unmodifiable(_optionalStringList(json, key));
}

Set<String> _stringSet(Map<String, Object?> json, String key) {
  final Object? raw = json[key];
  if (raw is! List<Object?>) {
    throw StateError('Pixa runtime plugin "$key" must be a string list.');
  }
  final Set<String> values = <String>{};
  for (final Object? value in raw) {
    if (value is! String || value.trim().isEmpty) {
      throw StateError('Pixa runtime plugin "$key" contains an invalid value.');
    }
    values.add(value);
  }
  return values;
}

List<String> _sortedList(Set<String> values) {
  return values.toList()..sort();
}

String _resolveBuildPath(String value, Uri? baseUri) {
  final Uri? parsed = Uri.tryParse(value);
  if (parsed != null && parsed.isAbsolute) {
    return value;
  }
  if (_looksAbsoluteFilePath(value) || baseUri == null) {
    return value;
  }
  return baseUri.resolve(value).toFilePath();
}

bool _looksAbsoluteFilePath(String value) {
  return value.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
}

void _validateLinkValues(Iterable<String> values, String field) {
  for (final String value in values) {
    if (value.trim().isEmpty ||
        value.contains('\n') ||
        value.contains('\r') ||
        value.contains('\u0000')) {
      throw StateError('Pixa runtime plugin $field contains an invalid value.');
    }
  }
}
