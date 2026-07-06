import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as allocator;

import '../failure.dart';
import '../progress.dart';
import '../request.dart';
import '../source.dart';
import 'runtime_binary.dart';

/// Encoded bytes loaded by the Rust pipeline.
final class PixaRuntimeLoadResult {
  /// Creates a runtime load result.
  const PixaRuntimeLoadResult(this.buffer);

  /// Creates a load result from a sendable isolate message.
  factory PixaRuntimeLoadResult.fromMessage(PixaRuntimeLoadMessage message) {
    return PixaRuntimeLoadResult(
      PixaRuntimeOwnedBuffer.fromAddress(message.handleAddress, message.length),
    );
  }

  /// Owned runtime buffer.
  final PixaRuntimeOwnedBuffer buffer;

  /// Encoded image bytes.
  Uint8List get bytes => buffer.bytes;

  /// Releases the runtime buffer.
  void dispose() => buffer.dispose();
}

/// Runtime-owned RGBA pixels decoded from an encoded runtime buffer.
final class PixaRuntimeRgbaImage {
  PixaRuntimeRgbaImage._({
    required this.buffer,
    required this.width,
    required this.height,
    required this.rowBytes,
  });

  /// Runtime-owned RGBA byte buffer.
  final PixaRuntimeOwnedBuffer buffer;

  /// Decoded pixel width.
  final int width;

  /// Decoded pixel height.
  final int height;

  /// Number of bytes per row.
  final int rowBytes;

  /// Borrowed immutable RGBA bytes view.
  Uint8List get bytes => buffer.bytes;

  /// Releases the runtime RGBA buffer immediately.
  void dispose() => buffer.dispose();
}

/// Sendable runtime load result payload.
final class PixaRuntimeLoadMessage {
  /// Creates a runtime load result message.
  const PixaRuntimeLoadMessage({
    required this.handleAddress,
    required this.length,
    this.dartToRuntimeInputCopies = 0,
    this.dartToRuntimeInputBytesCopied = 0,
  });

  /// Opaque Runtime-owned-buffer handle address.
  final int handleAddress;

  /// Encoded byte length.
  final int length;

  /// Number of Dart-owned input buffers copied into runtime call memory.
  final int dartToRuntimeInputCopies;

  /// Total input bytes copied into runtime call memory.
  final int dartToRuntimeInputBytesCopied;
}

/// Runtime-owned encoded byte buffer with finalizer-backed release.
final class PixaRuntimeOwnedBuffer implements Finalizable {
  PixaRuntimeOwnedBuffer._(this._handle, this.length) {
    if (_handle == nullptr) {
      throw StateError('runtime buffer handle is null.');
    }
    final int runtimeLength = _ownedBufferLen(_handle);
    if (runtimeLength != length) {
      _ownedBufferFree(_handle);
      throw StateError('runtime buffer length mismatch.');
    }
    _finalizer.attach(this, _handle, detach: this, externalSize: length);
  }

  /// Creates a buffer owner from a runtime handle address.
  factory PixaRuntimeOwnedBuffer.fromAddress(int handleAddress, int length) {
    if (handleAddress == 0) {
      throw StateError('runtime buffer handle address is zero.');
    }
    if (length < 0) {
      throw StateError('runtime buffer length is negative.');
    }
    return PixaRuntimeOwnedBuffer._(
      Pointer<Void>.fromAddress(handleAddress),
      length,
    );
  }

  /// Takes ownership of a runtime byte buffer returned by the runtime ABI.
  factory PixaRuntimeOwnedBuffer.takePointer(
    Pointer<Uint8> pointer,
    int length,
  ) {
    if (length < 0) {
      throw StateError('runtime buffer length is negative.');
    }
    if (pointer == nullptr) {
      throw StateError('runtime buffer pointer is null.');
    }
    final Pointer<Void> handle = _ownedBufferCreate(pointer, length);
    if (handle == nullptr) {
      _bufferFree(pointer, length);
      throw StateError('Failed to create runtime buffer handle.');
    }
    return PixaRuntimeOwnedBuffer._(handle, length);
  }

  static final NativeFinalizer _finalizer = NativeFinalizer(
    Native.addressOf(_ownedBufferFree),
  );

  final Pointer<Void> _handle;

  /// Byte length.
  final int length;

  Uint8List? _bytes;
  bool _isDisposed = false;

  /// Borrowed typed view. It is invalid after [dispose].
  Uint8List get bytes {
    if (_isDisposed) {
      throw StateError('runtime buffer has already been released.');
    }
    return _bytes ??= _createBytesView();
  }

  /// Releases runtime memory immediately.
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _bytes = null;
    _finalizer.detach(this);
    _ownedBufferFree(_handle);
  }

  /// Decodes this encoded buffer into a Runtime-owned RGBA display buffer.
  PixaRuntimeRgbaImage decodeRgba({
    required int maxDecodedPixels,
    required int maxOutputBytes,
  }) {
    if (_isDisposed) {
      throw StateError('runtime buffer has already been released.');
    }
    if (maxDecodedPixels <= 0) {
      throw RangeError.value(
        maxDecodedPixels,
        'maxDecodedPixels',
        'must be greater than zero',
      );
    }
    if (maxOutputBytes <= 0) {
      throw RangeError.value(
        maxOutputBytes,
        'maxOutputBytes',
        'must be greater than zero',
      );
    }
    final Pointer<Uint32> width = allocator.calloc<Uint32>();
    final Pointer<Uint32> height = allocator.calloc<Uint32>();
    final Pointer<UintPtr> rowBytes = allocator.calloc<UintPtr>();
    final Pointer<UintPtr> outLen = allocator.calloc<UintPtr>();
    final Pointer<Pointer<Uint8>> errorPtr = allocator.calloc<Pointer<Uint8>>();
    final Pointer<UintPtr> errorLen = allocator.calloc<UintPtr>();
    try {
      final Pointer<Void> output = _decodeRgbaFromOwnedBuffer(
        _handle,
        maxDecodedPixels,
        maxOutputBytes,
        width,
        height,
        rowBytes,
        outLen,
        errorPtr,
        errorLen,
      );
      if (output == nullptr) {
        throw _runtimeFailure(errorPtr.value, errorLen.value);
      }
      return PixaRuntimeRgbaImage._(
        buffer: PixaRuntimeOwnedBuffer.fromAddress(
          output.address,
          outLen.value,
        ),
        width: width.value,
        height: height.value,
        rowBytes: rowBytes.value,
      );
    } finally {
      allocator.calloc.free(width);
      allocator.calloc.free(height);
      allocator.calloc.free(rowBytes);
      allocator.calloc.free(outLen);
      allocator.calloc.free(errorPtr);
      allocator.calloc.free(errorLen);
    }
  }

  Uint8List _createBytesView() {
    if (length == 0) {
      return Uint8List(0);
    }
    final Pointer<Uint8> data = _ownedBufferData(_handle);
    if (data == nullptr) {
      throw StateError('runtime buffer data pointer is null.');
    }
    return data.asTypedList(length).asUnmodifiableView();
  }
}

/// runtime progress drain result.
final class PixaRuntimeProgressDrain {
  /// Creates a progress drain result.
  const PixaRuntimeProgressDrain({
    required this.droppedEvents,
    required this.events,
  });

  /// Empty drain result.
  static const PixaRuntimeProgressDrain empty = PixaRuntimeProgressDrain(
    droppedEvents: 0,
    events: <PixaRuntimeProgressEvent>[],
  );

  /// Number of events dropped by bounded runtime buffering.
  final int droppedEvents;

  /// Drained runtime progress events.
  final List<PixaRuntimeProgressEvent> events;
}

/// runtime progress event payload.
final class PixaRuntimeProgressEvent {
  /// Creates a runtime progress event.
  const PixaRuntimeProgressEvent({
    required this.stage,
    required this.name,
    required this.timestampMs,
    this.receivedBytes,
    this.expectedBytes,
    this.message,
    this.previewBuffer,
  });

  /// Stage name from Rust.
  final String stage;

  /// Stable event name.
  final String name;

  /// Received byte count.
  final int? receivedBytes;

  /// Expected byte count.
  final int? expectedBytes;

  /// Redacted message.
  final String? message;

  /// Optional runtime-owned progressive preview buffer.
  final PixaRuntimeOwnedBuffer? previewBuffer;

  /// runtime event timestamp.
  final int timestampMs;
}

/// runtime progress session backed by a bounded Rust queue.
final class PixaRuntimeProgressSession {
  PixaRuntimeProgressSession._(this.id);

  /// Creates a runtime progress session.
  factory PixaRuntimeProgressSession.create() {
    final int id = _progressSessionCreate();
    if (id == 0) {
      throw StateError('Failed to create runtime progress session.');
    }
    return PixaRuntimeProgressSession._(id);
  }

  /// runtime session id.
  final int id;

  bool _isDisposed = false;

  /// Drains pending runtime events.
  PixaRuntimeProgressDrain drain() {
    if (_isDisposed) {
      return PixaRuntimeProgressDrain.empty;
    }
    final Pointer<UintPtr> outLen = allocator.calloc<UintPtr>();
    try {
      final Pointer<Uint8> ptr = _progressSessionDrain(id, outLen);
      if (ptr == nullptr) {
        return PixaRuntimeProgressDrain.empty;
      }
      final int length = outLen.value;
      try {
        return decodeRuntimeProgressDrainForTest(ptr.asTypedList(length));
      } finally {
        _bufferFree(ptr, length);
      }
    } finally {
      allocator.calloc.free(outLen);
    }
  }

  /// Releases the runtime progress queue.
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _progressSessionFree(id);
  }
}

/// runtime cancellation token shared across Dart isolates through Rust state.
final class PixaRuntimeCancelToken {
  PixaRuntimeCancelToken._(this.id);

  /// Creates a runtime cancellation token.
  factory PixaRuntimeCancelToken.create() {
    final int id = _cancelTokenCreate();
    if (id == 0) {
      throw StateError('Failed to create runtime cancellation token.');
    }
    return PixaRuntimeCancelToken._(id);
  }

  /// runtime token id.
  final int id;

  bool _isDisposed = false;

  /// Requests cancellation.
  void cancel() {
    if (_isDisposed) {
      return;
    }
    _cancelTokenCancel(id);
  }

  /// Releases the token from Rust registry.
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _cancelTokenFree(id);
  }
}

/// Thin wrapper over `pixa_load`.
final class PixaRuntimeLoader {
  /// Creates a runtime loader.
  const PixaRuntimeLoader({required this.rootPath});

  /// Platform cache root path.
  final String rootPath;

  /// Loads encoded bytes through the single Rust runtime.
  PixaRuntimeLoadResult load(PixaRequest request, {Uint8List? inlineBytes}) {
    return loadPrepared(encodeRequest(request), inlineBytes: inlineBytes);
  }

  /// Encodes a Dart request for the Rust runtime binary ABI.
  static Uint8List encodeRequest(PixaRequest request) {
    final _BinaryRequestWriter writer = _BinaryRequestWriter();
    writer.writeMagic();
    _writeSource(writer, request.source);
    writer.writeStringMap(request.headers);
    writer.writeString(request.cacheNamespace);
    writer.writeString(request.cacheKey.value);
    writer.writeString(request.encodedCacheKey.value);
    writer.writeUint32(request.targetSize?.width ?? 0);
    writer.writeUint32(request.targetSize?.height ?? 0);
    writer.writeUint8(_cacheModeCode(request.cachePolicy.mode));
    writer.writeUint8(_priorityCode(request.priority));
    writer.writeBool(request.cachePolicy.privateDiskCache);
    final Duration? ttl = request.cachePolicy.maxAge;
    writer.writeBool(ttl != null);
    writer.writeInt64(ttl?.inMilliseconds ?? 0);
    writer.writeUint64(request.limits.maxEncodedBytes);
    writer.writeUint64(request.limits.maxDecodedPixels);
    writer.writeUint64(request.limits.maxAnimationFrames);
    writer.writeUint64(request.limits.maxAnimationDuration.inMilliseconds);
    writer.writeUint64(request.limits.maxProcessorOutputBytes);
    writer.writeUint64(request.limits.maxRedirects);
    writer.writeUint64(request.limits.timeout.inMilliseconds);
    writer.writeUint64(request.limits.connectTimeout.inMilliseconds);
    writer.writeUint64(request.limits.idleTimeout.inMilliseconds);
    writer.writeBool(request.redirectPolicy.allowCrossHostRedirects);
    writer.writeBool(request.redirectPolicy.allowHttpsToHttp);
    writer.writeUint8(_retryModeCode(request.retryPolicy.mode));
    writer.writeUint64(request.retryPolicy.maxAttempts);
    writer.writeUint64(request.retryPolicy.delay.inMilliseconds);
    writer.writeUint64(request.retryPolicy.jitter.inMilliseconds);
    writer.writeString(_decoderMimeTypeHint(request) ?? '');
    writer.writeString(_decoderFormatIdHint(request) ?? '');
    writer.writeStringList(request.processors);
    return writer.takeBytes();
  }

  /// Loads an already encoded request through the single Rust runtime.
  PixaRuntimeLoadResult loadPrepared(
    Uint8List requestPayload, {
    Uint8List? inlineBytes,
    int cancelTokenId = 0,
  }) {
    return PixaRuntimeLoadResult.fromMessage(
      loadPreparedMessage(
        requestPayload,
        inlineBytes: inlineBytes,
        cancelTokenId: cancelTokenId,
      ),
    );
  }

  /// Loads an encoded request and returns a sendable runtime handle message.
  PixaRuntimeLoadMessage loadPreparedMessage(
    Uint8List requestPayload, {
    Uint8List? inlineBytes,
    int cancelTokenId = 0,
    int progressSessionId = 0,
  }) {
    final _RuntimeInputCopyCounter copyCounter = _RuntimeInputCopyCounter();
    return _withUtf8(rootPath, (Pointer<Uint8> rootPtr, int rootLen) {
      return _withBytes(requestPayload, (
        Pointer<Uint8> requestPtr,
        int requestLen,
      ) {
        return _withBytes(inlineBytes, (
          Pointer<Uint8> inlinePtr,
          int inlineLen,
        ) {
          final Pointer<UintPtr> outLen = allocator.calloc<UintPtr>();
          final Pointer<Pointer<Uint8>> errorPtr = allocator
              .calloc<Pointer<Uint8>>();
          final Pointer<UintPtr> errorLen = allocator.calloc<UintPtr>();
          try {
            final Pointer<Void> handle = _runtimeLoadHandle(
              rootPtr,
              rootLen,
              requestPtr,
              requestLen,
              inlinePtr,
              inlineLen,
              cancelTokenId,
              progressSessionId,
              outLen,
              errorPtr,
              errorLen,
            );
            if (handle == nullptr) {
              throw _runtimeFailure(errorPtr.value, errorLen.value);
            }
            final int length = outLen.value;
            return PixaRuntimeLoadMessage(
              handleAddress: handle.address,
              length: length,
              dartToRuntimeInputCopies: copyCounter.copies,
              dartToRuntimeInputBytesCopied: copyCounter.bytesCopied,
            );
          } finally {
            allocator.calloc.free(outLen);
            allocator.calloc.free(errorPtr);
            allocator.calloc.free(errorLen);
          }
        }, copyCounter: copyCounter);
      }, copyCounter: copyCounter);
    }, copyCounter: copyCounter);
  }
}

/// Decodes runtime progress drain payloads from the internal binary ABI.
PixaRuntimeProgressDrain decodeRuntimeProgressDrainForTest(Uint8List bytes) {
  try {
    final PixaRuntimeBinaryReader reader = PixaRuntimeBinaryReader(bytes);
    if (!reader.readMagic(0x50, 0x58, 0x50, 0x31)) {
      return PixaRuntimeProgressDrain.empty;
    }
    final int droppedEvents = reader.readUint64();
    final int eventCount = reader.readUint32();
    final List<PixaRuntimeProgressEvent> events = <PixaRuntimeProgressEvent>[];
    for (int index = 0; index < eventCount; index++) {
      final int stageCode = reader.readUint8();
      final String name = reader.readString();
      final int flags = reader.readUint8();
      if (flags & ~0x0f != 0) {
        throw const FormatException('Unknown runtime progress event flags.');
      }
      final int? receivedBytes = flags & 0x01 == 0 ? null : reader.readUint64();
      final int? expectedBytes = flags & 0x02 == 0 ? null : reader.readUint64();
      final int timestampMs = reader.readInt64();
      final String? message = flags & 0x04 == 0 ? null : reader.readString();
      final PixaRuntimeOwnedBuffer? previewBuffer;
      if (flags & 0x08 == 0) {
        previewBuffer = null;
      } else {
        final int handleAddress = reader.readUint64();
        final int length = reader.readUint64();
        previewBuffer = PixaRuntimeOwnedBuffer.fromAddress(
          handleAddress,
          length,
        );
      }
      events.add(
        PixaRuntimeProgressEvent(
          stage: _progressStageName(stageCode),
          name: name,
          receivedBytes: receivedBytes,
          expectedBytes: expectedBytes,
          message: message,
          previewBuffer: previewBuffer,
          timestampMs: timestampMs,
        ),
      );
    }
    if (!reader.isComplete) {
      return PixaRuntimeProgressDrain.empty;
    }
    return PixaRuntimeProgressDrain(
      droppedEvents: droppedEvents,
      events: events,
    );
  } on FormatException {
    return PixaRuntimeProgressDrain.empty;
  }
}

String _progressStageName(int code) {
  return switch (code) {
    0 => 'request',
    1 => 'cache_lookup',
    2 => 'fetch',
    3 => 'decode',
    4 => 'process',
    5 => 'cache_write',
    6 => 'complete',
    7 => 'cancel',
    _ => throw const FormatException('Unknown runtime progress stage.'),
  };
}

void _writeSource(_BinaryRequestWriter writer, PixaSource source) {
  switch (source) {
    case PixaNetworkSource(:final uri):
      writer.writeUint8(0);
      writer.writeString(uri.toString());
    case PixaFileSource(:final path):
      writer.writeUint8(1);
      writer.writeString(path);
    case PixaExifThumbnailSource(:final path):
      writer.writeUint8(4);
      writer.writeString(path);
    case PixaMemorySource(:final id):
      writer.writeUint8(2);
      writer.writeString(id);
    case PixaBytesSource(:final id):
      writer.writeUint8(2);
      writer.writeString(id ?? 'bytes');
    case PixaAssetSource(:final name, :final package):
      writer.writeUint8(3);
      writer.writeString(package == null ? name : 'packages/$package/$name');
    case PixaCustomSource(:final id):
      writer.writeUint8(2);
      writer.writeString(id);
    case PixaRuntimePluginSource(:final sourceKind, :final locator):
      writer.writeUint8(5);
      writer.writeString(sourceKind);
      writer.writeString(locator);
  }
}

int _cacheModeCode(PixaCacheMode mode) {
  return switch (mode) {
    PixaCacheMode.noStore => 0,
    PixaCacheMode.memoryOnly => 1,
    PixaCacheMode.diskOnly => 2,
    PixaCacheMode.memoryAndDisk => 3,
    PixaCacheMode.cacheOnly => 4,
    PixaCacheMode.networkOnly => 5,
    PixaCacheMode.refresh => 6,
    PixaCacheMode.staleWhileRevalidate => 7,
  };
}

int _priorityCode(PixaPriority priority) {
  return switch (priority) {
    PixaPriority.low => 0,
    PixaPriority.normal => 1,
    PixaPriority.high => 2,
    PixaPriority.immediate => 3,
  };
}

int _retryModeCode(PixaRetryMode mode) {
  return switch (mode) {
    PixaRetryMode.none => 0,
    PixaRetryMode.fixed => 1,
    PixaRetryMode.exponential => 2,
  };
}

String? _decoderMimeTypeHint(PixaRequest request) {
  final Object? value = request.decoderOptions['mimeType'];
  if (value is! String) {
    return null;
  }
  final String mimeType = value.split(';').first.trim().toLowerCase();
  return mimeType.isEmpty ? null : mimeType;
}

String? _decoderFormatIdHint(PixaRequest request) {
  final Object? value = request.decoderOptions['formatId'];
  if (value is! String) {
    return null;
  }
  final String formatId = value.trim().toLowerCase();
  return formatId.isEmpty ? null : formatId;
}

final class _BinaryRequestWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void writeMagic() {
    _builder.add(<int>[0x50, 0x58, 0x52, 0x31]);
  }

  void writeBool(bool value) {
    writeUint8(value ? 1 : 0);
  }

  void writeUint8(int value) {
    if (value < 0 || value > 0xff) {
      throw RangeError.range(value, 0, 0xff, 'value');
    }
    _builder.add(<int>[value]);
  }

  void writeUint32(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw RangeError.range(value, 0, 0xffffffff, 'value');
    }
    final ByteData data = ByteData(4)..setUint32(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void writeUint64(int value) {
    if (value < 0) {
      throw RangeError.value(value, 'value', 'must be non-negative');
    }
    final ByteData data = ByteData(8)..setUint64(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void writeInt64(int value) {
    final ByteData data = ByteData(8)..setInt64(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void writeString(String value) {
    final Uint8List bytes = utf8.encode(value);
    writeUint32(bytes.length);
    _builder.add(bytes);
  }

  void writeStringMap(Map<String, String> values) {
    writeUint32(values.length);
    for (final MapEntry<String, String> entry in values.entries) {
      writeString(entry.key);
      writeString(entry.value);
    }
  }

  void writeStringList(List<String> values) {
    writeUint32(values.length);
    for (final String value in values) {
      writeString(value);
    }
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

PixaFailure _runtimeFailure(Pointer<Uint8> ptr, int length) {
  try {
    if (ptr == nullptr || length == 0) {
      return PixaFailure(
        requestId: -1,
        stage: PixaStage.request,
        safeMessage: 'runtime image pipeline failed without an error payload.',
        retryability: PixaRetryability.unknown,
      );
    }
    return decodeRuntimeFailureForTest(ptr.asTypedList(length));
  } finally {
    if (ptr != nullptr && length > 0) {
      _bufferFree(ptr, length);
    }
  }
}

/// Decodes runtime failure payloads from the internal binary ABI.
PixaFailure decodeRuntimeFailureForTest(Uint8List bytes) {
  try {
    final PixaRuntimeBinaryReader reader = PixaRuntimeBinaryReader(bytes);
    if (!reader.readMagic(0x50, 0x58, 0x45, 0x31)) {
      return _invalidRuntimeFailure();
    }
    final int stageCode = reader.readUint8();
    final int retryableCode = reader.readUint8();
    final String message = reader.readString();
    if (!reader.isComplete) {
      return _invalidRuntimeFailure();
    }
    return PixaFailure(
      requestId: -1,
      stage: _stageFromCode(stageCode),
      safeMessage: message,
      retryability: _retryabilityFromCode(retryableCode),
    );
  } on FormatException {
    return _invalidRuntimeFailure();
  }
}

PixaFailure _invalidRuntimeFailure() {
  return PixaFailure(
    requestId: -1,
    stage: PixaStage.request,
    safeMessage: 'runtime image pipeline returned an invalid error payload.',
    retryability: PixaRetryability.unknown,
  );
}

PixaStage _stageFromCode(int code) {
  return switch (code) {
    0 => PixaStage.request,
    1 => PixaStage.cacheLookup,
    2 => PixaStage.fetch,
    3 => PixaStage.decode,
    4 => PixaStage.process,
    5 => PixaStage.cacheWrite,
    6 => PixaStage.complete,
    7 => PixaStage.cancel,
    _ => throw const FormatException('Unknown runtime failure stage.'),
  };
}

PixaRetryability _retryabilityFromCode(int code) {
  return switch (code) {
    0 => PixaRetryability.notRetryable,
    1 => PixaRetryability.retryable,
    _ => throw const FormatException('Unknown runtime failure retryability.'),
  };
}

T _withUtf8<T>(
  String value,
  T Function(Pointer<Uint8>, int) operation, {
  _RuntimeInputCopyCounter? copyCounter,
}) {
  return _withBytes(
    Uint8List.fromList(utf8.encode(value)),
    operation,
    copyCounter: copyCounter,
  );
}

T _withBytes<T>(
  Uint8List? bytes,
  T Function(Pointer<Uint8>, int) operation, {
  _RuntimeInputCopyCounter? copyCounter,
}) {
  if (bytes == null || bytes.isEmpty) {
    return operation(nullptr.cast<Uint8>(), 0);
  }
  final Pointer<Uint8> pointer = allocator.calloc<Uint8>(bytes.length);
  try {
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    copyCounter?.record(bytes.length);
    return operation(pointer, bytes.length);
  } finally {
    allocator.calloc.free(pointer);
  }
}

final class _RuntimeInputCopyCounter {
  int copies = 0;
  int bytesCopied = 0;

  void record(int byteCount) {
    copies++;
    bytesCopied += byteCount;
  }
}

@Native<
  Pointer<Void> Function(
    Pointer<Uint8>,
    UintPtr,
    Pointer<Uint8>,
    UintPtr,
    Pointer<Uint8>,
    UintPtr,
    Uint64,
    Uint64,
    Pointer<UintPtr>,
    Pointer<Pointer<Uint8>>,
    Pointer<UintPtr>,
  )
>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_load_handle_with_cancel_and_progress',
  isLeaf: false,
)
external Pointer<Void> _runtimeLoadHandle(
  Pointer<Uint8> rootPtr,
  int rootLen,
  Pointer<Uint8> requestPtr,
  int requestLen,
  Pointer<Uint8> inlineBytesPtr,
  int inlineBytesLen,
  int cancelTokenId,
  int progressSessionId,
  Pointer<UintPtr> outLen,
  Pointer<Pointer<Uint8>> outErrorPtr,
  Pointer<UintPtr> outErrorLen,
);

@Native<Pointer<Void> Function(Pointer<Uint8>, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_owned_buffer_create',
  isLeaf: false,
)
external Pointer<Void> _ownedBufferCreate(Pointer<Uint8> ptr, int len);

@Native<Pointer<Uint8> Function(Pointer<Void>)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_owned_buffer_data',
  isLeaf: true,
)
external Pointer<Uint8> _ownedBufferData(Pointer<Void> handle);

@Native<UintPtr Function(Pointer<Void>)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_owned_buffer_len',
  isLeaf: true,
)
external int _ownedBufferLen(Pointer<Void> handle);

@Native<
  Pointer<Void> Function(
    Pointer<Void>,
    Uint64,
    UintPtr,
    Pointer<Uint32>,
    Pointer<Uint32>,
    Pointer<UintPtr>,
    Pointer<UintPtr>,
    Pointer<Pointer<Uint8>>,
    Pointer<UintPtr>,
  )
>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_decode_rgba_from_owned_buffer',
  isLeaf: false,
)
external Pointer<Void> _decodeRgbaFromOwnedBuffer(
  Pointer<Void> handle,
  int maxDecodedPixels,
  int maxOutputBytes,
  Pointer<Uint32> outWidth,
  Pointer<Uint32> outHeight,
  Pointer<UintPtr> outRowBytes,
  Pointer<UintPtr> outLen,
  Pointer<Pointer<Uint8>> outErrorPtr,
  Pointer<UintPtr> outErrorLen,
);

@Native<Void Function(Pointer<Void>)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_owned_buffer_free',
  isLeaf: false,
)
external void _ownedBufferFree(Pointer<Void> handle);

@Native<Uint64 Function()>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_progress_session_create',
  isLeaf: false,
)
external int _progressSessionCreate();

@Native<Pointer<Uint8> Function(Uint64, Pointer<UintPtr>)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_progress_session_drain',
  isLeaf: false,
)
external Pointer<Uint8> _progressSessionDrain(
  int sessionId,
  Pointer<UintPtr> outLen,
);

@Native<Int32 Function(Uint64)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_progress_session_free',
  isLeaf: false,
)
external int _progressSessionFree(int sessionId);

@Native<Uint64 Function()>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_cancel_token_create',
  isLeaf: false,
)
external int _cancelTokenCreate();

@Native<Int32 Function(Uint64)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_cancel_token_cancel',
  isLeaf: false,
)
external int _cancelTokenCancel(int tokenId);

@Native<Int32 Function(Uint64)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_cancel_token_free',
  isLeaf: false,
)
external int _cancelTokenFree(int tokenId);

@Native<Void Function(Pointer<Uint8>, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_buffer_free',
  isLeaf: false,
)
external void _bufferFree(Pointer<Uint8> ptr, int len);
