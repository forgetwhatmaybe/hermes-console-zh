import 'package:shared_preferences/shared_preferences.dart';

import '../utils/server_paths.dart';

/// User choice for the Hermes host OS (Settings → Appearance → Server OS).
/// Default is [ServerOs.auto]: the folder browser inspects the paths the
/// server returns and adapts.
class ServerOsPref {
  ServerOsPref._();

  static const String key = 'server_os';

  static ServerOs read(SharedPreferences prefs) =>
      ServerOs.fromStorage(prefs.getString(key));

  static Future<void> write(SharedPreferences prefs, ServerOs value) =>
      prefs.setString(key, value.storageKey);
}
