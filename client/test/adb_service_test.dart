import 'dart:io';

import 'package:audioshare/models/device_model.dart';
import 'package:audioshare/services/adb_service.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAdbRunner implements AdbCommandRunner {
  final requests = <AdbCommandRequest>[];
  final responses = <({int exitCode, String stdout, String stderr})>[];

  void enqueue({int exitCode = 0, String stdout = '', String stderr = ''}) {
    responses.add((exitCode: exitCode, stdout: stdout, stderr: stderr));
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

const _fixtureApkHash =
    '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81';
const _wrongFixtureApkHash =
    '0000000000000000000000000000000000000000000000000000000000000000';

Future<Directory> createCompanionFixture() async {
  final directory = await Directory.systemTemp.createTemp(
    'audioshare-companion-test-',
  );
  await File(
    '${directory.path}${Platform.pathSeparator}'
    'audioshare-companion-poc-debug.apk',
  ).writeAsBytes(const [1, 2, 3]);
  return directory;
}

void main() {
  test(
    'USB-only environment removes ambient ADB routing case-insensitively',
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
    },
  );

  test('Windows device parser recognizes USB without a usb devpath', () async {
    final runner = FakeAdbRunner()
      ..enqueue(
        stdout: '''List of devices attached
USB123 device product:a model:Pixel_8 transport_id:1
USB456 unauthorized transport_id:2
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
    expect(devices[0].transportType, AdbTransportType.usb);
    expect(devices[0].model, 'Pixel 8');
    expect(devices[1].adbState, AdbDeviceState.unauthorized);
    expect(devices[1].transportType, AdbTransportType.usb);
    expect(devices[1].connectableUsb, isFalse);
    expect(devices[2].transportType, AdbTransportType.network);
    expect(devices[2].connectableUsb, isFalse);
    expect(devices[3].transportType, AdbTransportType.emulator);
    expect(devices[3].connectableUsb, isFalse);
    expect(runner.requests, hasLength(2));
    expect(runner.requests.last.operation, 'read Android device metadata');
    adb.dispose();
  });

  test('one flaky USB metadata query does not hide other devices', () async {
    final runner = FakeAdbRunner()
      ..enqueue(
        stdout: '''List of devices attached
USB123 device product:a model:Working transport_id:1
USB456 device product:b model:Flaky transport_id:2
''',
      )
      ..enqueue(stdout: 'sn:USB123\nmo:Working\nmf:Test\nav:14\nal:34\n')
      ..enqueue(exitCode: 1, stderr: 'device is offline');
    final adb = AdbService(runner: runner, adbPath: 'fake-adb');

    final devices = await adb.devices();

    expect(devices, hasLength(2));
    expect(devices[0].metadataError, isNull);
    expect(devices[1].metadataError, contains('device is offline'));
    expect(devices[1].connectableUsb, isTrue);
    adb.dispose();
  });

  test('Windows transport classifier rejects every non-USB ADB form', () {
    expect(
      classifyWindowsAdbTransport('USB123', const {}),
      AdbTransportType.usb,
    );
    expect(
      classifyWindowsAdbTransport('USB123', const {'usb': '1-2'}),
      AdbTransportType.usb,
    );
    expect(
      classifyWindowsAdbTransport('example.test:5555', const {}),
      AdbTransportType.network,
    );
    expect(
      classifyWindowsAdbTransport('[2001:db8::1]:5555', const {}),
      AdbTransportType.network,
    );
    expect(
      classifyWindowsAdbTransport(
        'adb-serial-random._adb-tls-connect._tcp',
        const {},
      ),
      AdbTransportType.network,
    );
    expect(
      classifyWindowsAdbTransport('emulator-5554', const {}),
      AdbTransportType.emulator,
    );
    expect(
      classifyWindowsAdbTransport('vsock:3:5555', const {}),
      AdbTransportType.emulator,
    );
  });

  test('companion package version parser is strict', () {
    expect(
      parseCompanionVersionCode(
        'Packages:\n  versionCode=2 minSdk=26 targetSdk=36\n',
      ),
      2,
    );
    expect(parseCompanionVersionCode('versionCode=not-a-number'), isNull);
    expect(parseCompanionVersionCode('otherVersionCode=2'), isNull);
  });

  test('activity launch requires an explicit successful status', () {
    expect(
      hasSuccessfulActivityLaunchStatus(
        'Starting: Intent { ... }\nStatus: ok\nComplete\n',
      ),
      isTrue,
    );
    expect(
      hasSuccessfulActivityLaunchStatus('Starting: Intent { ... }\n'),
      isFalse,
    );
    expect(hasSuccessfulActivityLaunchStatus('Status: Error\n'), isFalse);
  });

  test('shared ADB server status parser accepts only simple keys', () {
    expect(
      parseAdbServerStatus('''version: 37.0.1
executable_absolute_path: C:\\Android\\adb.exe
mdns_enabled: true
not a key: ignored
'''),
      {
        'version': '37.0.1',
        'executable_absolute_path': r'C:\Android\adb.exe',
        'mdns_enabled': 'true',
      },
    );
  });

  test(
    'companion handshake inputs are redacted and cleanup is exact',
    () async {
      final companionDirectory = await createCompanionFixture();
      final runner = FakeAdbRunner()
        ..enqueue(exitCode: 1)
        ..enqueue(stdout: 'package:/data/app/debug/base.apk\n')
        ..enqueue(stdout: '    versionCode=7 minSdk=26 targetSdk=36\n')
        ..enqueue(stdout: '$_fixtureApkHash  /data/app/debug/base.apk\n')
        ..enqueue(stdout: '43210\n');
      final adb = AdbService(
        runner: runner,
        adbPath: 'fake-adb',
        companionDirectoryPath: companionDirectory.path,
        forwardJournalPath:
            '${companionDirectory.path}${Platform.pathSeparator}forward.json',
      );
      const token =
          '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

      final installation = await adb.findCompanion('USB123');
      expect(installation, CompanionInstallation.debug);
      final forward = await adb.createForward(
        deviceId: 'USB123',
        socketName: 'as_1_0011223344556677',
        generation: 7,
      );
      expect(forward.hostPort, 43210);
      expect(
        File(
          '${companionDirectory.path}${Platform.pathSeparator}forward.json',
        ).existsSync(),
        isTrue,
      );

      runner.enqueue(
        stdout: 'Starting: Intent { ... }\nStatus: ok\nComplete\n',
      );
      await adb.launchCompanion(
        deviceId: 'USB123',
        socketName: 'as_1_0011223344556677',
        tokenHex: token,
        generation: 7,
        installation: installation!,
      );
      expect(runner.requests.last.safeArguments, contains('<redacted>'));
      expect(runner.requests.last.safeArguments, isNot(contains(token)));

      runner.enqueue();
      await adb.removeForward(forward);
      expect(runner.requests.last.arguments, [
        '-s',
        'USB123',
        'forward',
        '--remove',
        'tcp:43210',
      ]);
      expect(runner.requests.last.arguments, isNot(contains('--remove-all')));
      expect(
        File(
          '${companionDirectory.path}${Platform.pathSeparator}forward.json',
        ).existsSync(),
        isFalse,
      );
      adb.dispose();
      await companionDirectory.delete(recursive: true);
    },
  );

  test(
    'repackaged installed companion is rejected by exact APK hash',
    () async {
      final companionDirectory = await createCompanionFixture();
      final runner = FakeAdbRunner()
        ..enqueue(exitCode: 1)
        ..enqueue(stdout: 'package:/data/app/debug/base.apk\n')
        ..enqueue(stdout: '    versionCode=7 minSdk=26 targetSdk=36\n')
        ..enqueue(stdout: '$_wrongFixtureApkHash  /data/app/debug/base.apk\n');
      final adb = AdbService(
        runner: runner,
        adbPath: 'fake-adb',
        companionDirectoryPath: companionDirectory.path,
      );

      expect(await adb.findCompanion('USB123'), isNull);
      expect(
        runner.requests.map((request) => request.operation),
        contains('verify installed Android companion APK'),
      );
      adb.dispose();
      await companionDirectory.delete(recursive: true);
    },
  );

  test('outdated installed companion is offered as missing', () async {
    final runner = FakeAdbRunner()
      ..enqueue(stdout: 'package:/data/app/release/base.apk\n')
      ..enqueue(stdout: '    versionCode=2 minSdk=26 targetSdk=36\n')
      ..enqueue(exitCode: 1);
    final adb = AdbService(runner: runner, adbPath: 'fake-adb');

    expect(await adb.findCompanion('USB123'), isNull);
    expect(
      runner.requests.map((request) => request.operation),
      contains('check Android companion compatibility'),
    );
    adb.dispose();
  });

  test(
    'newer installed companion requests a host update instead of downgrade',
    () async {
      final runner = FakeAdbRunner()
        ..enqueue(stdout: 'package:/data/app/release/base.apk\n')
        ..enqueue(stdout: '    versionCode=8 minSdk=26 targetSdk=36\n');
      final adb = AdbService(runner: runner, adbPath: 'fake-adb');

      await expectLater(
        adb.findCompanion('USB123'),
        throwsA(isA<CompanionHostUpdateRequiredException>()),
      );
      expect(
        runner.requests.map((request) => request.operation),
        isNot(contains('verify installed Android companion APK')),
      );
      adb.dispose();
    },
  );

  test('invalid dynamic forward output fails closed', () async {
    final runner = FakeAdbRunner()..enqueue(stdout: 'not-a-port\n');
    final adb = AdbService(runner: runner, adbPath: 'fake-adb');

    await expectLater(
      adb.createForward(
        deviceId: 'USB123',
        socketName: 'as_1_0011223344556677',
        generation: 1,
      ),
      throwsFormatException,
    );
    adb.dispose();
  });

  test('crash recovery removes only the exact journaled forward', () async {
    final directory = await Directory.systemTemp.createTemp(
      'audioshare-forward-recovery-',
    );
    final journal = '${directory.path}${Platform.pathSeparator}forward.json';
    final creatorRunner = FakeAdbRunner()..enqueue(stdout: '43210\n');
    final creator = AdbService(
      runner: creatorRunner,
      adbPath: 'fake-adb',
      forwardJournalPath: journal,
    );
    await creator.createForward(
      deviceId: 'USB123',
      socketName: 'as_1_0011223344556677',
      generation: 7,
    );
    creator.dispose();

    final recoveryRunner = FakeAdbRunner()
      ..enqueue(
        stdout: 'USB123 tcp:43210 localabstract:as_1_0011223344556677\n',
      )
      ..enqueue();
    final recovery = AdbService(
      runner: recoveryRunner,
      adbPath: 'fake-adb',
      forwardJournalPath: journal,
    );

    await recovery.recoverOwnedForwards();

    expect(recoveryRunner.requests.last.arguments, [
      '-s',
      'USB123',
      'forward',
      '--remove',
      'tcp:43210',
    ]);
    expect(
      recoveryRunner.requests.last.arguments,
      isNot(contains('--remove-all')),
    );
    expect(File(journal).existsSync(), isFalse);
    expect(
      recovery.diagnosticLines,
      contains('adb_forward_journal=recovered:1'),
    );
    recovery.dispose();
    await directory.delete(recursive: true);
  });

  test('crash recovery never removes a mismatched mapping', () async {
    final directory = await Directory.systemTemp.createTemp(
      'audioshare-forward-mismatch-',
    );
    final journal = '${directory.path}${Platform.pathSeparator}forward.json';
    final creatorRunner = FakeAdbRunner()..enqueue(stdout: '43210\n');
    final creator = AdbService(
      runner: creatorRunner,
      adbPath: 'fake-adb',
      forwardJournalPath: journal,
    );
    await creator.createForward(
      deviceId: 'USB123',
      socketName: 'as_1_0011223344556677',
      generation: 7,
    );
    creator.dispose();

    final recoveryRunner = FakeAdbRunner()
      ..enqueue(stdout: 'USB123 tcp:43210 localabstract:not_audioshare\n');
    final recovery = AdbService(
      runner: recoveryRunner,
      adbPath: 'fake-adb',
      forwardJournalPath: journal,
    );

    await recovery.recoverOwnedForwards();

    expect(recoveryRunner.requests, hasLength(1));
    expect(recoveryRunner.requests.single.arguments, ['forward', '--list']);
    expect(File(journal).existsSync(), isFalse);
    recovery.dispose();
    await directory.delete(recursive: true);
  });

  test('crash recovery runs only once per host process', () async {
    final directory = await Directory.systemTemp.createTemp(
      'audioshare-forward-once-',
    );
    final journal = '${directory.path}${Platform.pathSeparator}forward.json';
    final runner = FakeAdbRunner()..enqueue(stdout: '43210\n');
    final adb = AdbService(
      runner: runner,
      adbPath: 'fake-adb',
      forwardJournalPath: journal,
    );

    await adb.recoverOwnedForwards();
    await adb.createForward(
      deviceId: 'USB123',
      socketName: 'as_1_0011223344556677',
      generation: 7,
    );
    await adb.recoverOwnedForwards();

    expect(runner.requests, hasLength(1));
    expect(runner.requests.single.operation, 'create ADB USB audio forward');
    adb.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'wrong-key companion install returns an actionable replacement error',
    () async {
      final companionDirectory = await createCompanionFixture();
      final runner = FakeAdbRunner()
        ..enqueue(
          exitCode: 1,
          stdout:
              'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures differ]\n',
        );
      final adb = AdbService(
        runner: runner,
        adbPath: 'fake-adb',
        companionDirectoryPath: companionDirectory.path,
      );

      await expectLater(
        adb.installBundledCompanion('USB123'),
        throwsA(isA<CompanionReplacementRequiredException>()),
      );
      adb.dispose();
      await companionDirectory.delete(recursive: true);
    },
  );
}
