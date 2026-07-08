import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pixa/pixa.dart';

import '../pixa/pixa_recipes.dart';
import '../widgets/neu_controls.dart';
import 'display_previews.dart';

/// Demonstrates [PixaImage.file] loading an image from the device filesystem.
///
/// The recipe materialises a bundled asset into a temp file at build time so
/// the file source path is real, then hands it to `PixaImage.file`.
class FileSourcePreview extends StatefulWidget {
  const FileSourcePreview({super.key});

  @override
  State<FileSourcePreview> createState() => _FileSourcePreviewState();
}

class _FileSourcePreviewState extends State<FileSourcePreview> {
  String? _path;
  String? _error;

  @override
  void initState() {
    super.initState();
    _materialise();
  }

  Future<void> _materialise() async {
    try {
      final bytes = await rootBundle.load('assets/pixa_sample.ppm');
      final dir = await Directory.systemTemp.createTemp('pixa-file-src-');
      final file = File('${dir.path}/sample.ppm');
      await file.writeAsBytes(bytes.buffer.asUint8List());
      if (mounted) {
        setState(() => _path = file.path);
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      height: 150,
      child: _path == null
          ? Center(
              child: _error == null
                  ? const NeuSpinner(size: 22)
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Could not materialise file: $_error',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
            )
          : PixaImage.file(
              _path!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              semanticLabel: 'PixaImage.file local image source demo',
              placeholder: learnPlaceholder(context),
              errorBuilder: pixaErrorBuilder,
              transitionDuration: kLearnTransitionDuration,
            ),
    );
  }
}

/// Demonstrates [PixaImage.memory] loading from a runtime [Uint8List].
class MemorySourcePreview extends StatefulWidget {
  const MemorySourcePreview({super.key});

  @override
  State<MemorySourcePreview> createState() => _MemorySourcePreviewState();
}

class _MemorySourcePreviewState extends State<MemorySourcePreview> {
  Uint8List? _bytes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await rootBundle.load('assets/pixa_sample.ppm');
      if (mounted) {
        setState(() => _bytes = bytes.buffer.asUint8List());
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      height: 150,
      child: _bytes == null
          ? Center(
              child: _error == null
                  ? const NeuSpinner(size: 22)
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Could not load memory bytes: $_error',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
            )
          : PixaImage.memory(
              'learn-memory-sample',
              _bytes!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              semanticLabel: 'PixaImage.memory runtime Uint8List demo',
              placeholder: learnPlaceholder(context),
              errorBuilder: pixaErrorBuilder,
              transitionDuration: kLearnTransitionDuration,
            ),
    );
  }
}

/// Demonstrates [PixaImage.bytes] loading raw encoded bytes with an explicit
/// format hint.
class BytesSourcePreview extends StatefulWidget {
  const BytesSourcePreview({super.key});

  @override
  State<BytesSourcePreview> createState() => _BytesSourcePreviewState();
}

class _BytesSourcePreviewState extends State<BytesSourcePreview> {
  Uint8List? _bytes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await rootBundle.load('assets/pixa_sample.ppm');
      if (mounted) {
        setState(() => _bytes = bytes.buffer.asUint8List());
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      height: 150,
      child: _bytes == null
          ? Center(
              child: _error == null
                  ? const NeuSpinner(size: 22)
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Could not load bytes: $_error',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
            )
          : PixaImage.bytes(
              _bytes!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              semanticLabel: 'PixaImage.bytes raw encoded bytes demo',
              placeholder: learnPlaceholder(context),
              errorBuilder: pixaErrorBuilder,
              transitionDuration: kLearnTransitionDuration,
            ),
    );
  }
}
