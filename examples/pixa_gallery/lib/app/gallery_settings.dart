import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// App-level user preferences persisted in a small JSON file.
///
/// Acts as a [ChangeNotifier] so the app can react to preference changes
/// (theme mode, gallery defaults, runtime behaviour) in real time.
class GallerySettings extends ChangeNotifier {
  GallerySettings._(this._file, this._values);

  static const String _fileName = 'pixa_settings.json';

  static GallerySettings? _instance;

  /// Gets the singleton instance, loading preferences on first access.
  static Future<GallerySettings> instance() async {
    if (_instance != null) {
      return _instance!;
    }
    final Directory directory = await getApplicationSupportDirectory();
    final File file = File(
      '${directory.path}${Platform.pathSeparator}$_fileName',
    );
    _instance = GallerySettings._(file, await _readValues(file));
    return _instance!;
  }

  final File _file;
  final Map<String, Object?> _values;
  bool _muteNotifications = false;

  /// Updates a value and notifies listeners (unless [batchUpdate] is active).
  void _put(String key, Object? value) {
    _values[key] = value;
    _writeValues();
    if (!_muteNotifications) {
      notifyListeners();
    }
  }

  /// Runs [fn] without notifying on every intermediate write, then notifies
  /// once at the end. Use when several settings change atomically.
  void batchUpdate(VoidCallback fn) {
    _muteNotifications = true;
    try {
      fn();
    } finally {
      _muteNotifications = false;
      notifyListeners();
    }
  }

  // --- Values ---

  /// 'system', 'light', or 'dark'
  String get themeMode => _stringValue('themeMode', 'system');
  set themeMode(String v) => _put('themeMode', v);

  /// Default image source key.
  String get defaultSource => _stringValue('defaultSource', 'nekosia');
  set defaultSource(String v) => _put('defaultSource', v);

  /// Default gallery tile target row height.
  double get targetRowHeight => _doubleValue('targetRowHeight', 180.0);
  set targetRowHeight(double v) => _put('targetRowHeight', v);

  /// Whether Runtime page auto-refreshes.
  bool get runtimeAutoRefresh => _boolValue('runtimeAutoRefresh', true);
  set runtimeAutoRefresh(bool v) => _put('runtimeAutoRefresh', v);

  /// Learn page collapsed groups (persisted set of group titles).
  List<String> get collapsedGroups => _stringListValue('collapsedGroups');
  set collapsedGroups(List<String> v) => _put('collapsedGroups', v);

  /// Flushes pending writes to disk.
  Future<void> save() async => _writeValues();

  String _stringValue(String key, String defaultValue) {
    final Object? value = _values[key];
    return value is String ? value : defaultValue;
  }

  double _doubleValue(String key, double defaultValue) {
    final Object? value = _values[key];
    return value is num ? value.toDouble() : defaultValue;
  }

  bool _boolValue(String key, bool defaultValue) {
    final Object? value = _values[key];
    return value is bool ? value : defaultValue;
  }

  List<String> _stringListValue(String key) {
    final Object? value = _values[key];
    if (value is! List<Object?>) {
      return const <String>[];
    }
    return List<String>.unmodifiable(value.whereType<String>());
  }

  void _writeValues() {
    _file.parent.createSync(recursive: true);
    const JsonEncoder encoder = JsonEncoder.withIndent('  ');
    _file.writeAsStringSync('${encoder.convert(_values)}\n', flush: true);
  }

  static Future<Map<String, Object?>> _readValues(File file) async {
    if (!file.existsSync()) {
      return <String, Object?>{};
    }
    final Object? decoded = const JsonDecoder().convert(
      await file.readAsString(),
    );
    if (decoded is! Map) {
      throw const FormatException('Pixa gallery settings must be a JSON map.');
    }
    final values = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in decoded.entries) {
      final key = entry.key;
      if (key is String) {
        values[key] = entry.value;
      }
    }
    return values;
  }
}
