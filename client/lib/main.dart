import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data_source.dart';
import 'l10n/app_localizations_extensions.dart';
import 'l10n/generated/app_localizations.dart';
import 'models/device_model.dart';
import 'services/audio_capture.dart' show WindowsCaptureMode;
import 'utils/prefs.dart';

const _supportedLocales = [Locale('en'), Locale('zh')];
const _languagePreferenceKey = 'locale';

void main() {
  Prefs.load();
  runZonedGuarded(() => runApp(const AudioShareApp()), (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
  });
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
}

class AudioShareApp extends StatefulWidget {
  const AudioShareApp({super.key});

  @override
  State<AudioShareApp> createState() => _AudioShareAppState();
}

class _AudioShareAppState extends State<AudioShareApp> {
  Locale? _locale;

  @override
  void initState() {
    super.initState();
    final savedLanguage = Prefs.getString(_languagePreferenceKey);
    if (_supportedLocales.any(
      (locale) => locale.languageCode == savedLanguage,
    )) {
      _locale = Locale(savedLanguage);
    }
  }

  void _setLocale(Locale locale) {
    Prefs.setString(_languagePreferenceKey, locale.languageCode);
    setState(() => _locale = locale);
  }

  Locale _resolveLocale(
    Locale? deviceLocale,
    Iterable<Locale> supportedLocales,
  ) {
    final languageCode = deviceLocale?.languageCode;
    return supportedLocales.firstWhere(
      (locale) => locale.languageCode == languageCode,
      orElse: () => const Locale('en'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AudioShare',
      debugShowCheckedModeBanner: false,
      locale: _locale,
      supportedLocales: _supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      localeResolutionCallback: _resolveLocale,
      home: AudioShareHomePage(onLocaleChanged: _setLocale),
    );
  }
}

class AudioShareHomePage extends StatefulWidget {
  const AudioShareHomePage({super.key, required this.onLocaleChanged});

  final ValueChanged<Locale> onLocaleChanged;

  @override
  State<AudioShareHomePage> createState() => _AudioShareHomePageState();
}

class _AudioShareHomePageState extends State<AudioShareHomePage>
    with WidgetsBindingObserver {
  late final DataSource _dataSource;
  Future<void>? _dataSourceShutdown;
  bool _showingError = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dataSource = DataSource();
    _dataSource.addListener(_onDataSourceChanged);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_shutdownDataSource());
    }
  }

  Future<void> _shutdownDataSource() {
    final existing = _dataSourceShutdown;
    if (existing != null) return existing;
    _dataSource.removeListener(_onDataSourceChanged);
    final shutdown = _dataSource.shutdown().whenComplete(_dataSource.dispose);
    _dataSourceShutdown = shutdown;
    return shutdown;
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _shutdownDataSource();
    return AppExitResponse.exit;
  }

  void _onDataSourceChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _showPendingError());
  }

  String _errorDescription(AppLocalizations l10n, UiError error) {
    final description = switch (error.type) {
      UiErrorType.packageValidationFailed => l10n.packageValidationFailed,
      UiErrorType.adbCommandFailed => l10n.adbCommandFailed,
      UiErrorType.companionCheckFailed => l10n.companionCheckFailed,
      UiErrorType.companionInstallFailed => l10n.companionInstallFailed,
      UiErrorType.companionLaunchFailed => l10n.companionLaunchFailed,
      UiErrorType.forwardCreationFailed => l10n.forwardCreationFailed,
      UiErrorType.forwardCleanupFailed => l10n.forwardCleanupFailed,
      UiErrorType.transportStartFailed => l10n.transportStartFailed,
      UiErrorType.transportHandshakeFailed => l10n.transportHandshakeFailed,
      UiErrorType.captureInitializationFailed =>
        l10n.captureInitializationFailed,
      UiErrorType.captureStopped => l10n.captureStopped,
      UiErrorType.captureStartFailed => l10n.captureStartFailed,
      UiErrorType.connectAndroidDeviceFailed => l10n.connectAndroidDeviceFailed,
      UiErrorType.connectDeviceFailed => l10n.connectDeviceFailed,
    };
    if (error.nativeError case final nativeError?) {
      final details = <String>[
        description,
        l10n.nativeErrorDescription(nativeError.code),
        if (nativeError.message.trim().isNotEmpty)
          l10n.exceptionDetails(nativeError.message.trim()),
        l10n.nativeErrorDetailsFormatted(nativeError.code),
      ];
      return details.join('\n\n');
    }
    if (error.exception case final exception?) {
      return '$description\n\n${l10n.exceptionDetails(exception.toString())}';
    }
    return description;
  }

  Future<void> _showPendingError() async {
    if (!mounted || _showingError) return;
    _showingError = true;
    try {
      while (mounted) {
        final error = _dataSource.takePendingError();
        if (error == null) break;
        if (!mounted) break;
        final l10n = AppLocalizations.of(context);
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.connectionFailedTitle),
            content: SelectableText(_errorDescription(l10n, error)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.ok),
              ),
            ],
          ),
        );
      }
    } finally {
      _showingError = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_shutdownDataSource());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          PopupMenuButton<Locale>(
            tooltip: l10n.language,
            icon: const Icon(Icons.language),
            onSelected: widget.onLocaleChanged,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: const Locale('en'),
                child: Text(l10n.languageEnglish),
              ),
              PopupMenuItem(
                value: const Locale('zh'),
                child: Text(l10n.languageChinese),
              ),
            ],
          ),
        ],
      ),
      body: SizedBox(
        width: 360,
        height: 540,
        child: Column(
          children: [
            Expanded(child: _buildContent(l10n)),
            _buildCheckBox(l10n),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(AppLocalizations l10n) {
    switch (_dataSource.deviceState) {
      case 0:
        return const Center(child: CircularProgressIndicator());
      case 1:
        return Center(child: Text(l10n.waitingForPhone));
      case 2:
        return ListView.separated(
          itemCount: _dataSource.devices.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final device = _dataSource.devices[index];
            final connectState = _dataSource.getConnectState(device.deviceId);
            final connectEnable = _dataSource.getConnectEnable(device.deviceId);
            final companionMissing = _dataSource.isCompanionMissing(
              device.deviceId,
            );
            final companionInstalling = _dataSource.isCompanionInstalling(
              device.deviceId,
            );
            final apiLevel = int.tryParse(device.apiLevel) ?? 0;
            final port = int.tryParse(device.port) ?? 0;
            final connectionLabel = switch (connectState) {
              0 when companionInstalling => l10n.installingCompanion,
              0 when companionMissing => l10n.installCompanion,
              0 => l10n.connect,
              1 => l10n.connecting,
              2 => l10n.disconnect,
              _ => l10n.connect,
            };
            final deviceName =
                '${device.manufacturer} ${device.model}'.trim().isEmpty
                ? device.deviceId
                : '${device.manufacturer} ${device.model}'.trim();
            final phase = _dataSource.getConnectionPhase(device.deviceId);
            final phaseStatus = switch (phase) {
              ConnectionPhase.initializing => l10n.phaseInitializing,
              ConnectionPhase.waitingForPhone => l10n.waitingForPhone,
              ConnectionPhase.phoneUnauthorized => l10n.usbUnauthorized,
              ConnectionPhase.phoneOffline => l10n.usbOffline,
              ConnectionPhase.phoneReady => l10n.phoneReady,
              ConnectionPhase.checkingAdb => l10n.phaseCheckingAdb,
              ConnectionPhase.checkingCompanion => l10n.phaseCheckingCompanion,
              ConnectionPhase.companionMissing => l10n.installCompanion,
              ConnectionPhase.installingCompanion => l10n.installingCompanion,
              ConnectionPhase.creatingForward => l10n.phaseCreatingForward,
              ConnectionPhase.startingCompanion => l10n.phaseStartingCompanion,
              ConnectionPhase.connectingTransport =>
                l10n.phaseConnectingTransport,
              ConnectionPhase.handshaking => l10n.phaseHandshaking,
              ConnectionPhase.initializingCapture =>
                l10n.phaseInitializingCapture,
              ConnectionPhase.reconnecting => l10n.phaseReconnecting,
              ConnectionPhase.disconnecting => l10n.phaseDisconnecting,
              ConnectionPhase.failed => l10n.phaseFailed,
              _ => null,
            };
            final deviceStatus = switch (device.adbState) {
              AdbDeviceState.unauthorized => l10n.usbUnauthorized,
              AdbDeviceState.offline => l10n.usbOffline,
              _ when device.transportType != AdbTransportType.usb =>
                l10n.ignoredAdbDevice,
              _ when connectState == 2 => switch (_dataSource.captureMode) {
                WindowsCaptureMode.globalSystem =>
                  l10n.streamingGlobalSystemAudio,
                WindowsCaptureMode.multiEndpoint =>
                  l10n.streamingMultiOutputAudio(
                    _dataSource.activeEndpointCount.toString(),
                  ),
                WindowsCaptureMode.defaultEndpoint =>
                  l10n.streamingDefaultOutputAudio,
                WindowsCaptureMode.inactive => l10n.streamingAllSystemAudio,
              },
              _ when phaseStatus != null => phaseStatus,
              _ when companionMissing => l10n.installCompanion,
              _ =>
                '${l10n.deviceAndroidVersionFormatted(device.androidVersion, apiLevel)}${device.usb ? '' : l10n.deviceNetworkAddressFormatted(device.ip, port)}',
            };
            return SizedBox(
              height: 72,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Icon(device.usb ? Icons.usb : Icons.wifi, size: 24),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            deviceName,
                            style: const TextStyle(fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            deviceStatus,
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (connectState == 2)
                    IconButton(
                      tooltip: l10n.streamingDiagnostics,
                      onPressed: () =>
                          _showStreamingDiagnostics(context, l10n, deviceName),
                      icon: const Icon(Icons.monitor_heart_outlined),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: ElevatedButton(
                      onPressed: companionInstalling
                          ? null
                          : companionMissing && connectEnable
                          ? () => unawaited(
                              _dataSource.installCompanion(device.deviceId),
                            )
                          : connectEnable
                          ? () {
                              if (connectState == 0) {
                                _dataSource.connectDevice(device.deviceId);
                              } else if (connectState == 2) {
                                _dataSource.disconnectDevice(device.deviceId);
                              }
                            }
                          : null,
                      child: Text(connectionLabel),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      case 3:
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.inventory_2_outlined, size: 44),
              const SizedBox(height: 16),
              Text(l10n.packageValidationFailed, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              SelectableText(
                _dataSource.startupFailure,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _dataSource.retryStartup,
                child: Text(l10n.retry),
              ),
            ],
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Future<void> _showStreamingDiagnostics(
    BuildContext context,
    AppLocalizations l10n,
    String deviceName,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${l10n.streamingDiagnostics} — $deviceName'),
      content: SingleChildScrollView(
        child: SelectableText(
          _dataSource.streamingDiagnostics,
          style: const TextStyle(fontFamily: 'monospace'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.ok),
        ),
      ],
    ),
  );

  Widget _buildCheckBox(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.only(left: 10, bottom: 10),
      child: Row(
        children: [
          Checkbox(
            value: _dataSource.lastCheck,
            onChanged: (value) => _dataSource.lastCheck = value ?? false,
          ),
          Expanded(child: Text(l10n.autoConnectLastDevice)),
        ],
      ),
    );
  }
}
