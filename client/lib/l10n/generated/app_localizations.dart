import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'AudioShare'**
  String get appTitle;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @streamingDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Streaming diagnostics'**
  String get streamingDiagnostics;

  /// No description provided for @noDevices.
  ///
  /// In en, this message translates to:
  /// **'No devices found'**
  String get noDevices;

  /// No description provided for @waitingForPhone.
  ///
  /// In en, this message translates to:
  /// **'Connect an Android phone by USB'**
  String get waitingForPhone;

  /// No description provided for @phoneReady.
  ///
  /// In en, this message translates to:
  /// **'Authorized USB phone is ready'**
  String get phoneReady;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get connecting;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @installCompanion.
  ///
  /// In en, this message translates to:
  /// **'Install companion'**
  String get installCompanion;

  /// No description provided for @installingCompanion.
  ///
  /// In en, this message translates to:
  /// **'Installing'**
  String get installingCompanion;

  /// No description provided for @usbUnauthorized.
  ///
  /// In en, this message translates to:
  /// **'Unlock the phone and approve USB debugging.'**
  String get usbUnauthorized;

  /// No description provided for @usbOffline.
  ///
  /// In en, this message translates to:
  /// **'USB device is offline. Reconnect the cable.'**
  String get usbOffline;

  /// No description provided for @ignoredAdbDevice.
  ///
  /// In en, this message translates to:
  /// **'Ignored: connect this device by USB.'**
  String get ignoredAdbDevice;

  /// No description provided for @deviceMetadataUnavailable.
  ///
  /// In en, this message translates to:
  /// **'USB device is ready; optional device details are unavailable.'**
  String get deviceMetadataUnavailable;

  /// No description provided for @preferencesUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Settings could not be saved. Automatic reconnect choices may reset after restart.'**
  String get preferencesUnavailable;

  /// No description provided for @streamingAllSystemAudio.
  ///
  /// In en, this message translates to:
  /// **'Streaming all Windows system audio'**
  String get streamingAllSystemAudio;

  /// No description provided for @streamingGlobalSystemAudio.
  ///
  /// In en, this message translates to:
  /// **'Streaming all Windows audio (global mode)'**
  String get streamingGlobalSystemAudio;

  /// No description provided for @streamingMultiOutputAudio.
  ///
  /// In en, this message translates to:
  /// **'Streaming all active Windows outputs ({count} endpoints)'**
  String streamingMultiOutputAudio(String count);

  /// No description provided for @streamingDefaultOutputAudio.
  ///
  /// In en, this message translates to:
  /// **'Streaming Windows default output (last-resort compatibility mode)'**
  String get streamingDefaultOutputAudio;

  /// No description provided for @phaseCheckingAdb.
  ///
  /// In en, this message translates to:
  /// **'Checking USB and ADB'**
  String get phaseCheckingAdb;

  /// No description provided for @phaseCheckingCompanion.
  ///
  /// In en, this message translates to:
  /// **'Checking Android companion'**
  String get phaseCheckingCompanion;

  /// No description provided for @phaseCreatingForward.
  ///
  /// In en, this message translates to:
  /// **'Creating USB transport'**
  String get phaseCreatingForward;

  /// No description provided for @phaseStartingCompanion.
  ///
  /// In en, this message translates to:
  /// **'Starting Android companion'**
  String get phaseStartingCompanion;

  /// No description provided for @phaseConnectingTransport.
  ///
  /// In en, this message translates to:
  /// **'Connecting through USB'**
  String get phaseConnectingTransport;

  /// No description provided for @phaseHandshaking.
  ///
  /// In en, this message translates to:
  /// **'Authenticating session'**
  String get phaseHandshaking;

  /// No description provided for @phaseInitializingCapture.
  ///
  /// In en, this message translates to:
  /// **'Starting system-audio capture'**
  String get phaseInitializingCapture;

  /// No description provided for @phaseInitializing.
  ///
  /// In en, this message translates to:
  /// **'Validating the portable package'**
  String get phaseInitializing;

  /// No description provided for @phaseReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Connection interrupted; retrying automatically'**
  String get phaseReconnecting;

  /// No description provided for @phaseDisconnecting.
  ///
  /// In en, this message translates to:
  /// **'Cleaning up the USB audio session'**
  String get phaseDisconnecting;

  /// No description provided for @phaseFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed; see diagnostics'**
  String get phaseFailed;

  /// No description provided for @autoConnectLastDevice.
  ///
  /// In en, this message translates to:
  /// **'Automatically connect to an authorized USB phone'**
  String get autoConnectLastDevice;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageChinese.
  ///
  /// In en, this message translates to:
  /// **'Chinese (Simplified)'**
  String get languageChinese;

  /// No description provided for @deviceAndroidVersion.
  ///
  /// In en, this message translates to:
  /// **'Android {version} (API {apiLevel})'**
  String deviceAndroidVersion(String version, String apiLevel);

  /// No description provided for @deviceNetworkAddress.
  ///
  /// In en, this message translates to:
  /// **' - {ip}:{port}'**
  String deviceNetworkAddress(String ip, String port);

  /// No description provided for @connectionFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get connectionFailedTitle;

  /// No description provided for @packageValidationFailed.
  ///
  /// In en, this message translates to:
  /// **'The portable package is incomplete or ADB could not start.'**
  String get packageValidationFailed;

  /// No description provided for @adbCommandFailed.
  ///
  /// In en, this message translates to:
  /// **'ADB could not inspect the connected phone.'**
  String get adbCommandFailed;

  /// No description provided for @companionCheckFailed.
  ///
  /// In en, this message translates to:
  /// **'The Android companion could not be checked.'**
  String get companionCheckFailed;

  /// No description provided for @companionInstallFailed.
  ///
  /// In en, this message translates to:
  /// **'The bundled Android companion could not be installed.'**
  String get companionInstallFailed;

  /// No description provided for @companionLaunchFailed.
  ///
  /// In en, this message translates to:
  /// **'The Android companion could not be started.'**
  String get companionLaunchFailed;

  /// No description provided for @forwardCreationFailed.
  ///
  /// In en, this message translates to:
  /// **'The USB-local ADB transport could not be created.'**
  String get forwardCreationFailed;

  /// No description provided for @forwardCleanupFailed.
  ///
  /// In en, this message translates to:
  /// **'The owned ADB transport mapping could not be removed.'**
  String get forwardCleanupFailed;

  /// No description provided for @transportStartFailed.
  ///
  /// In en, this message translates to:
  /// **'The Windows outbound USB transport could not start.'**
  String get transportStartFailed;

  /// No description provided for @transportHandshakeFailed.
  ///
  /// In en, this message translates to:
  /// **'The authenticated USB audio handshake failed.'**
  String get transportHandshakeFailed;

  /// No description provided for @captureInitializationFailed.
  ///
  /// In en, this message translates to:
  /// **'System audio capture could not be initialized.'**
  String get captureInitializationFailed;

  /// No description provided for @captureStopped.
  ///
  /// In en, this message translates to:
  /// **'System audio capture stopped.'**
  String get captureStopped;

  /// No description provided for @captureStartFailed.
  ///
  /// In en, this message translates to:
  /// **'System audio capture could not be started.'**
  String get captureStartFailed;

  /// No description provided for @connectAndroidDeviceFailed.
  ///
  /// In en, this message translates to:
  /// **'An error occurred while connecting to the Android device.'**
  String get connectAndroidDeviceFailed;

  /// No description provided for @connectDeviceFailed.
  ///
  /// In en, this message translates to:
  /// **'An error occurred while connecting to the device.'**
  String get connectDeviceFailed;

  /// No description provided for @nativeErrorDetails.
  ///
  /// In en, this message translates to:
  /// **'Error code: {code}'**
  String nativeErrorDetails(String code);

  /// No description provided for @nativeError1000.
  ///
  /// In en, this message translates to:
  /// **'Audio capture initialization failed.'**
  String get nativeError1000;

  /// No description provided for @nativeError1200.
  ///
  /// In en, this message translates to:
  /// **'System audio capture could not be started.'**
  String get nativeError1200;

  /// No description provided for @nativeErrorHost.
  ///
  /// In en, this message translates to:
  /// **'The native Windows host could not initialize or change state.'**
  String get nativeErrorHost;

  /// No description provided for @nativeErrorTransport.
  ///
  /// In en, this message translates to:
  /// **'The authenticated Android USB audio transport failed.'**
  String get nativeErrorTransport;

  /// No description provided for @nativeErrorWindowsCapture.
  ///
  /// In en, this message translates to:
  /// **'Windows system-audio capture failed.'**
  String get nativeErrorWindowsCapture;

  /// No description provided for @nativeErrorUnknown.
  ///
  /// In en, this message translates to:
  /// **'An unknown system audio capture error occurred.'**
  String get nativeErrorUnknown;

  /// No description provided for @exceptionDetails.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic: {message}'**
  String exceptionDetails(String message);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
