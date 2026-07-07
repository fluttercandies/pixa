import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa_plugins.dart';
import 'package:pixa/pixa_debug.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/src/image_format.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PixaProvider rejects decoded image bomb dimensions', () async {
    final Directory cacheRoot = await Directory.systemTemp.createTemp(
      'pixa-provider-test-',
    );
    addTearDown(() => cacheRoot.delete(recursive: true));
    await Pixa.configure(PixaConfig(cacheRootPath: cacheRoot.path));
    final PixaProvider provider = PixaProvider(
      request: PixaRequest(
        source: PixaSource.custom('oversized', () async => _minimalGif()),
        cachePolicy: const PixaCachePolicy.noStore(),
        limits: const PixaRequestLimits(maxDecodedPixels: 100),
      ),
    );
    final ImageStreamCompleter completer = provider.loadImage(provider, (
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) async {
      getTargetSize!(1000, 1000);
      throw StateError('decode limit should throw before codec creation');
    });
    final Completer<Object> errorCompleter = Completer<Object>();
    final ImageStreamListener listener = ImageStreamListener(
      (ImageInfo image, bool synchronousCall) {
        fail('oversized decoded image should not produce an ImageInfo');
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!errorCompleter.isCompleted) {
          errorCompleter.complete(error);
        }
      },
    );

    completer.addListener(listener);
    final Object error = await errorCompleter.future.timeout(
      const Duration(seconds: 5),
    );
    completer.removeListener(listener);

    expect(error, isA<PixaFailure>());
    final PixaFailure failure = error as PixaFailure;
    expect(failure.stage, PixaStage.decode);
    expect(failure.retryability, PixaRetryability.notRetryable);
    expect(failure.safeMessage, contains('max decoded pixels 100'));
  });

  test('PixaProvider emits decode failure timing span', () async {
    final Directory cacheRoot = await Directory.systemTemp.createTemp(
      'pixa-provider-decode-test-',
    );
    addTearDown(() => cacheRoot.delete(recursive: true));
    final List<PixaEvent> events = <PixaEvent>[];
    await Pixa.configure(
      PixaConfig(
        cacheRootPath: cacheRoot.path,
        observers: <PixaObserver>[PixaCallbackObserver(events.add)],
      ),
    );
    final PixaProvider provider = PixaProvider(
      request: PixaRequest(
        source: PixaSource.custom('decode-failure', () async => _minimalGif()),
        cachePolicy: const PixaCachePolicy.noStore(),
      ),
    );
    final ImageStreamCompleter completer = provider.loadImage(provider, (
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) async {
      throw StateError('decoder failed');
    });
    final Completer<Object> errorCompleter = Completer<Object>();
    final ImageStreamListener listener = ImageStreamListener(
      (ImageInfo image, bool synchronousCall) {
        fail('decode failure should not produce an ImageInfo');
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!errorCompleter.isCompleted) {
          errorCompleter.complete(error);
        }
      },
    );

    completer.addListener(listener);
    await errorCompleter.future.timeout(const Duration(seconds: 5));
    completer.removeListener(listener);

    final int startIndex = events.indexWhere(
      (PixaEvent event) => event.name == 'decode.start',
    );
    final int failureIndex = events.indexWhere(
      (PixaEvent event) => event.name == 'decode.failure',
    );

    expect(startIndex, isNonNegative);
    expect(failureIndex, greaterThan(startIndex));
    final PixaEvent start = events[startIndex];
    expect(start.attributes['backend'], 'engine');
    expect(start.attributes['execution'], 'flutter');
    expect(start.attributes['selector'], 'pixa-display-decoder-v1');
    final PixaEvent failure = events[failureIndex];
    expect(failure.stage, PixaStage.decode);
    expect(failure.attributes['backend'], 'engine');
    expect(failure.attributes['execution'], 'flutter');
    expect(failure.attributes['selector'], 'pixa-display-decoder-v1');
    expect(failure.durationMicros, isNotNull);
    expect(failure.durationMicros, greaterThanOrEqualTo(0));
  });

  test(
    'PixaProvider rejects unknown payload before Flutter engine decode',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-unknown-format-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      final List<PixaEvent> events = <PixaEvent>[];
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          observers: <PixaObserver>[PixaCallbackObserver(events.add)],
        ),
      );
      var engineDecodeCalls = 0;
      final PixaProvider provider = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'unknown-format',
            () async => Uint8List.fromList('not an image'.codeUnits),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
      );
      final ImageStreamCompleter completer = provider.loadImage(provider, (
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        engineDecodeCalls += 1;
        throw StateError(
          'unknown payload must not reach Flutter engine decode',
        );
      });
      final Completer<Object> errorCompleter = Completer<Object>();
      final ImageStreamListener listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          fail('unknown payload should not produce an ImageInfo');
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!errorCompleter.isCompleted) {
            errorCompleter.complete(error);
          }
        },
      );

      completer.addListener(listener);
      final Object error = await errorCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      completer.removeListener(listener);

      expect(engineDecodeCalls, 0);
      expect(error, isA<PixaFailure>());
      final PixaFailure failure = error as PixaFailure;
      expect(failure.stage, PixaStage.decode);
      expect(failure.retryability, PixaRetryability.notRetryable);
      expect(failure.safeMessage, contains('supported image signature'));
    },
  );

  test(
    'PixaProvider rejects mismatched built-in MIME before Flutter engine decode',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-mismatched-format-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      await Pixa.configure(PixaConfig(cacheRootPath: cacheRoot.path));
      var engineDecodeCalls = 0;
      final PixaProvider provider = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'mismatched-format',
            () async => Uint8List.fromList('not a png'.codeUnits),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
          decoderOptions: const <String, Object?>{'mimeType': 'image/png'},
        ),
      );
      final ImageStreamCompleter completer = provider.loadImage(provider, (
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        engineDecodeCalls += 1;
        throw StateError(
          'mismatched built-in MIME must not reach Flutter engine decode',
        );
      });
      final Completer<Object> errorCompleter = Completer<Object>();
      final ImageStreamListener listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          fail('mismatched built-in MIME should not produce an ImageInfo');
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!errorCompleter.isCompleted) {
            errorCompleter.complete(error);
          }
        },
      );

      completer.addListener(listener);
      final Object error = await errorCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      completer.removeListener(listener);

      expect(engineDecodeCalls, 0);
      expect(error, isA<PixaFailure>());
      final PixaFailure failure = error as PixaFailure;
      expect(failure.stage, PixaStage.decode);
      expect(failure.retryability, PixaRetryability.notRetryable);
      expect(failure.safeMessage, contains('supported image signature'));
    },
  );

  test(
    'PixaProvider rejects plugin output with no display backend before engine',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-plugin-unknown-format-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      final List<PixaEvent> events = <PixaEvent>[];
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          plugins: const <PixaPlugin>[_UnknownTranscodePlugin()],
          observers: <PixaObserver>[PixaCallbackObserver(events.add)],
        ),
      );
      var engineDecodeCalls = 0;
      final PixaProvider provider = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'plugin-unknown-format',
            () async => _minimalGif(),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
          decoderOptions: const <String, Object?>{
            'mimeType': 'image/pixa-unknown-transcode',
          },
          pluginExecutionPolicy:
              const PixaPluginExecutionPolicy.runtimeFirstWithDart(),
        ),
      );
      final ImageStreamCompleter completer = provider.loadImage(provider, (
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        engineDecodeCalls += 1;
        throw StateError(
          'plugin output without a display backend must not reach engine decode',
        );
      });
      final Completer<Object> errorCompleter = Completer<Object>();
      final ImageStreamListener listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          fail('unsupported plugin output should not produce an ImageInfo');
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!errorCompleter.isCompleted) {
            errorCompleter.complete(error);
          }
        },
      );

      completer.addListener(listener);
      final Object error = await errorCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      completer.removeListener(listener);

      expect(engineDecodeCalls, 0);
      expect(error, isA<PixaFailure>());
      final PixaFailure failure = error as PixaFailure;
      expect(failure.stage, PixaStage.decode);
      expect(failure.retryability, PixaRetryability.notRetryable);
      expect(failure.safeMessage, contains('Unsupported image format'));
      final PixaEvent event = events.singleWhere(
        (PixaEvent event) => event.name == 'decode.failure',
      );
      expect(event.stage, PixaStage.decode);
      expect(event.failure, same(failure));
      expect(event.attributes['backend'], 'engine');
      expect(event.attributes['execution'], 'flutter');
    },
  );

  test(
    'PixaProvider displays plugin decoder output using output MIME route',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-plugin-gif-output-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      final List<PixaEvent> events = <PixaEvent>[];
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          plugins: const <PixaPlugin>[_GifTranscodePlugin()],
          observers: <PixaObserver>[PixaCallbackObserver(events.add)],
        ),
      );
      var engineDecodeCalls = 0;
      final PixaProvider provider = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'plugin-gif-output',
            () async => _minimalGif(),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
          decoderOptions: const <String, Object?>{
            'mimeType': 'image/pixa-gif-transcode',
          },
          pluginExecutionPolicy:
              const PixaPluginExecutionPolicy.runtimeFirstWithDart(),
        ),
      );
      final ImageStreamCompleter completer = provider.loadImage(provider, (
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        engineDecodeCalls += 1;
        return ui.instantiateImageCodec(_minimalGif());
      });
      final Completer<ImageInfo> imageCompleter = Completer<ImageInfo>();
      final Completer<Object> errorCompleter = Completer<Object>();
      final ImageStreamListener listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          if (!imageCompleter.isCompleted) {
            imageCompleter.complete(image);
          }
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!errorCompleter.isCompleted) {
            errorCompleter.complete(error);
          }
        },
      );

      completer.addListener(listener);
      final Object result = await Future.any<Object>(<Future<Object>>[
        imageCompleter.future,
        errorCompleter.future,
      ]).timeout(const Duration(seconds: 5));
      completer.removeListener(listener);
      if (result is ImageInfo) {
        result.dispose();
      }

      expect(result, isA<ImageInfo>());
      expect(engineDecodeCalls, 1);
      final PixaEvent start = events.singleWhere(
        (PixaEvent event) => event.name == 'decode.start',
      );
      expect(start.attributes['backend'], 'engine');
      expect(start.attributes['execution'], 'flutter');
    },
  );

  test(
    'PixaProvider displays cached plugin decoder output using payload route',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-plugin-gif-cache-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      final List<PixaEvent> events = <PixaEvent>[];
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          plugins: const <PixaPlugin>[_GifTranscodePlugin()],
          observers: <PixaObserver>[PixaCallbackObserver(events.add)],
        ),
      );
      final PixaRequest request = PixaRequest(
        source: PixaSource.custom(
          'plugin-gif-cache',
          () async => _minimalGif(),
        ),
        cachePolicy: const PixaCachePolicy(mode: PixaCacheMode.memoryOnly),
        decoderOptions: const <String, Object?>{
          'mimeType': 'image/pixa-gif-transcode',
        },
        pluginExecutionPolicy:
            const PixaPluginExecutionPolicy.runtimeFirstWithDart(),
      );
      var engineDecodeCalls = 0;

      Future<Object> loadOnce() async {
        final PixaProvider provider = PixaProvider(request: request);
        final ImageStreamCompleter completer = provider.loadImage(provider, (
          ui.ImmutableBuffer buffer, {
          ui.TargetImageSizeCallback? getTargetSize,
        }) async {
          engineDecodeCalls += 1;
          return ui.instantiateImageCodec(_minimalGif());
        });
        final Completer<ImageInfo> imageCompleter = Completer<ImageInfo>();
        final Completer<Object> errorCompleter = Completer<Object>();
        final ImageStreamListener listener = ImageStreamListener(
          (ImageInfo image, bool synchronousCall) {
            if (!imageCompleter.isCompleted) {
              imageCompleter.complete(image);
            }
          },
          onError: (Object error, StackTrace? stackTrace) {
            if (!errorCompleter.isCompleted) {
              errorCompleter.complete(error);
            }
          },
        );
        completer.addListener(listener);
        final Object result = await Future.any<Object>(<Future<Object>>[
          imageCompleter.future,
          errorCompleter.future,
        ]).timeout(const Duration(seconds: 5));
        completer.removeListener(listener);
        if (result is ImageInfo) {
          result.dispose();
        }
        return result;
      }

      final Object first = await loadOnce();
      final Object second = await loadOnce();

      expect(first, isA<ImageInfo>());
      expect(second, isA<ImageInfo>());
      expect(engineDecodeCalls, 2);
      expect(
        events.where((PixaEvent event) => event.name == 'plugin.decoder.start'),
        hasLength(1),
      );
      expect(
        events.map((PixaEvent event) => event.name),
        containsAll(<String>[
          'cache.decoder.memory.write',
          'cache.decoder.memory.hit',
        ]),
      );
    },
  );

  test(
    'PixaProvider rejects plugin output with mismatched built-in MIME before engine',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-plugin-bad-gif-output-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          plugins: const <PixaPlugin>[_InvalidGifTranscodePlugin()],
        ),
      );
      var engineDecodeCalls = 0;
      final PixaProvider provider = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'plugin-bad-gif-output',
            () async => _minimalGif(),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
          decoderOptions: const <String, Object?>{
            'mimeType': 'image/pixa-invalid-gif-transcode',
          },
          pluginExecutionPolicy:
              const PixaPluginExecutionPolicy.runtimeFirstWithDart(),
        ),
      );
      final ImageStreamCompleter completer = provider.loadImage(provider, (
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        engineDecodeCalls += 1;
        throw StateError(
          'mismatched plugin output MIME must not reach Flutter engine decode',
        );
      });
      final Completer<Object> errorCompleter = Completer<Object>();
      final ImageStreamListener listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          fail('mismatched plugin output should not produce an ImageInfo');
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!errorCompleter.isCompleted) {
            errorCompleter.complete(error);
          }
        },
      );

      completer.addListener(listener);
      final Object error = await errorCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      completer.removeListener(listener);

      expect(engineDecodeCalls, 0);
      expect(error, isA<PixaFailure>());
      final PixaFailure failure = error as PixaFailure;
      expect(failure.stage, PixaStage.decode);
      expect(failure.retryability, PixaRetryability.notRetryable);
      expect(failure.safeMessage, contains('supported image signature'));
    },
  );

  test(
    'PixaProvider suppresses pipeline cancel errors after last listener removal',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-pipeline-cancel-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      await Pixa.configure(PixaConfig(cacheRootPath: cacheRoot.path));

      final FlutterExceptionHandler? previousOnError = FlutterError.onError;
      final List<Object> cancelErrors = <Object>[];
      final List<Object> unexpectedErrors = <Object>[];
      FlutterError.onError = (FlutterErrorDetails details) {
        final Object exception = details.exception;
        if (exception is PixaFailure && exception.stage == PixaStage.cancel) {
          cancelErrors.add(exception);
          return;
        }
        unexpectedErrors.add(exception);
      };
      addTearDown(() {
        FlutterError.onError = previousOnError;
      });

      final Completer<void> fetchStarted = Completer<void>();
      final Completer<Uint8List> pendingBytes = Completer<Uint8List>();
      final List<Object> listenerErrors = <Object>[];
      final PixaProvider provider = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom('pipeline-cancel', () async {
            fetchStarted.complete();
            return pendingBytes.future;
          }),
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
      );
      final ImageStreamCompleter completer = provider.loadImage(provider, (
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        throw StateError('cancelled provider load must not decode');
      });
      final ImageStreamListener listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          fail('cancelled provider load should not produce an image');
        },
        onError: (Object error, StackTrace? stackTrace) {
          listenerErrors.add(error);
        },
      );

      completer.addListener(listener);
      await fetchStarted.future.timeout(const Duration(seconds: 5));
      completer.removeListener(listener);
      pendingBytes.complete(_minimalGif());
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(listenerErrors, isEmpty);
      expect(cancelErrors, isEmpty);
      expect(unexpectedErrors, isEmpty);
    },
  );

  test('PixaProvider limits concurrent Flutter decode callbacks', () async {
    final Directory cacheRoot = await Directory.systemTemp.createTemp(
      'pixa-provider-decode-limit-',
    );
    addTearDown(() => cacheRoot.delete(recursive: true));
    await Pixa.configure(
      PixaConfig(cacheRootPath: cacheRoot.path, decodeConcurrency: 1),
    );

    final Completer<void> firstEntered = Completer<void>();
    final Completer<void> secondEntered = Completer<void>();
    final Completer<void> releaseFirst = Completer<void>();
    var activeDecodes = 0;
    var maxActiveDecodes = 0;
    var decodeCalls = 0;

    Future<ui.Codec> decode(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) async {
      activeDecodes += 1;
      if (activeDecodes > maxActiveDecodes) {
        maxActiveDecodes = activeDecodes;
      }
      decodeCalls += 1;
      if (decodeCalls == 1) {
        firstEntered.complete();
        await releaseFirst.future;
      } else {
        secondEntered.complete();
      }
      activeDecodes -= 1;
      throw StateError('stop decode after concurrency assertion');
    }

    final PixaProvider first = PixaProvider(
      request: PixaRequest(
        source: PixaSource.custom('decode-limit-a', () async => _minimalGif()),
        cachePolicy: const PixaCachePolicy.noStore(),
      ),
    );
    final PixaProvider second = PixaProvider(
      request: PixaRequest(
        source: PixaSource.custom('decode-limit-b', () async => _minimalGif()),
        cachePolicy: const PixaCachePolicy.noStore(),
      ),
    );
    final ImageStreamCompleter firstCompleter = first.loadImage(first, decode);
    final ImageStreamCompleter secondCompleter = second.loadImage(
      second,
      decode,
    );
    final Completer<Object> firstError = Completer<Object>();
    final Completer<Object> secondError = Completer<Object>();
    final ImageStreamListener firstListener = ImageStreamListener(
      (ImageInfo image, bool synchronousCall) {
        fail('first decode should fail after assertion');
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!firstError.isCompleted) {
          firstError.complete(error);
        }
      },
    );
    final ImageStreamListener secondListener = ImageStreamListener(
      (ImageInfo image, bool synchronousCall) {
        fail('second decode should fail after assertion');
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!secondError.isCompleted) {
          secondError.complete(error);
        }
      },
    );

    firstCompleter.addListener(firstListener);
    secondCompleter.addListener(secondListener);
    await firstEntered.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(decodeCalls, 1);
    expect(maxActiveDecodes, 1);

    releaseFirst.complete();
    await secondEntered.future.timeout(const Duration(seconds: 5));
    await Future.wait<Object>(<Future<Object>>[
      firstError.future,
      secondError.future,
    ]).timeout(const Duration(seconds: 5));
    firstCompleter.removeListener(firstListener);
    secondCompleter.removeListener(secondListener);

    expect(decodeCalls, 2);
    expect(maxActiveDecodes, 1);
  });

  test(
    'PixaProvider does not report image errors when gated completion is cancelled',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-completion-cancel-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          decodeConcurrency: 2,
          maxImageCompletionsPerFrame: 1,
        ),
      );

      final FlutterExceptionHandler? previousOnError = FlutterError.onError;
      final List<FlutterErrorDetails> cancelErrors = <FlutterErrorDetails>[];
      final List<FlutterErrorDetails> unexpectedErrors =
          <FlutterErrorDetails>[];
      FlutterError.onError = (FlutterErrorDetails details) {
        final Object exception = details.exception;
        if (exception is PixaFailure && exception.stage == PixaStage.cancel) {
          cancelErrors.add(details);
          return;
        }
        unexpectedErrors.add(details);
      };
      addTearDown(() {
        FlutterError.onError = previousOnError;
      });

      final Completer<void> firstDecoded = Completer<void>();
      final Completer<void> secondDecoded = Completer<void>();

      Future<ui.Codec> firstDecode(
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        final ui.Codec codec = await ui.instantiateImageCodec(_minimalGif());
        firstDecoded.complete();
        return codec;
      }

      Future<ui.Codec> secondDecode(
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        await firstDecoded.future;
        final ui.Codec codec = await ui.instantiateImageCodec(_minimalGif());
        secondDecoded.complete();
        return codec;
      }

      final PixaProvider first = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'completion-cancel-a',
            () async => _minimalGif(),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
      );
      final PixaProvider second = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'completion-cancel-b',
            () async => _minimalGif(),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
      );
      final ImageStreamCompleter firstCompleter = first.loadImage(
        first,
        firstDecode,
      );
      final ImageStreamCompleter secondCompleter = second.loadImage(
        second,
        secondDecode,
      );
      final ImageStreamListener firstListener = ImageStreamListener((
        ImageInfo image,
        bool synchronousCall,
      ) {
        image.dispose();
      });
      final ImageStreamListener secondListener = ImageStreamListener((
        ImageInfo image,
        bool synchronousCall,
      ) {
        image.dispose();
      });

      firstCompleter.addListener(firstListener);
      secondCompleter.addListener(secondListener);
      await secondDecoded.future.timeout(const Duration(seconds: 5));
      secondCompleter.removeListener(secondListener);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      firstCompleter.removeListener(firstListener);

      expect(cancelErrors, isEmpty);
      expect(unexpectedErrors, isEmpty);
    },
  );

  test('PixaProvider paces image completions across frame budget', () async {
    final Directory cacheRoot = await Directory.systemTemp.createTemp(
      'pixa-provider-completion-budget-',
    );
    addTearDown(() => cacheRoot.delete(recursive: true));
    await Pixa.configure(
      PixaConfig(
        cacheRootPath: cacheRoot.path,
        decodeConcurrency: 2,
        maxImageCompletionsPerFrame: 1,
      ),
    );
    await _waitForCompletionGateIdle();

    final Completer<void> firstDecodeReturned = Completer<void>();
    final Completer<void> secondDecodeReturned = Completer<void>();

    Future<ui.Codec> firstDecode(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) async {
      final ui.Codec codec = await ui.instantiateImageCodec(_minimalGif());
      firstDecodeReturned.complete();
      return codec;
    }

    Future<ui.Codec> secondDecode(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) async {
      final ui.Codec codec = await ui.instantiateImageCodec(_minimalGif());
      secondDecodeReturned.complete();
      return codec;
    }

    final PixaProvider first = PixaProvider(
      request: PixaRequest(
        source: PixaSource.custom(
          'completion-budget-a',
          () async => _minimalGif(),
        ),
        cachePolicy: const PixaCachePolicy.noStore(),
      ),
    );
    final PixaProvider second = PixaProvider(
      request: PixaRequest(
        source: PixaSource.custom(
          'completion-budget-b',
          () async => _minimalGif(),
        ),
        cachePolicy: const PixaCachePolicy.noStore(),
      ),
    );
    final ImageStreamCompleter firstCompleter = first.loadImage(
      first,
      firstDecode,
    );
    final ImageStreamCompleter secondCompleter = second.loadImage(
      second,
      secondDecode,
    );
    final Completer<ImageInfo> firstImage = Completer<ImageInfo>();
    final Completer<ImageInfo> secondImage = Completer<ImageInfo>();
    final ImageStreamListener firstListener = ImageStreamListener((
      ImageInfo image,
      bool synchronousCall,
    ) {
      if (!firstImage.isCompleted) {
        firstImage.complete(image);
      } else {
        image.dispose();
      }
    });
    final ImageStreamListener secondListener = ImageStreamListener((
      ImageInfo image,
      bool synchronousCall,
    ) {
      if (!secondImage.isCompleted) {
        secondImage.complete(image);
      } else {
        image.dispose();
      }
    });
    var listenersAttached = false;
    addTearDown(() {
      if (listenersAttached) {
        firstCompleter.removeListener(firstListener);
        secondCompleter.removeListener(secondListener);
      }
    });

    firstCompleter.addListener(firstListener);
    secondCompleter.addListener(secondListener);
    listenersAttached = true;
    await Future.wait<void>(<Future<void>>[
      firstDecodeReturned.future,
      secondDecodeReturned.future,
    ]).timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    final Map<String, Object?> snapshot = PixaDebugInspector.snapshot()
        .toJson();
    final Map<String, Object?> displayDecoder =
        snapshot['displayDecoder']! as Map<String, Object?>;

    expect(displayDecoder['completionQueueDepth'], 1);
    expect(displayDecoder['completionsReleasedThisFrame'], 1);
    expect(displayDecoder['completionFrameScheduled'], isTrue);
    expect(secondImage.isCompleted, isFalse);

    final ImageInfo firstInfo = await firstImage.future.timeout(
      const Duration(seconds: 5),
    );
    addTearDown(firstInfo.dispose);
    final ImageInfo secondInfo = await secondImage.future.timeout(
      const Duration(seconds: 5),
    );
    addTearDown(secondInfo.dispose);
    firstCompleter.removeListener(firstListener);
    secondCompleter.removeListener(secondListener);
    listenersAttached = false;
  });

  test(
    'PixaProvider gates burst image completions behind frame budget',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-completion-burst-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          decodeConcurrency: 12,
          maxImageCompletionsPerFrame: 3,
        ),
      );
      await _waitForCompletionGateIdle();

      const int imageCount = 12;
      final List<Completer<void>> decodeReturned =
          List<Completer<void>>.generate(imageCount, (_) => Completer<void>());
      final List<Completer<ImageInfo>> delivered =
          List<Completer<ImageInfo>>.generate(
            imageCount,
            (_) => Completer<ImageInfo>(),
          );
      final List<ImageInfo> retainedImages = <ImageInfo>[];
      addTearDown(() {
        for (final ImageInfo image in retainedImages) {
          image.dispose();
        }
      });

      Future<ui.Codec> decodeAt(
        int index,
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        final ui.Codec codec = await ui.instantiateImageCodec(_minimalGif());
        decodeReturned[index].complete();
        return codec;
      }

      final List<PixaProvider> providers = List<PixaProvider>.generate(
        imageCount,
        (int index) => PixaProvider(
          request: PixaRequest(
            source: PixaSource.custom(
              'completion-burst-$index',
              () async => _minimalGif(),
            ),
            cachePolicy: const PixaCachePolicy.noStore(),
          ),
        ),
      );
      final List<ImageStreamCompleter> completers =
          List<ImageStreamCompleter>.generate(
            imageCount,
            (int index) => providers[index].loadImage(
              providers[index],
              (
                ui.ImmutableBuffer buffer, {
                ui.TargetImageSizeCallback? getTargetSize,
              }) => decodeAt(index, buffer, getTargetSize: getTargetSize),
            ),
          );
      final List<ImageStreamListener> listeners =
          List<ImageStreamListener>.generate(imageCount, (int index) {
            return ImageStreamListener((ImageInfo image, bool synchronousCall) {
              if (!delivered[index].isCompleted) {
                retainedImages.add(image);
                delivered[index].complete(image);
              } else {
                image.dispose();
              }
            });
          });
      addTearDown(() {
        for (var index = 0; index < imageCount; index += 1) {
          completers[index].removeListener(listeners[index]);
        }
      });

      for (var index = 0; index < imageCount; index += 1) {
        completers[index].addListener(listeners[index]);
      }
      await Future.wait<void>(
        decodeReturned.map((Completer<void> completer) => completer.future),
      ).timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      final Map<String, Object?> firstSnapshot = PixaDebugInspector.snapshot()
          .toJson();
      final Map<String, Object?> firstDisplayDecoder =
          firstSnapshot['displayDecoder']! as Map<String, Object?>;
      final int firstQueueDepth =
          firstDisplayDecoder['completionQueueDepth']! as int;
      final int firstReleasedThisFrame =
          firstDisplayDecoder['completionsReleasedThisFrame']! as int;
      final int firstDelivered = delivered
          .where((Completer<ImageInfo> completer) => completer.isCompleted)
          .length;
      expect(firstQueueDepth, inInclusiveRange(1, imageCount - 3));
      expect(firstReleasedThisFrame, inInclusiveRange(0, 3));
      expect(firstDisplayDecoder['completionFrameScheduled'], isTrue);
      expect(firstDelivered, lessThan(imageCount));
      expect(firstDelivered, lessThanOrEqualTo(imageCount - firstQueueDepth));

      await Future.wait<ImageInfo>(
        delivered.map((Completer<ImageInfo> completer) => completer.future),
      ).timeout(const Duration(seconds: 5));
      final Map<String, Object?> drainedSnapshot = PixaDebugInspector.snapshot()
          .toJson();
      final Map<String, Object?> drainedDisplayDecoder =
          drainedSnapshot['displayDecoder']! as Map<String, Object?>;
      expect(drainedDisplayDecoder['completionQueueDepth'], 0);
    },
  );

  test(
    'PixaProvider releases queued completions on Flutter frame boundary',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-completion-frame-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          decodeConcurrency: 2,
          maxImageCompletionsPerFrame: 1,
        ),
      );
      await _waitForCompletionGateIdle();
      final int transientCallbacksBefore =
          SchedulerBinding.instance.transientCallbackCount;

      final Completer<void> firstDecodeReturned = Completer<void>();
      final Completer<void> secondDecodeReturned = Completer<void>();

      Future<ui.Codec> firstDecode(
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        final ui.Codec codec = await ui.instantiateImageCodec(_minimalGif());
        firstDecodeReturned.complete();
        return codec;
      }

      Future<ui.Codec> secondDecode(
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        final ui.Codec codec = await ui.instantiateImageCodec(_minimalGif());
        secondDecodeReturned.complete();
        return codec;
      }

      final PixaProvider first = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'completion-frame-a',
            () async => _minimalGif(),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
      );
      final PixaProvider second = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'completion-frame-b',
            () async => _minimalGif(),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
      );
      final ImageStreamCompleter firstCompleter = first.loadImage(
        first,
        firstDecode,
      );
      final ImageStreamCompleter secondCompleter = second.loadImage(
        second,
        secondDecode,
      );
      final Completer<ImageInfo> firstImage = Completer<ImageInfo>();
      final Completer<ImageInfo> secondImage = Completer<ImageInfo>();
      final List<ImageInfo> retainedImages = <ImageInfo>[];
      addTearDown(() {
        for (final ImageInfo image in retainedImages) {
          image.dispose();
        }
      });
      final ImageStreamListener firstListener = ImageStreamListener((
        ImageInfo image,
        bool synchronousCall,
      ) {
        retainedImages.add(image);
        if (!firstImage.isCompleted) {
          firstImage.complete(image);
        }
      });
      final ImageStreamListener secondListener = ImageStreamListener((
        ImageInfo image,
        bool synchronousCall,
      ) {
        retainedImages.add(image);
        if (!secondImage.isCompleted) {
          secondImage.complete(image);
        }
      });
      addTearDown(() {
        firstCompleter.removeListener(firstListener);
        secondCompleter.removeListener(secondListener);
      });

      firstCompleter.addListener(firstListener);
      secondCompleter.addListener(secondListener);
      await Future.wait<void>(<Future<void>>[
        firstDecodeReturned.future,
        secondDecodeReturned.future,
      ]).timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      final Map<String, Object?> beforeFrame = PixaDebugInspector.snapshot()
          .toJson();
      final Map<String, Object?> beforeDisplayDecoder =
          beforeFrame['displayDecoder']! as Map<String, Object?>;
      expect(beforeDisplayDecoder['completionQueueDepth'], 1);
      expect(secondImage.isCompleted, isFalse);
      expect(
        SchedulerBinding.instance.transientCallbackCount,
        greaterThan(transientCallbacksBefore),
      );

      _pumpFlutterFrame();
      await Future<void>.delayed(Duration.zero);

      final Map<String, Object?> afterFrame = PixaDebugInspector.snapshot()
          .toJson();
      final Map<String, Object?> afterDisplayDecoder =
          afterFrame['displayDecoder']! as Map<String, Object?>;
      expect(afterDisplayDecoder['completionQueueDepth'], 0);
      await firstImage.future.timeout(const Duration(seconds: 5));
      await secondImage.future.timeout(const Duration(seconds: 5));
    },
  );

  test(
    'PixaProvider rejects decode work when queued decode budget is full',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-decode-queue-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          decodeConcurrency: 1,
          maxQueuedDecodes: 0,
        ),
      );

      final Completer<void> firstEntered = Completer<void>();
      final Completer<void> releaseFirst = Completer<void>();
      var firstDecodeCalls = 0;
      var secondDecodeCalls = 0;

      Future<ui.Codec> firstDecode(
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        firstDecodeCalls += 1;
        firstEntered.complete();
        await releaseFirst.future;
        throw StateError('stop decode after queue assertion');
      }

      Future<ui.Codec> secondDecode(
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        secondDecodeCalls += 1;
        throw StateError('second decode should be rejected before decode');
      }

      final PixaProvider first = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'decode-queue-a',
            () async => _minimalGif(),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
      );
      final PixaProvider second = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom('decode-queue-b', () async {
            await firstEntered.future;
            return _minimalGif();
          }),
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
      );
      final ImageStreamCompleter firstCompleter = first.loadImage(
        first,
        firstDecode,
      );
      final ImageStreamCompleter secondCompleter = second.loadImage(
        second,
        secondDecode,
      );
      final Completer<Object> firstError = Completer<Object>();
      final Completer<Object> secondError = Completer<Object>();
      final ImageStreamListener firstListener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          fail('first decode should fail after release');
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!firstError.isCompleted) {
            firstError.complete(error);
          }
        },
      );
      final ImageStreamListener secondListener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          fail('second decode should be rejected by queue budget');
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!secondError.isCompleted) {
            secondError.complete(error);
          }
        },
      );

      firstCompleter.addListener(firstListener);
      secondCompleter.addListener(secondListener);
      final Object firstStartOrFailure = await Future.any<Object>(
        <Future<Object>>[
          firstEntered.future.then<Object>((_) => 'entered'),
          firstError.future,
        ],
      ).timeout(const Duration(seconds: 5));
      expect(firstStartOrFailure, 'entered');

      final Object secondFailure = await secondError.future.timeout(
        const Duration(seconds: 5),
      );
      expect(secondFailure, isA<PixaFailure>());
      final PixaFailure failure = secondFailure as PixaFailure;
      expect(failure.stage, PixaStage.decode);
      expect(failure.safeMessage, contains('decode queue is full'));
      expect(firstDecodeCalls, 1);
      expect(secondDecodeCalls, 0);

      releaseFirst.complete();
      await firstError.future.timeout(const Duration(seconds: 5));
      firstCompleter.removeListener(firstListener);
      secondCompleter.removeListener(secondListener);
    },
  );

  test('PixaProvider can opt into runtime display decoding', () async {
    final Directory cacheRoot = await Directory.systemTemp.createTemp(
      'pixa-provider-runtime-decode-',
    );
    addTearDown(() => cacheRoot.delete(recursive: true));
    final List<PixaEvent> events = <PixaEvent>[];
    await Pixa.configure(
      PixaConfig(
        cacheRootPath: cacheRoot.path,
        observers: <PixaObserver>[PixaCallbackObserver(events.add)],
      ),
    );

    final PixaProvider provider = PixaProvider(
      request: PixaRequest(
        source: PixaSource.custom('runtime-display', () async => _minimalGif()),
        cachePolicy: const PixaCachePolicy.noStore(),
        decoderOptions: const <String, Object?>{'displayBackend': 'runtime'},
      ),
    );
    final ImageStreamCompleter completer = provider.loadImage(provider, (
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) async {
      throw StateError('runtime display backend must not call engineDecode');
    });
    final Completer<ImageInfo> imageCompleter = Completer<ImageInfo>();
    final Completer<Object> errorCompleter = Completer<Object>();
    final ImageStreamListener listener = ImageStreamListener(
      (ImageInfo image, bool synchronousCall) {
        if (!imageCompleter.isCompleted) {
          imageCompleter.complete(image);
        }
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!errorCompleter.isCompleted) {
          errorCompleter.complete(error);
        }
      },
    );

    completer.addListener(listener);
    final Object result = await Future.any<Object>(<Future<Object>>[
      imageCompleter.future,
      errorCompleter.future,
    ]).timeout(const Duration(seconds: 5));
    completer.removeListener(listener);
    expect(result, isA<ImageInfo>());
    final ImageInfo image = result as ImageInfo;
    addTearDown(image.dispose);

    expect(image.image.width, 1);
    expect(image.image.height, 1);
    final PixaEvent start = events.singleWhere(
      (PixaEvent event) => event.name == 'decode.start',
    );
    final PixaEvent complete = events.singleWhere(
      (PixaEvent event) => event.name == 'decode.complete',
    );
    expect(start.attributes['backend'], 'runtime-rgba');
    expect(start.attributes['execution'], 'runtime');
    expect(complete.attributes['backend'], 'runtime-rgba');
    expect(complete.attributes['execution'], 'runtime');

    final Map<String, Object?> snapshot = PixaDebugInspector.snapshot()
        .toJson();
    final Map<String, Object?> displayDecoder =
        snapshot['displayDecoder']! as Map<String, Object?>;
    expect(displayDecoder['hasRuntimeDisplayBackend'], isTrue);
  });

  test(
    'engine-backed WBMP can explicitly use runtime display decoding',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-wbmp-runtime-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      final List<PixaEvent> events = <PixaEvent>[];
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          observers: <PixaObserver>[PixaCallbackObserver(events.add)],
        ),
      );

      final PixaProvider provider = PixaProvider(
        request: PixaRequest(
          source: PixaSource.bytes(_wbmpBytes(), id: 'runtime-wbmp'),
          cachePolicy: const PixaCachePolicy.noStore(),
          decoderOptions: const <String, Object?>{'displayBackend': 'runtime'},
        ),
      );
      final ImageStreamCompleter completer = provider.loadImage(provider, (
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        throw StateError('WBMP runtime opt-in must not call engineDecode');
      });
      final Completer<ImageInfo> imageCompleter = Completer<ImageInfo>();
      final Completer<Object> errorCompleter = Completer<Object>();
      final ImageStreamListener listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          if (!imageCompleter.isCompleted) {
            imageCompleter.complete(image);
          }
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!errorCompleter.isCompleted) {
            errorCompleter.complete(error);
          }
        },
      );

      completer.addListener(listener);
      final Object result = await Future.any<Object>(<Future<Object>>[
        imageCompleter.future,
        errorCompleter.future,
      ]).timeout(const Duration(seconds: 5));
      completer.removeListener(listener);
      expect(result, isA<ImageInfo>());
      final ImageInfo image = result as ImageInfo;
      addTearDown(image.dispose);

      expect(image.image.width, 1);
      expect(image.image.height, 1);
      final ByteData pixels =
          await image.image.toByteData(format: ui.ImageByteFormat.rawRgba) ??
          (throw StateError('Failed to read WBMP pixels.'));
      expect(pixels.buffer.asUint8List(0, 4), <int>[255, 255, 255, 255]);
      final PixaEvent start = events.singleWhere(
        (PixaEvent event) => event.name == 'decode.start',
      );
      expect(start.attributes['backend'], 'runtime-rgba');
      expect(start.attributes['execution'], 'runtime');
    },
  );

  test(
    'runtime display decode maps RGBA budget failure to decode failure',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-runtime-decode-budget-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      final List<PixaEvent> events = <PixaEvent>[];
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          observers: <PixaObserver>[PixaCallbackObserver(events.add)],
        ),
      );
      final PixaProvider provider = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'runtime-display-budget',
            () async => _minimalGif(),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
          decoderOptions: const <String, Object?>{'displayBackend': 'runtime'},
          limits: const PixaRequestLimits(maxProcessorOutputBytes: 3),
        ),
      );
      final ImageStreamCompleter completer = provider.loadImage(provider, (
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        throw StateError('runtime display backend must not call engineDecode');
      });
      final Completer<Object> errorCompleter = Completer<Object>();
      final ImageStreamListener listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          fail('budget failure should not produce an ImageInfo');
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!errorCompleter.isCompleted) {
            errorCompleter.complete(error);
          }
        },
      );

      completer.addListener(listener);
      final Object error = await errorCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      completer.removeListener(listener);

      expect(error, isA<PixaFailure>());
      final PixaFailure failure = error as PixaFailure;
      expect(failure.stage, PixaStage.decode);
      expect(failure.safeMessage, contains('RGBA output bytes exceed limit'));
      final PixaEvent event = events.singleWhere(
        (PixaEvent event) => event.name == 'decode.failure',
      );
      expect(event.stage, PixaStage.decode);
      expect(event.attributes['backend'], 'runtime-rgba');
      expect(event.attributes['execution'], 'runtime');
    },
  );

  test(
    'processed runtime output automatically uses runtime display decoding',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-runtime-decode-auto-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      final List<PixaEvent> events = <PixaEvent>[];
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          observers: <PixaObserver>[PixaCallbackObserver(events.add)],
        ),
      );

      final PixaProvider provider = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'runtime-display-auto',
            () async => _minimalGif(),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
          processors: const <String>[
            'resize(width=1,height=1,mode=exact,filter=nearest)',
          ],
        ),
      );
      final ImageStreamCompleter completer = provider.loadImage(provider, (
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        throw StateError(
          'processed runtime output should not call engineDecode',
        );
      });
      final Completer<ImageInfo> imageCompleter = Completer<ImageInfo>();
      final Completer<Object> errorCompleter = Completer<Object>();
      final ImageStreamListener listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          if (!imageCompleter.isCompleted) {
            imageCompleter.complete(image);
          }
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!errorCompleter.isCompleted) {
            errorCompleter.complete(error);
          }
        },
      );

      completer.addListener(listener);
      final Object result = await Future.any<Object>(<Future<Object>>[
        imageCompleter.future,
        errorCompleter.future,
      ]).timeout(const Duration(seconds: 5));
      completer.removeListener(listener);
      expect(result, isA<ImageInfo>());
      final ImageInfo image = result as ImageInfo;
      addTearDown(image.dispose);

      expect(image.image.width, 1);
      expect(image.image.height, 1);
      final PixaEvent start = events.singleWhere(
        (PixaEvent event) => event.name == 'decode.start',
      );
      expect(start.attributes['backend'], 'runtime-rgba');
      expect(start.attributes['execution'], 'runtime');
    },
  );

  test(
    'common image processors automatically use runtime display decoding',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-runtime-common-processor-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      final List<PixaEvent> events = <PixaEvent>[];
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          observers: <PixaObserver>[PixaCallbackObserver(events.add)],
        ),
      );

      final PixaProvider provider = PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'runtime-common-processor',
            () async => _minimalGif(),
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
          processors: const <String>[
            'resize-to-fill(width=1,height=1,filter=nearest)',
          ],
        ),
      );
      final ImageStreamCompleter completer = provider.loadImage(provider, (
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        throw StateError(
          'common runtime processor output should not call engineDecode',
        );
      });
      final Completer<ImageInfo> imageCompleter = Completer<ImageInfo>();
      final Completer<Object> errorCompleter = Completer<Object>();
      final ImageStreamListener listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          if (!imageCompleter.isCompleted) {
            imageCompleter.complete(image);
          }
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!errorCompleter.isCompleted) {
            errorCompleter.complete(error);
          }
        },
      );

      completer.addListener(listener);
      final Object result = await Future.any<Object>(<Future<Object>>[
        imageCompleter.future,
        errorCompleter.future,
      ]).timeout(const Duration(seconds: 5));
      completer.removeListener(listener);
      expect(result, isA<ImageInfo>());
      final ImageInfo image = result as ImageInfo;
      addTearDown(image.dispose);

      expect(image.image.width, 1);
      expect(image.image.height, 1);
      final PixaEvent start = events.singleWhere(
        (PixaEvent event) => event.name == 'decode.start',
      );
      expect(start.attributes['backend'], 'runtime-rgba');
      expect(start.attributes['execution'], 'runtime');
    },
  );

  test(
    'non-engine ICO MIME automatically uses runtime display decoding',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-runtime-ico-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      final List<PixaEvent> events = <PixaEvent>[];
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          observers: <PixaObserver>[PixaCallbackObserver(events.add)],
        ),
      );

      final PixaProvider provider = PixaProvider(
        request: PixaRequest(
          source: PixaSource.bytes(_icoBytes(), id: 'runtime-ico'),
          cachePolicy: const PixaCachePolicy.noStore(),
          decoderOptions: const <String, Object?>{'mimeType': 'image/x-icon'},
        ),
      );
      final ImageStreamCompleter completer = provider.loadImage(provider, (
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) async {
        throw StateError('ICO should be decoded by runtime display backend');
      });
      final Completer<ImageInfo> imageCompleter = Completer<ImageInfo>();
      final Completer<Object> errorCompleter = Completer<Object>();
      final ImageStreamListener listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          if (!imageCompleter.isCompleted) {
            imageCompleter.complete(image);
          }
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!errorCompleter.isCompleted) {
            errorCompleter.complete(error);
          }
        },
      );

      completer.addListener(listener);
      final Object result = await Future.any<Object>(<Future<Object>>[
        imageCompleter.future,
        errorCompleter.future,
      ]).timeout(const Duration(seconds: 5));
      completer.removeListener(listener);
      expect(result, isA<ImageInfo>());
      final ImageInfo image = result as ImageInfo;
      addTearDown(image.dispose);

      expect(image.image.width, 1);
      expect(image.image.height, 1);
      final PixaEvent start = events.singleWhere(
        (PixaEvent event) => event.name == 'decode.start',
      );
      expect(start.attributes['backend'], 'runtime-rgba');
      expect(start.attributes['execution'], 'runtime');
    },
  );

  test(
    'runtime-only bytes automatically use runtime display decoding',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-provider-runtime-only-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      final List<PixaEvent> events = <PixaEvent>[];
      await Pixa.configure(
        PixaConfig(
          cacheRootPath: cacheRoot.path,
          observers: <PixaObserver>[PixaCallbackObserver(events.add)],
        ),
      );

      final Map<String, (Uint8List, List<int>, int, int)> fixtures =
          <String, (Uint8List, List<int>, int, int)>{
            'tiff': (_tiffBytes(), <int>[255, 0, 0, 255], 1, 1),
            'pnm': (_pnmBytes(), <int>[255, 0, 0, 255], 1, 1),
            'qoi': (_qoiBytes(), <int>[255, 0, 0, 255], 1, 1),
            'tga': (_tgaBytes(), <int>[255, 0, 0, 255], 1, 1),
            'dds': (_ddsBytes(), <int>[255, 0, 0, 255], 4, 4),
            'hdr': (_hdrBytes(), <int>[254, 0, 0, 255], 1, 1),
            'farbfeld': (_farbfeldBytes(), <int>[255, 0, 0, 255], 1, 1),
            'pcx': (_pcxBytes(), <int>[255, 0, 0, 255], 1, 1),
            'sgi': (_sgiBytes(), <int>[255, 0, 0, 255], 1, 1),
            'xbm': (_xbmBytes(), <int>[0, 0, 0, 255], 1, 1),
            'xpm': (_xpmBytes(), <int>[255, 0, 0, 255], 1, 1),
          };
      for (final MapEntry<String, (Uint8List, List<int>, int, int)> fixture
          in fixtures.entries) {
        final (
          Uint8List bytes,
          List<int> expectedPixel,
          int width,
          int height,
        ) = fixture.value;
        expect(
          pixaIsRuntimeOnlyDisplayMime(pixaSniffImageMimeType(bytes)),
          isTrue,
          reason: '${fixture.key} bytes should select runtime-rgba by sniffing',
        );
        events.clear();
        final PixaProvider provider = PixaProvider(
          request: PixaRequest(
            source: PixaSource.bytes(bytes, id: 'runtime-${fixture.key}'),
            cachePolicy: const PixaCachePolicy.noStore(),
          ),
        );
        final ImageStreamCompleter completer = provider.loadImage(provider, (
          ui.ImmutableBuffer buffer, {
          ui.TargetImageSizeCallback? getTargetSize,
        }) async {
          throw StateError(
            '${fixture.key} should be decoded by runtime display backend',
          );
        });
        final Completer<ImageInfo> imageCompleter = Completer<ImageInfo>();
        final Completer<Object> errorCompleter = Completer<Object>();
        final ImageStreamListener listener = ImageStreamListener(
          (ImageInfo image, bool synchronousCall) {
            if (!imageCompleter.isCompleted) {
              imageCompleter.complete(image);
            }
          },
          onError: (Object error, StackTrace? stackTrace) {
            if (!errorCompleter.isCompleted) {
              errorCompleter.complete(error);
            }
          },
        );

        completer.addListener(listener);
        final Object result = await Future.any<Object>(<Future<Object>>[
          imageCompleter.future,
          errorCompleter.future,
        ]).timeout(const Duration(seconds: 5));
        completer.removeListener(listener);
        expect(result, isA<ImageInfo>(), reason: fixture.key);
        final ImageInfo image = result as ImageInfo;
        addTearDown(image.dispose);

        expect(image.image.width, width, reason: fixture.key);
        expect(image.image.height, height, reason: fixture.key);
        final ByteData pixels =
            await image.image.toByteData(format: ui.ImageByteFormat.rawRgba) ??
            (throw StateError('Failed to read ${fixture.key} pixels.'));
        expect(
          pixels.buffer.asUint8List(0, 4),
          expectedPixel,
          reason: fixture.key,
        );
        final PixaEvent start = events.singleWhere(
          (PixaEvent event) => event.name == 'decode.start',
        );
        expect(
          start.attributes['backend'],
          'runtime-rgba',
          reason: fixture.key,
        );
        expect(start.attributes['execution'], 'runtime', reason: fixture.key);
      }
    },
  );

  testWidgets('PixaProvider key reuses Flutter decoded ImageCache', (
    WidgetTester tester,
  ) async {
    final ImageCache imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
    addTearDown(() {
      imageCache.clear();
      imageCache.clearLiveImages();
    });

    int loaderCalls = 0;
    final ui.Image image =
        await tester.runAsync(() => createTestImage(width: 1, height: 1)) ??
        (throw StateError('Failed to create test image.'));
    addTearDown(image.dispose);
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('decoded-cache-hit', () async {
        loaderCalls += 1;
        return _minimalGif();
      }),
      cachePolicy: const PixaCachePolicy.noStore(),
    );
    final PixaProvider first = PixaProvider(request: request);
    final PixaProvider second = PixaProvider(request: request);

    final ImageStreamCompleter firstCompleter = imageCache.putIfAbsent(
      first,
      () {
        loaderCalls += 1;
        return OneFrameImageStreamCompleter(
          Future<ImageInfo>.value(ImageInfo(image: image.clone())),
        );
      },
    )!;
    final ImageStreamCompleter secondCompleter = imageCache.putIfAbsent(
      second,
      () {
        loaderCalls += 1;
        throw StateError(
          'Flutter ImageCache should reuse the PixaProvider key',
        );
      },
    )!;

    expect(firstCompleter, same(secondCompleter));
    expect(loaderCalls, 1);
    expect(imageCache.containsKey(first), isTrue);
  });

  test('PixaProvider.network preserves request defaults', () {
    final PixaProvider provider = PixaProvider.network(
      'https://images.example.test/a.jpg',
    );
    final PixaRequest request = provider.request;

    expect(request.source, isA<PixaNetworkSource>());
    expect(
      (request.source as PixaNetworkSource).uri.toString(),
      'https://images.example.test/a.jpg',
    );
    expect(request.headers, isEmpty);
    expect(request.targetSize, const PixaTargetSize());
    expect(request.scale, 1.0);
    expect(request.fit, isNull);
    expect(request.cachePolicy, const PixaCachePolicy());
    expect(request.priority, PixaPriority.normal);
    expect(request.retryPolicy, const PixaRetryPolicy.none());
    expect(request.redirectPolicy, const PixaRedirectPolicy());
    expect(request.limits, const PixaRequestLimits());
    expect(provider.generation, 0);
    expect(provider.onProgress, isNull);
  });

  test('PixaRequest memoizes hot-path cache keys', () {
    final PixaRequest request = PixaRequest.network(
      'https://images.example.test/a.jpg?token=secret',
      targetSize: const PixaTargetSize(width: 240, height: 160),
      cachePolicy: const PixaCachePolicy.public(maxAge: Duration(days: 7)),
    );

    expect(identical(request.cacheKey, request.cacheKey), isTrue);
    expect(identical(request.encodedCacheKey, request.encodedCacheKey), isTrue);
  });

  test('PixaImage.network preserves widget and request defaults', () {
    final PixaImage image = PixaImage.network(
      'https://images.example.test/defaults.jpg',
    );

    expect(image.width, isNull);
    expect(image.height, isNull);
    expect(image.fit, isNull);
    expect(image.alignment, Alignment.center);
    expect(image.semanticLabel, isNull);
    expect(image.gaplessPlayback, isFalse);
    expect(image.filterQuality, ui.FilterQuality.medium);
    expect(image.transitionDuration, Duration.zero);
    expect(image.circle, isFalse);
    expect(image.borderRadius, isNull);
    expect(image.tapToRetry, isTrue);
    expect(image.request.source, isA<PixaNetworkSource>());
    expect(image.request.targetSize, const PixaTargetSize());
    expect(image.request.cachePolicy, const PixaCachePolicy());
    expect(image.request.priority, PixaPriority.normal);
    expect(image.request.retryPolicy, const PixaRetryPolicy.none());
    expect(image.request.redirectPolicy, const PixaRedirectPolicy());
  });

  test('PixaImage network factory attaches low-res request', () {
    final PixaRequest lowRes = PixaRequest(
      source: PixaSource.custom('low-res', () async => _minimalGif()),
      cachePolicy: const PixaCachePolicy.noStore(),
      priority: PixaPriority.high,
    );
    final PixaImage image = PixaImage.network(
      'https://images.example.test/full.jpg',
      lowRes: lowRes,
    );

    expect(image.request.lowRes, same(lowRes));
  });

  test('PixaImage file factory enables EXIF thumbnail-first by default', () {
    final PixaImage image = PixaImage.file(
      '/photos/private/full.jpg',
      width: 120,
      height: 90,
    );

    final PixaRequest? lowRes = image.request.lowRes;
    expect(lowRes, isNotNull);
    expect(lowRes!.source.safeLabel, 'exif-thumbnail:full.jpg');
    expect(lowRes.targetSize, const PixaTargetSize(width: 120, height: 90));
    expect(lowRes.encodedCacheKey, isNot(image.request.encodedCacheKey));
  });

  test('PixaImage file factory allows EXIF thumbnail-first opt-out', () {
    final PixaImage image = PixaImage.file(
      '/photos/private/full.jpg',
      exifThumbnailFirst: false,
    );

    expect(image.request.lowRes, isNull);
  });

  test('PixaImage file factory preserves explicit low-res request', () {
    final PixaRequest explicit = PixaRequest(
      source: PixaSource.custom('explicit-low', () async => _minimalGif()),
      cachePolicy: const PixaCachePolicy.noStore(),
    );
    final PixaImage image = PixaImage.file(
      '/photos/private/full.jpg',
      lowRes: explicit,
    );

    expect(image.request.lowRes, same(explicit));
  });
}

Duration _testFrameTimestamp = Duration.zero;

void _pumpFlutterFrame() {
  final SchedulerBinding binding = SchedulerBinding.instance;
  _testFrameTimestamp += const Duration(milliseconds: 1);
  binding.handleBeginFrame(_testFrameTimestamp);
  binding.handleDrawFrame();
}

Future<void> _waitForCompletionGateIdle() async {
  for (var attempt = 0; attempt < 12; attempt += 1) {
    final Map<String, Object?> snapshot = PixaDebugInspector.snapshot()
        .toJson();
    final Map<String, Object?> displayDecoder =
        snapshot['displayDecoder']! as Map<String, Object?>;
    if (displayDecoder['completionQueueDepth'] == 0 &&
        displayDecoder['completionFrameScheduled'] == false) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final Map<String, Object?> snapshot = PixaDebugInspector.snapshot().toJson();
  throw StateError('Pixa completion gate did not become idle: $snapshot');
}

Uint8List _minimalGif() {
  return Uint8List.fromList(<int>[
    0x47,
    0x49,
    0x46,
    0x38,
    0x39,
    0x61,
    0x01,
    0x00,
    0x01,
    0x00,
    0x80,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0xff,
    0xff,
    0xff,
    0x2c,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x01,
    0x00,
    0x00,
    0x02,
    0x02,
    0x4c,
    0x01,
    0x00,
    0x3b,
  ]);
}

Uint8List _icoBytes() {
  return base64Decode(
    'AAABAAEAAQEAAAEAIAAwAAAAFgAAACgAAAABAAAAAgAAAAEAIAAAAAAABAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAP//AAAAAA==',
  );
}

Uint8List _tiffBytes() {
  const int entryCount = 10;
  final int ifdEnd = 8 + 2 + entryCount * 12 + 4;
  final int bitsPerSampleOffset = ifdEnd;
  final int pixelOffset = bitsPerSampleOffset + 8;
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('II'.codeUnits);
  bytes.add(_le16(42));
  bytes.add(_le32(8));
  bytes.add(_le16(entryCount));
  bytes.add(_tiffEntry(256, 4, 1, 1));
  bytes.add(_tiffEntry(257, 4, 1, 1));
  bytes.add(_tiffEntry(258, 3, 4, bitsPerSampleOffset));
  bytes.add(_tiffEntry(259, 3, 1, 1));
  bytes.add(_tiffEntry(262, 3, 1, 2));
  bytes.add(_tiffEntry(273, 4, 1, pixelOffset));
  bytes.add(_tiffEntry(277, 3, 1, 4));
  bytes.add(_tiffEntry(278, 4, 1, 1));
  bytes.add(_tiffEntry(279, 4, 1, 4));
  bytes.add(_tiffEntry(338, 3, 1, 2));
  bytes.add(_le32(0));
  bytes.add(<int>[8, 0, 8, 0, 8, 0, 8, 0]);
  bytes.add(<int>[255, 0, 0, 255]);
  return bytes.toBytes();
}

List<int> _tiffEntry(int tag, int type, int count, int value) {
  return <int>[..._le16(tag), ..._le16(type), ..._le32(count), ..._le32(value)];
}

Uint8List _pnmBytes() {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('P6\n1 1\n255\n'.codeUnits);
  bytes.add(<int>[255, 0, 0]);
  return bytes.toBytes();
}

Uint8List _qoiBytes() {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('qoif'.codeUnits);
  bytes.add(_be32(1));
  bytes.add(_be32(1));
  bytes.add(<int>[4, 0, 0xff, 255, 0, 0, 255]);
  bytes.add(<int>[0, 0, 0, 0, 0, 0, 0, 1]);
  return bytes.toBytes();
}

Uint8List _tgaBytes() {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add(<int>[0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  bytes.add(_le16(1));
  bytes.add(_le16(1));
  bytes.add(<int>[24, 0x20, 0, 0, 255]);
  return bytes.toBytes();
}

Uint8List _ddsBytes() {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('DDS '.codeUnits);
  bytes.add(_le32(124));
  bytes.add(_le32(0x00021007));
  bytes.add(_le32(4));
  bytes.add(_le32(4));
  bytes.add(_le32(8));
  bytes.add(_le32(0));
  bytes.add(_le32(0));
  bytes.add(Uint8List(44));
  bytes.add(_le32(32));
  bytes.add(_le32(4));
  bytes.add('DXT1'.codeUnits);
  bytes.add(Uint8List(20));
  bytes.add(_le32(0x1000));
  bytes.add(Uint8List(16));
  bytes.add(<int>[0x00, 0xf8, 0x00, 0x00, 0, 0, 0, 0]);
  return bytes.toBytes();
}

Uint8List _hdrBytes() {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 1\n'.codeUnits);
  bytes.add(<int>[255, 0, 0, 128]);
  return bytes.toBytes();
}

Uint8List _farbfeldBytes() {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('farbfeld'.codeUnits);
  bytes.add(_be32(1));
  bytes.add(_be32(1));
  bytes.add(<int>[0xff, 0xff, 0, 0, 0, 0, 0xff, 0xff]);
  return bytes.toBytes();
}

Uint8List _wbmpBytes() {
  return Uint8List.fromList(<int>[0, 0, 1, 1, 0x80]);
}

Uint8List _xbmBytes() {
  return Uint8List.fromList(
    '#define test_width 1\n'
            '#define test_height 1\n'
            'static unsigned char test_bits[] = { 0x01 };\n'
        .codeUnits,
  );
}

Uint8List _xpmBytes() {
  return Uint8List.fromList(
    '/* XPM */\n'
            'static char *xpm[] = {\n'
            '"1 1 1 1",\n'
            '"a c #ff0000",\n'
            '"a"\n'
            '};\n'
        .codeUnits,
  );
}

Uint8List _pcxBytes() {
  final Uint8List bytes = Uint8List(132);
  bytes[0] = 0x0a;
  bytes[1] = 5;
  bytes[2] = 1;
  bytes[3] = 8;
  bytes.setRange(8, 10, _le16(0));
  bytes.setRange(10, 12, _le16(0));
  bytes.setRange(12, 14, _le16(72));
  bytes.setRange(14, 16, _le16(72));
  bytes[65] = 3;
  bytes.setRange(66, 68, _le16(1));
  bytes.setRange(68, 70, _le16(1));
  bytes.setRange(128, 132, <int>[0xc1, 0xff, 0, 0]);
  return bytes;
}

Uint8List _sgiBytes() {
  final Uint8List bytes = Uint8List(515);
  bytes.setRange(0, 2, _be16(0x01da));
  bytes[2] = 0;
  bytes[3] = 1;
  bytes.setRange(4, 6, _be16(3));
  bytes.setRange(6, 8, _be16(1));
  bytes.setRange(8, 10, _be16(1));
  bytes.setRange(10, 12, _be16(3));
  bytes.setRange(16, 20, _be32(255));
  bytes.setRange(512, 515, <int>[255, 0, 0]);
  return bytes;
}

List<int> _le16(int value) => <int>[value & 0xff, (value >> 8) & 0xff];

List<int> _le32(int value) {
  final int unsigned = value.toUnsigned(32);
  return <int>[
    unsigned & 0xff,
    (unsigned >> 8) & 0xff,
    (unsigned >> 16) & 0xff,
    (unsigned >> 24) & 0xff,
  ];
}

List<int> _be16(int value) => <int>[(value >> 8) & 0xff, value & 0xff];

List<int> _be32(int value) {
  final int unsigned = value.toUnsigned(32);
  return <int>[
    (unsigned >> 24) & 0xff,
    (unsigned >> 16) & 0xff,
    (unsigned >> 8) & 0xff,
    unsigned & 0xff,
  ];
}

final class _UnknownTranscodePlugin implements PixaPlugin {
  const _UnknownTranscodePlugin();

  @override
  String get id => 'unknown-transcode';

  @override
  PixaVersionConstraint get compatiblePixaVersions =>
      const PixaVersionConstraint.any();

  @override
  void register(PixaRegistry registry) {
    registry.registerDecoder(const _UnknownTranscodeDecoderDescriptor());
  }
}

final class _UnknownTranscodeDecoderDescriptor
    implements PixaDartDecoderDescriptor {
  const _UnknownTranscodeDecoderDescriptor();

  @override
  String get id => 'unknown-transcode-decoder';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  Set<String> get mimeTypes => const <String>{'image/pixa-unknown-transcode'};

  @override
  Set<String> get formatIds => const <String>{};

  @override
  List<PixaDecoderSignature> get signatures => const <PixaDecoderSignature>[];

  @override
  PixaDecoderCapabilities get capabilities =>
      const PixaDecoderCapabilities.dartBytes();

  @override
  int get priority => 1;

  @override
  PixaDecoder get decoder => const _UnknownTranscodeDecoder();
}

final class _UnknownTranscodeDecoder implements PixaDecoder {
  const _UnknownTranscodeDecoder();

  @override
  PixaBytePayload decode(PixaBytePayload input, PixaExecutionContext context) {
    return PixaBytePayload(
      bytes: Uint8List.fromList('not an image'.codeUnits),
      mimeType: 'image/pixa-unknown-output',
    );
  }
}

final class _GifTranscodePlugin implements PixaPlugin {
  const _GifTranscodePlugin();

  @override
  String get id => 'gif-transcode';

  @override
  PixaVersionConstraint get compatiblePixaVersions =>
      const PixaVersionConstraint.any();

  @override
  void register(PixaRegistry registry) {
    registry.registerDecoder(const _GifTranscodeDecoderDescriptor());
  }
}

final class _GifTranscodeDecoderDescriptor
    implements PixaDartDecoderDescriptor {
  const _GifTranscodeDecoderDescriptor();

  @override
  String get id => 'gif-transcode-decoder';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  Set<String> get mimeTypes => const <String>{'image/pixa-gif-transcode'};

  @override
  Set<String> get formatIds => const <String>{};

  @override
  List<PixaDecoderSignature> get signatures => const <PixaDecoderSignature>[];

  @override
  PixaDecoderCapabilities get capabilities =>
      const PixaDecoderCapabilities.dartBytes();

  @override
  int get priority => 1;

  @override
  PixaDecoder get decoder => const _GifTranscodeDecoder();
}

final class _GifTranscodeDecoder implements PixaDecoder {
  const _GifTranscodeDecoder();

  @override
  PixaBytePayload decode(PixaBytePayload input, PixaExecutionContext context) {
    return PixaBytePayload(bytes: _minimalGif(), mimeType: 'image/gif');
  }
}

final class _InvalidGifTranscodePlugin implements PixaPlugin {
  const _InvalidGifTranscodePlugin();

  @override
  String get id => 'invalid-gif-transcode';

  @override
  PixaVersionConstraint get compatiblePixaVersions =>
      const PixaVersionConstraint.any();

  @override
  void register(PixaRegistry registry) {
    registry.registerDecoder(const _InvalidGifTranscodeDecoderDescriptor());
  }
}

final class _InvalidGifTranscodeDecoderDescriptor
    implements PixaDartDecoderDescriptor {
  const _InvalidGifTranscodeDecoderDescriptor();

  @override
  String get id => 'invalid-gif-transcode-decoder';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  Set<String> get mimeTypes => const <String>{
    'image/pixa-invalid-gif-transcode',
  };

  @override
  Set<String> get formatIds => const <String>{};

  @override
  List<PixaDecoderSignature> get signatures => const <PixaDecoderSignature>[];

  @override
  PixaDecoderCapabilities get capabilities =>
      const PixaDecoderCapabilities.dartBytes();

  @override
  int get priority => 1;

  @override
  PixaDecoder get decoder => const _InvalidGifTranscodeDecoder();
}

final class _InvalidGifTranscodeDecoder implements PixaDecoder {
  const _InvalidGifTranscodeDecoder();

  @override
  PixaBytePayload decode(PixaBytePayload input, PixaExecutionContext context) {
    return PixaBytePayload(
      bytes: Uint8List.fromList('not a gif'.codeUnits),
      mimeType: 'image/gif',
    );
  }
}
