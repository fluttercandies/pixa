import 'package:flutter/material.dart';
import 'package:flutter_cockpit/flutter_cockpit_flutter.dart';
import 'package:pixa_gallery/main.dart' as gallery;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = await gallery.createPixaGalleryApp(
    navigatorObservers: <NavigatorObserver>[FlutterCockpit.navigatorObserver],
  );
  runApp(
    FlutterCockpitApp(
      config: FlutterCockpitConfig.production(
        initialRouteName: '/gallery',
        remoteSession: CockpitRemoteSessionConfiguration.resolveFromEnvironment(
          fallback: const CockpitRemoteSessionConfiguration(
            enabled: true,
            host: '127.0.0.1',
            port: 47331,
          ),
        ),
      ),
      child: app,
    ),
  );
}
