enum AdbDeviceState { authorized, unauthorized, offline, unknown }

enum AdbTransportType { usb, network, emulator, unknown }

class DeviceModel {
  final String deviceId;
  final bool usb;
  final String serialNumber;
  final String model;
  final String manufacturer;
  final String androidVersion;
  final String apiLevel;
  final String ip;
  final String port;
  final AdbDeviceState adbState;
  final AdbTransportType transportType;
  final int? transportId;

  /// Non-fatal metadata diagnostic. The device remains selectable when ADB
  /// cannot read optional properties such as manufacturer or API level.
  final String? metadataError;

  DeviceModel({
    required this.deviceId,
    required this.usb,
    required this.serialNumber,
    required this.model,
    required this.manufacturer,
    required this.androidVersion,
    required this.apiLevel,
    required this.ip,
    required this.port,
    this.adbState = AdbDeviceState.authorized,
    this.transportType = AdbTransportType.unknown,
    this.transportId,
    this.metadataError,
  });

  bool get connectableUsb =>
      adbState == AdbDeviceState.authorized &&
      transportType == AdbTransportType.usb;
}
