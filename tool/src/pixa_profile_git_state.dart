import 'dart:convert';

/// Classifies Git porcelain output while honoring policy-local planning files.
String classifyPixaProfileGitTreeState(String porcelain) {
  final Iterable<String> relevant = const LineSplitter()
      .convert(porcelain)
      .where((String line) => line.isNotEmpty)
      .where((String line) => !_isPolicyLocalUntrackedPath(line));
  return relevant.isEmpty ? 'clean' : 'dirty';
}

bool _isPolicyLocalUntrackedPath(String line) {
  if (!line.startsWith('?? ')) {
    return false;
  }
  final String path = line.substring(3);
  return path == 'AGENTS.md' ||
      path == 'GOALS.md' ||
      path == 'REF.md' ||
      path == '.third/' ||
      path.startsWith('.third/') ||
      path == '.thirdd/' ||
      path.startsWith('.thirdd/') ||
      path == 'docs/' ||
      path.startsWith('docs/');
}
