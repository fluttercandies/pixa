import Cocoa
import FlutterMacOS

public class PixaPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    // Runtime assets are loaded through Dart FFI hooks; this entry keeps
    // Flutter's Darwin dependency managers able to register Pixa.
  }
}
