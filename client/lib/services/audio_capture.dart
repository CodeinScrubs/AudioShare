import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// Connect callback: void (*)(const char* connectCode)
typedef ConnectCallbackNative = Void Function(Pointer<Int8> connectCode);
typedef ConnectCallbackDart = void Function(Pointer<Int8> connectCode);

typedef AudioCaptureInitializeNative = Int32 Function();
typedef AudioCaptureInitializeDart = int Function();

typedef AudioCaptureConnectNative =
    Int32 Function(
      Int32 port,
      Pointer<Int8> tokenHex,
      Pointer<NativeFunction<ConnectCallbackNative>> callback,
    );
typedef AudioCaptureConnectDart =
    int Function(
      int port,
      Pointer<Int8> tokenHex,
      Pointer<NativeFunction<ConnectCallbackNative>> callback,
    );

typedef AudioCaptureStartNative = Int32 Function();
typedef AudioCaptureStartDart = int Function();

typedef AudioCaptureStopNative = Void Function();
typedef AudioCaptureStopDart = void Function();

typedef AudioCaptureCleanupNative = Void Function();
typedef AudioCaptureCleanupDart = void Function();

typedef AudioCaptureBoolNative = Int32 Function();
typedef AudioCaptureBoolDart = int Function();

typedef AudioCaptureGetErrorMessageNative = Pointer<Int8> Function();
typedef AudioCaptureGetErrorMessageDart = Pointer<Int8> Function();

typedef AudioCaptureGetDroppedChunksNative = Uint64 Function();
typedef AudioCaptureGetDroppedChunksDart = int Function();

typedef AudioCaptureGetUint32Native = Uint32 Function();
typedef AudioCaptureGetUint32Dart = int Function();

typedef AudioCaptureGetInt32Native = Int32 Function();
typedef AudioCaptureGetInt32Dart = int Function();

enum WindowsCaptureMode {
  inactive,
  globalSystem,
  multiEndpoint,
  defaultEndpoint;

  static WindowsCaptureMode fromNative(int value) => switch (value) {
    1 => WindowsCaptureMode.globalSystem,
    2 => WindowsCaptureMode.multiEndpoint,
    3 => WindowsCaptureMode.defaultEndpoint,
    _ => WindowsCaptureMode.inactive,
  };
}

class AudioCaptureError {
  const AudioCaptureError(this.code, this.message);

  final int code;
  final String message;
}

/// Testable boundary between the Dart connection supervisor and the native
/// Windows capture/transport DLL.
///
/// Keeping this boundary small lets the supervisor's generation, retry, and
/// device-state behavior be exercised without loading a Windows DLL in unit
/// tests. [AudioCaptureService] remains the production FFI implementation.
abstract interface class AudioCaptureController {
  int get droppedNativeChunks;
  int get androidReceivedFrames;
  int get androidDroppedFrames;
  int get androidQueueDepth;
  int get androidBufferFrames;
  int get androidQueueFrames;
  int get androidBufferCapacityFrames;
  int get androidStartThresholdFrames;
  int get androidUnderrunCount;
  int get androidRoutedDeviceType;
  int get androidFocusState;
  int get androidMediaVolume;
  int get androidMediaVolumeMax;
  int get androidQueueHighWaterFrames;
  int get androidWrittenFrames;
  int get androidPlaybackHeadFrames;
  int get androidLastWriteProgressAgeMilliseconds;
  int get androidLastPlaybackAdvanceAgeMilliseconds;
  int get androidPlayState;
  int get androidPerformanceMode;
  int get hostQueueFrames;
  int get hostQueueHighWaterFrames;
  int get transportBytesSent;
  int get heartbeatRttMilliseconds;
  WindowsCaptureMode get captureMode;
  int get globalLoopbackHresult;
  int get activeEndpointCount;
  int get endpointDroppedFrames;
  int get endpointUnderrunFrames;
  int get endpointDiscontinuities;
  int get captureDiscontinuities;
  int get endpointRebuildCount;
  int get endpointCatchUpFrames;
  int get endpointQueueHighWaterFrames;
  int get capturedFrames;
  int get capturePeakPermille;
  int get captureRmsPermille;
  int get lastNonSilentAgeMilliseconds;

  bool initialize();

  bool connectToForward(
    int port,
    String tokenHex,
    void Function(String status) onConnect,
  );

  bool start();

  AudioCaptureError? takeLastError({
    int fallbackCode = -1,
    String fallbackMessage = 'Unknown audio capture error',
  });

  AudioCaptureError? pollLastError();

  void stop();
  void cleanup();
  void dispose();
}

String _decodeConnectStatus(Pointer<Int8> connectCodePtr) {
  final bytes = <int>[];
  for (var index = 0; index < 64; index++) {
    final byte = (connectCodePtr + index).value;
    if (byte == 0) break;
    bytes.add(byte & 0xff);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

class AudioCaptureService implements AudioCaptureController {
  DynamicLibrary? _lib;
  AudioCaptureInitializeDart? _initialize;
  AudioCaptureConnectDart? _connect;
  AudioCaptureStartDart? _start;
  AudioCaptureStopDart? _stop;
  AudioCaptureCleanupDart? _cleanup;
  AudioCaptureBoolDart? _getLastErrorCode;
  AudioCaptureGetErrorMessageDart? _getLastErrorMessage;
  AudioCaptureCleanupDart? _clearLastError;
  AudioCaptureGetDroppedChunksDart? _getDroppedChunks;
  AudioCaptureGetDroppedChunksDart? _getAndroidReceivedFrames;
  AudioCaptureGetDroppedChunksDart? _getAndroidDroppedFrames;
  AudioCaptureGetUint32Dart? _getAndroidQueueDepth;
  AudioCaptureGetUint32Dart? _getAndroidBufferFrames;
  AudioCaptureGetUint32Dart? _getAndroidQueueFrames;
  AudioCaptureGetUint32Dart? _getAndroidBufferCapacityFrames;
  AudioCaptureGetUint32Dart? _getAndroidStartThresholdFrames;
  AudioCaptureGetUint32Dart? _getAndroidUnderrunCount;
  AudioCaptureGetUint32Dart? _getAndroidRoutedDeviceType;
  AudioCaptureGetUint32Dart? _getAndroidFocusState;
  AudioCaptureGetUint32Dart? _getAndroidMediaVolume;
  AudioCaptureGetUint32Dart? _getAndroidMediaVolumeMax;
  AudioCaptureGetUint32Dart? _getAndroidQueueHighWaterFrames;
  AudioCaptureGetDroppedChunksDart? _getAndroidWrittenFrames;
  AudioCaptureGetDroppedChunksDart? _getAndroidPlaybackHeadFrames;
  AudioCaptureGetUint32Dart? _getAndroidLastWriteProgressAgeMilliseconds;
  AudioCaptureGetUint32Dart? _getAndroidLastPlaybackAdvanceAgeMilliseconds;
  AudioCaptureGetUint32Dart? _getAndroidPlayState;
  AudioCaptureGetUint32Dart? _getAndroidPerformanceMode;
  AudioCaptureGetUint32Dart? _getHostQueueFrames;
  AudioCaptureGetUint32Dart? _getHostQueueHighWaterFrames;
  AudioCaptureGetDroppedChunksDart? _getTransportBytesSent;
  AudioCaptureGetUint32Dart? _getHeartbeatRttMilliseconds;
  AudioCaptureGetUint32Dart? _getCaptureMode;
  AudioCaptureGetInt32Dart? _getGlobalLoopbackHresult;
  AudioCaptureGetUint32Dart? _getActiveEndpointCount;
  AudioCaptureGetDroppedChunksDart? _getEndpointDroppedFrames;
  AudioCaptureGetDroppedChunksDart? _getEndpointUnderrunFrames;
  AudioCaptureGetDroppedChunksDart? _getEndpointDiscontinuities;
  AudioCaptureGetDroppedChunksDart? _getCaptureDiscontinuities;
  AudioCaptureGetUint32Dart? _getEndpointRebuildCount;
  AudioCaptureGetDroppedChunksDart? _getEndpointCatchUpFrames;
  AudioCaptureGetUint32Dart? _getEndpointQueueHighWaterFrames;
  AudioCaptureGetDroppedChunksDart? _getCapturedFrames;
  AudioCaptureGetUint32Dart? _getCapturePeakPermille;
  AudioCaptureGetUint32Dart? _getCaptureRmsPermille;
  AudioCaptureGetUint32Dart? _getLastNonSilentAgeMilliseconds;

  bool _initialized = false;
  String? _libraryLoadError;

  NativeCallable<ConnectCallbackNative>? _connectCallback;

  AudioCaptureService() {
    _loadLibrary();
  }

  void _loadLibrary() {
    try {
      if (!Platform.isWindows) {
        throw UnsupportedError(
          'This fork supports Windows system audio capture only.',
        );
      }
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final dllPath = '$exeDir${Platform.pathSeparator}audio_capture.dll';
      _lib = DynamicLibrary.open(dllPath);
      _initialize = _lib!
          .lookupFunction<
            AudioCaptureInitializeNative,
            AudioCaptureInitializeDart
          >('AudioCapture_Initialize');
      _connect = _lib!
          .lookupFunction<AudioCaptureConnectNative, AudioCaptureConnectDart>(
            'AudioCapture_Connect',
          );
      _start = _lib!
          .lookupFunction<AudioCaptureStartNative, AudioCaptureStartDart>(
            'AudioCapture_Start',
          );
      _stop = _lib!
          .lookupFunction<AudioCaptureStopNative, AudioCaptureStopDart>(
            'AudioCapture_Stop',
          );
      _cleanup = _lib!
          .lookupFunction<AudioCaptureCleanupNative, AudioCaptureCleanupDart>(
            'AudioCapture_Cleanup',
          );
      _getLastErrorCode = _lib!
          .lookupFunction<AudioCaptureBoolNative, AudioCaptureBoolDart>(
            'AudioCapture_GetLastErrorCode',
          );
      _getLastErrorMessage = _lib!
          .lookupFunction<
            AudioCaptureGetErrorMessageNative,
            AudioCaptureGetErrorMessageDart
          >('AudioCapture_GetLastErrorMessage');
      _clearLastError = _lib!
          .lookupFunction<AudioCaptureCleanupNative, AudioCaptureCleanupDart>(
            'AudioCapture_ClearLastError',
          );
      _getDroppedChunks = _lib!
          .lookupFunction<
            AudioCaptureGetDroppedChunksNative,
            AudioCaptureGetDroppedChunksDart
          >('AudioCapture_GetDroppedChunks');
      _getAndroidReceivedFrames = _lib!
          .lookupFunction<
            AudioCaptureGetDroppedChunksNative,
            AudioCaptureGetDroppedChunksDart
          >('AudioCapture_GetAndroidReceivedFrames');
      _getAndroidDroppedFrames = _lib!
          .lookupFunction<
            AudioCaptureGetDroppedChunksNative,
            AudioCaptureGetDroppedChunksDart
          >('AudioCapture_GetAndroidDroppedFrames');
      _getAndroidQueueDepth = _lib!
          .lookupFunction<
            AudioCaptureGetUint32Native,
            AudioCaptureGetUint32Dart
          >('AudioCapture_GetAndroidQueueDepth');
      _getAndroidBufferFrames = _lib!
          .lookupFunction<
            AudioCaptureGetUint32Native,
            AudioCaptureGetUint32Dart
          >('AudioCapture_GetAndroidBufferFrames');
      _getAndroidQueueFrames = _lookupUint32(
        'AudioCapture_GetAndroidQueueFrames',
      );
      _getAndroidBufferCapacityFrames = _lookupUint32(
        'AudioCapture_GetAndroidBufferCapacityFrames',
      );
      _getAndroidStartThresholdFrames = _lookupUint32(
        'AudioCapture_GetAndroidStartThresholdFrames',
      );
      _getAndroidUnderrunCount = _lookupUint32(
        'AudioCapture_GetAndroidUnderrunCount',
      );
      _getAndroidRoutedDeviceType = _lookupUint32(
        'AudioCapture_GetAndroidRoutedDeviceType',
      );
      _getAndroidFocusState = _lookupUint32(
        'AudioCapture_GetAndroidFocusState',
      );
      _getAndroidMediaVolume = _lookupUint32(
        'AudioCapture_GetAndroidMediaVolume',
      );
      _getAndroidMediaVolumeMax = _lookupUint32(
        'AudioCapture_GetAndroidMediaVolumeMax',
      );
      _getAndroidQueueHighWaterFrames = _lookupUint32(
        'AudioCapture_GetAndroidQueueHighWaterFrames',
      );
      _getAndroidWrittenFrames = _lookupUint64(
        'AudioCapture_GetAndroidWrittenFrames',
      );
      _getAndroidPlaybackHeadFrames = _lookupUint64(
        'AudioCapture_GetAndroidPlaybackHeadFrames',
      );
      _getAndroidLastWriteProgressAgeMilliseconds = _lookupUint32(
        'AudioCapture_GetAndroidLastWriteProgressAgeMilliseconds',
      );
      _getAndroidLastPlaybackAdvanceAgeMilliseconds = _lookupUint32(
        'AudioCapture_GetAndroidLastPlaybackAdvanceAgeMilliseconds',
      );
      _getAndroidPlayState = _lookupUint32('AudioCapture_GetAndroidPlayState');
      _getAndroidPerformanceMode = _lookupUint32(
        'AudioCapture_GetAndroidPerformanceMode',
      );
      _getHostQueueFrames = _lookupUint32('AudioCapture_GetHostQueueFrames');
      _getHostQueueHighWaterFrames = _lookupUint32(
        'AudioCapture_GetHostQueueHighWaterFrames',
      );
      _getTransportBytesSent = _lib!
          .lookupFunction<
            AudioCaptureGetDroppedChunksNative,
            AudioCaptureGetDroppedChunksDart
          >('AudioCapture_GetTransportBytesSent');
      _getHeartbeatRttMilliseconds = _lookupUint32(
        'AudioCapture_GetHeartbeatRttMilliseconds',
      );
      _getCaptureMode = _lib!
          .lookupFunction<
            AudioCaptureGetUint32Native,
            AudioCaptureGetUint32Dart
          >('AudioCapture_GetCaptureMode');
      _getGlobalLoopbackHresult = _lib!
          .lookupFunction<AudioCaptureGetInt32Native, AudioCaptureGetInt32Dart>(
            'AudioCapture_GetGlobalLoopbackHresult',
          );
      _getActiveEndpointCount = _lib!
          .lookupFunction<
            AudioCaptureGetUint32Native,
            AudioCaptureGetUint32Dart
          >('AudioCapture_GetActiveEndpointCount');
      _getEndpointDroppedFrames = _lib!
          .lookupFunction<
            AudioCaptureGetDroppedChunksNative,
            AudioCaptureGetDroppedChunksDart
          >('AudioCapture_GetEndpointDroppedFrames');
      _getEndpointUnderrunFrames = _lib!
          .lookupFunction<
            AudioCaptureGetDroppedChunksNative,
            AudioCaptureGetDroppedChunksDart
          >('AudioCapture_GetEndpointUnderrunFrames');
      _getEndpointDiscontinuities = _lib!
          .lookupFunction<
            AudioCaptureGetDroppedChunksNative,
            AudioCaptureGetDroppedChunksDart
          >('AudioCapture_GetEndpointDiscontinuities');
      _getCaptureDiscontinuities = _lib!
          .lookupFunction<
            AudioCaptureGetDroppedChunksNative,
            AudioCaptureGetDroppedChunksDart
          >('AudioCapture_GetCaptureDiscontinuities');
      _getEndpointRebuildCount = _lib!
          .lookupFunction<
            AudioCaptureGetUint32Native,
            AudioCaptureGetUint32Dart
          >('AudioCapture_GetEndpointRebuildCount');
      _getEndpointCatchUpFrames = _lib!
          .lookupFunction<
            AudioCaptureGetDroppedChunksNative,
            AudioCaptureGetDroppedChunksDart
          >('AudioCapture_GetEndpointCatchUpFrames');
      _getEndpointQueueHighWaterFrames = _lookupUint32(
        'AudioCapture_GetEndpointQueueHighWaterFrames',
      );
      _getCapturedFrames = _lookupUint64('AudioCapture_GetCapturedFrames');
      _getCapturePeakPermille = _lookupUint32(
        'AudioCapture_GetCapturePeakPermille',
      );
      _getCaptureRmsPermille = _lookupUint32(
        'AudioCapture_GetCaptureRmsPermille',
      );
      _getLastNonSilentAgeMilliseconds = _lookupUint32(
        'AudioCapture_GetLastNonSilentAgeMilliseconds',
      );
    } catch (error) {
      _libraryLoadError = error.toString();
    }
  }

  AudioCaptureGetUint32Dart _lookupUint32(String name) => _lib!
      .lookupFunction<AudioCaptureGetUint32Native, AudioCaptureGetUint32Dart>(
        name,
      );

  AudioCaptureGetDroppedChunksDart _lookupUint64(String name) =>
      _lib!.lookupFunction<
        AudioCaptureGetDroppedChunksNative,
        AudioCaptureGetDroppedChunksDart
      >(name);

  /// Initialize Windows system-audio capture.
  @override
  bool initialize() {
    if (_initialized) return true;
    // A partial export lookup must fail before any native state is created.
    // Otherwise initialization could succeed and the first missing function
    // would surface later as an opaque transport failure.
    if (_libraryLoadError != null || _initialize == null) return false;
    _initialized = _initialize!() != 0;
    return _initialized;
  }

  /// Connect outbound to an ADB-owned loopback forward and authenticate the
  /// Android companion. AudioShare never binds or listens on Windows.
  @override
  bool connectToForward(
    int port,
    String tokenHex,
    void Function(String status) onConnect,
  ) {
    if (!_initialized || _connect == null) return false;
    // Each connection owns a closure containing that supervisor generation.
    // AudioCapture_Connect synchronously reaps the previous native worker
    // before it returns success, so only then is it safe to close the previous
    // callback. A callback already queued into Dart either retains its original
    // closure or is discarded; it can never be rebound to a newer generation.
    final nextCallback = NativeCallable<ConnectCallbackNative>.listener(
      (Pointer<Int8> connectCodePtr) =>
          onConnect(_decodeConnectStatus(connectCodePtr)),
    );
    final previousCallback = _connectCallback;
    final token = tokenHex.toNativeUtf8(allocator: calloc).cast<Int8>();
    var retainedNextCallback = false;
    try {
      final connected =
          _connect!(port, token, nextCallback.nativeFunction) != 0;
      if (!connected) return false;
      _connectCallback = nextCallback;
      retainedNextCallback = true;
      previousCallback?.close();
      return true;
    } finally {
      if (!retainedNextCallback) nextCallback.close();
      calloc.free(token);
    }
  }

  @override
  int get droppedNativeChunks => _getDroppedChunks?.call() ?? 0;
  @override
  int get androidReceivedFrames => _getAndroidReceivedFrames?.call() ?? 0;
  @override
  int get androidDroppedFrames => _getAndroidDroppedFrames?.call() ?? 0;
  @override
  int get androidQueueDepth => _getAndroidQueueDepth?.call() ?? 0;
  @override
  int get androidBufferFrames => _getAndroidBufferFrames?.call() ?? 0;
  @override
  int get androidQueueFrames => _getAndroidQueueFrames?.call() ?? 0;
  @override
  int get androidBufferCapacityFrames =>
      _getAndroidBufferCapacityFrames?.call() ?? 0;
  @override
  int get androidStartThresholdFrames =>
      _getAndroidStartThresholdFrames?.call() ?? 0;
  @override
  int get androidUnderrunCount => _getAndroidUnderrunCount?.call() ?? 0;
  @override
  int get androidRoutedDeviceType => _getAndroidRoutedDeviceType?.call() ?? 0;
  @override
  int get androidFocusState => _getAndroidFocusState?.call() ?? 0;
  @override
  int get androidMediaVolume => _getAndroidMediaVolume?.call() ?? 0;
  @override
  int get androidMediaVolumeMax => _getAndroidMediaVolumeMax?.call() ?? 0;
  @override
  int get androidQueueHighWaterFrames =>
      _getAndroidQueueHighWaterFrames?.call() ?? 0;
  @override
  int get androidWrittenFrames => _getAndroidWrittenFrames?.call() ?? 0;
  @override
  int get androidPlaybackHeadFrames =>
      _getAndroidPlaybackHeadFrames?.call() ?? 0;
  @override
  int get androidLastWriteProgressAgeMilliseconds =>
      _getAndroidLastWriteProgressAgeMilliseconds?.call() ?? 0;
  @override
  int get androidLastPlaybackAdvanceAgeMilliseconds =>
      _getAndroidLastPlaybackAdvanceAgeMilliseconds?.call() ?? 0;
  @override
  int get androidPlayState => _getAndroidPlayState?.call() ?? 0;
  @override
  int get androidPerformanceMode => _getAndroidPerformanceMode?.call() ?? 0;
  @override
  int get hostQueueFrames => _getHostQueueFrames?.call() ?? 0;
  @override
  int get hostQueueHighWaterFrames => _getHostQueueHighWaterFrames?.call() ?? 0;
  @override
  int get transportBytesSent => _getTransportBytesSent?.call() ?? 0;
  @override
  int get heartbeatRttMilliseconds => _getHeartbeatRttMilliseconds?.call() ?? 0;
  @override
  WindowsCaptureMode get captureMode =>
      WindowsCaptureMode.fromNative(_getCaptureMode?.call() ?? 0);
  @override
  int get globalLoopbackHresult => _getGlobalLoopbackHresult?.call() ?? 0;
  @override
  int get activeEndpointCount => _getActiveEndpointCount?.call() ?? 0;
  @override
  int get endpointDroppedFrames => _getEndpointDroppedFrames?.call() ?? 0;
  @override
  int get endpointUnderrunFrames => _getEndpointUnderrunFrames?.call() ?? 0;
  @override
  int get endpointDiscontinuities => _getEndpointDiscontinuities?.call() ?? 0;
  @override
  int get captureDiscontinuities => _getCaptureDiscontinuities?.call() ?? 0;
  @override
  int get endpointRebuildCount => _getEndpointRebuildCount?.call() ?? 0;
  @override
  int get endpointCatchUpFrames => _getEndpointCatchUpFrames?.call() ?? 0;
  @override
  int get endpointQueueHighWaterFrames =>
      _getEndpointQueueHighWaterFrames?.call() ?? 0;
  @override
  int get capturedFrames => _getCapturedFrames?.call() ?? 0;
  @override
  int get capturePeakPermille => _getCapturePeakPermille?.call() ?? 0;
  @override
  int get captureRmsPermille => _getCaptureRmsPermille?.call() ?? 0;
  @override
  int get lastNonSilentAgeMilliseconds =>
      _getLastNonSilentAgeMilliseconds?.call() ?? 0;

  /// Start audio capture after the Android transport handshake completes.
  @override
  bool start() {
    if (!_initialized || _start == null) return false;
    return _start!() != 0;
  }

  @override
  AudioCaptureError? takeLastError({
    int fallbackCode = -1,
    String fallbackMessage = 'Unknown audio capture error',
  }) {
    if (_libraryLoadError != null) {
      // Loading/export failure is structural, not a consumable native runtime
      // error. Keep it persistent so an automatic retry cannot initialize a
      // partially resolved, ABI-incompatible DLL after the UI reads it once.
      return AudioCaptureError(-1000, _libraryLoadError!);
    }

    final code = _getLastErrorCode?.call() ?? 0;
    var message = '';
    final messagePtr = _getLastErrorMessage?.call();
    if (messagePtr != null && messagePtr.address != 0) {
      final bytes = <int>[];
      for (var i = 0; i < 4096; i++) {
        final byte = (messagePtr + i).value;
        if (byte == 0) break;
        bytes.add(byte & 0xff);
      }
      message = utf8.decode(bytes, allowMalformed: true);
    }
    _clearLastError?.call();

    if (code == 0 && message.isEmpty) {
      return AudioCaptureError(fallbackCode, fallbackMessage);
    }
    return AudioCaptureError(
      code == 0 ? fallbackCode : code,
      message.isEmpty ? fallbackMessage : message,
    );
  }

  @override
  AudioCaptureError? pollLastError() {
    if ((_getLastErrorCode?.call() ?? 0) == 0) return null;
    return takeLastError();
  }

  @override
  void stop() {
    if (!_initialized || _stop == null) return;
    _stop!();
  }

  @override
  void cleanup() {
    if (!_initialized || _cleanup == null) return;
    _cleanup!();
    _connectCallback?.close();
    _connectCallback = null;
    _initialized = false;
  }

  @override
  void dispose() {
    cleanup();
  }
}
