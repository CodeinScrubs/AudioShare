// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'AudioShare';

  @override
  String get ok => 'OK';

  @override
  String get streamingDiagnostics => 'Streaming diagnostics';

  @override
  String get noDevices => 'No devices found';

  @override
  String get waitingForPhone => 'Connect an Android phone by USB';

  @override
  String get phoneReady => 'Authorized USB phone is ready';

  @override
  String get retry => 'Retry';

  @override
  String get connect => 'Connect';

  @override
  String get connecting => 'Connecting';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get installCompanion => 'Install companion';

  @override
  String get installingCompanion => 'Installing';

  @override
  String get usbUnauthorized => 'Unlock the phone and approve USB debugging.';

  @override
  String get usbOffline => 'USB device is offline. Reconnect the cable.';

  @override
  String get ignoredAdbDevice => 'Ignored: connect this device by USB.';

  @override
  String get deviceMetadataUnavailable =>
      'USB device is ready; optional device details are unavailable.';

  @override
  String get preferencesUnavailable =>
      'Settings could not be saved. Automatic reconnect choices may reset after restart.';

  @override
  String get streamingAllSystemAudio => 'Streaming all Windows system audio';

  @override
  String get streamingGlobalSystemAudio =>
      'Streaming all Windows audio (global mode)';

  @override
  String streamingMultiOutputAudio(String count) {
    return 'Streaming all active Windows outputs ($count endpoints)';
  }

  @override
  String get streamingDefaultOutputAudio =>
      'Streaming Windows default output (last-resort compatibility mode)';

  @override
  String get phaseCheckingAdb => 'Checking USB and ADB';

  @override
  String get phaseCheckingCompanion => 'Checking Android companion';

  @override
  String get phaseCreatingForward => 'Creating USB transport';

  @override
  String get phaseStartingCompanion => 'Starting Android companion';

  @override
  String get phaseConnectingTransport => 'Connecting through USB';

  @override
  String get phaseHandshaking => 'Authenticating session';

  @override
  String get phaseInitializingCapture => 'Starting system-audio capture';

  @override
  String get phaseInitializing => 'Validating the portable package';

  @override
  String get phaseReconnecting =>
      'Connection interrupted; retrying automatically';

  @override
  String get phaseDisconnecting => 'Cleaning up the USB audio session';

  @override
  String get phaseFailed => 'Connection failed; see diagnostics';

  @override
  String get autoConnectLastDevice =>
      'Automatically connect to an authorized USB phone';

  @override
  String get language => 'Language';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageChinese => 'Chinese (Simplified)';

  @override
  String deviceAndroidVersion(String version, String apiLevel) {
    return 'Android $version (API $apiLevel)';
  }

  @override
  String deviceNetworkAddress(String ip, String port) {
    return ' - $ip:$port';
  }

  @override
  String get connectionFailedTitle => 'Connection failed';

  @override
  String get packageValidationFailed =>
      'The portable package is incomplete or ADB could not start.';

  @override
  String get adbCommandFailed => 'ADB could not inspect the connected phone.';

  @override
  String get companionCheckFailed =>
      'The Android companion could not be checked.';

  @override
  String get companionInstallFailed =>
      'The bundled Android companion could not be installed.';

  @override
  String get companionLaunchFailed =>
      'The Android companion could not be started.';

  @override
  String get forwardCreationFailed =>
      'The USB-local ADB transport could not be created.';

  @override
  String get forwardCleanupFailed =>
      'The owned ADB transport mapping could not be removed.';

  @override
  String get transportStartFailed =>
      'The Windows outbound USB transport could not start.';

  @override
  String get transportHandshakeFailed =>
      'The authenticated USB audio handshake failed.';

  @override
  String get captureInitializationFailed =>
      'System audio capture could not be initialized.';

  @override
  String get captureStopped => 'System audio capture stopped.';

  @override
  String get captureStartFailed => 'System audio capture could not be started.';

  @override
  String get connectAndroidDeviceFailed =>
      'An error occurred while connecting to the Android device.';

  @override
  String get connectDeviceFailed =>
      'An error occurred while connecting to the device.';

  @override
  String nativeErrorDetails(String code) {
    return 'Error code: $code';
  }

  @override
  String get nativeError1000 => 'Audio capture initialization failed.';

  @override
  String get nativeError1200 => 'System audio capture could not be started.';

  @override
  String get nativeErrorHost =>
      'The native Windows host could not initialize or change state.';

  @override
  String get nativeErrorTransport =>
      'The authenticated Android USB audio transport failed.';

  @override
  String get nativeErrorWindowsCapture =>
      'Windows system-audio capture failed.';

  @override
  String get nativeErrorUnknown =>
      'An unknown system audio capture error occurred.';

  @override
  String exceptionDetails(String message) {
    return 'Diagnostic: $message';
  }
}
