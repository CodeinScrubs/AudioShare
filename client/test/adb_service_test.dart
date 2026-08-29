import 'package:audioshare/models/device_model.dart';
import 'package:audioshare/services/adb_service.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAdbRunner implements AdbCommandRunner {
  final requests = <AdbCommandRequest>[];
  final responses = <({int exitCode, String stdout, String stderr})>[];

  void enqueue({int exitCode = 0, String stdout = '', String stderr = ''}) {
    responses.add((
      exitCode: exitCode,
      stdout: stdout,
      stderr: stderr,
    ));
  }

  @override
  Future<AdbCommandResult> run(
    String executable,
    AdbCommandRequest request,
  ) async {
    requests.add(request);
    if (responses.isEmpty) {
      throw StateError('No fake response for ${request.operation}');
    }
    final response = responses.removeAt(0);
    return AdbCommandResult(
      operation: request.operation,
      executable: executable,
      arguments: request.safeArguments,
      exitCode: response.exitCode,
      stdout: response.stdout,
      stderr: response.stderr,
      duration: const Duration(milliseconds: 1),
      timedOut: false,
    );
  }
}

void main() {
  test('USB-only environment removes ambient ADB routing case-insensitively',
      () {
    final result = buildUsbOnlyAdbEnvironment({
      'Path': 'example',
      'adb_server_socket': 'tcp:host.example:5037',
      'ANDROID_ADB_SERVER_ADDRESS': 'host.example',
      'ANDROID_ADB_SERVER_PORT': '5038',
      'ANDROID_SERIAL': 'host.example:5555',
    });

    expect(result['Path'], 'example');
    expect(
      result.keys.map((key) => key.toUpperCase()),
      isNot(contains('ADB_SERVER_SOCKET')),
    );
    expect(result, isNot(contains('ANDROID_ADB_SERVER_ADDRESS')));
    expect(result, isNot(contains('ANDROID_ADB_SERVER_PORT')));
    expect(result, isNot(contains('ANDROID_SERIAL')));
    expect(result['ADB_MDNS'], '0');
    expect(result['ADB_MDNS_AUTO_CONNECT'], '0');
    expect(result['ADB_EMU'], '0');
  });

  test('device parser preserves states and probes metadata only over USB',
      () async {
    final runner = FakeAdbRunner()
      ..enqueue(
        stdout: '''List of devices attached
USB123 device usb:1-2 product:a model:Pixel_8 transport_id:1
USB456 unauthorized usb:1-3 transport_id:2
192.0.2.1:5555 device product:b model:Network transport_id:3
emulator-5554 device product:c model:Emulator transport_id:4
''',
      )
      ..enqueue(
        stdout: '''sn:USB123
mo:Pixel 8
mf:Google
av:16
al:36
''',
      );
    final adb = AdbService(runner: runner, adbPath: 'fake-adb');

    final devices = await adb.devices();

    expect(devices, hasLength(4));
    expect(devices[0].connectableUsb, isTrue);
    expect(devices[0].model, 'Pixel 8');
    expect(devices[1].adbState, AdbDeviceState.unauthorized);
    expect(devices[1].connectableUsb, isFalse);
    expect(devices[2].transportType, AdbTransportType.network);
    expect(devices[2].connectableUsb, isFalse);
    expect(devices[3].transportType, AdbTransportType.emulator);
    expect(devices[3].connectableUsb, isFalse);
    expect(runner.requests, hasLength(2));
    expect(runner.requests.last.operation, 'read Android device metadata');
    adb.dispose();
  });

  test('companion handshake inputs are redacted and cleanup is exact',
      () async {
    final runner = FakeAdbRunner()
      ..enqueue()
      ..enqueue(stdout: 'package:/data/app/debug/base.apk\n')
      ..enqueue(stdout: '43210\n');
    final adb = AdbService(runner: runner, adbPath: 'fake-adb');
    const token =
        '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

    final installation = await adb.findCompanion('USB123');
    expect(installation, CompanionInstallation.debug);
    final forward = await adb.createForward(
      deviceId: 'USB123',
      socketName: 'as_1_test',
      generation: 7,
    );
    expect(forward.hostPort, 43210);

    runner.enqueue();
    await adb.launchCompanion(
      deviceId: 'USB123',
      socketName: 'as_1_test',
      tokenHex: token,
      generation: 7,
      installation: installation!,
    );
    expect(runner.requests.last.safeArguments, contains('<redacted>'));
    expect(runner.requests.last.safeArguments, isNot(contains(token)));

    runner.enqueue();
    await adb.removeForward(forward);
    expect(
      runner.requests.last.arguments,
      ['-s', 'USB123', 'forward', '--remove', 'tcp:43210'],
    );
    expect(runner.requests.last.arguments, isNot(contains('--remove-all')));
    adb.dispose();
  });

  test('invalid dynamic forward output fails closed', () async {
    final runner = FakeAdbRunner()..enqueue(stdout: 'not-a-port\n');
    final adb = AdbService(runner: runner, adbPath: 'fake-adb');

    await expectLater(
      adb.createForward(
        deviceId: 'USB123',
        socketName: 'as_1_test',
        generation: 1,
      ),
      throwsFormatException,
    );
    adb.dispose();
  });
}
