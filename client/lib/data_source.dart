import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'models/device_model.dart';
import 'services/adb_service.dart';
import 'services/audio_capture.dart';
import 'utils/prefs.dart';

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    for (final value in this) {
      return value;
    }
    return null;
  }
}

enum UiErrorType {
  captureInitializationFailed,
  captureStopped,
  captureStartFailed,
  connectAndroidDeviceFailed,
  connectDeviceFailed,
}

enum ConnectionPhase {
  idle,
  checkingAdb,
  checkingCompanion,
  creatingForward,
  startingCompanion,
  connectingTransport,
  handshaking,
  initializingCapture,
  streaming,
  disconnecting,
  failed,
}

class UiError {
  const UiError({required this.type, this.nativeError, this.exception});

  final UiErrorType type;
  final AudioCaptureError? nativeError;
  final Object? exception;
}

class DataSource extends ChangeNotifier {
  DataSource({AdbService? adb, AudioCaptureService? audioCapture})
      : _adb = adb ?? AdbService(),
        _audioCapture = audioCapture ?? AudioCaptureService() {
    _startTime = DateTime.now();
    Prefs.load();
    _lastDeviceId = Prefs.getString('lastDeviceId');
    _lastCheck = Prefs.getBool('lastCheck', defaultValue: true);
    unawaited(_pollDevices());
    _deviceTrackerSubscription = _adb.deviceChanges().listen(
      (_) => unawaited(_pollDevices()),
      onError: (Object error, StackTrace stack) {
        debugPrint('ADB device tracker failed: $error\n$stack');
      },
    );
    _pollTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_pollDevices()),
    );
    _healthTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollNativeCaptureError(),
    );
  }

  final AdbService _adb;
  final AudioCaptureService _audioCapture;
  final Random _secureRandom = Random.secure();

  List<DeviceModel> _devices = [];
  final Map<String, int> _connectStateMap = {};
  final Map<String, ConnectionPhase> _phaseMap = {};
  final Set<String> _missingCompanionDeviceIds = {};
  final Set<String> _installingCompanionDeviceIds = {};
  int _deviceState = 0;
  bool _lastCheck = true;
  String _lastDeviceId = '';
  String _lastAutoDeviceId = '';
  UiError? _pendingError;
  late final DateTime _startTime;
  Timer? _pollTimer;
  Timer? _healthTimer;
  StreamSubscription<void>? _deviceTrackerSubscription;
  Timer? _connectionDeadline;
  bool _pollInFlight = false;
  bool _disposed = false;
  int _sessionGeneration = 0;
  AdbForwardSession? _forwardSession;
  WindowsCaptureMode _lastNotifiedCaptureMode = WindowsCaptureMode.inactive;
  int _lastNotifiedActiveEndpointCount = 0;

  List<DeviceModel> get devices => _devices;
  int get deviceState => _deviceState;
  bool get lastCheck => _lastCheck;
  int get droppedNativeChunks => _audioCapture.droppedNativeChunks;
  int get androidReceivedFrames => _audioCapture.androidReceivedFrames;
  int get androidDroppedFrames => _audioCapture.androidDroppedFrames;
  int get androidQueueDepth => _audioCapture.androidQueueDepth;
  int get androidBufferFrames => _audioCapture.androidBufferFrames;
  WindowsCaptureMode get captureMode => _audioCapture.captureMode;
  int get globalLoopbackHresult => _audioCapture.globalLoopbackHresult;
  int get activeEndpointCount => _audioCapture.activeEndpointCount;
  int get endpointDroppedFrames => _audioCapture.endpointDroppedFrames;
  int get endpointUnderrunFrames => _audioCapture.endpointUnderrunFrames;
  int get endpointDiscontinuities => _audioCapture.endpointDiscontinuities;
  int get endpointRebuildCount => _audioCapture.endpointRebuildCount;

  bool isCompanionMissing(String deviceId) =>
      _missingCompanionDeviceIds.contains(deviceId);

  bool isCompanionInstalling(String deviceId) =>
      _installingCompanionDeviceIds.contains(deviceId);

  ConnectionPhase getConnectionPhase(String deviceId) =>
      _phaseMap[deviceId] ?? ConnectionPhase.idle;

  UiError? takePendingError() {
    final error = _pendingError;
    _pendingError = null;
    return error;
  }

  void _setLastDeviceId(String id) {
    _lastDeviceId = id;
    Prefs.setString('lastDeviceId', id);
  }

  set lastCheck(bool value) {
    if (value) {
      _lastAutoDeviceId = _lastDeviceId;
    } else {
      _lastAutoDeviceId = '';
      _setLastDeviceId('');
    }
    _lastCheck = value;
    Prefs.setBool('lastCheck', value);
    notifyListeners();
  }

  int getConnectState(String deviceId) => _connectStateMap[deviceId] ?? 0;

  bool getConnectEnable(String deviceId) {
    final device = _devices
        .where((candidate) => candidate.deviceId == deviceId)
        .firstOrNull;
    if (device == null || !device.connectableUsb) return false;
    if (_connectStateMap.values.any((state) => state == 1)) return false;
    final state = _connectStateMap[deviceId] ?? 0;
    return state == 0 || state == 2;
  }

  Future<void> _pollDevices() async {
    if (_disposed || _pollInFlight) return;
    _pollInFlight = true;
    try {
      final devices = await _adb.devices();
      if (_disposed) return;
      _devices = devices;
      if (devices.isEmpty) {
        if (DateTime.now().difference(_startTime).inSeconds >= 2) {
          _deviceState = 1;
        }
      } else {
        _deviceState = 2;
      }

      final activeDevice = _connectStateMap.entries
          .where((entry) => entry.value == 1 || entry.value == 2)
          .map((entry) => entry.key)
          .firstOrNull;
      if (activeDevice != null &&
          !devices.any(
            (device) =>
                device.deviceId == activeDevice && device.connectableUsb,
          )) {
        unawaited(_handleDeviceLost(activeDevice));
      }

      final remembered = devices
          .where(
            (device) =>
                device.deviceId == _lastDeviceId && device.connectableUsb,
          )
          .firstOrNull;
      if (remembered != null &&
          _lastCheck &&
          _lastDeviceId.isNotEmpty &&
          (_connectStateMap[_lastDeviceId] ?? 0) == 0 &&
          _lastDeviceId != _lastAutoDeviceId) {
        connectDevice(_lastDeviceId);
      } else if (remembered == null && activeDevice == null) {
        _lastAutoDeviceId = '';
      }
      _pollNativeCaptureError();
    } catch (error) {
      if (_deviceState == 0) _deviceState = 1;
      debugPrint('ADB device refresh failed: $error');
    } finally {
      _pollInFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  bool _prepareAudioCapture() {
    if (!_audioCapture.initialize()) {
      _reportNativeError(
        UiErrorType.captureInitializationFailed,
        _audioCapture.takeLastError(fallbackCode: 1000, fallbackMessage: ''),
      );
      return false;
    }
    return true;
  }

  void _reportNativeError(UiErrorType type, AudioCaptureError? error) {
    _pendingError = UiError(
      type: type,
      nativeError: error ?? const AudioCaptureError(-1, ''),
    );
    if (!_disposed) notifyListeners();
  }

  void _pollNativeCaptureError() {
    if (!_connectStateMap.values.any((state) => state == 1 || state == 2)) {
      return;
    }
    final error = _audioCapture.pollLastError();
    if (error == null) {
      final mode = _audioCapture.captureMode;
      final activeEndpointCount = _audioCapture.activeEndpointCount;
      if (mode != _lastNotifiedCaptureMode ||
          activeEndpointCount != _lastNotifiedActiveEndpointCount) {
        _lastNotifiedCaptureMode = mode;
        _lastNotifiedActiveEndpointCount = activeEndpointCount;
        if (!_disposed) notifyListeners();
      }
      return;
    }
    final generation = _sessionGeneration;
    unawaited(
      _failConnection(
        generation,
        UiError(type: UiErrorType.captureStopped, nativeError: error),
        retryAutomatically: true,
      ),
    );
  }

  String _randomHex(int byteCount) => List<String>.generate(
        byteCount,
        (_) => _secureRandom.nextInt(256).toRadixString(16).padLeft(2, '0'),
        growable: false,
      ).join();

  void connectDevice(String deviceId) {
    unawaited(_connectDevice(deviceId));
  }

  Future<void> _connectDevice(String deviceId) async {
    if (_disposed) return;
    final device = _devices
        .where((candidate) => candidate.deviceId == deviceId)
        .firstOrNull;
    if (device == null || !device.connectableUsb) {
      _pendingError = const UiError(
        type: UiErrorType.connectDeviceFailed,
        exception: 'Select an authorized USB device. Network and emulator '
            'ADB transports are not accepted in automatic mode.',
      );
      notifyListeners();
      return;
    }

    _sessionGeneration++;
    final generation = _sessionGeneration;
    await _cleanupSession(forgetRememberedDevice: false);
    if (_disposed || generation != _sessionGeneration) return;
    if (!_prepareAudioCapture()) return;

    _lastAutoDeviceId = deviceId;
    _setLastDeviceId(deviceId);
    _connectStateMap
      ..clear()
      ..[deviceId] = 1;
    _phaseMap
      ..clear()
      ..[deviceId] = ConnectionPhase.checkingAdb;
    notifyListeners();

    try {
      await _adb.validateRuntime();
      _ensureCurrent(generation);
      await _connectWindowsCompanion(deviceId, generation);
    } catch (error, stack) {
      debugPrint('Connection failed: $error\n$stack');
      await _failConnection(
        generation,
        UiError(type: UiErrorType.connectAndroidDeviceFailed, exception: error),
        retryAutomatically: !_missingCompanionDeviceIds.contains(deviceId),
      );
    }
  }

  Future<void> _connectWindowsCompanion(String deviceId, int generation) async {
    _phaseMap[deviceId] = ConnectionPhase.checkingCompanion;
    notifyListeners();
    final installation = await _adb.findCompanion(deviceId);
    if (installation == null) {
      _missingCompanionDeviceIds.add(deviceId);
      notifyListeners();
      throw StateError(
        'The AudioShare USB companion is not installed or uses an '
        'incompatible package. Install the matching bundled APK once, then '
        'reconnect.',
      );
    }
    _missingCompanionDeviceIds.remove(deviceId);
    _ensureCurrent(generation);

    final socketName = 'as_1_${_randomHex(8)}';
    final tokenHex = _randomHex(32);
    _phaseMap[deviceId] = ConnectionPhase.creatingForward;
    notifyListeners();
    final forward = await _adb.createForward(
      deviceId: deviceId,
      socketName: socketName,
      generation: generation,
    );
    _ensureCurrent(generation);
    _forwardSession = forward;

    _phaseMap[deviceId] = ConnectionPhase.startingCompanion;
    notifyListeners();
    await _adb.launchCompanion(
      deviceId: deviceId,
      socketName: socketName,
      tokenHex: tokenHex,
      generation: generation,
      installation: installation,
    );
    _ensureCurrent(generation);

    _phaseMap[deviceId] = ConnectionPhase.connectingTransport;
    notifyListeners();
    final connectStarted = _audioCapture.connectToForward(
      forward.hostPort,
      tokenHex,
      (status) => _onNativeConnected(generation, deviceId, status),
    );
    if (!connectStarted) {
      throw StateError('Native outbound transport could not start');
    }
    _phaseMap[deviceId] = ConnectionPhase.handshaking;
    _connectionDeadline?.cancel();
    _connectionDeadline = Timer(const Duration(seconds: 15), () {
      if (generation == _sessionGeneration &&
          (_connectStateMap[deviceId] ?? 0) == 1) {
        unawaited(
          _failConnection(
            generation,
            const UiError(
              type: UiErrorType.connectAndroidDeviceFailed,
              exception: 'Timed out while waiting for the Android companion '
                  'transport handshake.',
            ),
            retryAutomatically: true,
          ),
        );
      }
    });
  }

  void _onNativeConnected(int generation, String deviceId, String status) {
    if (_disposed || generation != _sessionGeneration || status != 'ready') {
      return;
    }
    _connectionDeadline?.cancel();
    _phaseMap[deviceId] = ConnectionPhase.initializingCapture;
    final started = _audioCapture.start();
    if (!started) {
      final error = _audioCapture.takeLastError(
        fallbackCode: 1200,
        fallbackMessage: 'Native system-audio capture did not start',
      );
      unawaited(
        _failConnection(
          generation,
          UiError(type: UiErrorType.captureStartFailed, nativeError: error),
          retryAutomatically: true,
        ),
      );
      return;
    }
    _connectStateMap[deviceId] = 2;
    _phaseMap[deviceId] = ConnectionPhase.streaming;
    _lastNotifiedCaptureMode = _audioCapture.captureMode;
    _lastNotifiedActiveEndpointCount = _audioCapture.activeEndpointCount;
    _lastAutoDeviceId = deviceId;
    notifyListeners();
  }

  void _ensureCurrent(int generation) {
    if (_disposed || generation != _sessionGeneration) {
      throw StateError('Connection attempt was superseded');
    }
  }

  Future<void> _failConnection(
    int generation,
    UiError error, {
    bool retryAutomatically = false,
  }) async {
    if (_disposed || generation != _sessionGeneration) return;
    _sessionGeneration++;
    for (final deviceId in _connectStateMap.keys) {
      _phaseMap[deviceId] = ConnectionPhase.failed;
    }
    _pendingError = error;
    if (retryAutomatically && _lastCheck) {
      _lastAutoDeviceId = '';
    }
    await _cleanupSession(forgetRememberedDevice: false);
    for (final deviceId in _connectStateMap.keys) {
      _phaseMap[deviceId] = ConnectionPhase.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _handleDeviceLost(String deviceId) async {
    if ((_connectStateMap[deviceId] ?? 0) == 0) return;
    _sessionGeneration++;
    _lastAutoDeviceId = '';
    await _cleanupSession(forgetRememberedDevice: false);
    if (!_disposed) notifyListeners();
  }

  Future<void> _cleanupSession({required bool forgetRememberedDevice}) async {
    _connectionDeadline?.cancel();
    _connectionDeadline = null;
    for (final deviceId in _connectStateMap.keys) {
      _phaseMap[deviceId] = ConnectionPhase.disconnecting;
    }
    _audioCapture.stop();

    final forward = _forwardSession;
    _forwardSession = null;
    _lastNotifiedCaptureMode = WindowsCaptureMode.inactive;
    _lastNotifiedActiveEndpointCount = 0;

    if (forward != null) {
      try {
        await _adb.removeForward(forward);
      } catch (error) {
        debugPrint('Could not remove owned ADB forward: $error');
      }
    }
    for (final deviceId in _connectStateMap.keys) {
      _connectStateMap[deviceId] = 0;
      _phaseMap[deviceId] = ConnectionPhase.idle;
    }
    if (forgetRememberedDevice) {
      _lastAutoDeviceId = '';
      _setLastDeviceId('');
    }
  }

  void disconnectDevice(String deviceId) {
    if ((_connectStateMap[deviceId] ?? 0) == 0) return;
    _sessionGeneration++;
    unawaited(
      _cleanupSession(forgetRememberedDevice: true).whenComplete(() {
        if (!_disposed) notifyListeners();
      }),
    );
  }

  void disconnectAllDevice() {
    _sessionGeneration++;
    unawaited(
      _cleanupSession(forgetRememberedDevice: false).whenComplete(() {
        if (!_disposed) notifyListeners();
      }),
    );
  }

  Future<void> installCompanion(String deviceId) async {
    if (_disposed || _installingCompanionDeviceIds.contains(deviceId)) return;
    final device = _devices
        .where((candidate) => candidate.deviceId == deviceId)
        .firstOrNull;
    if (device == null || !device.connectableUsb) return;
    _installingCompanionDeviceIds.add(deviceId);
    notifyListeners();
    try {
      await _adb.validateRuntime();
      await _adb.installBundledCompanion(deviceId);
      _missingCompanionDeviceIds.remove(deviceId);
      if (!_disposed) connectDevice(deviceId);
    } catch (error, stack) {
      debugPrint('Companion install failed: $error\n$stack');
      _pendingError = UiError(
        type: UiErrorType.connectAndroidDeviceFailed,
        exception: error,
      );
    } finally {
      _installingCompanionDeviceIds.remove(deviceId);
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pollTimer?.cancel();
    _healthTimer?.cancel();
    unawaited(_deviceTrackerSubscription?.cancel());
    _connectionDeadline?.cancel();
    _sessionGeneration++;
    _audioCapture.stop();
    final forward = _forwardSession;
    _forwardSession = null;
    final cleanup = forward == null
        ? Future<void>.value()
        : _adb.removeForward(forward).catchError((Object _) {});
    unawaited(cleanup.whenComplete(_adb.dispose));
    _audioCapture.dispose();
    super.dispose();
  }
}
