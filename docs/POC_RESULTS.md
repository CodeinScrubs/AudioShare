# Phase B POC Results

Status: release-candidate evidence, not final hardware acceptance. Windows
global, multi-endpoint, and default fallback capture pass native integration.
The actual Android app passes ADB-forwarded protocol/playback tests on an Android
16 emulator. Physical USB-cable and audible phone-speaker acceptance remain open.

Recorded: 2026-08-29–30 (Asia/Tehran)

This report distinguishes command-surface/static evidence from an actual
end-to-end proof. It must not be used to claim that USB audio or firewall
acceptance has passed.

## 2026-08-30 hardening checkpoint

An authorized Samsung SM-A528B running Android 14 was briefly visible to the
bundled Windows ADB. Its native Windows USB entry had no `usb:` attribute, which
reproduced a critical classifier error: the old parser labeled real Windows USB
devices as unknown. The Windows-only parser now rejects identifiable TCP, mDNS,
emulator, and vsock serials and treats the remaining native hardware transport
as USB. A regression fixture mirrors the real Windows output. The phone was
disconnected before the companion could be installed, so this is USB discovery
evidence, not phone playback evidence.

The current version-code 2 debug companion was then cold-installed on a real
Android 16 emulator. A reusable fail-closed smoke harness exercised the
production bridge Activity, ADB `tcp:0` to randomized `localabstract` forward,
256-bit HELLO token, confirmed playback-head/speaker readiness, quiet non-zero
PCM, STATS, PING/PONG, STOP, screen restoration, and exact forward/service
cleanup:

```text
DEVICE_PROTOCOL_SMOKE_OK frames=2880000 dropped=0 queue=3 buffer=8720 wake_lock=True service_stopped=True forward_removed=True
```

The final clean-build run began from uninstall/install, kept the display off for
60 seconds, and restored it afterward. Three additional cold-install 12-second
runs also completed without drops. The app confirmed its actual route as the
emulated built-in speaker, required the playback head to advance before READY,
and exposed the session-scoped wake lock while streaming. A bounded 32-chunk
(256 KiB maximum) queue absorbed the cold route/screen transition and the
60-second run ended nearly empty. This is Android integration evidence, but an
emulator cannot prove audible output or a physical USB cable.

The first smoke attempt also reproduced an ADB ordering race: the Windows TCP
listener can accept before Android creates its abstract socket. Native transport
now retries the complete connect + HELLO + READY transaction for eight seconds.
A strict native regression rejects the first accepted connection and verifies
successful recovery. A second verifies that clean peer EOF becomes native error
2112 instead of leaving the UI in a false streaming state. A third stalls the
handshake and verifies full native shutdown in roughly 101 ms, protecting fast
reconnect and normal application exit from a missed-socket race.
A fourth regression returns a fatal Android ERROR and verifies that the native
diagnostic and callback reach the supervisor immediately. Before launching any
installed companion, the host now compares its on-device base APK SHA-256 with
the corresponding bundled APK and treats a repackaged artifact as missing.

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

### Physical-device checks still blocked

The following require a physical authorized Android device and remain NOT RUN:

- audible built-in-speaker output on the Samsung;
- proof that the tested transport traverses the physical USB cable with Wi-Fi
  disabled;
- sustained physical-device throughput and measured end-to-end latency;
- forced disconnect and repeated reconnect;
- transport socket ownership during streaming;
- Defender Firewall prompt and USB/Wi-Fi-off acceptance.

## POC 2: `exec-in` binary transport

Status: NOT RUN on physical hardware. The available emulator does not establish
the physical-cable properties this comparison is intended to measure. This
remains a comparison POC only; it is not the leading production transport.

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
pcm_bytes=783360 nonzero_pcm_bytes=723988
host_dropped_chunks=0 active_endpoint_count=0 endpoint_dropped_frames=0 endpoint_underrun_frames=0 endpoint_discontinuities=0 endpoint_rebuilds=0
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
pcm_bytes=785280 nonzero_pcm_bytes=736196
host_dropped_chunks=0 active_endpoint_count=1 endpoint_dropped_frames=0 endpoint_underrun_frames=0 endpoint_discontinuities=1 endpoint_rebuilds=0
```

A third strict build defined the test-only
`AUDIOSHARE_FORCE_DEFAULT_ENDPOINT` compile flag and required the final default
endpoint mode plus non-zero signal:

```text
capture_mode=3 global_hresult=0x80004001
pcm_bytes=785280 nonzero_pcm_bytes=724236
host_dropped_chunks=0 active_endpoint_count=0 endpoint_dropped_frames=0 endpoint_underrun_frames=0 endpoint_discontinuities=0 endpoint_rebuilds=0
```

These verify both compatibility branches without weakening production feature
detection. `0x80004001` is the intentionally injected `E_NOTIMPL` probe result;
it is not evidence from an actually unsupported/old Windows build. The multi
branch also exercises active-endpoint enumeration, high-resolution host-clock
mixing, bounded scheduler catch-up, and clean teardown on this host. Five
consecutive forced multi-endpoint runs all reported non-zero signal with zero
host queue drops, zero endpoint ring drops, and zero underruns. This host exposed
one active render endpoint, so this is not a claim about multi-device coverage.

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

ADB forward is the selected transport and now has real Android implementation
evidence. Physical USB/firewall/audibility claims remain blocked until the target
phone and restricted Windows PC complete the manual matrix.

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
- package validation runs before device work; supervised `adb track-devices -l`
  triggers refreshes, with a 15-second recovery poll;
- the explicit generation-owned connection supervisor automatically selects one
  authorized USB phone, continues unauthorized-to-authorized transitions without
  restart, treats missing companion as an explicit install state, rejects stale
  native callbacks, and retries transient failures with bounded backoff;
- the host waits for a non-inactive native capture mode before reporting
  `streaming`;
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
flutter test: 19 tests passed
```

The tests cover isolated ADB environment construction, real-Windows-style USB/state parsing,
non-USB fail-closed behavior, companion selection, secret redaction, dynamic
forward parsing, exact cleanup, startup failure recovery, zero-click single-phone
selection, authorization recovery, explicit companion installation, stale
callback rejection, deliberate-disconnect suppression, bounded retry, companion
version and exact-APK compatibility, immediate fatal-handshake reporting,
awaited forward cleanup, and native capture readiness. A Windows Debug build was attempted, but
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
88 actionable tasks: 86 executed, 2 up-to-date
11 unit tests passed (2 session-config + 9 protocol)
Android release lint: No Issues Found / no errors or warnings
debug APK: app/build/outputs/apk/debug/app-debug.apk
unsigned POC release APK: app/build/outputs/apk/release/app-release-unsigned.apk
```

Artifact manifest inspection reports only:

```text
android.permission.FOREGROUND_SERVICE
android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK
android.permission.POST_NOTIFICATIONS
android.permission.WAKE_LOCK
```

`INTERNET` is absent. The playback service is `exported=false` and declares
`mediaPlayback`; the exported bridge requires shell-only `DUMP`. Installation,
ADB launch, forward transport, playback-head readiness, AudioTrack writes,
actual route verification, 60-second screen-off behavior, wake-lock ownership,
and cleanup are emulator INTEGRATION TESTED. Foreground notification denial and
audible output remain physical-device checks.

The locally rebuilt unsigned POC release APK SHA-256 at this checkpoint is:

```text
BB138948ECD47D2F2F88FA1CE0632261DEB231E3539F6A7DD566A6D02736BB61
```

It is not a distributable artifact. Production signing requires a stable
external key supplied through the documented environment variables. The debug
APK intentionally bundled only by Windows Debug packaging has SHA-256:

```text
D32112C9082773CECED3ED46244F70D0FE658FC91BB7314E2468E4B3C6D282A0
```

The final clean serialized Android regression reran `testDebugUnitTest`,
`lintRelease`, `assembleDebug`, and `assembleRelease`: `BUILD SUCCESSFUL in
1m 21s` with 86 tasks executed and two up-to-date. Flutter analysis and all 19
tests also passed.
The project's Gradle 10 deprecation warning was removed by migrating the Android
Groovy DSL to assignment syntax. Hosted CI is added to keep the wrapper, Android
build, Flutter analysis/tests, and MSVC Windows build under continuous verification.
