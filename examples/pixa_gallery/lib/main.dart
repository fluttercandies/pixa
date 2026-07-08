import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';

import 'app/gallery_settings.dart';
import 'app/pixa_gallery_app.dart' show PixaGalleryApp;
import 'diagnostics/pixa_event_capture.dart';

/// Public re-export so external runtime drivers can reach the gallery entry
/// points from `package:pixa_gallery/main.dart`.
export 'app/gallery_routes.dart' show GalleryTab;
export 'app/pixa_gallery_app.dart' show PixaGalleryApp;
export 'widgets/neu_controls.dart'
    show NeuButton, NeuCard, NeuIconButton, NeuProgress, NeuSpinner;
export 'widgets/neu_surface.dart' show NeuSurface, NeuElevation, NeuShape;
export 'widgets/neu_navigation.dart'
    show NeuBottomNav, NeuRail, NeuStat, NeuStatTone, PixaDestination;

/// Entry point for the Pixa gallery workbench example.
///
/// Configures the Pixa pipeline with a production-minded budget so the
/// dense gallery hot path stays bounded under fast scrolling, then runs
/// the neumorphic gallery shell.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(await createPixaGalleryApp());
}

/// Builds the configured gallery app.
///
/// Cockpit and production entrypoints both use this factory so runtime budgets,
/// settings, and observers stay identical while cockpit-specific imports remain
/// outside `lib/`.
Future<PixaGalleryApp> createPixaGalleryApp({
  List<NavigatorObserver> navigatorObservers = const <NavigatorObserver>[],
}) async {
  await Pixa.configure(
    PixaConfig(
      memoryCacheBytes: 160 * 1024 * 1024,
      diskCacheBytes: 1024 * 1024 * 1024,
      networkConcurrency: 6,
      decodeConcurrency: 2,
      maxImageCompletionsPerFrame: 3,
      maxQueuedRuntimeLoads: 256,
      maxQueuedDecodes: 32,
      decodedCacheMaximumSize: 1200,
      decodedCacheMaximumSizeBytes: 180 * 1024 * 1024,
      observers: <PixaObserver>[appEventObserver],
    ),
  );
  final settings = await GallerySettings.instance();
  return PixaGalleryApp(
    settings: settings,
    navigatorObservers: navigatorObservers,
  );
}
