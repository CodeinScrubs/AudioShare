import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/device_model.dart';

const _companionLaunchAction = 'com.audioshare.usbcompanion.LAUNCH_SESSION';
// Keep this synchronized with the companion artifact accepted by the
// release workflow. A newer phone-side companion must never be silently
// downgraded by an older portable host.
const bundledCompanionVersionCode = 6;
const minimumCompanionVersionCode = bundledCompanionVersionCode;
const _forwardJournalOwner = 'CodeinScrubs.AudioShare';
const _forwardJournalVersion = 1;

Map<String, String> parseAdbServerStatus(String output) {
  final values = <String, String>{};
  for (final rawLine in const LineSplitter().convert(output)) {
    final line = rawLine.trim();
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).trim();
    final value = line.substring(separator + 1).trim();
    if (RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(key) && value.isNotEmpty) {
      values[key] = value;
    }
  }
  return values;
}

Future<String> _collectBoundedText(
  Stream<List<int>> source, {
  int maximumCharacters = 16 * 1024,
}) async {
  final output = StringBuffer();
  var remaining = maximumCharacters;
  await for (final text in source.transform(
    const Utf8Decoder(allowMalformed: true),
  )) {
    if (remaining <= 0) continue;
    final accepted = text.length <= remaining
        ? text
        : text.substring(0, remaining);
    output.write(accepted);
    remaining -= accepted.length;
  }
  if (remaining <= 0) output.write('\n<output truncated>');
  return output.toString();
}

String _diagnosticValue(Object? value) {
  final normalized = value?.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return normalized == null || normalized.isEmpty ? 'none' : normalized;
}

class CompanionHostUpdateRequiredException implements Exception {
  const CompanionHostUpdateRequiredException({
    required this.installedVersionCode,
    required this.hostVersionCode,
  });

  final int installedVersionCode;
  final int hostVersionCode;

  @override
  String toString() =>
      'The installed Android companion (version code '
      '$installedVersionCode) is newer than this Windows host (version code '
      '$hostVersionCode). Update AudioShare for Windows before connecting.';
}

class CompanionReplacementRequiredException implements Exception {
  const CompanionReplacementRequiredException();

  @override
  String toString() =>
      'Android already has an AudioShare companion signed by a different '
      'publisher. Uninstall that companion from the phone, then choose '
      'Install companion again. AudioShare will not silently remove an app.';
}

int? parseCompanionVersionCode(String packageDump) {
  final match = RegExp(
    r'^\s*versionCode=(\d+)\b',
    multiLine: true,
  ).firstMatch(packageDump);
  return match == null ? null : int.tryParse(match.group(1)!);
}

bool hasSuccessfulActivityLaunchStatus(String output) => RegExp(
  r'^\s*Status:\s*ok\s*$',
  multiLine: true,
  caseSensitive: false,
).hasMatch(output);

class CompanionInstallation {
  const CompanionInstallation(this.packageName);

  final String packageName;

  String get activityComponent =>
      '$packageName/com.audioshare.usbcompanion.BridgeActivity';

  String get bundledApkName => switch (packageName) {
    'com.audioshare.usbcompanion' => 'audioshare-companion.apk',
    'com.audioshare.usbcompanion.debug' => 'audioshare-companion-poc-debug.apk',
    _ => throw StateError('Unsupported companion package: $packageName'),
  };

  static const release = CompanionInstallation('com.audioshare.usbcompanion');
  static const debug = CompanionInstallation(
    'com.audioshare.usbcompanion.debug',
  );
}

Map<String, String> buildUsbOnlyAdbEnvironment(
  Map<String, String> parentEnvironment,
) {
  const forbiddenKeys = {
    'ADB_SERVER_SOCKET',
    'ANDROID_ADB_SERVER_ADDRESS',
    'ANDROID_ADB_SERVER_PORT',
    'ANDROID_SERIAL',
  };
  final environment = Map<String, String>.of(parentEnvironment)
    ..removeWhere((key, _) => forbiddenKeys.contains(key.toUpperCase()));
  environment['ADB_MDNS'] = '0';
  environment['ADB_MDNS_AUTO_CONNECT'] = '0';
  environment['ADB_EMU'] = '0';
  return environment;
}

extension _LastOrNull<T> on Iterable<T> {
  T? get lastOrNull {
    T? result;
    for (final value in this) {
      result = value;
    }
    return result;
  }
}

AdbTransportType classifyWindowsAdbTransport(
  String deviceId,
  Map<String, String> attributes,
) {
  final normalizedId = deviceId.toLowerCase();
  if (normalizedId.startsWith('emulator-') ||
      normalizedId.startsWith('vsock:')) {
    return AdbTransportType.emulator;
  }
  if (attributes.containsKey('usb')) return AdbTransportType.usb;

  // ADB's Windows USB backend registers native USB transports without a
  // devpath, so `adb devices -l` normally omits the `usb:` field that Linux
  // and macOS builds expose. TCP and wireless-debugging serials remain
  // syntactically identifiable; every remaining Windows hardware transport is
  // therefore the positive USB case for this Windows-only host application.
  final tcpSerial = RegExp(r'^(?:\[[^\]]+\]|[^:]+):\d{1,5}$');
  final mdnsTlsSerial = normalizedId.contains('._adb-tls-connect._tcp');
  if (tcpSerial.hasMatch(deviceId) || mdnsTlsSerial) {
    return AdbTransportType.network;
  }
  return AdbTransportType.usb;
}

class AdbCommandRequest {
  const AdbCommandRequest({
    required this.operation,
    required this.arguments,
    this.timeout = const Duration(seconds: 8),
    this.sensitiveArgumentIndexes = const <int>{},
  });

  final String operation;
  final List<String> arguments;
  final Duration timeout;
  final Set<int> sensitiveArgumentIndexes;

  List<String> get safeArguments => List<String>.generate(
    arguments.length,
    (index) => sensitiveArgumentIndexes.contains(index)
        ? '<redacted>'
        : arguments[index],
    growable: false,
  );
}

class AdbCommandResult {
  const AdbCommandResult({
    required this.operation,
    required this.executable,
    required this.arguments,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.duration,
    required this.timedOut,
    this.spawnError,
  });

  final String operation;
  final String executable;
  final List<String> arguments;
  final int? exitCode;
  final String stdout;
  final String stderr;
  final Duration duration;
  final bool timedOut;
  final Object? spawnError;

  bool get succeeded => !timedOut && spawnError == null && exitCode == 0;

  @override
  String toString() {
    final status = timedOut
        ? 'timed out'
        : spawnError != null
        ? 'could not start'
        : 'exit ${exitCode ?? 'unknown'}';
    final details = stderr.trim().isNotEmpty ? stderr.trim() : stdout.trim();
    return '$operation $status after ${duration.inMilliseconds} ms'
        '${details.isEmpty ? '' : ': $details'}';
  }
}

class AdbCommandException implements Exception {
  const AdbCommandException(this.result);

  final AdbCommandResult result;

  @override
  String toString() => result.toString();
}

abstract interface class AdbCommandRunner {
  Future<AdbCommandResult> run(String executable, AdbCommandRequest request);
}

class ProcessAdbCommandRunner implements AdbCommandRunner {
  ProcessAdbCommandRunner({Map<String, String>? parentEnvironment})
    : _parentEnvironment = Map<String, String>.of(
        parentEnvironment ?? Platform.environment,
      );

  static const _maximumOutputCharacters = 64 * 1024;
  final Map<String, String> _parentEnvironment;

  Future<String> _collect(Stream<List<int>> source) async {
    final output = StringBuffer();
    var remaining = _maximumOutputCharacters;
    await for (final text in source.transform(
      const Utf8Decoder(allowMalformed: true),
    )) {
      if (remaining <= 0) continue;
      final accepted = text.length <= remaining
          ? text
          : text.substring(0, remaining);
      output.write(accepted);
      remaining -= accepted.length;
    }
    if (remaining <= 0) output.write('\n<output truncated>');
    return output.toString();
  }

  @override
  Future<AdbCommandResult> run(
    String executable,
    AdbCommandRequest request,
  ) async {
    final stopwatch = Stopwatch()..start();
    Process process;
    try {
      process = await Process.start(
        executable,
        request.arguments,
        environment: buildUsbOnlyAdbEnvironment(_parentEnvironment),
        includeParentEnvironment: false,
        runInShell: false,
      );
    } catch (error) {
      stopwatch.stop();
      return AdbCommandResult(
        operation: request.operation,
        executable: executable,
        arguments: request.safeArguments,
        exitCode: null,
        stdout: '',
        stderr: '',
        duration: stopwatch.elapsed,
        timedOut: false,
        spawnError: error,
      );
    }

    final stdoutFuture = _collect(process.stdout);
    final stderrFuture = _collect(process.stderr);
    final exitFuture = process.exitCode;
    var timedOut = false;
    int? exitCode;
    try {
      exitCode = await exitFuture.timeout(request.timeout);
    } on TimeoutException {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      try {
        exitCode = await exitFuture.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        exitCode = null;
      }
    }

    final output = await Future.wait([
      stdoutFuture.timeout(
        const Duration(seconds: 2),
        onTimeout: () => '<stdout stream did not close>',
      ),
      stderrFuture.timeout(
        const Duration(seconds: 2),
        onTimeout: () => '<stderr stream did not close>',
      ),
    ]);
    stopwatch.stop();
    return AdbCommandResult(
      operation: request.operation,
      executable: executable,
      arguments: request.safeArguments,
      exitCode: exitCode,
      stdout: output[0],
      stderr: output[1],
      duration: stopwatch.elapsed,
      timedOut: timedOut,
    );
  }
}

class AdbForwardSession {
  const AdbForwardSession({
    required this.deviceId,
    required this.hostPort,
    required this.socketName,
    required this.generation,
  });

  final String deviceId;
  final int hostPort;
  final String socketName;
  final int generation;
}

/// Testable boundary used by the Windows connection supervisor.
///
/// The production implementation below owns process execution and ADB device
/// tracking. Tests can provide deterministic device snapshots without starting
/// or mutating the user's ambient ADB server.
abstract interface class AdbController {
  String get executablePath;
  List<String> get diagnosticLines;

  Future<void> validateRuntime();
  Future<List<DeviceModel>> devices();
  Stream<void> deviceChanges();
  Future<CompanionInstallation?> findCompanion(String deviceId);
  String? bundledCompanionApkPath();
  Future<CompanionInstallation> installBundledCompanion(String deviceId);

  Future<void> launchCompanion({
    required String deviceId,
    required String socketName,
    required String tokenHex,
    required int generation,
    required CompanionInstallation installation,
  });

  Future<AdbForwardSession> createForward({
    required String deviceId,
    required String socketName,
    required int generation,
  });

  Future<void> removeForward(AdbForwardSession session);
  void dispose();
}

class AdbService implements AdbController {
  AdbService({
    AdbCommandRunner? runner,
    String? adbPath,
    String? companionDirectoryPath,
    String? forwardJournalPath,
  }) : _runner = runner ?? ProcessAdbCommandRunner(),
       _adbPath = adbPath ?? _defaultAdbPath(),
       _companionDirectoryPath = companionDirectoryPath,
       _forwardJournalPath = forwardJournalPath ?? _defaultForwardJournalPath();

  final AdbCommandRunner _runner;
  final String _adbPath;
  final String? _companionDirectoryPath;
  final String _forwardJournalPath;
  final Map<String, DeviceModel> _deviceCache = {};
  bool _disposed = false;
  Process? _deviceTrackerProcess;
  bool _trackerHealthy = false;
  int _trackerRestartCount = 0;
  int? _trackerLastExitCode;
  String _trackerLastError = '';
  String _forwardJournalStatus = 'not_checked';
  Map<String, String> _adbServerStatus = const {};
  String _adbServerStatusError = 'not_checked';
  Future<void>? _forwardRecovery;
  bool _forwardRecoveryCompleted = false;

  static String _defaultAdbPath() {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    return '$executableDirectory${Platform.pathSeparator}adb.exe';
  }

  static String _defaultForwardJournalPath() {
    final base =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return '$base${Platform.pathSeparator}CodeinScrubs'
        '${Platform.pathSeparator}AudioShare'
        '${Platform.pathSeparator}adb-forward-journal.json';
  }

  @override
  String get executablePath => _adbPath;

  @override
  List<String> get diagnosticLines => [
    'adb_tracker_healthy=$_trackerHealthy',
    'adb_tracker_restarts=$_trackerRestartCount',
    'adb_tracker_last_exit=${_trackerLastExitCode ?? 'none'}',
    'adb_tracker_last_error=${_diagnosticValue(_trackerLastError)}',
    'adb_forward_journal=$_forwardJournalStatus',
    if (_adbServerStatus.isNotEmpty)
      ..._adbServerStatus.entries.map(
        (entry) => 'adb_server_${entry.key}=${_diagnosticValue(entry.value)}',
      )
    else
      'adb_server_status=${_diagnosticValue(_adbServerStatusError)}',
  ];

  Future<AdbCommandResult> run(AdbCommandRequest request) async {
    if (_disposed) {
      throw StateError('ADB service has been disposed');
    }
    return _runner.run(_adbPath, request);
  }

  Future<AdbCommandResult> _required(AdbCommandRequest request) async {
    final result = await run(request);
    if (!result.succeeded) throw AdbCommandException(result);
    return result;
  }

  @override
  Future<void> validateRuntime() async {
    final executable = File(_adbPath);
    if (!executable.existsSync()) {
      throw StateError(
        'Package incomplete. Extract the complete ZIP first. '
        'Bundled ADB is missing: $_adbPath',
      );
    }
    final directory = executable.parent.path;
    for (final name in ['AdbWinApi.dll', 'AdbWinUsbApi.dll']) {
      final file = File('$directory${Platform.pathSeparator}$name');
      if (!file.existsSync()) {
        throw StateError(
          'Package incomplete. Extract the complete ZIP first. '
          'Bundled ADB dependency is missing: ${file.path}',
        );
      }
    }
    if (bundledCompanionApkPath() == null) {
      throw StateError(
        'Package incomplete. Extract the complete ZIP first. '
        'The bundled Android companion APK is missing.',
      );
    }
    await _required(
      const AdbCommandRequest(
        operation: 'check ADB version',
        arguments: ['version'],
        timeout: Duration(seconds: 5),
      ),
    );
    final serverStatus = await run(
      const AdbCommandRequest(
        operation: 'inspect shared ADB server',
        arguments: ['server-status'],
        timeout: Duration(seconds: 5),
      ),
    );
    if (serverStatus.succeeded) {
      _adbServerStatus = parseAdbServerStatus(serverStatus.stdout);
      _adbServerStatusError = _adbServerStatus.isEmpty
          ? 'empty_or_unrecognized'
          : 'none';
    } else {
      _adbServerStatus = const {};
      _adbServerStatusError = serverStatus.toString();
    }
    await recoverOwnedForwards();
  }

  @override
  Future<List<DeviceModel>> devices() async {
    final result = await _required(
      const AdbCommandRequest(
        operation: 'list ADB devices',
        arguments: ['devices', '-l'],
        timeout: Duration(seconds: 6),
      ),
    );
    final parsed = <DeviceModel>[];
    for (final raw in const LineSplitter().convert(result.stdout)) {
      final line = raw.trim();
      if (line.isEmpty ||
          line.startsWith('List of devices') ||
          line.startsWith('* daemon')) {
        continue;
      }
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final deviceId = parts[0];
      final state = switch (parts[1]) {
        'device' => AdbDeviceState.authorized,
        'unauthorized' => AdbDeviceState.unauthorized,
        'offline' => AdbDeviceState.offline,
        _ => AdbDeviceState.unknown,
      };
      final attributes = <String, String>{};
      for (final part in parts.skip(2)) {
        final separator = part.indexOf(':');
        if (separator > 0) {
          attributes[part.substring(0, separator)] = part.substring(
            separator + 1,
          );
        }
      }
      final transport = classifyWindowsAdbTransport(deviceId, attributes);
      final transportId = int.tryParse(attributes['transport_id'] ?? '');

      DeviceModel? metadata;
      String? metadataError;
      if (state == AdbDeviceState.authorized &&
          transport == AdbTransportType.usb) {
        metadata = _deviceCache[deviceId];
        if (metadata == null) {
          try {
            metadata = await _loadMetadata(
              deviceId,
              transport,
              transportId,
              attributes,
            );
            _deviceCache[deviceId] = metadata;
          } catch (error, stack) {
            // Optional metadata must not make every other connected phone
            // disappear. Keep a basic, connectable model and retry metadata
            // on the next poll.
            metadataError = error.toString();
            stderr.writeln(
              'Android metadata unavailable for $deviceId: '
              '$error\n$stack',
            );
          }
        }
      }
      final ipPort = _getIpPort(deviceId);
      parsed.add(
        metadata ??
            DeviceModel(
              deviceId: deviceId,
              usb: transport == AdbTransportType.usb,
              serialNumber: '',
              model: attributes['model'] ?? '',
              manufacturer: '',
              androidVersion: '',
              apiLevel: '',
              ip: ipPort.$1,
              port: ipPort.$2,
              adbState: state,
              transportType: transport,
              transportId: transportId,
              metadataError: metadataError,
            ),
      );
    }
    final currentIds = parsed.map((device) => device.deviceId).toSet();
    _deviceCache.removeWhere((id, _) => !currentIds.contains(id));
    return parsed;
  }

  /// Emits whenever `adb track-devices` reports a new device snapshot.
  ///
  /// The tracker is only a wake-up signal. [devices] remains the single
  /// structured parser and source of truth. If ADB exits or cannot start, the
  /// tracker restarts after a bounded delay while the caller retains a slow
  /// polling fallback.
  @override
  Stream<void> deviceChanges() async* {
    var restartDelaySeconds = 1;
    while (!_disposed) {
      Process? tracker;
      var sawSnapshot = false;
      Future<String>? stderrFuture;
      try {
        tracker = await Process.start(
          _adbPath,
          const ['track-devices', '-l'],
          environment: buildUsbOnlyAdbEnvironment(Platform.environment),
          includeParentEnvironment: false,
          runInShell: false,
        );
        if (_disposed) {
          tracker.kill(ProcessSignal.sigkill);
          return;
        }
        _deviceTrackerProcess = tracker;
        stderrFuture = _collectBoundedText(tracker.stderr);
        await for (final chunk in tracker.stdout) {
          if (_disposed) return;
          if (chunk.isNotEmpty) {
            sawSnapshot = true;
            _trackerHealthy = true;
            yield null;
          }
        }
        _trackerLastExitCode = await tracker.exitCode;
        _trackerLastError = (await stderrFuture).trim();
      } catch (error) {
        // The periodic structured refresh reports actionable ADB failures.
        // Tracking itself is only a latency optimization.
        _trackerLastError = error.toString();
      } finally {
        _trackerHealthy = false;
        _trackerRestartCount++;
        if (identical(_deviceTrackerProcess, tracker)) {
          _deviceTrackerProcess = null;
        }
        tracker?.kill(ProcessSignal.sigkill);
      }
      if (!_disposed) {
        await Future<void>.delayed(Duration(seconds: restartDelaySeconds));
        if (sawSnapshot) {
          restartDelaySeconds = 1;
        } else {
          restartDelaySeconds = (restartDelaySeconds * 2).clamp(1, 15);
        }
      }
    }
  }

  Future<DeviceModel> _loadMetadata(
    String deviceId,
    AdbTransportType transport,
    int? transportId,
    Map<String, String> attributes,
  ) async {
    final result = await _required(
      AdbCommandRequest(
        operation: 'read Android device metadata',
        arguments: [
          '-s',
          deviceId,
          'shell',
          'echo "sn:\$(getprop ro.serialno)"; '
              'echo "mo:\$(getprop ro.product.model)"; '
              'echo "mf:\$(getprop ro.product.manufacturer)"; '
              'echo "av:\$(getprop ro.build.version.release)"; '
              'echo "al:\$(getprop ro.build.version.sdk)"',
        ],
        timeout: const Duration(seconds: 6),
      ),
    );
    String tag(String name) {
      for (final raw in const LineSplitter().convert(result.stdout)) {
        final line = raw.trim();
        if (line.startsWith('$name:')) return line.substring(name.length + 1);
      }
      return '';
    }

    final ipPort = _getIpPort(deviceId);
    return DeviceModel(
      deviceId: deviceId,
      usb: transport == AdbTransportType.usb,
      serialNumber: tag('sn'),
      model: tag('mo').isEmpty ? attributes['model'] ?? '' : tag('mo'),
      manufacturer: tag('mf'),
      androidVersion: tag('av'),
      apiLevel: tag('al'),
      ip: ipPort.$1,
      port: ipPort.$2,
      adbState: AdbDeviceState.authorized,
      transportType: transport,
      transportId: transportId,
    );
  }

  (String, String) _getIpPort(String deviceId) {
    final match = RegExp(
      r'(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})',
    ).firstMatch(deviceId);
    return match == null ? ('', '') : (match.group(1)!, match.group(2)!);
  }

  @override
  Future<CompanionInstallation?> findCompanion(String deviceId) async {
    for (final installation in const [
      CompanionInstallation.release,
      CompanionInstallation.debug,
    ]) {
      final result = await run(
        AdbCommandRequest(
          operation: 'check Android companion',
          arguments: [
            '-s',
            deviceId,
            'shell',
            'pm',
            'path',
            installation.packageName,
          ],
          timeout: const Duration(seconds: 6),
        ),
      );
      final packageAbsent =
          (result.exitCode == 0 || result.exitCode == 1) &&
          result.stdout.trim().isEmpty &&
          result.stderr.trim().isEmpty;
      if (packageAbsent) continue;
      if (!result.succeeded) throw AdbCommandException(result);
      final installedApkPath = _parseInstalledBaseApkPath(result.stdout);
      if (installedApkPath == null) {
        throw FormatException(
          'The installed ${installation.packageName} package does not have '
          'one valid base APK.',
        );
      }
      final packageDump = await _required(
        AdbCommandRequest(
          operation: 'check Android companion compatibility',
          arguments: [
            '-s',
            deviceId,
            'shell',
            'dumpsys',
            'package',
            installation.packageName,
          ],
          timeout: const Duration(seconds: 8),
        ),
      );
      final versionCode = parseCompanionVersionCode(packageDump.stdout);
      if (versionCode == null) {
        throw FormatException(
          'Could not read the installed companion version for '
          '${installation.packageName}.',
        );
      }
      if (versionCode > bundledCompanionVersionCode) {
        throw CompanionHostUpdateRequiredException(
          installedVersionCode: versionCode,
          hostVersionCode: bundledCompanionVersionCode,
        );
      }
      if (versionCode >= minimumCompanionVersionCode &&
          await _matchesBundledCompanion(
            deviceId,
            installation,
            installedApkPath,
          )) {
        return installation;
      }
    }
    return null;
  }

  @override
  String? bundledCompanionApkPath() {
    for (final installation in const [
      CompanionInstallation.release,
      CompanionInstallation.debug,
    ]) {
      final path = _bundledCompanionPath(installation);
      if (path != null) return path;
    }
    return null;
  }

  String? _bundledCompanionPath(CompanionInstallation installation) {
    final directory =
        _companionDirectoryPath ??
        '${File(Platform.resolvedExecutable).parent.path}'
            '${Platform.pathSeparator}android';
    final candidate = File(
      '$directory${Platform.pathSeparator}${installation.bundledApkName}',
    );
    return candidate.existsSync() ? candidate.path : null;
  }

  String? _parseInstalledBaseApkPath(String output) {
    final packageLines = const LineSplitter()
        .convert(output)
        .map((line) => line.trim())
        .where((line) => line.startsWith('package:'))
        .toList(growable: false);
    if (packageLines.length != 1) return null;
    final path = packageLines.single.substring('package:'.length);
    final safePath = RegExp(r'^/[A-Za-z0-9._~+=@%/-]+/base\.apk$');
    return safePath.hasMatch(path) ? path : null;
  }

  Future<bool> _matchesBundledCompanion(
    String deviceId,
    CompanionInstallation installation,
    String installedApkPath,
  ) async {
    final bundledPath = _bundledCompanionPath(installation);
    if (bundledPath == null) return false;
    final result = await _required(
      AdbCommandRequest(
        operation: 'verify installed Android companion APK',
        arguments: ['-s', deviceId, 'shell', 'sha256sum', installedApkPath],
        timeout: const Duration(seconds: 12),
      ),
    );
    String? installedHash;
    for (final rawLine in const LineSplitter().convert(result.stdout)) {
      final fields = rawLine.trim().split(RegExp(r'\s+'));
      if (fields.length == 2 &&
          fields[1] == installedApkPath &&
          RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(fields[0])) {
        installedHash = fields[0].toLowerCase();
        break;
      }
    }
    if (installedHash == null) {
      throw FormatException(
        'Android did not return a valid companion APK SHA-256.',
      );
    }
    final bundledHash = (await sha256.bind(File(bundledPath).openRead()).first)
        .toString();
    return installedHash == bundledHash;
  }

  @override
  Future<CompanionInstallation> installBundledCompanion(String deviceId) async {
    final apkPath = bundledCompanionApkPath();
    if (apkPath == null) {
      throw StateError(
        'No companion APK is included in this AudioShare build.',
      );
    }
    final installResult = await run(
      AdbCommandRequest(
        operation: 'install Android companion',
        arguments: ['-s', deviceId, 'install', '-r', apkPath],
        timeout: const Duration(minutes: 2),
      ),
    );
    if (!installResult.succeeded) {
      final details = '${installResult.stdout}\n${installResult.stderr}';
      if (details.contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
        throw const CompanionReplacementRequiredException();
      }
      throw AdbCommandException(installResult);
    }
    if (!installResult.stdout
        .split(RegExp(r'\r?\n'))
        .any((line) => line.trim() == 'Success')) {
      throw AdbCommandException(
        AdbCommandResult(
          operation: installResult.operation,
          executable: installResult.executable,
          arguments: installResult.arguments,
          exitCode: 1,
          stdout: installResult.stdout,
          stderr: installResult.stderr,
          duration: installResult.duration,
          timedOut: false,
        ),
      );
    }
    final installed = await findCompanion(deviceId);
    if (installed == null) {
      throw StateError(
        'ADB reported a successful install, but the companion package '
        'cannot be found on the device.',
      );
    }
    return installed;
  }

  @override
  Future<void> launchCompanion({
    required String deviceId,
    required String socketName,
    required String tokenHex,
    required int generation,
    required CompanionInstallation installation,
  }) async {
    final arguments = [
      '-s',
      deviceId,
      'shell',
      'am',
      'start',
      '-W',
      '-n',
      installation.activityComponent,
      '-a',
      _companionLaunchAction,
      '--es',
      'socket_name',
      socketName,
      '--es',
      'token_hex',
      tokenHex,
      '--el',
      'generation',
      generation.toString(),
    ];
    final result = await _required(
      AdbCommandRequest(
        operation: 'launch Android companion',
        arguments: arguments,
        timeout: const Duration(seconds: 10),
        sensitiveArgumentIndexes: {arguments.indexOf(tokenHex)},
      ),
    );
    final combined = '${result.stdout}\n${result.stderr}';
    if (!hasSuccessfulActivityLaunchStatus(combined) ||
        combined.contains('Error:') ||
        combined.contains('Error type') ||
        combined.contains('Exception')) {
      throw AdbCommandException(
        AdbCommandResult(
          operation: result.operation,
          executable: result.executable,
          arguments: result.arguments,
          exitCode: 1,
          stdout: result.stdout,
          stderr: result.stderr,
          duration: result.duration,
          timedOut: false,
        ),
      );
    }
  }

  @override
  Future<AdbForwardSession> createForward({
    required String deviceId,
    required String socketName,
    required int generation,
  }) async {
    _validateOwnedForwardIdentity(
      deviceId: deviceId,
      socketName: socketName,
      generation: generation,
    );
    final result = await _required(
      AdbCommandRequest(
        operation: 'create ADB USB audio forward',
        arguments: [
          '-s',
          deviceId,
          'forward',
          '--no-rebind',
          'tcp:0',
          'localabstract:$socketName',
        ],
        timeout: const Duration(seconds: 8),
      ),
    );
    final port = RegExp(r'^\s*(\d{1,5})\s*$', multiLine: true)
        .allMatches(result.stdout)
        .map((match) => int.tryParse(match.group(1)!))
        .whereType<int>()
        .lastOrNull;
    if (port == null || port < 1 || port > 65535) {
      throw FormatException(
        'ADB did not return a valid forwarded port: ${result.stdout.trim()}',
      );
    }
    final session = AdbForwardSession(
      deviceId: deviceId,
      hostPort: port,
      socketName: socketName,
      generation: generation,
    );
    try {
      final existing = await _readForwardJournal();
      await _writeForwardJournal([...existing, session]);
      _forwardJournalStatus = 'active:${existing.length + 1}';
    } catch (journalError) {
      // Never return an unjournaled mapping: a process crash immediately
      // after this method returns would otherwise make exact cleanup
      // impossible. Roll the just-created mapping back first.
      try {
        await _removeForwardMapping(session);
      } catch (cleanupError) {
        throw StateError(
          'Could not record the owned ADB forward ($journalError) and could '
          'not roll it back ($cleanupError).',
        );
      }
      rethrow;
    }
    return session;
  }

  @override
  Future<void> removeForward(AdbForwardSession session) async {
    await _removeForwardMapping(session);
    try {
      final existing = await _readForwardJournal();
      await _writeForwardJournal(
        existing
            .where((candidate) => !_sameForward(candidate, session))
            .toList(),
      );
    } catch (error) {
      // The mapping is already gone. Retaining a stale journal entry is safe:
      // the next startup verifies --list before removing anything and will
      // clear the absent entry.
      _forwardJournalStatus = 'cleanup_record_failed:$error';
      stderr.writeln('Could not update ADB forward cleanup journal: $error');
    }
  }

  Future<void> _removeForwardMapping(AdbForwardSession session) async {
    final result = await run(
      AdbCommandRequest(
        operation: 'remove owned ADB USB audio forward',
        arguments: [
          '-s',
          session.deviceId,
          'forward',
          '--remove',
          'tcp:${session.hostPort}',
        ],
        timeout: const Duration(seconds: 6),
      ),
    );
    final cleanupError = result.stderr.toLowerCase();
    final alreadyGone =
        cleanupError.contains('device not found') ||
        (cleanupError.contains('listener') &&
            cleanupError.contains('not found'));
    if (!result.succeeded && !alreadyGone) {
      throw AdbCommandException(result);
    }
  }

  Future<void> recoverOwnedForwards() {
    if (_forwardRecoveryCompleted) return Future.value();
    final active = _forwardRecovery;
    if (active != null) return active;
    final recovery = _runForwardRecovery();
    _forwardRecovery = recovery;
    return recovery.whenComplete(() {
      if (identical(_forwardRecovery, recovery)) _forwardRecovery = null;
    });
  }

  Future<void> _runForwardRecovery() async {
    await _recoverOwnedForwards();
    final retryable =
        _forwardJournalStatus.startsWith('recovery_deferred') ||
        _forwardJournalStatus.startsWith('recovery_record_failed');
    if (!retryable) _forwardRecoveryCompleted = true;
  }

  Future<void> _recoverOwnedForwards() async {
    final journal = await _readForwardJournal();
    if (journal.isEmpty) {
      if (_forwardJournalStatus == 'not_checked') {
        _forwardJournalStatus = 'clean';
      }
      return;
    }
    final listed = await run(
      const AdbCommandRequest(
        operation: 'list ADB forwards for crash recovery',
        arguments: ['forward', '--list'],
        timeout: Duration(seconds: 6),
      ),
    );
    if (!listed.succeeded) {
      _forwardJournalStatus = 'recovery_deferred:${listed.toString()}';
      return;
    }
    final activeMappings = const LineSplitter()
        .convert(listed.stdout)
        .map((line) => line.trim().split(RegExp(r'\s+')))
        .where((parts) => parts.length == 3)
        .map((parts) => (parts[0], parts[1], parts[2]))
        .toSet();
    final retained = <AdbForwardSession>[];
    var removed = 0;
    for (final session in journal) {
      final exact = (
        session.deviceId,
        'tcp:${session.hostPort}',
        'localabstract:${session.socketName}',
      );
      if (!activeMappings.contains(exact)) continue;
      try {
        await _removeForwardMapping(session);
        removed++;
      } catch (error) {
        retained.add(session);
        _forwardJournalStatus = 'recovery_deferred:$error';
      }
    }
    try {
      await _writeForwardJournal(retained);
      if (retained.isEmpty) {
        _forwardJournalStatus = removed == 0
            ? 'cleaned_absent_entries'
            : 'recovered:$removed';
      } else {
        _forwardJournalStatus = 'recovery_deferred:${retained.length}';
      }
    } catch (error) {
      _forwardJournalStatus = 'recovery_record_failed:$error';
    }
  }

  void _validateOwnedForwardIdentity({
    required String deviceId,
    required String socketName,
    required int generation,
  }) {
    if (!RegExp(r'^[^\s]{1,255}$').hasMatch(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Invalid ADB serial');
    }
    if (!RegExp(r'^as_1_[0-9a-f]{16}$').hasMatch(socketName)) {
      throw ArgumentError.value(
        socketName,
        'socketName',
        'Not an AudioShare-owned socket name',
      );
    }
    if (generation < 1) {
      throw ArgumentError.value(generation, 'generation', 'Must be positive');
    }
  }

  bool _sameForward(AdbForwardSession left, AdbForwardSession right) =>
      left.deviceId == right.deviceId &&
      left.hostPort == right.hostPort &&
      left.socketName == right.socketName &&
      left.generation == right.generation;

  Future<List<AdbForwardSession>> _readForwardJournal() async {
    final file = File(_forwardJournalPath);
    if (!await file.exists()) return [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['owner'] != _forwardJournalOwner ||
          decoded['version'] != _forwardJournalVersion ||
          decoded['forwards'] is! List<dynamic>) {
        throw const FormatException('Unrecognized journal envelope');
      }
      final result = <AdbForwardSession>[];
      for (final raw in decoded['forwards'] as List<dynamic>) {
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('Invalid journal record');
        }
        final deviceId = raw['deviceId'];
        final hostPort = raw['hostPort'];
        final socketName = raw['socketName'];
        final generation = raw['generation'];
        if (deviceId is! String ||
            hostPort is! int ||
            socketName is! String ||
            generation is! int ||
            hostPort < 1 ||
            hostPort > 65535) {
          throw const FormatException('Invalid journal field');
        }
        _validateOwnedForwardIdentity(
          deviceId: deviceId,
          socketName: socketName,
          generation: generation,
        );
        result.add(
          AdbForwardSession(
            deviceId: deviceId,
            hostPort: hostPort,
            socketName: socketName,
            generation: generation,
          ),
        );
      }
      return result;
    } catch (error) {
      _forwardJournalStatus = 'invalid_ignored:$error';
      // The journal itself is application-owned, but its contents are not
      // trusted. Quarantine it without issuing any ADB removal command.
      final quarantine = File(
        '$_forwardJournalPath.invalid.${DateTime.now().millisecondsSinceEpoch}',
      );
      try {
        await file.rename(quarantine.path);
      } catch (_) {
        try {
          await file.delete();
        } catch (_) {}
      }
      return [];
    }
  }

  Future<void> _writeForwardJournal(List<AdbForwardSession> sessions) async {
    final file = File(_forwardJournalPath);
    if (sessions.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    final temporary = File(
      '$_forwardJournalPath.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    final encoded = jsonEncode({
      'owner': _forwardJournalOwner,
      'version': _forwardJournalVersion,
      'forwards': sessions
          .map(
            (session) => {
              'deviceId': session.deviceId,
              'hostPort': session.hostPort,
              'socketName': session.socketName,
              'generation': session.generation,
            },
          )
          .toList(growable: false),
    });
    try {
      await temporary.writeAsString(encoded, flush: true);
      try {
        await temporary.rename(file.path);
      } on FileSystemException {
        if (await file.exists()) await file.delete();
        await temporary.rename(file.path);
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _deviceTrackerProcess?.kill(ProcessSignal.sigkill);
    _deviceTrackerProcess = null;
    _deviceCache.clear();
  }
}
