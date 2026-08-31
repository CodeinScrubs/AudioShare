import 'dart:convert';
import 'dart:io';

class Prefs {
  static Map<String, dynamic> _cache = {};
  static String? _lastError;
  static Directory? _storageDirectoryOverride;

  static String? get lastError => _lastError;

  static void useStorageDirectoryForTesting(Directory? directory) {
    _storageDirectoryOverride = directory;
    _cache = {};
    _lastError = null;
  }

  static File _file() {
    final base = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    final sep = Platform.pathSeparator;
    final dir =
        _storageDirectoryOverride ??
        Directory('$base${sep}CodeinScrubs${sep}AudioShare');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final current = File('${dir.path}${sep}prefs.json');
    final legacy = File('$base${sep}ysbing${sep}AudioShare${sep}prefs.json');
    if (_storageDirectoryOverride == null &&
        !current.existsSync() &&
        legacy.existsSync()) {
      // Preserve remembered-device and locale choices from older builds while
      // moving new writes into this fork's own application-data namespace.
      legacy.copySync(current.path);
    }
    return current;
  }

  static void load() {
    late final File current;
    late final File backup;
    try {
      current = _file();
      backup = File('${current.path}.bak');
      if (current.existsSync()) {
        try {
          _cache = _read(current);
          _lastError = null;
          return;
        } catch (primaryError) {
          _recoverFromBackup(
            current,
            backup,
            'the primary file could not be read: $primaryError',
          );
          return;
        }
      }

      if (backup.existsSync()) {
        _recoverFromBackup(current, backup, 'the primary file was missing');
        return;
      }

      _cache = {};
      _lastError = null;
    } catch (error) {
      _cache = {};
      _lastError = 'Could not load AudioShare preferences: $error';
      stderr.writeln(_lastError);
    }
  }

  static void _recoverFromBackup(
    File current,
    File backup,
    Object primaryError,
  ) {
    if (!backup.existsSync()) {
      throw StateError(
        'primary=$primaryError; no preference backup is available',
      );
    }

    try {
      _cache = _read(backup);
      Object? repairError;
      try {
        _restoreCurrent(current, _cache);
      } catch (error) {
        repairError = error;
      }

      _lastError =
          'Recovered AudioShare preferences from the backup after '
          '$primaryError.';
      if (repairError != null) {
        _lastError =
            '$_lastError The primary file could not be repaired: '
            '$repairError';
      }
      stderr.writeln(_lastError);
    } catch (backupError) {
      _cache = {};
      throw StateError('primary=$primaryError; backup=$backupError');
    }
  }

  static Map<String, dynamic> _read(File file) {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Preference root must be a JSON object.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static void _restoreCurrent(File current, Map<String, dynamic> values) {
    final recovery = File('${current.path}.recovery');
    if (recovery.existsSync()) recovery.deleteSync();
    recovery.writeAsStringSync(jsonEncode(values), flush: true);
    if (current.existsSync()) current.deleteSync();
    recovery.renameSync(current.path);
  }

  static String getString(String key, {String defaultValue = ''}) =>
      (_cache[key] as String?) ?? defaultValue;

  static bool getBool(String key, {bool defaultValue = false}) =>
      (_cache[key] as bool?) ?? defaultValue;

  static void setString(String key, String value) {
    _cache[key] = value;
    _persist();
  }

  static void setBool(String key, bool value) {
    _cache[key] = value;
    _persist();
  }

  static void _persist() {
    File? temporary;
    try {
      final current = _file();
      final backup = File('${current.path}.bak');
      temporary = File('${current.path}.tmp');

      if (temporary.existsSync()) temporary.deleteSync();
      temporary.writeAsStringSync(jsonEncode(_cache), flush: true);

      // Keep one known-good generation while replacing the primary file. If
      // the process or PC stops between either rename, load() recovers from
      // prefs.json.bak instead of silently losing the remembered phone.
      if (backup.existsSync()) backup.deleteSync();
      if (current.existsSync()) current.renameSync(backup.path);
      try {
        temporary.renameSync(current.path);
      } catch (_) {
        if (!current.existsSync() && backup.existsSync()) {
          backup.copySync(current.path);
        }
        rethrow;
      }

      _lastError = null;
    } catch (error) {
      _lastError = 'Could not save AudioShare preferences: $error';
      stderr.writeln(_lastError);
    } finally {
      if (temporary != null && temporary.existsSync()) {
        try {
          temporary.deleteSync();
        } catch (_) {
          // The visible persistence warning above is the useful failure.
        }
      }
    }
  }
}
