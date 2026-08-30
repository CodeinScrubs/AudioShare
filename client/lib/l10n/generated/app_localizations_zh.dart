// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'AudioShare';

  @override
  String get ok => '确定';

  @override
  String get noDevices => '未找到设备';

  @override
  String get connect => '连接';

  @override
  String get connecting => '连接中';

  @override
  String get disconnect => '断开';

  @override
  String get installCompanion => '安装配套应用';

  @override
  String get installingCompanion => '正在安装';

  @override
  String get usbUnauthorized => '请解锁手机并允许 USB 调试。';

  @override
  String get usbOffline => 'USB 设备离线。请重新连接数据线。';

  @override
  String get ignoredAdbDevice => '已忽略：请通过 USB 连接此设备。';

  @override
  String get streamingAllSystemAudio => '正在传输全部 Windows 系统音频';

  @override
  String get streamingGlobalSystemAudio => '正在传输全部 Windows 音频（全局模式）';

  @override
  String streamingMultiOutputAudio(String count) {
    return '正在传输所有活动的 Windows 输出（$count 个）';
  }

  @override
  String get streamingDefaultOutputAudio => '正在传输 Windows 默认输出（最终兼容回退）';

  @override
  String get phaseCheckingAdb => '正在检查 USB 和 ADB';

  @override
  String get phaseCheckingCompanion => '正在检查 Android 配套应用';

  @override
  String get phaseCreatingForward => '正在创建 USB 传输';

  @override
  String get phaseStartingCompanion => '正在启动 Android 配套应用';

  @override
  String get phaseConnectingTransport => '正在通过 USB 连接';

  @override
  String get phaseHandshaking => '正在验证会话';

  @override
  String get phaseInitializingCapture => '正在启动系统音频捕获';

  @override
  String get autoConnectLastDevice => '自动连接上次使用的设备';

  @override
  String get language => '语言';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageChinese => '简体中文';

  @override
  String deviceAndroidVersion(String version, String apiLevel) {
    return 'Android $version（API $apiLevel）';
  }

  @override
  String deviceNetworkAddress(String ip, String port) {
    return ' - $ip:$port';
  }

  @override
  String get connectionFailedTitle => '连接失败';

  @override
  String get captureInitializationFailed => '无法初始化系统音频捕获。';

  @override
  String get captureStopped => '系统音频捕获已停止。';

  @override
  String get captureStartFailed => '无法开始捕获系统音频。';

  @override
  String get connectAndroidDeviceFailed => '连接 Android 设备时发生错误。';

  @override
  String get connectDeviceFailed => '连接设备时发生错误。';

  @override
  String nativeErrorDetails(String code) {
    return '错误码：$code';
  }

  @override
  String get nativeError1000 => '系统音频捕获初始化失败。';

  @override
  String get nativeError1200 => '无法开始系统音频捕获。';

  @override
  String get nativeErrorHost => 'Windows 原生主机无法初始化或切换状态。';

  @override
  String get nativeErrorTransport => '经身份验证的 Android USB 音频传输失败。';

  @override
  String get nativeErrorWindowsCapture => 'Windows 系统音频捕获失败。';

  @override
  String get nativeErrorUnknown => '发生未知系统音频捕获错误。';

  @override
  String exceptionDetails(String message) {
    return '诊断信息：$message';
  }
}
