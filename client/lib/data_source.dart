import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'models/device_model.dart';
import 'services/adb_service.dart';
import 'services/audio_capture.dart';
import 'services/connection_preferences.dart';

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    for (final value in this) {
      return value;
    }
    return null;
  }
}

enum UiErrorType {
  packageValidationFailed,
  adbCommandFailed,
  companionCheckFailed,
  companionInstallFailed,
  companionLaunchFailed,
  forwardCreationFailed,
  forwardCleanupFailed,
  transportStartFailed,
  transportHandshakeFailed,
  captureInitializationFailed,
  captureStopped,
  captureStartFailed,
  connectAndroidDeviceFailed,
  connectDeviceFailed,
}

/// User-visible lifecycle for the single owned USB-audio session.
///
/// Passive phone states are represented here too, so unauthorized/offline
/// transitions do not have to masquerade as generic connection failures.
enum ConnectionPhase {
  idle,
  initializing,
  waitingForPhone,
  phoneUnauthorized,
  phoneOffline,
  phoneReady,
  checkingAdb,
  checkingCompanion,
  companionMissing,
  installingCompanion,
  creatingForward,
  startingCompanion,
  connectingTransport,
  handshaking,
  initializingCapture,
  streaming,
  reconnecting,
  disconnecting,
  failed,
}

class UiError {
  const UiError({
    required this.type,
    this.phase,
    this.nativeError,
    this.exception,
  });

  final UiErrorType type;
  final ConnectionPhase? phase;
  final AudioCaptureError? nativeError;
  final Object? exception;
}

class _ConnectionFailure implements Exception {
  const _ConnectionFailure(this.error);

  final UiError error;
}

class DataSource extends ChangeNotifier {
  DataSource({
    AdbController? adb,
    AudioCaptureController? audioCapture,
    ConnectionPreferences? preferences,
    Duration pollInterval = const Duration(seconds: 15),
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration captureStartupTimeout = const Duration(seconds: 5),
    Duration reconnectBaseDelay = const Duration(seconds: 1),
    Duration reconnectMaxDelay = const Duration(seconds: 15),
    bool enableBackgroundTimers = true,
  }) : _adb = adb ?? AdbService(),
       _audioCapture = audioCapture ?? AudioCaptureService(),
       _preferences = preferences ?? FileConnectionPreferences(),
       _connectionTimeout = connectionTimeout,
       _captureStartupTimeout = captureStartupTimeout,
       _reconnectBaseDelay = reconnectBaseDelay,
       _reconnectMaxDelay = reconnectMaxDelay {
    _lastDeviceId = _preferences.lastDeviceId;
    _lastCheck = _preferences.autoConnectEnabled;
    _requestDevicePoll();
    if (enableBackgroundTimers) {
      _pollTimer = Timer.periodic(pollInterval, (_) => _requestDevicePoll());
      _healthTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _pollNativeCaptureError(),
      );
    }
  }

  final AdbController _adb;
  final AudioCaptureController _audioCapture;
  final ConnectionPreferences _preferences;
  final Duration _connectionTimeout;
  final Duration _captureStartupTimeout;
  final Duration _reconnectBaseDelay;
  final Duration _reconnectMaxDelay;
  final Random _secureRandom = Random.secure();

  List<DeviceModel> _devices = [];
  final Map<String, int> _connectStateMap = {};
  final Map<String, ConnectionPhase> _phaseMap = {};
  final Set<String> _missingCompanionDeviceIds = {};
  final Set<String> _installingCompanionDeviceIds = {};
  final Set<String> _manuallySuppressedDeviceIds = {};
  int _deviceState = 0;
  bool _lastCheck = true;
  String _lastDeviceId = '';
  String _lastAutoDeviceId = '';
  String _startupFailure = '';
  ConnectionPhase _overallPhase = ConnectionPhase.initializing;
  UiError? _pendingError;
  UiError? _lastError;
  String _lastErrorFingerprint = '';
  DateTime? _lastErrorNotification;
  Timer? _pollTimer;
  Timer? _healthTimer;
  Timer? _connectionDeadline;
  Timer? _reconnectTimer;
  StreamSubscription<void>? _deviceTrackerSubscription;
  bool _pollInFlight = false;
  bool _pollAgain = false;
  bool _runtimeReady = false;
  bool _trackerStarted = false;
  bool _disposed = false;
  bool _notifierDisposed = false;
  Future<void>? _shutdownFuture;
  int _sessionGeneration = 0;
  int _reconnectAttempt = 0;
  String? _connectingDeviceId;
  AdbForwardSession? _forwardSession;
  WindowsCaptureMode _lastNotifiedCaptureMode = WindowsCaptureMode.inactive;
  int _lastNotifiedActiveEndpointCount = 0;

  List<DeviceModel> get devices => _devices;
  int get deviceState => _deviceState;
  bool get lastCheck => _lastCheck;
  String get startupFailure => _startupFailure;
  ConnectionPhase get overallPhase => _overallPhase;
  UiError? get lastError => _lastError;
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
    _preferences.setLastDeviceId(id);
  }

  set lastCheck(bool value) {
    _lastCheck = value;
    _preferences.setAutoConnectEnabled(value);
    if (value) {
      _lastAutoDeviceId = '';
      _requestDevicePoll();
    } else {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
    notifyListeners();
  }

  int getConnectState(String deviceId) => _connectStateMap[deviceId] ?? 0;

  bool getConnectEnable(String deviceId) {
    final device = _devices
        .where((candidate) => candidate.deviceId == deviceId)
        .firstOrNull;
    if (device == null || !device.connectableUsb) return false;
    if (_connectingDeviceId != null) return false;
    if (_connectStateMap.values.any((state) => state == 1)) return false;
    final state = _connectStateMap[deviceId] ?? 0;
    return state == 0 || state == 2;
  }

  void retryStartup() {
    if (_disposed) return;
    _runtimeReady = false;
    _startupFailure = '';
    _deviceState = 0;
    _overallPhase = ConnectionPhase.initializing;
    _lastErrorFingerprint = '';
    _requestDevicePoll();
    notifyListeners();
  }

  void _requestDevicePoll() {
    if (_disposed) return;
    if (_pollInFlight) {
      _pollAgain = true;
      return;
    }
    unawaited(_pollDevices());
  }

  Future<void> _pollDevices() async {
    if (_disposed) return;
    if (_pollInFlight) {
      _pollAgain = true;
      return;
    }
    _pollInFlight = true;
    try {
      do {
        _pollAgain = false;
        await _pollDevicesOnce();
      } while (_pollAgain && !_disposed);
    } finally {
      _pollInFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _pollDevicesOnce() async {
    try {
      if (!_runtimeReady) {
        _overallPhase = ConnectionPhase.initializing;
        await _adb.validateRuntime();
        if (_disposed) return;
        _runtimeReady = true;
        _startupFailure = '';
        _startDeviceTracker();
      }

      final devices = await _adb.devices();
      if (_disposed) return;
      _devices = devices;
      _deviceState = devices.isEmpty ? 1 : 2;
      _startupFailure = '';
      _manuallySuppressedDeviceIds.removeWhere(
        (deviceId) => !devices.any(
          (device) => device.deviceId == deviceId && device.connectableUsb,
        ),
      );

      final activeDevice = _activeSessionDeviceId;
      if (activeDevice != null) {
        final activeSnapshot = devices
            .where((device) => device.deviceId == activeDevice)
            .firstOrNull;
        if (activeSnapshot == null || !activeSnapshot.connectableUsb) {
          await _handleDeviceLost(activeDevice, _passivePhase(activeSnapshot));
        }
      }

      _applyPassiveDevicePhases(devices);
      _updateOverallPhase(devices);

      final candidate = _automaticCandidate(devices);
      if (candidate != null && candidate.deviceId != _lastAutoDeviceId) {
        _lastAutoDeviceId = candidate.deviceId;
        unawaited(_connectDevice(candidate.deviceId, automatic: true));
      } else if (devices.where((device) => device.connectableUsb).isEmpty &&
          _activeSessionDeviceId == null) {
        // Permit the same physical phone to auto-connect after
        // absent/unauthorized/offline -> authorized transitions.
        _lastAutoDeviceId = '';
      }
      _pollNativeCaptureError();
    } catch (error, stack) {
      debugPrint('ADB device refresh failed: $error\n$stack');
      if (!_runtimeReady) {
        _deviceState = 3;
        _overallPhase = ConnectionPhase.failed;
        _startupFailure = error.toString();
        _queueError(
          UiError(
            type: UiErrorType.packageValidationFailed,
            phase: ConnectionPhase.initializing,
            exception: error,
          ),
        );
      } else {
        if (_activeSessionDeviceId == null) {
          _deviceState = 3;
          _overallPhase = ConnectionPhase.failed;
          _startupFailure = error.toString();
        }
        _queueError(
          UiError(
            type: UiErrorType.adbCommandFailed,
            phase: _overallPhase,
            exception: error,
          ),
        );
      }
    }
  }

  void _startDeviceTracker() {
    if (_trackerStarted || _disposed) return;
    _trackerStarted = true;
    _deviceTrackerSubscription = _adb.deviceChanges().listen(
      (_) => _requestDevicePoll(),
      onError: (Object error, StackTrace stack) {
        debugPrint('ADB device tracker failed: $error\n$stack');
      },
    );
  }

  String? get _activeSessionDeviceId {
    if (_connectingDeviceId != null) return _connectingDeviceId;
    return _connectStateMap.entries
        .where((entry) => entry.value == 1 || entry.value == 2)
        .map((entry) => entry.key)
        .firstOrNull;
  }

  ConnectionPhase _passivePhase(DeviceModel? device) {
    if (device == null) return ConnectionPhase.waitingForPhone;
    return switch (device.adbState) {
      AdbDeviceState.unauthorized => ConnectionPhase.phoneUnauthorized,
      AdbDeviceState.offline => ConnectionPhase.phoneOffline,
      _ when device.connectableUsb => ConnectionPhase.phoneReady,
      _ => ConnectionPhase.waitingForPhone,
    };
  }

  void _applyPassiveDevicePhases(List<DeviceModel> devices) {
    final currentIds = devices.map((device) => device.deviceId).toSet();
    _phaseMap.removeWhere(
      (id, _) => !currentIds.contains(id) && id != _activeSessionDeviceId,
    );
    for (final device in devices) {
      if (device.deviceId == _activeSessionDeviceId) continue;
      if (_installingCompanionDeviceIds.contains(device.deviceId)) {
        _phaseMap[device.deviceId] = ConnectionPhase.installingCompanion;
      } else if (_missingCompanionDeviceIds.contains(device.deviceId) &&
          device.connectableUsb) {
        _phaseMap[device.deviceId] = ConnectionPhase.companionMissing;
      } else {
        _phaseMap[device.deviceId] = _passivePhase(device);
      }
    }
  }

  void _updateOverallPhase(List<DeviceModel> devices) {
    final activeDevice = _activeSessionDeviceId;
    if (activeDevice != null) {
      _overallPhase = _phaseMap[activeDevice] ?? ConnectionPhase.initializing;
      return;
    }
    if (_reconnectTimer != null &&
        _phaseMap.values.contains(ConnectionPhase.reconnecting)) {
      _overallPhase = ConnectionPhase.reconnecting;
      return;
    }
    if (devices.any(
      (device) =>
          device.adbState == AdbDeviceState.unauthorized &&
          device.transportType == AdbTransportType.usb,
    )) {
      _overallPhase = ConnectionPhase.phoneUnauthorized;
    } else if (devices.any(
      (device) =>
          device.adbState == AdbDeviceState.offline &&
          device.transportType == AdbTransportType.usb,
    )) {
      _overallPhase = ConnectionPhase.phoneOffline;
    } else if (devices.any((device) => device.connectableUsb)) {
      _overallPhase = ConnectionPhase.phoneReady;
    } else {
      _overallPhase = ConnectionPhase.waitingForPhone;
    }
  }

  DeviceModel? _automaticCandidate(List<DeviceModel> devices) {
    if (!_lastCheck ||
        _connectingDeviceId != null ||
        _connectStateMap.values.any((state) => state == 1 || state == 2)) {
      return null;
    }
    final authorizedUsb = devices
        .where(
          (device) =>
              device.connectableUsb &&
              !_missingCompanionDeviceIds.contains(device.deviceId) &&
              !_installingCompanionDeviceIds.contains(device.deviceId) &&
              !_manuallySuppressedDeviceIds.contains(device.deviceId),
        )
        .toList(growable: false);
    final remembered = authorizedUsb
        .where((device) => device.deviceId == _lastDeviceId)
        .firstOrNull;
    if (remembered != null) return remembered;
    return authorizedUsb.length == 1 ? authorizedUsb.single : null;
  }

  void _queueError(UiError error, {bool notifyUser = true}) {
    _lastError = error;
    final fingerprint = [
      error.type.name,
      error.phase?.name ?? '',
      error.nativeError?.code.toString() ?? '',
      error.nativeError?.message ?? '',
      error.exception?.toString() ?? '',
    ].join('|');
    final now = DateTime.now();
    final duplicate =
        fingerprint == _lastErrorFingerprint &&
        _lastErrorNotification != null &&
        now.difference(_lastErrorNotification!) < const Duration(seconds: 30);
    if (notifyUser && !duplicate) {
      _pendingError = error;
      _lastErrorFingerprint = fingerprint;
      _lastErrorNotification = now;
    }
    if (!_disposed) notifyListeners();
  }

  void _pollNativeCaptureError() {
    if (!_connectStateMap.values.any((state) => state == 2)) return;
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
        UiError(
          type: UiErrorType.captureStopped,
          phase: ConnectionPhase.streaming,
          nativeError: error,
        ),
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
    _manuallySuppressedDeviceIds.remove(deviceId);
    unawaited(_connectDevice(deviceId, automatic: false));
  }

  Future<void> _connectDevice(
    String deviceId, {
    required bool automatic,
  }) async {
    if (_disposed || _connectingDeviceId != null) return;
    final device = _devices
        .where((candidate) => candidate.deviceId == deviceId)
        .firstOrNull;
    if (device == null || !device.connectableUsb) {
      _queueError(
        const UiError(
          type: UiErrorType.connectDeviceFailed,
          phase: ConnectionPhase.phoneReady,
          exception:
              'Select an authorized USB device. Network and emulator '
              'ADB transports are not accepted in automatic mode.',
        ),
      );
      return;
    }

    if (!automatic) _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sessionGeneration++;
    final generation = _sessionGeneration;
    _connectingDeviceId = deviceId;
    await _cleanupSession(
      forgetRememberedDevice: false,
      finalPhase: ConnectionPhase.idle,
    );
    if (_disposed || generation != _sessionGeneration) return;

    _lastAutoDeviceId = deviceId;
    _setLastDeviceId(deviceId);
    _connectStateMap
      ..clear()
      ..[deviceId] = 1;
    _phaseMap
      ..clear()
      ..[deviceId] = ConnectionPhase.checkingAdb;
    _overallPhase = ConnectionPhase.checkingAdb;
    notifyListeners();

    try {
      await _adb.validateRuntime();
      _ensureCurrent(generation);
      await _connectWindowsCompanion(deviceId, generation);
    } catch (error, stack) {
      debugPrint('Connection failed: $error\n$stack');
      if (generation == _sessionGeneration) {
        await _failConnection(
          generation,
          _connectionError(deviceId, error),
          retryAutomatically: true,
        );
      }
    } finally {
      if (generation == _sessionGeneration) {
        _connectingDeviceId = null;
      }
    }
  }

  UiError _connectionError(String deviceId, Object error) {
    if (error is _ConnectionFailure) return error.error;
    final phase = _phaseMap[deviceId] ?? _overallPhase;
    final type = switch (phase) {
      ConnectionPhase.checkingAdb => UiErrorType.adbCommandFailed,
      ConnectionPhase.checkingCompanion => UiErrorType.companionCheckFailed,
      ConnectionPhase.creatingForward => UiErrorType.forwardCreationFailed,
      ConnectionPhase.startingCompanion => UiErrorType.companionLaunchFailed,
      ConnectionPhase.connectingTransport => UiErrorType.transportStartFailed,
      ConnectionPhase.handshaking => UiErrorType.transportHandshakeFailed,
      ConnectionPhase.initializingCapture => UiErrorType.captureStartFailed,
      _ => UiErrorType.connectAndroidDeviceFailed,
    };
    return UiError(type: type, phase: phase, exception: error);
  }

  Future<void> _connectWindowsCompanion(String deviceId, int generation) async {
    _setSessionPhase(deviceId, ConnectionPhase.checkingCompanion);
    final installation = await _adb.findCompanion(deviceId);
    _ensureCurrent(generation);
    if (installation == null) {
      _missingCompanionDeviceIds.add(deviceId);
      _sessionGeneration++;
      _connectingDeviceId = null;
      await _cleanupSession(
        forgetRememberedDevice: false,
        finalPhase: ConnectionPhase.companionMissing,
        targetDeviceId: deviceId,
      );
      if (!_disposed) notifyListeners();
      return;
    }
    _missingCompanionDeviceIds.remove(deviceId);

    final socketName = 'as_1_${_randomHex(8)}';
    final tokenHex = _randomHex(32);
    _setSessionPhase(deviceId, ConnectionPhase.creatingForward);
    final forward = await _adb.createForward(
      deviceId: deviceId,
      socketName: socketName,
      generation: generation,
    );
    _forwardSession = forward;
    try {
      _ensureCurrent(generation);
    } catch (_) {
      // ADB creates the mapping before this await completes. If the device
      // disappears (or the user disconnects) during that window, the normal
      // session cleanup could not have seen the mapping yet. Remove this
      // exact stale mapping here so a superseded attempt cannot leak a port.
      if (identical(_forwardSession, forward)) {
        _forwardSession = null;
        try {
          await _adb.removeForward(forward);
        } catch (cleanupError, cleanupStack) {
          debugPrint(
            'Could not remove superseded ADB forward: '
            '$cleanupError\n$cleanupStack',
          );
        }
      }
      rethrow;
    }

    _setSessionPhase(deviceId, ConnectionPhase.startingCompanion);
    await _adb.launchCompanion(
      deviceId: deviceId,
      socketName: socketName,
      tokenHex: tokenHex,
      generation: generation,
      installation: installation,
    );
    _ensureCurrent(generation);

    _setSessionPhase(deviceId, ConnectionPhase.connectingTransport);
    if (!_audioCapture.initialize()) {
      throw _ConnectionFailure(
        UiError(
          type: UiErrorType.captureInitializationFailed,
          phase: ConnectionPhase.connectingTransport,
          nativeError: _audioCapture.takeLastError(
            fallbackCode: 1000,
            fallbackMessage:
                'Native Windows capture transport did not initialize',
          ),
        ),
      );
    }

    _setSessionPhase(deviceId, ConnectionPhase.handshaking);
    _connectionDeadline?.cancel();
    _connectionDeadline = Timer(_connectionTimeout, () {
      if (generation == _sessionGeneration &&
          (_connectStateMap[deviceId] ?? 0) == 1) {
        unawaited(
          _failConnection(
            generation,
            const UiError(
              type: UiErrorType.transportHandshakeFailed,
              phase: ConnectionPhase.handshaking,
              exception:
                  'Timed out while waiting for the Android companion '
                  'transport handshake.',
            ),
            retryAutomatically: true,
          ),
        );
      }
    });
    final connectStarted = _audioCapture.connectToForward(
      forward.hostPort,
      tokenHex,
      (status) => _onNativeConnected(generation, deviceId, status),
    );
    if (!connectStarted) {
      _connectionDeadline?.cancel();
      throw const _ConnectionFailure(
        UiError(
          type: UiErrorType.transportStartFailed,
          phase: ConnectionPhase.connectingTransport,
          exception: 'Native outbound USB transport could not start.',
        ),
      );
    }
  }

  void _setSessionPhase(String deviceId, ConnectionPhase phase) {
    _phaseMap[deviceId] = phase;
    _overallPhase = phase;
    if (!_disposed) notifyListeners();
  }

  void _onNativeConnected(int generation, String deviceId, String status) {
    if (_disposed || generation != _sessionGeneration) return;
    if (status != 'ready') {
      final nativeError = _audioCapture.pollLastError();
      unawaited(
        _failConnection(
          generation,
          UiError(
            type: UiErrorType.transportHandshakeFailed,
            phase: ConnectionPhase.handshaking,
            nativeError: nativeError,
            exception: nativeError == null
                ? 'Android companion rejected the session: $status'
                : null,
          ),
          retryAutomatically: true,
        ),
      );
      return;
    }
    _connectionDeadline?.cancel();
    _connectionDeadline = null;
    _setSessionPhase(deviceId, ConnectionPhase.initializingCapture);
    unawaited(_startCaptureAndWaitUntilReady(generation, deviceId));
  }

  Future<void> _startCaptureAndWaitUntilReady(
    int generation,
    String deviceId,
  ) async {
    if (!_audioCapture.start()) {
      final error = _audioCapture.takeLastError(
        fallbackCode: 1200,
        fallbackMessage: 'Native system-audio capture did not start',
      );
      await _failConnection(
        generation,
        UiError(
          type: UiErrorType.captureStartFailed,
          phase: ConnectionPhase.initializingCapture,
          nativeError: error,
        ),
        retryAutomatically: true,
      );
      return;
    }

    final deadline = DateTime.now().add(_captureStartupTimeout);
    while (!_disposed && generation == _sessionGeneration) {
      final nativeError = _audioCapture.pollLastError();
      if (nativeError != null) {
        await _failConnection(
          generation,
          UiError(
            type: UiErrorType.captureStartFailed,
            phase: ConnectionPhase.initializingCapture,
            nativeError: nativeError,
          ),
          retryAutomatically: true,
        );
        return;
      }
      final mode = _audioCapture.captureMode;
      if (mode != WindowsCaptureMode.inactive) {
        _connectStateMap[deviceId] = 2;
        _phaseMap[deviceId] = ConnectionPhase.streaming;
        _overallPhase = ConnectionPhase.streaming;
        _lastNotifiedCaptureMode = mode;
        _lastNotifiedActiveEndpointCount = _audioCapture.activeEndpointCount;
        _lastAutoDeviceId = deviceId;
        _connectingDeviceId = null;
        _reconnectAttempt = 0;
        if (!_disposed) notifyListeners();
        return;
      }
      if (DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!_disposed && generation == _sessionGeneration) {
      await _failConnection(
        generation,
        const UiError(
          type: UiErrorType.captureStartFailed,
          phase: ConnectionPhase.initializingCapture,
          exception:
              'Windows capture did not become ready before the startup '
              'deadline.',
        ),
        retryAutomatically: true,
      );
    }
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
    final deviceId = _activeSessionDeviceId ?? _phaseMap.keys.firstOrNull;
    _sessionGeneration++;
    _connectingDeviceId = null;
    _queueError(error);
    final willRetry = retryAutomatically && _lastCheck && deviceId != null;
    if (willRetry) _lastAutoDeviceId = '';
    await _cleanupSession(
      forgetRememberedDevice: false,
      finalPhase: willRetry
          ? ConnectionPhase.reconnecting
          : ConnectionPhase.failed,
      targetDeviceId: deviceId,
    );
    if (willRetry && !_disposed) _scheduleReconnect(deviceId);
    if (!_disposed) notifyListeners();
  }

  void _scheduleReconnect(String deviceId) {
    _reconnectTimer?.cancel();
    final exponent = min(_reconnectAttempt, 4);
    final scaledMilliseconds =
        _reconnectBaseDelay.inMilliseconds * (1 << exponent);
    final delay = Duration(
      milliseconds: min(scaledMilliseconds, _reconnectMaxDelay.inMilliseconds),
    );
    _reconnectAttempt++;
    final generation = _sessionGeneration;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed || generation != _sessionGeneration || !_lastCheck) return;
      _lastAutoDeviceId = '';
      _requestDevicePoll();
    });
    _phaseMap[deviceId] = ConnectionPhase.reconnecting;
    _overallPhase = ConnectionPhase.reconnecting;
  }

  Future<void> _handleDeviceLost(
    String deviceId,
    ConnectionPhase finalPhase,
  ) async {
    if (_activeSessionDeviceId != deviceId) return;
    _sessionGeneration++;
    _connectingDeviceId = null;
    _lastAutoDeviceId = '';
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _cleanupSession(
      forgetRememberedDevice: false,
      finalPhase: finalPhase,
      targetDeviceId: deviceId,
    );
  }

  Future<void> _cleanupSession({
    required bool forgetRememberedDevice,
    ConnectionPhase finalPhase = ConnectionPhase.idle,
    String? targetDeviceId,
  }) async {
    _connectionDeadline?.cancel();
    _connectionDeadline = null;
    final affectedDeviceIds = <String>{
      ..._connectStateMap.keys,
      ?targetDeviceId,
    };
    for (final deviceId in affectedDeviceIds) {
      if ((_connectStateMap[deviceId] ?? 0) != 0) {
        _phaseMap[deviceId] = ConnectionPhase.disconnecting;
      }
    }
    _audioCapture.stop();

    final forward = _forwardSession;
    _forwardSession = null;
    _lastNotifiedCaptureMode = WindowsCaptureMode.inactive;
    _lastNotifiedActiveEndpointCount = 0;

    if (forward != null) {
      try {
        await _adb.removeForward(forward);
      } catch (error, stack) {
        debugPrint('Could not remove owned ADB forward: $error\n$stack');
        _queueError(
          UiError(
            type: UiErrorType.forwardCleanupFailed,
            phase: ConnectionPhase.disconnecting,
            exception: error,
          ),
          notifyUser: false,
        );
      }
    }
    for (final deviceId in affectedDeviceIds) {
      _connectStateMap[deviceId] = 0;
      _phaseMap[deviceId] = finalPhase;
    }
    _overallPhase = finalPhase;
    if (forgetRememberedDevice) {
      _lastAutoDeviceId = '';
      _setLastDeviceId('');
    }
  }

  void disconnectDevice(String deviceId) {
    if ((_connectStateMap[deviceId] ?? 0) == 0) return;
    // A deliberate Disconnect must not be undone by the next 15-second device
    // poll. Suppression lasts only while this physical authorization remains;
    // unplug/replug makes the phone eligible for the normal zero-click path.
    _manuallySuppressedDeviceIds.add(deviceId);
    _sessionGeneration++;
    _connectingDeviceId = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    unawaited(
      _cleanupSession(
        forgetRememberedDevice: true,
        finalPhase: ConnectionPhase.phoneReady,
        targetDeviceId: deviceId,
      ).whenComplete(() {
        if (!_disposed) notifyListeners();
      }),
    );
  }

  void disconnectAllDevice() {
    _sessionGeneration++;
    _connectingDeviceId = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    unawaited(
      _cleanupSession(
        forgetRememberedDevice: false,
        finalPhase: ConnectionPhase.idle,
      ).whenComplete(() {
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
    _phaseMap[deviceId] = ConnectionPhase.installingCompanion;
    _overallPhase = ConnectionPhase.installingCompanion;
    notifyListeners();
    try {
      await _adb.validateRuntime();
      await _adb.installBundledCompanion(deviceId);
      _missingCompanionDeviceIds.remove(deviceId);
      _manuallySuppressedDeviceIds.remove(deviceId);
      _lastAutoDeviceId = '';
      if (!_disposed) {
        await _connectDevice(deviceId, automatic: false);
      }
    } catch (error, stack) {
      debugPrint('Companion install failed: $error\n$stack');
      _phaseMap[deviceId] = ConnectionPhase.companionMissing;
      _overallPhase = ConnectionPhase.companionMissing;
      _queueError(
        UiError(
          type: UiErrorType.companionInstallFailed,
          phase: ConnectionPhase.installingCompanion,
          exception: error,
        ),
      );
    } finally {
      _installingCompanionDeviceIds.remove(deviceId);
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> shutdown() {
    final existing = _shutdownFuture;
    if (existing != null) return existing;
    _disposed = true;
    _pollTimer?.cancel();
    _healthTimer?.cancel();
    _reconnectTimer?.cancel();
    _connectionDeadline?.cancel();
    final trackerCancellation = _deviceTrackerSubscription?.cancel();
    _deviceTrackerSubscription = null;
    _sessionGeneration++;
    _audioCapture.stop();
    final forward = _forwardSession;
    _forwardSession = null;
    final shutdown = _completeShutdown(trackerCancellation, forward);
    _shutdownFuture = shutdown;
    return shutdown;
  }

  Future<void> _completeShutdown(
    Future<void>? trackerCancellation,
    AdbForwardSession? forward,
  ) async {
    try {
      await trackerCancellation?.timeout(const Duration(seconds: 2));
    } catch (_) {
      // ADB disposal below forcibly stops a tracker that did not cancel.
    }
    if (forward != null) {
      try {
        await _adb.removeForward(forward);
      } catch (_) {
        // Process teardown cannot present a useful dialog. Normal session
        // cleanup still reports this failure while the UI is alive.
      }
    }
    _adb.dispose();
    _audioCapture.dispose();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    super.dispose();
  }
}
