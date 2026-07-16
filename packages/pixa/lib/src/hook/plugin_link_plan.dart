// ignore_for_file: public_member_api_docs

part of 'plugin_plan.dart';

final class PixaRuntimePluginLinkPlan {
  const PixaRuntimePluginLinkPlan({
    this.searchPaths = const <String>[],
    this.staticLibraries = const <String>[],
    this.dynamicLibraries = const <String>[],
    this.frameworks = const <String>[],
    this.linkArgs = const <String>[],
  });

  const PixaRuntimePluginLinkPlan.empty() : this();

  factory PixaRuntimePluginLinkPlan.fromJson(
    Map<String, Object?>? json, {
    Uri? baseUri,
  }) {
    if (json == null) {
      return const PixaRuntimePluginLinkPlan.empty();
    }
    return PixaRuntimePluginLinkPlan(
      searchPaths: _optionalStringList(json, 'searchPaths')
          .map((String path) => _resolveBuildPath(path, baseUri))
          .toList(growable: false),
      staticLibraries: _optionalStringList(json, 'staticLibraries'),
      dynamicLibraries: _optionalStringList(json, 'dynamicLibraries'),
      frameworks: _optionalStringList(json, 'frameworks'),
      linkArgs: _optionalStringList(json, 'linkArgs'),
    );
  }

  final List<String> searchPaths;
  final List<String> staticLibraries;
  final List<String> dynamicLibraries;
  final List<String> frameworks;
  final List<String> linkArgs;

  bool get isNotEmpty {
    return searchPaths.isNotEmpty ||
        staticLibraries.isNotEmpty ||
        dynamicLibraries.isNotEmpty ||
        frameworks.isNotEmpty ||
        linkArgs.isNotEmpty;
  }

  void validate() {
    _validateLinkValues(searchPaths, 'link.searchPaths');
    _validateLinkValues(staticLibraries, 'link.staticLibraries');
    _validateLinkValues(dynamicLibraries, 'link.dynamicLibraries');
    _validateLinkValues(frameworks, 'link.frameworks');
    _validateLinkValues(linkArgs, 'link.linkArgs');
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (searchPaths.isNotEmpty) 'searchPaths': searchPaths,
      if (staticLibraries.isNotEmpty) 'staticLibraries': staticLibraries,
      if (dynamicLibraries.isNotEmpty) 'dynamicLibraries': dynamicLibraries,
      if (frameworks.isNotEmpty) 'frameworks': frameworks,
      if (linkArgs.isNotEmpty) 'linkArgs': linkArgs,
    };
  }
}
