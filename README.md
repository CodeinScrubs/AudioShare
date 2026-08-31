# AudioShare USB Custom

Stream **all Windows system audio** to an Android phone speaker over a USB ADB
connection. This fork is being specialized for a portable, standard-user,
firewall-independent Windows workflow.

## Download and use it

For non-developers, start with the [beginner guide](docs/GETTING_STARTED.md).
The release page publishes one standalone Windows ZIP containing the EXE,
bundled ADB, and matching companion APK:

[Download AudioShare USB for Windows](https://github.com/CodeinScrubs/AudioShare/releases/tag/v3.0.0-rc.2)

Development status: the Android companion passes clean unit, lint, debug, and
permanently signed release builds. A
real Android 16 emulator passed a cold-install, authenticated
ADB-forwarded stream with enforced speaker route, wake-lock continuity, and
exact cleanup. Headless virtual audio can underrun, so the current Android
hardening pass treats zero-drop timing as a physical-device gate. The Windows
capture hierarchy passes strict
native integration in global, multi-endpoint, and default-output modes with
non-zero PCM. Flutter analysis and 31 supervisor/lifecycle/security/persistence
tests pass.
The complete audible path is now hardware tested on a Samsung Galaxy A52s with
Android 14: global-system capture, a 10 ms host queue high-water mark, and zero
visible host/Android drops in the initial run. Screen-off endurance, repeated
USB recovery, measured latency, restricted-PC checks, and the two-hour run remain
stable-release gates. See [hardware results](docs/HARDWARE_TEST_RESULTS.md) and
[POC results](docs/POC_RESULTS.md).

## Architecture

```text
all ordinary Windows applications and system sounds
                -> global process loopback (preferred)
                -> active-endpoint loopback + bounded mixer (legacy fallback)
                -> default-output loopback (last-resort fallback)
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
fails, it enumerates usable active render endpoints, captures each with event-driven
WASAPI loopback, and mixes them on a bounded 10 ms clock. If no endpoint can be
opened, it falls back to the current default output. The UI identifies the active
mode and endpoint count. The multi-endpoint path has independent device clocks,
so it favors bounded live-edge latency and reports drops/underruns; its strict
local stress run had zero host/ring drops, while long-run drift and duplicate
mirrored-output suppression still require target-hardware evidence.

## First time only

1. Extract the complete Windows package to a normal user-writable folder.
2. Enable Android Developer Options and USB debugging.
3. Connect the phone with a data-capable USB cable.
4. Unlock the phone and approve **Allow USB debugging?** for this computer.
5. Start AudioShare. If exactly one authorized USB phone is present, it is
   selected automatically; with multiple phones, choose the intended one.
6. If shown, choose **Install companion**. This is an explicit one-time ADB
   APK installation; AudioShare never silently installs an app in the background.
7. After installation, the host verifies that the installed base APK exactly
   matches the bundled artifact, launches it, creates the USB-local transport,
   authenticates it, and starts capture automatically.
   If the phone already has a newer companion than this portable host supports,
   AudioShare asks for a newer Windows build instead of attempting a downgrade.
8. Confirm that system audio plays through the phone and leave automatic
   connection enabled.

The PC must already have a working Android USB/ADB driver. Installing a missing
driver can require administrator access and is outside AudioShare's control.

## Daily use target

1. Start AudioShare after logging in to Windows.
2. Plug in the remembered, authorized phone by USB.
3. Play sound from any Windows application, including Infinit/idplayer.

Once the Windows host is open, the intended workflow requires no Android UI, IP
address, Wi-Fi, Internet, firewall approval, or Connect click. Automatic Windows
startup and tray UI are not implemented yet. The zero-click USB supervisor is
unit tested but not yet verified across a target-phone reconnect. A deliberate
**Disconnect** stops the current session but keeps the preferred phone
remembered; it stays disconnected while that cable session remains, and
unplug/replug restores the normal automatic path.

If the same failure happens three times in one minute, automatic retries stop
and AudioShare shows the exact error with a manual retry path. This prevents a
permanent “Connecting” loop for broken packages, unsupported capture, or a
device policy that cannot recover by itself.

## Build from source

The tested host toolchain is Flutter 3.47.2 / Dart 3.13.2 and Visual Studio 2022
or newer with Desktop C++. From `client`:

```powershell
flutter pub get
flutter gen-l10n
flutter analyze
flutter test
flutter build windows --debug
```

Debug builds bundle the clearly labeled version-code 5 debug companion APK. A
distributable release must use a stable signing key and provide both the signed
APK and its pinned signer-certificate SHA-256 explicitly. Configuration fails
unless Android SDK `apkanalyzer` and `apksigner` confirm the signature, exact
certificate, package ID, and exact host-compatible version:

```powershell
$env:AUDIOSHARE_COMPANION_APK = 'C:\absolute\path\audioshare-companion.apk'
$env:AUDIOSHARE_COMPANION_CERT_SHA256 = '<64 hex digits from apksigner --print-certs>'
flutter build windows --release
..\tools\package_windows_release.ps1 `
  -BundleDirectory .\build\windows\x64\runner\Release `
  -OutputZip .\build\AudioShare-Windows.zip
```

The packaging script checks every manifest hash, tests the ZIP after extraction
to a path containing spaces, and proves that missing or altered files are
rejected. It writes the archive SHA-256 beside the ZIP.

Public tags are assembled by the release workflow from the pinned companion in
`client/companion-release.json`. The companion's package, release signature,
certificate, version, debug state, and permission allowlist are verified before
the Windows package is built. Windows binaries are portable but not Authenticode
signed; users may therefore see Microsoft SmartScreen reputation warnings.

The sibling `client android app` Git repository owns the native companion:

```powershell
cd '..\client android app'
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
.\gradlew.bat testDebugUnitTest lintRelease assembleRelease `
  --no-daemon --max-workers=1
```

The upstream `com.ysbing.audioshare` Android server, its public default signing
key, and its stale APK are retired from this branch. They are not compatible
with or trusted by the USB companion. See [security policy](SECURITY.md).

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
.\system_capture_integration_test.exe --require-signal --expect-global
.\system_capture_integration_test.exe --expect-handshake-retry
.\system_capture_integration_test.exe --expect-handshake-stop
.\system_capture_integration_test.exe --expect-handshake-error
.\system_capture_integration_test.exe --expect-disconnect-error
# Compatibility branch checks (test-only compile flags):
# -DAUDIOSHARE_FORCE_MULTI_ENDPOINT  -> --expect-multi
# -DAUDIOSHARE_FORCE_DEFAULT_ENDPOINT -> --expect-default
```

## Documentation

- [Selected companion architecture](docs/COMPANION_ARCHITECTURE.md)
- [Wire protocol](docs/PROTOCOL.md)
- [Evidence and POC results](docs/POC_RESULTS.md)
- [Layered troubleshooting](docs/TROUBLESHOOTING.md)
- [Manual test plan](docs/MY_TEST_PLAN.md)
- [Physical-device results](docs/HARDWARE_TEST_RESULTS.md)
- [Pinned upstream baseline](docs/BASELINE.md)

## License

Licensed under [LGPL-3.0-or-later](LICENSE). Bundled Android platform-tools
notices are preserved in `client/assets/platform-tools-NOTICE.txt` and copied
into Windows distributions.
