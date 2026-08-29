import 'package:audioshare/services/audio_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native Windows capture modes fail closed', () {
    expect(
      WindowsCaptureMode.fromNative(1),
      WindowsCaptureMode.globalSystem,
    );
    expect(
      WindowsCaptureMode.fromNative(2),
      WindowsCaptureMode.defaultEndpoint,
    );
    expect(WindowsCaptureMode.fromNative(0), WindowsCaptureMode.inactive);
    expect(WindowsCaptureMode.fromNative(-1), WindowsCaptureMode.inactive);
    expect(WindowsCaptureMode.fromNative(99), WindowsCaptureMode.inactive);
  });
}
