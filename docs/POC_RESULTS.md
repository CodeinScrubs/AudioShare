# Phase B POC Results

Status: partial. Windows global, multi-endpoint, and default fallback capture now
have hardware-independent native integration results; physical USB/Android
transport and phone playback remain blocked because no authorized Android device
is attached.

Recorded: 2026-08-29–30 (Asia/Tehran)

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

The requested scope is **System Audio (All Apps)**. The production hierarchy is:

1. feature-probe endpoint-independent Application Process Loopback in
   `EXCLUDE_TARGET_PROCESS_TREE` mode, excluding the AudioShare host and children;
2. if activation or 48 kHz initialization is unsupported, enumerate active
   render endpoints and mix their event-driven shared-mode loopbacks on a bounded
   10 ms host clock;
3. if no active endpoint can be opened, use event-driven loopback of the default
   console render endpoint as a last resort.

The implementation does not select `idplayer.exe` or any other source process.
It owns activation and all WASAPI interfaces on the capture thread, asks the
Windows audio engine for canonical 48 kHz stereo PCM16, and separates capture
from blocking transport through a bounded eight-chunk live-edge queue.

Status: INTEGRATION TESTED locally without Android. A native fake companion
exercised the real DLL handshake, started capture, drained framed PCM, and
reported:

```text
capture_mode=1 global_hresult=0x00000000
pcm_bytes=785280 nonzero_pcm_bytes=135161
active_endpoint_count=0 endpoint_dropped_frames=0 endpoint_underrun_frames=0 endpoint_discontinuities=0 endpoint_rebuilds=0
EXIT=0
```

`capture_mode=1` is the global endpoint-independent path. The test ran for four
seconds and required at least one non-zero PCM byte. The fake TCP listener exists
only in `system_capture_integration_test.exe`; production `audio_capture.dll`
still contains no bind/listen path. This proves successful feature activation,
48 kHz initialization, capture start, and non-zero signal delivery on this
Windows host. It does not prove which applications produced the ambient signal,
simultaneous multi-application coverage, cross-endpoint coverage, phone playback,
or end-to-end latency.

A second strict build defined the test-only
`AUDIOSHARE_FORCE_MULTI_ENDPOINT` compile flag and required the multi-endpoint
compatibility mode plus non-zero signal:

```text
capture_mode=2 global_hresult=0x80004001
pcm_bytes=503040 nonzero_pcm_bytes=86336
active_endpoint_count=1 endpoint_dropped_frames=67200 endpoint_underrun_frames=0 endpoint_discontinuities=1 endpoint_rebuilds=0
MULTI_EXIT=0
```

A third strict build defined the test-only
`AUDIOSHARE_FORCE_DEFAULT_ENDPOINT` compile flag and required the final default
endpoint mode plus non-zero signal:

```text
capture_mode=3 global_hresult=0x80004001
pcm_bytes=789120 nonzero_pcm_bytes=135804
active_endpoint_count=0 endpoint_dropped_frames=0 endpoint_underrun_frames=0 endpoint_discontinuities=0 endpoint_rebuilds=0
DEFAULT_EXIT=0
```

These verify both compatibility branches without weakening production feature
detection. `0x80004001` is the intentionally injected `E_NOTIMPL` probe result;
it is not evidence from an actually unsupported/old Windows build. The multi
branch also exercises active-endpoint enumeration, event-driven packet drains,
bounded mixing, and clean teardown on this host.
This host exposed one active render endpoint; its reported dropped frames are the
bounded live-edge trim while the loopback client caught up, not a claim about
multi-device coverage or steady-state loss.

Strict portable GCC 16.2 compilation passed under `-Wall -Wextra -Werror` for
both the DLL and integration harness. The installed MSYS2 GCC 16.1 front end was
not used because its `cc1plus.exe` currently exits before parsing source with
Windows status `0xC0000139` (toolchain installation failure, not a source error).

Required checks remain:

- simultaneous audio from several applications plus Windows system sounds;
- applications explicitly routed to different output endpoints;
- validation of fallback on a Windows build that genuinely lacks/rejects global
  process loopback (the forced local branch test already passes);
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
- global process-loopback capture is feature-probed, excludes the host process
  tree, and exposes active/fallback mode diagnostics to the UI;
- the compatibility hierarchy enumerates active render endpoints, mixes bounded
  10 ms periods, observes endpoint notifications, and exposes endpoint
  count/drop/underrun/discontinuity/rebuild diagnostics;
- native fake-companion integration runs activated global, multi-endpoint, and
  default-endpoint modes and delivered non-zero framed PCM through the actual
  DLL transport;
- a 256-bit per-session token authenticates a versioned framed handshake;
- native transport and WASAPI capture run on separate bounded-lifecycle threads;
- native wire-format golden/bounds/token tests compile and pass;
- READY format values and periodic Android playback statistics are now validated
  before being exposed as FFI diagnostic counters;
- the DLL compiles and links under `-Wall -Wextra -Werror`; its transport path
  remains outbound-only and contains no listening/bind API;
- the Windows CMake wrapper conditionally applies MSVC or GNU warning/encoding
  flags, and its native target configures and builds with portable MinGW;
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
flutter test: 5 tests passed
```

The tests cover isolated ADB environment construction, USB/state parsing,
non-USB fail-closed behavior, companion selection, secret redaction, dynamic
forward parsing, and exact cleanup. A Windows Debug build was attempted, but
Flutter correctly refused because the detected Visual Studio 2026 Insiders
installation lacks the Desktop C++ workload components, CMake tools, and Windows
10 SDK required by Flutter. No MSVC or Flutter Windows artifact is claimed.

The Windows CMake project also configured and generated successfully with
CMake 4.3.2/Ninja against a temporary MinGW toolchain. The native DLL and
system-capture harness additionally compile/link with portable GCC 16.2. This
validates the edited native code and CMake graph, but is not substituted for the
required MSVC Flutter link/build.

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

The locally rebuilt unsigned POC release APK SHA-256 at this checkpoint is:

```text
67220EDB0AB1420D8D662C2B5BE6E04DC22C0954EAD0CA0A1BF44D4CDD37B964
```

It is not a distributable artifact. Production signing requires a stable
external key supplied through the documented environment variables. The debug
APK intentionally bundled only by Windows Debug packaging has SHA-256:

```text
A561C224D8792270F18494187E67523DD4A3B75F0B84629739C996A8022B5817
```

The final cross-repository regression reran `testDebugUnitTest`, `lintRelease`,
`assembleDebug`, and `assembleRelease`: `BUILD SUCCESSFUL in 16s` with 87 tasks
(2 executed, 85 up-to-date). The SDK XML version warning and Gradle 10
deprecation warning remain non-fatal and unchanged.
