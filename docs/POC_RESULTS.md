# Phase B POC Results

Status: partial; hardware-dependent transport and audio POCs are blocked because
no Android device is currently attached.

Recorded: 2026-08-29 (Asia/Tehran)

This report distinguishes command-surface/static evidence from an actual
end-to-end proof. It must not be used to claim that USB audio or firewall
acceptance has passed.

## POC 1: ADB forward to Android LocalServerSocket

### Verified without a device

The fork's updated bundled Windows executable reports:

```text
Android Debug Bridge version 1.0.41
Version 37.0.1-15733141
```

Its own help advertises:

```text
-d
forward [--no-rebind] LOCAL REMOTE
tcp:<port> (<local> may be "tcp:0" to pick any open port)
localabstract:<unix domain socket name>
forward --remove LOCAL
```

This confirms that the pinned client exposes the required command syntax. It
does not prove device daemon compatibility or actual data flow.

The updated `adb.exe` SHA-256 is
`B4A6B455702684652CCCF7B46258B29E653538904359A58FD4931CF3EF286B3F`.
The matching platform-tools notice is included in Windows packaging.

### Existing ADB server observation

A read-only process/socket inspection found an existing Android SDK ADB server:

```text
executable: C:\Users\Shayan\AppData\Local\Android\Sdk\platform-tools\adb.exe
command:    adb -L tcp:5037 fork-server server ...
listener:   127.0.0.1:5037
```

The server was already running and was not killed, restarted, or replaced. A
read-only `adb devices -l` query returned no attached devices.

### Unusable emulator entries observed later

After the production-slice commit, ADB briefly listed three emulator serials in
state `host`, not the required state `device`. A read-only `shell getprop` probe
against one such entry returned a protocol reset; the shared ADB server exited
and ADB automatically restarted it from the fork's bundled platform-tools 37.0.1
binary. No `kill-server` command was issued. No APK was installed, no forward was
created, and no emulator state was intentionally changed. The stale entries then
disappeared and `adb devices -l` was empty.

This is not integration evidence. It also reinforces the production rule that
only state `device` plus a positively identified USB transport is eligible for
metadata, package, launch, or forwarding commands.

### Blocked checks

The following require a physical authorized Android device and remain NOT RUN:

- installed companion creation of `LocalServerSocket`;
- `forward --no-rebind tcp:0 localabstract:<nonce>` port allocation;
- outbound connection to the allocated `127.0.0.1` port;
- handshake and random binary integrity;
- sustained throughput above 20 Mbit/s;
- forced disconnect and repeated reconnect;
- exact owned-mapping cleanup;
- transport socket ownership during streaming;
- Defender Firewall prompt and USB/Wi-Fi-off acceptance.

## POC 2: `exec-in` binary transport

Status: NOT RUN. No device is attached. This remains a comparison POC only; it
is not the leading production transport.

Required vectors include `00 0A 0D 1A FF`, large random blocks, device-side
cryptographic hashes, immediate/mid-stream remote failure, host EOF, USB unplug,
and process exit behavior.

## POC 3: Windows system-loopback capture

The requested scope is now **System Audio (All Apps)** on the selected/default
render endpoint. Application/process loopback is not required.

Status: the Windows native source compiles and links with strict MinGW warnings,
and its protocol tests pass. Runtime capture remains NOT RUN because the
production Flutter/MSVC desktop executable has not been built. The implementation
uses ordinary event-driven shared-mode endpoint loopback, owns all WASAPI
interfaces on the capture thread, asks the Windows audio engine to convert to
48 kHz stereo PCM16, and separates capture from blocking transport through a
bounded eight-chunk live-edge queue.

Required checks remain:

- simultaneous audio from several applications plus Windows system sounds;
- default and manually selected output endpoints;
- 44.1/48 kHz, PCM16/24/32, float32, stereo, and multichannel sources;
- endpoint change/invalidation, Audio service interruption, silence, and
  discontinuity;
- backpressure, queue bounds, dropped-frame accounting, drift, and long run.

## POC 4: Firewall and socket ownership

The only observed ADB smart-socket listener was `127.0.0.1:5037`, owned by the
existing SDK ADB server. AudioShare was not running, so this is not an audio-path
acceptance result.

Status: NOT RUN end-to-end. The final test must map every listening/connected
socket to its PID while streaming and confirm:

- AudioShare owns no listening socket;
- ADB forward listens only on loopback;
- no `0.0.0.0`, `[::]`, LAN, Wi-Fi, mDNS, or Internet audio path;
- no firewall rule or Defender Allow access prompt.

## Current gate

Architecture evidence still favors ADB forward, but the transport decision is
provisional until POC 1 runs on an authorized USB device. Production transport
implementation can develop behind an interface with automated fake/protocol
tests, but physical USB/firewall claims remain blocked.

## Windows production-slice checkpoint

Implemented and locally checked without claiming hardware behavior:

- Windows native code has no listening export or `bind`/`listen` call and
  connects only to `127.0.0.1:<allocated-forward-port>`;
- a 256-bit per-session token authenticates a versioned framed handshake;
- native transport and WASAPI capture run on separate bounded-lifecycle threads;
- native wire-format golden/bounds/token tests compile and pass;
- READY format values and periodic Android playback statistics are now validated
  before being exposed as FFI diagnostic counters;
- the DLL compiles and links under `-Wall -Wextra -Werror` and exports only the
  outbound connection API;
- Dart ADB commands have structured results, bounded output and timeouts,
  secret redaction, exact resource cleanup, and isolated child environments;
- supervised `adb track-devices -l` triggers refreshes, with a 15-second
  recovery poll;
- Flutter unit tests pass device-state/transport parsing,
  no-metadata-on-network enforcement, companion discovery, token redaction,
  dynamic forward parsing, and exact cleanup;
- Windows Debug packaging includes the explicitly labeled debug POC APK and a
  one-click install action; Profile/Release require a separately signed APK;
- Windows manifest XML is valid and explicitly requests `asInvoker`.

Flutter 3.47.2 / Dart 3.13.2 were staged outside the repositories. The following
host checks now pass:

```text
flutter pub get
flutter gen-l10n
flutter analyze: No issues found
flutter test: 4 tests passed
```

The tests cover isolated ADB environment construction, USB/state parsing,
non-USB fail-closed behavior, companion selection, secret redaction, dynamic
forward parsing, and exact cleanup. A Windows Debug build was attempted, but
Flutter correctly refused because the detected Visual Studio 2026 Insiders
installation lacks the Desktop C++ workload components, CMake tools, and Windows
10 SDK required by Flutter. No MSVC or Flutter Windows artifact is claimed.

The Windows CMake project also configured and generated successfully with
CMake 4.3.2/Ninja against a temporary MinGW toolchain. This validates the edited
CMake graph and packaging syntax, but is not substituted for the required MSVC
Flutter link/build.

## Installed companion: hardware-independent slice

The separate `client android app` repository now contains a native Kotlin POC
for the installed receiver: exported no-history bridge Activity, unexported
media-playback foreground service, nonce-scoped LocalServerSocket, versioned
bounded frame parser, bounded AudioTrack queue, watchdog, and minimal UI.

Executed locally:

```text
testDebugUnitTest + lintRelease + assembleRelease
BUILD SUCCESSFUL in 1m 12s
71 actionable tasks: 48 executed, 23 up-to-date
11 unit tests passed (2 session-config + 9 protocol)
Android release lint: No Issues Found / no errors or warnings
debug APK: app/build/outputs/apk/debug/app-debug.apk
unsigned POC release APK: app/build/outputs/apk/release/app-release-unsigned.apk
```

Artifact manifest inspection reported only:

```text
android.permission.FOREGROUND_SERVICE
android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK
```

`INTERNET` is absent. The playback service is `exported=false` and declares
`mediaPlayback`; the launcher and bridge Activities are exported. This is BUILD
TESTED and STATICALLY VERIFIED only. Installation, ADB launch, forward transport,
AudioTrack output, route preference, locked-screen behavior, and foreground
notification behavior remain NOT RUN without an attached device.

The unsigned POC release APK SHA-256 at this checkpoint is:

```text
B1B13E509FDBEB92E799E7402FF2A5BC730F3D87D868C4604CF8862BC578181E
```

It is not a distributable artifact. Production signing requires a stable
external key supplied through the documented environment variables.
