import 'package:flutter/material.dart';
import 'package:flutter_cockpit/flutter_cockpit_flutter.dart';
import 'package:pixa_gallery/main.dart' as gallery;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
      child: const _CockpitGalleryBootstrap(),
    ),
  );
}

final class _CockpitGalleryBootstrap extends StatefulWidget {
  const _CockpitGalleryBootstrap();

  @override
  State<_CockpitGalleryBootstrap> createState() =>
      _CockpitGalleryBootstrapState();
}

final class _CockpitGalleryBootstrapState
    extends State<_CockpitGalleryBootstrap> {
  late final Future<Widget> _app = gallery.createPixaGalleryApp(
    navigatorObservers: <NavigatorObserver>[FlutterCockpit.navigatorObserver],
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _app,
      builder: (BuildContext context, AsyncSnapshot<Widget> snapshot) {
        final app = snapshot.data;
        if (app != null) {
          return app;
        }
        return const MaterialApp(
          home: Scaffold(body: Center(child: CircularProgressIndicator())),
        );
      },
    );
  }
}
