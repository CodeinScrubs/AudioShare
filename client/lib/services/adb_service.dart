import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/device_model.dart';

const _companionLaunchAction = 'com.audioshare.usbcompanion.LAUNCH_SESSION';

class CompanionInstallation {
  const CompanionInstallation(this.packageName);

  final String packageName;

  String get activityComponent =>
      '$packageName/com.audioshare.usbcompanion.BridgeActivity';

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
      final accepted =
          text.length <= remaining ? text : text.substring(0, remaining);
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
  AdbService({AdbCommandRunner? runner, String? adbPath})
      : _runner = runner ?? ProcessAdbCommandRunner(),
        _adbPath = adbPath ?? _defaultAdbPath();

  final AdbCommandRunner _runner;
  final String _adbPath;
  final Map<String, DeviceModel> _deviceCache = {};
  bool _disposed = false;
  Process? _deviceTrackerProcess;

  static String _defaultAdbPath() {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    return '$executableDirectory${Platform.pathSeparator}adb.exe';
  }

  @override
  String get executablePath => _adbPath;

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
      final transport = deviceId.startsWith('emulator-')
          ? AdbTransportType.emulator
          : attributes.containsKey('usb')
              ? AdbTransportType.usb
              : deviceId.contains(':')
                  ? AdbTransportType.network
                  : AdbTransportType.unknown;
      final transportId = int.tryParse(attributes['transport_id'] ?? '');

      DeviceModel? metadata;
      if (state == AdbDeviceState.authorized &&
          transport == AdbTransportType.usb) {
        metadata = _deviceCache[deviceId];
        metadata ??= await _loadMetadata(
          deviceId,
          transport,
          transportId,
          attributes,
        );
        _deviceCache[deviceId] = metadata;
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
    while (!_disposed) {
      Process? tracker;
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
        unawaited(tracker.stderr.drain<void>());
        await for (final chunk in tracker.stdout) {
          if (_disposed) return;
          if (chunk.isNotEmpty) yield null;
        }
        await tracker.exitCode;
      } catch (_) {
        // The periodic structured refresh reports actionable ADB failures.
        // Tracking itself is only a latency optimization.
      } finally {
        if (identical(_deviceTrackerProcess, tracker)) {
          _deviceTrackerProcess = null;
        }
        tracker?.kill(ProcessSignal.sigkill);
      }
      if (!_disposed) {
        await Future<void>.delayed(const Duration(seconds: 1));
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
    final match =
        RegExp(r'(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})').firstMatch(deviceId);
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
      if (result.succeeded && result.stdout.contains('package:')) {
        return installation;
      }
      if (result.timedOut ||
          result.spawnError != null ||
          result.exitCode == null ||
          result.exitCode != 0) {
        throw AdbCommandException(result);
      }
    }
    return null;
  }

  @override
  String? bundledCompanionApkPath() {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final androidDirectory = Directory(
      '$executableDirectory${Platform.pathSeparator}android',
    );
    for (final name in const [
      'audioshare-companion.apk',
      'audioshare-companion-poc-debug.apk',
    ]) {
      final candidate = File(
        '${androidDirectory.path}${Platform.pathSeparator}$name',
      );
      if (candidate.existsSync()) return candidate.path;
    }
    return null;
  }

  @override
  Future<CompanionInstallation> installBundledCompanion(String deviceId) async {
    final apkPath = bundledCompanionApkPath();
    if (apkPath == null) {
      throw StateError(
        'No companion APK is included in this AudioShare build.',
      );
    }
    final installResult = await _required(
      AdbCommandRequest(
        operation: 'install Android companion',
        arguments: ['-s', deviceId, 'install', '-r', apkPath],
        timeout: const Duration(minutes: 2),
      ),
    );
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
    if (combined.contains('Error:') ||
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
    return AdbForwardSession(
      deviceId: deviceId,
      hostPort: port,
      socketName: socketName,
      generation: generation,
    );
  }

  @override
  Future<void> removeForward(AdbForwardSession session) async {
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
    final alreadyGone = cleanupError.contains('device not found') ||
        (cleanupError.contains('listener') &&
            cleanupError.contains('not found'));
    if (!result.succeeded && !alreadyGone) {
      throw AdbCommandException(result);
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
