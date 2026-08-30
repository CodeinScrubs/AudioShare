import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// Connect callback: void (*)(const char* connectCode)
typedef ConnectCallbackNative = Void Function(Pointer<Int8> connectCode);
typedef ConnectCallbackDart = void Function(Pointer<Int8> connectCode);

typedef AudioCaptureInitializeNative = Int32 Function();
typedef AudioCaptureInitializeDart = int Function();

typedef AudioCaptureConnectNative = Int32 Function(
  Int32 port,
  Pointer<Int8> tokenHex,
  Pointer<NativeFunction<ConnectCallbackNative>> callback,
);
typedef AudioCaptureConnectDart = int Function(
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

AudioCaptureService? _activeService;

void _handleConnect(Pointer<Int8> connectCodePtr) {
  final service = _activeService;
  if (service != null && service.onConnected != null) {
    final bytes = <int>[];
    var i = 0;
    while (true) {
      final byte = (connectCodePtr + i).value;
      if (byte == 0) break;
      bytes.add(byte);
      i++;
    }
    final connectCode = utf8.decode(bytes, allowMalformed: true);
    service.onConnected!(connectCode);
  }
}

class AudioCaptureService {
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
  AudioCaptureGetUint32Dart? _getCaptureMode;
  AudioCaptureGetInt32Dart? _getGlobalLoopbackHresult;
  AudioCaptureGetUint32Dart? _getActiveEndpointCount;
  AudioCaptureGetDroppedChunksDart? _getEndpointDroppedFrames;
  AudioCaptureGetDroppedChunksDart? _getEndpointUnderrunFrames;
  AudioCaptureGetDroppedChunksDart? _getEndpointDiscontinuities;
  AudioCaptureGetUint32Dart? _getEndpointRebuildCount;

  bool _initialized = false;
  String? _libraryLoadError;
  void Function(String connectCode)? onConnected;

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
      _initialize = _lib!.lookupFunction<AudioCaptureInitializeNative,
          AudioCaptureInitializeDart>('AudioCapture_Initialize');
      _connect = _lib!
          .lookupFunction<AudioCaptureConnectNative, AudioCaptureConnectDart>(
        'AudioCapture_Connect',
      );
      _start =
          _lib!.lookupFunction<AudioCaptureStartNative, AudioCaptureStartDart>(
        'AudioCapture_Start',
      );
      _stop =
          _lib!.lookupFunction<AudioCaptureStopNative, AudioCaptureStopDart>(
        'AudioCapture_Stop',
      );
      _cleanup = _lib!
          .lookupFunction<AudioCaptureCleanupNative, AudioCaptureCleanupDart>(
        'AudioCapture_Cleanup',
      );
      _getLastErrorCode =
          _lib!.lookupFunction<AudioCaptureBoolNative, AudioCaptureBoolDart>(
        'AudioCapture_GetLastErrorCode',
      );
      _getLastErrorMessage = _lib!.lookupFunction<
          AudioCaptureGetErrorMessageNative,
          AudioCaptureGetErrorMessageDart>('AudioCapture_GetLastErrorMessage');
      _clearLastError = _lib!
          .lookupFunction<AudioCaptureCleanupNative, AudioCaptureCleanupDart>(
        'AudioCapture_ClearLastError',
      );
      _getDroppedChunks = _lib!.lookupFunction<
          AudioCaptureGetDroppedChunksNative,
          AudioCaptureGetDroppedChunksDart>('AudioCapture_GetDroppedChunks');
      _getAndroidReceivedFrames = _lib!.lookupFunction<
          AudioCaptureGetDroppedChunksNative, AudioCaptureGetDroppedChunksDart>(
        'AudioCapture_GetAndroidReceivedFrames',
      );
      _getAndroidDroppedFrames = _lib!.lookupFunction<
          AudioCaptureGetDroppedChunksNative, AudioCaptureGetDroppedChunksDart>(
        'AudioCapture_GetAndroidDroppedFrames',
      );
      _getAndroidQueueDepth = _lib!.lookupFunction<AudioCaptureGetUint32Native,
          AudioCaptureGetUint32Dart>('AudioCapture_GetAndroidQueueDepth');
      _getAndroidBufferFrames = _lib!.lookupFunction<
          AudioCaptureGetUint32Native,
          AudioCaptureGetUint32Dart>('AudioCapture_GetAndroidBufferFrames');
      _getCaptureMode = _lib!.lookupFunction<AudioCaptureGetUint32Native,
          AudioCaptureGetUint32Dart>('AudioCapture_GetCaptureMode');
      _getGlobalLoopbackHresult = _lib!
          .lookupFunction<AudioCaptureGetInt32Native, AudioCaptureGetInt32Dart>(
              'AudioCapture_GetGlobalLoopbackHresult');
      _getActiveEndpointCount = _lib!.lookupFunction<
          AudioCaptureGetUint32Native,
          AudioCaptureGetUint32Dart>('AudioCapture_GetActiveEndpointCount');
      _getEndpointDroppedFrames = _lib!.lookupFunction<
              AudioCaptureGetDroppedChunksNative,
              AudioCaptureGetDroppedChunksDart>(
          'AudioCapture_GetEndpointDroppedFrames');
      _getEndpointUnderrunFrames = _lib!.lookupFunction<
              AudioCaptureGetDroppedChunksNative,
              AudioCaptureGetDroppedChunksDart>(
          'AudioCapture_GetEndpointUnderrunFrames');
      _getEndpointDiscontinuities = _lib!.lookupFunction<
              AudioCaptureGetDroppedChunksNative,
              AudioCaptureGetDroppedChunksDart>(
          'AudioCapture_GetEndpointDiscontinuities');
      _getEndpointRebuildCount = _lib!.lookupFunction<
          AudioCaptureGetUint32Native,
          AudioCaptureGetUint32Dart>('AudioCapture_GetEndpointRebuildCount');
    } catch (error) {
      _libraryLoadError = error.toString();
    }
  }

  /// Initialize Windows system-audio capture.
  bool initialize() {
    if (_initialized) return true;
    if (_initialize == null) return false;
    _activeService = this;
    _initialized = _initialize!() != 0;
    return _initialized;
  }

  /// Connect outbound to an ADB-owned loopback forward and authenticate the
  /// Android companion. AudioShare never binds or listens on Windows.
  bool connectToForward(
    int port,
    String tokenHex,
    void Function(String status) onConnect,
  ) {
    if (!_initialized || _connect == null) return false;
    onConnected = onConnect;
    _connectCallback?.close();
    _connectCallback = NativeCallable<ConnectCallbackNative>.listener(
      _handleConnect,
    );
    final token = tokenHex.toNativeUtf8(allocator: calloc).cast<Int8>();
    try {
      return _connect!(port, token, _connectCallback!.nativeFunction) != 0;
    } finally {
      calloc.free(token);
    }
  }

  int get droppedNativeChunks => _getDroppedChunks?.call() ?? 0;
  int get androidReceivedFrames => _getAndroidReceivedFrames?.call() ?? 0;
  int get androidDroppedFrames => _getAndroidDroppedFrames?.call() ?? 0;
  int get androidQueueDepth => _getAndroidQueueDepth?.call() ?? 0;
  int get androidBufferFrames => _getAndroidBufferFrames?.call() ?? 0;
  WindowsCaptureMode get captureMode => WindowsCaptureMode.fromNative(
        _getCaptureMode?.call() ?? 0,
      );
  int get globalLoopbackHresult => _getGlobalLoopbackHresult?.call() ?? 0;
  int get activeEndpointCount => _getActiveEndpointCount?.call() ?? 0;
  int get endpointDroppedFrames => _getEndpointDroppedFrames?.call() ?? 0;
  int get endpointUnderrunFrames => _getEndpointUnderrunFrames?.call() ?? 0;
  int get endpointDiscontinuities => _getEndpointDiscontinuities?.call() ?? 0;
  int get endpointRebuildCount => _getEndpointRebuildCount?.call() ?? 0;

  /// Start audio capture after the Android transport handshake completes.
  bool start() {
    if (!_initialized || _start == null) return false;
    return _start!() != 0;
  }

  AudioCaptureError? takeLastError({
    int fallbackCode = -1,
    String fallbackMessage = 'Unknown audio capture error',
  }) {
    if (_libraryLoadError != null) {
      final message = _libraryLoadError!;
      _libraryLoadError = null;
      return AudioCaptureError(-1000, message);
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

  AudioCaptureError? pollLastError() {
    if ((_getLastErrorCode?.call() ?? 0) == 0) return null;
    return takeLastError();
  }

  void stop() {
    if (!_initialized || _stop == null) return;
    _stop!();
  }

  void cleanup() {
    if (!_initialized || _cleanup == null) return;
    _cleanup!();
    _connectCallback?.close();
    _connectCallback = null;
    _initialized = false;
  }

  void dispose() {
    cleanup();
  }
}
