# AudioShare USB Custom

Stream **all Windows system audio** to an Android phone speaker over a USB ADB
connection. This fork is being specialized for a portable, standard-user,
firewall-independent Windows workflow.

Development status: the Android companion builds and its unit/lint checks pass;
the Windows global-capture path compiles and passed a local native integration
test with non-zero PCM. Physical USB, phone playback, firewall-prompt, latency,
and long-run tests are still required before this fork is release-ready. See
[POC results](docs/POC_RESULTS.md).

## Architecture

```text
all ordinary Windows applications and system sounds
                -> global process loopback (preferred)
                -> default-output loopback (compatibility fallback)
                -> 48 kHz stereo PCM16
                -> outbound 127.0.0.1 connection
                -> ADB forward over USB
                -> installed Android companion
                -> AudioTrack
                -> phone speaker
```

The Windows program creates no listening audio socket. Automatic mode rejects
Wi-Fi ADB and emulators. The Android companion declares no `INTERNET` permission.
No virtual audio driver, firewall rule, LAN, Wi-Fi, Internet, installer, Windows
service, or administrator elevation is intentionally required at runtime.

On supported Windows builds, AudioShare uses Microsoft's virtual process-loopback
device in exclude mode: it captures the global system mix except AudioShare's own
process tree, independent of physical render endpoint. If that feature probe
fails, it falls back to event-driven loopback of the default Windows output. The
UI identifies which mode is active. A true multi-endpoint aggregator for older
Windows remains planned; compatibility mode does not claim to capture apps
explicitly routed to a different output endpoint.

## First time only

1. Extract the complete Windows package to a normal user-writable folder.
2. Enable Android Developer Options and USB debugging.
3. Connect the phone with a data-capable USB cable.
4. Unlock the phone and approve **Allow USB debugging?** for this computer.
5. Start AudioShare. Select the authorized USB phone.
6. If prompted, choose **Install companion**. This is an explicit one-time ADB
   APK installation; AudioShare never silently installs an app in the background.
7. Choose **Connect** and confirm that system audio plays through the phone.
8. Leave automatic reconnection enabled for the remembered phone.

The PC must already have a working Android USB/ADB driver. Installing a missing
driver can require administrator access and is outside AudioShare's control.

## Daily use target

1. Start or log in to Windows with AudioShare running.
2. Plug in the remembered, authorized phone by USB.
3. Play sound from any Windows application, including Infinit/idplayer.

The intended final workflow requires no Android UI, IP address, Wi-Fi, Internet,
firewall approval, or Connect click. That zero-click behavior is implemented but
not yet hardware-verified.

## Build from source

Host prerequisites are Flutter 3.x and Visual Studio 2022 or newer with Desktop
C++. From `client`:

```powershell
flutter pub get
flutter gen-l10n
flutter analyze
flutter test
flutter build windows --debug
```

Debug builds bundle the clearly labeled POC debug companion APK. A distributable
release must use a stable signing key and provide the signed APK explicitly:

```powershell
$env:AUDIOSHARE_COMPANION_APK = 'C:\absolute\path\audioshare-companion.apk'
flutter build windows --release
```

The sibling `client android app` Git repository owns the native companion:

```powershell
cd '..\client android app'
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
.\gradlew.bat testDebugUnitTest lintRelease assembleRelease --no-daemon
```

Additional native protocol check:

```powershell
g++ -std=c++17 -Wall -Wextra -Werror client/native/wire_protocol_test.cpp
```

The native system-capture integration harness uses a fake local companion. It
verifies activation, handshake, 48 kHz PCM flow, and non-zero signal without an
Android device; the fake listener exists only inside the test executable:

```powershell
g++ -std=c++17 -Wall -Wextra -Werror -shared client/native/audio_capture.cpp `
  -o audio_capture.dll -lmmdevapi -lole32 -lws2_32 -lwinmm -luuid
g++ -std=c++17 -Wall -Wextra -Werror `
  client/native/system_capture_integration_test.cpp `
  -o system_capture_integration_test.exe -lws2_32
.\system_capture_integration_test.exe --require-signal
```

## Documentation

- [Selected companion architecture](docs/COMPANION_ARCHITECTURE.md)
- [Wire protocol](docs/PROTOCOL.md)
- [Evidence and POC results](docs/POC_RESULTS.md)
- [Layered troubleshooting](docs/TROUBLESHOOTING.md)
- [Manual test plan](docs/MY_TEST_PLAN.md)
- [Pinned upstream baseline](docs/BASELINE.md)

## License

Licensed under [LGPL-3.0-or-later](LICENSE). Bundled Android platform-tools
notices are preserved in `client/assets/platform-tools-NOTICE.txt` and copied
into Windows distributions.
