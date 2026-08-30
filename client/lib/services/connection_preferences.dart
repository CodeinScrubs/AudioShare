import '../utils/prefs.dart';

abstract interface class ConnectionPreferences {
  String get lastDeviceId;
  bool get autoConnectEnabled;

  void setLastDeviceId(String value);
  void setAutoConnectEnabled(bool value);
}

class FileConnectionPreferences implements ConnectionPreferences {
  FileConnectionPreferences() {
    Prefs.load();
  }

  static const _lastDeviceIdKey = 'lastDeviceId';
  static const _autoConnectKey = 'lastCheck';

  @override
  String get lastDeviceId => Prefs.getString(_lastDeviceIdKey);

  @override
  bool get autoConnectEnabled =>
      Prefs.getBool(_autoConnectKey, defaultValue: true);

  @override
  void setLastDeviceId(String value) {
    Prefs.setString(_lastDeviceIdKey, value);
  }

  @override
  void setAutoConnectEnabled(bool value) {
    Prefs.setBool(_autoConnectKey, value);
  }
}
