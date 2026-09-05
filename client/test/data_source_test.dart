import 'dart:async';

import 'package:audioshare/data_source.dart';
import 'package:audioshare/models/device_model.dart';
import 'package:audioshare/services/adb_service.dart';
import 'package:audioshare/services/audio_capture.dart';
import 'package:audioshare/services/connection_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryConnectionPreferences implements ConnectionPreferences {
  MemoryConnectionPreferences({
    this.lastDeviceId = '',
    this.autoConnectEnabled = true,
  });

  @override
  String lastDeviceId;

  @override
  bool autoConnectEnabled;

  @override
  void setAutoConnectEnabled(bool value) {
    autoConnectEnabled = value;
  }

  @override
  void setLastDeviceId(String value) {
    lastDeviceId = value;
  }
}

class FakeAdbController implements AdbController {
  final _changes = StreamController<void>.broadcast(sync: true);
  List<DeviceModel> snapshot = [];
  CompanionInstallation? companion = CompanionInstallation.release;
  Object? companionError;
  Object? validationError;
  Object? deviceError;
  int validationCalls = 0;
  int deviceCalls = 0;
  int findCompanionCalls = 0;
  int installCalls = 0;
  int createForwardCalls = 0;
  int launchCalls = 0;
  int removeForwardCalls = 0;
  int companionFailuresRemaining = 0;
  int launchFailuresRemaining = 0;
  bool disposed = false;
  Completer<void>? removeForwardGate;
  Completer<void>? createForwardGate;

  @override
  String get executablePath => 'fake-adb.exe';

  @override
  List<String> get diagnosticLines => const ['adb_test_controller=true'];

  void publish(List<DeviceModel> devices) {
    snapshot = devices;
    _changes.add(null);
  }

  @override
  Future<void> validateRuntime() async {
    validationCalls++;
    if (validationError case final error?) throw error;
  }

  @override
  Future<List<DeviceModel>> devices() async {
    deviceCalls++;
    if (deviceError case final error?) throw error;
    return List<DeviceModel>.of(snapshot);
  }

  @override
  Stream<void> deviceChanges() => _changes.stream;

  @override
  Future<CompanionInstallation?> findCompanion(String deviceId) async {
    findCompanionCalls++;
    if (companionFailuresRemaining > 0) {
      companionFailuresRemaining--;
      throw StateError('injected transient companion check failure');
    }
    if (companionError case final error?) throw error;
    return companion;
  }

  @override
  String? bundledCompanionApkPath() => 'fake-companion.apk';

  @override
  Future<CompanionInstallation> installBundledCompanion(String deviceId) async {
    installCalls++;
    companion = CompanionInstallation.release;
    return companion!;
  }

  @override
  Future<AdbForwardSession> createForward({
    required String deviceId,
    required String socketName,
    required int generation,
  }) async {
    createForwardCalls++;
    await createForwardGate?.future;
    return AdbForwardSession(
      deviceId: deviceId,
      hostPort: 43210,
      socketName: socketName,
      generation: generation,
    );
  }

  @override
  Future<void> launchCompanion({
    required String deviceId,
    required String socketName,
    required String tokenHex,
    required int generation,
    required CompanionInstallation installation,
  }) async {
    launchCalls++;
    if (launchFailuresRemaining > 0) {
      launchFailuresRemaining--;
      throw StateError('injected companion launch failure');
    }
  }

  @override
  Future<void> removeForward(AdbForwardSession session) async {
    removeForwardCalls++;
    await removeForwardGate?.future;
  }

  @override
  void dispose() {
    disposed = true;
  }

  Future<void> close() => _changes.close();
}

class FakeAudioCaptureController implements AudioCaptureController {
  bool initializeResult = true;
  bool connectResult = true;
  bool startResult = true;
  bool autoReady = true;
  WindowsCaptureMode modeAfterStart = WindowsCaptureMode.globalSystem;
  void Function(String status)? connectCallback;
  AudioCaptureError? nextError;
  int initializeCalls = 0;
  int connectCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  WindowsCaptureMode _mode = WindowsCaptureMode.inactive;

  @override
  int get droppedNativeChunks => 0;
  @override
  int get androidReceivedFrames => 0;
  @override
  int get androidDroppedFrames => 0;
  @override
  int get androidQueueDepth => 0;
  @override
  int get androidBufferFrames => 0;
  @override
  int get androidQueueFrames => 0;
  @override
  int get androidBufferCapacityFrames => 0;
  @override
  int get androidStartThresholdFrames => 0;
  @override
  int get androidUnderrunCount => 0;
  @override
  int get androidRoutedDeviceType => 0;
  @override
  int get androidFocusState => 0;
  @override
  int get androidMediaVolume => 0;
  @override
  int get androidMediaVolumeMax => 0;
  @override
  int get androidQueueHighWaterFrames => 0;
  @override
  int get androidWrittenFrames => 0;
  @override
  int get androidPlaybackHeadFrames => 0;
  @override
  int get androidLastWriteProgressAgeMilliseconds => 0;
  @override
  int get androidLastPlaybackAdvanceAgeMilliseconds => 0;
  @override
  int get androidPlayState => 0;
  @override
  int get androidPerformanceMode => 0;
  @override
  int get hostQueueFrames => 0;
  @override
  int get hostQueueHighWaterFrames => 0;
  @override
  int get transportBytesSent => 0;
  @override
  int get heartbeatRttMilliseconds => 0;
  @override
  WindowsCaptureMode get captureMode => _mode;
  @override
  int get globalLoopbackHresult => 0;
  @override
  int get activeEndpointCount =>
      _mode == WindowsCaptureMode.multiEndpoint ? 2 : 0;
  @override
  int get endpointDroppedFrames => 0;
  @override
  int get endpointUnderrunFrames => 0;
  @override
  int get endpointDiscontinuities => 0;
  @override
  int get captureDiscontinuities => 0;
  @override
  int get endpointRebuildCount => 0;
  @override
  int get endpointCatchUpFrames => 0;
  @override
  int get endpointQueueHighWaterFrames => 0;
  @override
  int capturedFrames = 0;
  @override
  int get capturePeakPermille => 0;
  @override
  int get captureRmsPermille => 0;
  @override
  int lastNonSilentAgeMilliseconds = 0xFFFFFFFF;

  @override
  bool initialize() {
    initializeCalls++;
    return initializeResult;
  }

  @override
  bool connectToForward(
    int port,
    String tokenHex,
    void Function(String status) onConnect,
  ) {
    connectCalls++;
    connectCallback = onConnect;
    if (connectResult && autoReady) scheduleMicrotask(() => onConnect('ready'));
    return connectResult;
  }

  @override
  bool start() {
    startCalls++;
    if (startResult) _mode = modeAfterStart;
    return startResult;
  }

  @override
  AudioCaptureError? takeLastError({
    int fallbackCode = -1,
    String fallbackMessage = 'Unknown audio capture error',
  }) {
    final error = nextError;
    nextError = null;
    return error ?? AudioCaptureError(fallbackCode, fallbackMessage);
  }

  @override
  AudioCaptureError? pollLastError() {
    final error = nextError;
    nextError = null;
    return error;
  }

  @override
  void stop() {
    stopCalls++;
    _mode = WindowsCaptureMode.inactive;
  }

  @override
  void cleanup() {
    _mode = WindowsCaptureMode.inactive;
  }

  @override
  void dispose() {
    disposeCalls++;
    cleanup();
  }
}

DeviceModel usbPhone({AdbDeviceState state = AdbDeviceState.authorized}) =>
    DeviceModel(
      deviceId: 'USB123',
      usb: true,
      serialNumber: 'USB123',
      model: 'Test Phone',
      manufacturer: 'Test',
      androidVersion: '16',
      apiLevel: '36',
      ip: '',
      port: '',
      adbState: state,
      transportType: AdbTransportType.usb,
      transportId: 1,
    );

Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not reached before $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  group('failure retry classification', () {
    test('unknown launch failures remain transient', () {
      expect(
        classifyFailure(
          const UiError(
            type: UiErrorType.companionLaunchFailed,
            exception: 'ADB transport closed temporarily',
          ),
        ),
        FailureDisposition.transient,
      );
    });

    test('focus and persistent speaker-route failures stop for user action', () {
      expect(
        classifyFailure(
          const UiError(
            type: UiErrorType.captureStopped,
            exception:
                'AudioTrack playback failed: Android audio focus was lost',
          ),
        ),
        FailureDisposition.needsUserAction,
      );
      expect(
        classifyFailure(
          const UiError(
            type: UiErrorType.captureStopped,
            exception:
                'Android routed PC audio to Bluetooth instead of the phone speaker',
          ),
        ),
        FailureDisposition.environmental,
      );
    });

    test('protocol and package failures fail closed', () {
      expect(
        classifyFailure(
          const UiError(
            type: UiErrorType.transportHandshakeFailed,
            exception: 'Unsupported protocol version 2',
          ),
        ),
        FailureDisposition.fatal,
      );
      expect(
        classifyFailure(
          const UiError(type: UiErrorType.packageValidationFailed),
        ),
        FailureDisposition.fatal,
      );
    });
  });

  late FakeAdbController adb;
  late FakeAudioCaptureController audio;
  late MemoryConnectionPreferences preferences;
  DataSource? source;

  setUp(() {
    adb = FakeAdbController();
    audio = FakeAudioCaptureController();
    preferences = MemoryConnectionPreferences();
  });

  tearDown(() async {
    await source?.shutdown();
    source?.dispose();
    source = null;
    await Future<void>.delayed(Duration.zero);
    await adb.close();
  });

  DataSource createSource({
    Duration captureStartupTimeout = const Duration(milliseconds: 100),
    Duration reconnectDelay = const Duration(milliseconds: 2),
    bool enableBackgroundTimers = false,
  }) {
    return source = DataSource(
      adb: adb,
      audioCapture: audio,
      preferences: preferences,
      captureStartupTimeout: captureStartupTimeout,
      reconnectBaseDelay: reconnectDelay,
      reconnectMaxDelay: reconnectDelay,
      enableBackgroundTimers: enableBackgroundTimers,
    );
  }

  test(
    'one authorized USB phone reaches streaming without a Connect click',
    () async {
      adb.snapshot = [usbPhone()];
      final dataSource = createSource();

      await waitUntil(
        () => dataSource.overallPhase == ConnectionPhase.streaming,
      );

      expect(dataSource.getConnectState('USB123'), 2);
      expect(preferences.lastDeviceId, 'USB123');
      expect(adb.findCompanionCalls, 1);
      expect(adb.createForwardCalls, 1);
      expect(adb.launchCalls, 1);
      expect(audio.initializeCalls, 1);
      expect(audio.startCalls, 1);
    },
  );

  test('silence is visible but never tears down a healthy session', () async {
    adb.snapshot = [usbPhone()];
    final dataSource = createSource(enableBackgroundTimers: true);
    expect(dataSource.captureSignalStatus, CaptureSignalStatus.inactive);
    await waitUntil(() => dataSource.overallPhase == ConnectionPhase.streaming);
    expect(dataSource.captureSignalStatus, CaptureSignalStatus.waiting);
    final stopsAfterConnect = audio.stopCalls;
    audio.capturedFrames = 48000;
    expect(dataSource.captureSignalStatus, CaptureSignalStatus.quiet);
    audio.lastNonSilentAgeMilliseconds = 4999;
    expect(dataSource.captureSignalStatus, CaptureSignalStatus.detected);
    audio.lastNonSilentAgeMilliseconds = 5000;
    expect(dataSource.captureSignalStatus, CaptureSignalStatus.quiet);

    var notifications = 0;
    dataSource.addListener(() => notifications++);
    await waitUntil(() => notifications > 0);
    notifications = 0;
    audio.lastNonSilentAgeMilliseconds = 0;
    await waitUntil(() => notifications > 0);
    expect(dataSource.streamingDiagnostics, contains('signal_status=detected'));
    expect(dataSource.streamingDiagnostics, contains('host_os='));
    expect(
      dataSource.streamingDiagnostics,
      contains('global_loopback_hresult=0x00000000'),
    );
    expect(audio.startCalls, 1);
    expect(audio.stopCalls, stopsAfterConnect);
    expect(adb.launchCalls, 1);
    expect(dataSource.takePendingError(), isNull);

    dataSource.disconnectDevice('USB123');
    await waitUntil(
      () => dataSource.overallPhase == ConnectionPhase.phoneReady,
    );
    expect(dataSource.captureSignalStatus, CaptureSignalStatus.inactive);
  });

  test('startup package failure is actionable and retryable', () async {
    adb
      ..snapshot = [usbPhone()]
      ..validationError = StateError('missing bundled adb.exe');
    final dataSource = createSource();

    await waitUntil(() => dataSource.deviceState == 3);
    expect(dataSource.overallPhase, ConnectionPhase.failed);
    expect(dataSource.startupFailure, contains('missing bundled adb.exe'));
    expect(
      dataSource.takePendingError()?.type,
      UiErrorType.packageValidationFailed,
    );
    expect(adb.deviceCalls, 0);

    adb.validationError = null;
    dataSource.retryStartup();
    await waitUntil(() => dataSource.overallPhase == ConnectionPhase.streaming);
    expect(adb.deviceCalls, 1);
  });

  test('transient ADB refresh failure keeps the last usable screen', () async {
    adb.snapshot = const [];
    final dataSource = createSource();
    await waitUntil(
      () => dataSource.overallPhase == ConnectionPhase.waitingForPhone,
    );

    adb.deviceError = StateError('temporary ADB read failure');
    adb.publish(const []);
    await waitUntil(
      () => dataSource.lastError?.type == UiErrorType.adbCommandFailed,
    );

    expect(dataSource.deviceState, 1);
    expect(dataSource.overallPhase, ConnectionPhase.waitingForPhone);
    expect(dataSource.startupFailure, isEmpty);
  });

  test(
    'unauthorized phone automatically continues after the user approves it',
    () async {
      adb.snapshot = [usbPhone(state: AdbDeviceState.unauthorized)];
      final dataSource = createSource();

      await waitUntil(
        () =>
            dataSource.getConnectionPhase('USB123') ==
            ConnectionPhase.phoneUnauthorized,
      );
      expect(adb.findCompanionCalls, 0);

      adb.publish([usbPhone()]);
      await waitUntil(
        () => dataSource.overallPhase == ConnectionPhase.streaming,
      );

      expect(adb.findCompanionCalls, 1);
      expect(audio.startCalls, 1);
    },
  );

  test(
    'missing companion becomes an explicit install state without retry spam',
    () async {
      adb
        ..snapshot = [usbPhone()]
        ..companion = null;
      final dataSource = createSource();

      await waitUntil(() => dataSource.isCompanionMissing('USB123'));

      expect(
        dataSource.getConnectionPhase('USB123'),
        ConnectionPhase.companionMissing,
      );
      expect(dataSource.takePendingError(), isNull);
      expect(audio.initializeCalls, 0);
      expect(adb.findCompanionCalls, 1);

      await dataSource.installCompanion('USB123');
      await waitUntil(
        () => dataSource.overallPhase == ConnectionPhase.streaming,
      );

      expect(adb.installCalls, 1);
      expect(adb.findCompanionCalls, 2);
      expect(audio.startCalls, 1);
    },
  );

  test(
    'newer companion is surfaced as a non-retryable host update error',
    () async {
      adb
        ..snapshot = [usbPhone()]
        ..companionError = const CompanionHostUpdateRequiredException(
          installedVersionCode: 6,
          hostVersionCode: 5,
        );
      final dataSource = createSource();

      await waitUntil(() => dataSource.overallPhase == ConnectionPhase.failed);

      expect(
        dataSource.lastError?.exception,
        isA<CompanionHostUpdateRequiredException>(),
      );
      expect(dataSource.getConnectState('USB123'), 0);
      expect(audio.startCalls, 0);
    },
  );

  test('transient companion check failure reconnects automatically', () async {
    adb
      ..snapshot = [usbPhone()]
      ..companionFailuresRemaining = 1;
    final dataSource = createSource();

    await waitUntil(() => dataSource.overallPhase == ConnectionPhase.streaming);

    expect(adb.findCompanionCalls, 2);
    expect(dataSource.lastError?.type, UiErrorType.companionCheckFailed);
    expect(dataSource.takePendingError(), isNull);
  });

  test(
    'a stale native READY callback cannot revive an unplugged session',
    () async {
      adb.snapshot = [usbPhone()];
      audio.autoReady = false;
      final dataSource = createSource();

      await waitUntil(
        () => dataSource.overallPhase == ConnectionPhase.handshaking,
      );
      final staleReady = audio.connectCallback!;

      adb.publish([]);
      await waitUntil(
        () => dataSource.overallPhase == ConnectionPhase.waitingForPhone,
      );
      staleReady('ready');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(audio.startCalls, 0);
      expect(dataSource.getConnectState('USB123'), 0);
      expect(dataSource.overallPhase, ConnectionPhase.waitingForPhone);
    },
  );

  test(
    'persistent speaker-route errors stop instead of retrying pointlessly',
    () async {
      adb.snapshot = [usbPhone()];
      audio.autoReady = false;
      final dataSource = createSource(reconnectDelay: const Duration(hours: 1));
      await waitUntil(
        () => dataSource.overallPhase == ConnectionPhase.handshaking,
      );

      audio.nextError = const AudioCaptureError(
        2107,
        'Android handshake error: built-in speaker unavailable',
      );
      audio.connectCallback!('error');
      await waitUntil(
        () =>
            dataSource.lastError?.type ==
                UiErrorType.transportHandshakeFailed &&
            dataSource.overallPhase == ConnectionPhase.failed,
      );

      expect(dataSource.lastError?.nativeError?.code, 2107);
      expect(
        dataSource.lastError?.nativeError?.message,
        contains('built-in speaker unavailable'),
      );
      expect(dataSource.getConnectState('USB123'), 0);
      expect(dataSource.takePendingError(), isNotNull);
    },
  );

  test(
    'phone media taking audio focus stops once with an actionable error',
    () async {
      adb.snapshot = [usbPhone()];
      final dataSource = createSource(
        reconnectDelay: const Duration(milliseconds: 1),
        enableBackgroundTimers: true,
      );
      await waitUntil(
        () => dataSource.overallPhase == ConnectionPhase.streaming,
      );

      audio.nextError = const AudioCaptureError(
        2107,
        'Android playback error: AudioTrack playback failed: '
        'Android audio focus was lost',
      );
      await waitUntil(() => dataSource.overallPhase == ConnectionPhase.failed);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(dataSource.lastError?.type, UiErrorType.phoneAudioInUse);
      expect(dataSource.getConnectState('USB123'), 0);
      expect(adb.launchCalls, 1);
      expect(adb.createForwardCalls, 1);
      expect(dataSource.takePendingError()?.type, UiErrorType.phoneAudioInUse);
    },
  );

  test(
    'manual disconnect stays disconnected until manual connect or replug',
    () async {
      adb.snapshot = [usbPhone()];
      final dataSource = createSource();
      await waitUntil(
        () => dataSource.overallPhase == ConnectionPhase.streaming,
      );

      dataSource.disconnectDevice('USB123');
      await waitUntil(() => dataSource.getConnectState('USB123') == 0);
      expect(preferences.lastDeviceId, 'USB123');
      adb.publish([usbPhone()]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(adb.launchCalls, 1);

      adb.publish([]);
      await waitUntil(
        () => dataSource.overallPhase == ConnectionPhase.waitingForPhone,
      );
      adb.publish([usbPhone()]);
      await waitUntil(
        () => dataSource.overallPhase == ConnectionPhase.streaming,
      );
      expect(adb.launchCalls, 2);
    },
  );

  test(
    'transient companion launch failure reconnects with bounded backoff',
    () async {
      adb
        ..snapshot = [usbPhone()]
        ..launchFailuresRemaining = 1;
      final dataSource = createSource();

      await waitUntil(
        () => dataSource.overallPhase == ConnectionPhase.streaming,
      );

      expect(adb.launchCalls, 2);
      expect(adb.createForwardCalls, 2);
      expect(adb.removeForwardCalls, greaterThanOrEqualTo(1));
      expect(dataSource.lastError?.type, UiErrorType.companionLaunchFailed);
      expect(
        dataSource.takePendingError(),
        isNull,
        reason: 'a recovered automatic retry must not leave a stale modal',
      );
    },
  );

  test(
    'three identical automatic failures stop retrying and notify the user',
    () async {
      adb
        ..snapshot = [usbPhone()]
        ..launchFailuresRemaining = 3;
      final dataSource = createSource(
        reconnectDelay: const Duration(milliseconds: 1),
      );

      await waitUntil(
        () =>
            dataSource.overallPhase == ConnectionPhase.failed &&
            dataSource.getConnectState('USB123') == 0,
      );

      expect(adb.launchCalls, 3);
      expect(dataSource.takePendingError(), isNotNull);
      expect(dataSource.overallPhase, ConnectionPhase.failed);
    },
  );

  test(
    'a superseded forward creation removes the mapping it created',
    () async {
      adb
        ..snapshot = [usbPhone()]
        ..createForwardGate = Completer<void>();
      final dataSource = createSource();

      await waitUntil(() => adb.createForwardCalls == 1);
      adb.publish([]);
      await waitUntil(
        () => dataSource.overallPhase == ConnectionPhase.waitingForPhone,
      );

      adb.createForwardGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(adb.removeForwardCalls, 1);
      expect(dataSource.getConnectState('USB123'), 0);
    },
  );

  test(
    'capture is not reported streaming until native mode is active',
    () async {
      adb.snapshot = [usbPhone()];
      audio.modeAfterStart = WindowsCaptureMode.inactive;
      final dataSource = createSource(
        // Leave enough scheduling headroom for a loaded Windows CI runner while
        // still exercising the bounded readiness timeout.
        captureStartupTimeout: const Duration(milliseconds: 100),
        reconnectDelay: const Duration(hours: 1),
      );

      await waitUntil(
        () =>
            dataSource.lastError?.type == UiErrorType.captureStartFailed &&
            dataSource.overallPhase == ConnectionPhase.reconnecting &&
            dataSource.getConnectState('USB123') == 0,
      );

      expect(dataSource.getConnectState('USB123'), 0);
      expect(dataSource.overallPhase, ConnectionPhase.reconnecting);
      expect(audio.startCalls, 1);
    },
  );

  test('normal shutdown awaits exact ADB forward cleanup', () async {
    adb.snapshot = [usbPhone()];
    adb.removeForwardGate = Completer<void>();
    final dataSource = createSource();
    await waitUntil(() => dataSource.overallPhase == ConnectionPhase.streaming);

    final shutdown = dataSource.shutdown();
    await Future<void>.delayed(Duration.zero);
    expect(adb.removeForwardCalls, 1);
    expect(adb.disposed, isFalse);

    adb.removeForwardGate!.complete();
    await shutdown;
    expect(adb.disposed, isTrue);
    expect(audio.disposeCalls, 1);
  });
}
