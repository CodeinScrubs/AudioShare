# Locked-down Windows / USB ADB Architecture Review

Status: superseded by `COMPANION_ARCHITECTURE.md`. The transport findings remain
useful, but the installed Android companion is now the primary receiver.

Baseline: upstream AudioShare v2.1.1 (`70db6b5`) on branch `custom`.

## 1. Objective and non-negotiable constraints

Build a portable, non-admin Windows application that captures all ordinary
Windows render streams—applications, browser tabs, media players, games, and
Windows sounds—and plays them on an Android device connected by USB debugging.

The production path must:

- require no installer, administrator privilege, Windows service, LAN, Wi-Fi,
  or Internet access;
- not make the AudioShare process bind or listen on a TCP port;
- use only the ADB USB transport and loopback endpoints managed by ADB;
- expose bounded, actionable connection phases and errors;
- clean up only the resources created by this application; and
- produce a complete, reproducible portable release rather than a hand-copied
  executable.

An OS-owned or ADB-owned loopback listener can still appear in socket tables.
The acceptance criterion is that AudioShare itself has no listening socket and
no non-loopback traffic, not that Windows contains no loopback listeners.

## 2. Current architecture and runtime flow

```text
Flutter UI / DataSource
  |-- periodic `adb devices` polling
  |-- choose an arbitrary host TCP port
  |-- remove every ADB reverse mapping
  |-- push server.jar
  |-- `adb reverse tcp:devicePort tcp:hostPort`
  |-- launch app_process Android server
  v
Windows native DLL
  |-- bind/listen on 0.0.0.0:hostPort
  |-- accept the Android connection
  |-- WASAPI system-loopback capture
  `-- send a small PCM header followed by raw PCM
            |
            | ADB reverse over USB
            v
Android app_process server
  |-- LocalSocket connects to `localabstract:audioshare`
  `-- AudioTrack writes PCM to the selected output device
```

Files inspected:

- `client/lib/main.dart`
- `client/lib/data_source.dart`
- `client/lib/services/adb_service.dart`
- `client/lib/services/audio_capture.dart`
- `client/native/audio_capture.cpp`
- `client/native/audio_capture_mac.mm`
- `server/src/main/java/com/ysbing/audioshare/Main.java`
- Windows runner manifests and CMake packaging configuration

### Startup and shutdown as implemented

`DataSource` immediately polls ADB and repeats every three seconds. If a saved
device is present, it can auto-connect. A connection prepares native capture,
stops the prior session, sets state to Connecting, and starts an unawaited
sequence: remove all reverse mappings, probe ports, start the native listener,
create a reverse mapping, push the Android payload, and launch it. Native code
changes the state to Connected only after `accept()` receives the expected
connection code.

Disconnect kills the local ADB shell process and stops native capture. It does
not reliably identify and stop the remote process, immediately remove a single
owned mapping, or invalidate every asynchronous continuation from an older
connection attempt.

## 3. Confirmed failure modes and risks

### Connection lifecycle

1. ADB commands return strings rather than structured results. Exit codes,
   command context, durations, and timeouts are lost; exceptions often become
   an empty string.
2. Push, reverse, and server launch are treated as successful without checking
   their results. Server stdout and stderr are discarded.
3. There is no readiness deadline. A failed launch, unauthorized device, stale
   payload, or failed reverse mapping can leave the UI in Connecting forever.
4. Connection work is fire-and-forget. A stale attempt can complete after a
   disconnect or a newer attempt.
5. Periodic device polls can overlap slow or blocked ADB invocations.
6. `adb reverse --remove-all` destroys mappings owned by other applications.
7. Windows ADB binaries are copied to `%TEMP%`; copy failures are swallowed and
   a stale or partial set can be used.

### Native capture and transport

1. The Windows process binds `INADDR_ANY`, which exposes a wildcard listener
   even though only local ADB traffic is needed. The Dart port probe also binds
   `anyIPv4`, creating a port-selection race between probe and listener.
2. The Windows global session state uses cross-thread flags and resources
   without a coherent atomic/locking ownership model. Blocking socket sends can
   delay shutdown, and finite waits can be followed by resource release while a
   worker is still active.
3. `WSAStartup` is invoked for each listen cycle but cleanup is not balanced per
   cycle.
4. Capture uses a one-millisecond polling loop. Event-driven WASAPI is a better
   fit and enables prompt cancellation.
5. The preferred 48 kHz PCM initialization does not request the documented
   shared-mode conversion flags. The fallback assumes a float mix format even
   though the returned format must be inspected rather than assumed.
6. Runtime capture and transport errors are not propagated to the UI with a
   phase or recovery action.

### Android playback

1. The wire header has no magic, protocol version, length, or strict validation.
2. `getMinBufferSize()` failures and AudioTrack initialization state are not
   handled defensively; a zero-byte write can spin.
3. There are no underrun, bytes/second, startup latency, or playback activity
   measurements.
4. The current buffer is approximately 2× `minBufferSize`, with 1× pre-roll.
   Buffer tuning can affect latency and underruns, but cannot explain the
   indefinite connection state.

### Packaging and validation

1. The Windows v2.1.1 archive contains only `AudioShare.exe`; the Android
   payload and bundled ADB runtime required by the code path are absent.
2. Packaging is manual and outside the build graph, with no manifest/checksum
   gate that proves all runtime files are present.
3. The runner manifest lacks an explicit `requestedExecutionLevel` declaration.
4. There are no automated unit, integration, lifecycle, protocol, or packaging
   tests, and the current concrete process calls provide no fake-ADB seam.

## 4. Transport alternatives

| Option | Shape | Firewall / privilege characteristics | Diagnostics | Change and operational risk | Decision |
|---|---|---|---|---|---|
| A. Keep ADB reverse | Android connects to an AudioShare-owned host listener | Can be restricted to `127.0.0.1`, but AudioShare still owns an inbound listening socket; that does not meet the strict acceptance criterion | Bidirectional after connect, but current launch path is opaque | Smallest patch; retains listener lifecycle and port race unless redesigned | Reject as final architecture |
| B. ADB forward | Android owns a LocalServerSocket; ADB exposes a randomized host loopback port; AudioShare connects outbound to `127.0.0.1` | AudioShare never calls bind/listen; ADB's documented host endpoint is localhost; no LAN path | Bidirectional protocol plus independent launch stdout/stderr/exit | Moderate, localized role reversal; preserves the native PCM-to-socket pipeline | **Selected** |
| C. `adb exec-in` | Native/Dart streams PCM into ADB stdin | No custom TCP endpoint | Weak: current ADB `exec-in` is a raw one-way copy, does not consume remote output/exit, and its implementation does not surface copy failure reliably | Largest redesign: native-to-Dart streaming or native ADB process ownership, backpressure, cancellation, and recovery | Defer as an experimental transport only |

ADB's official [service documentation](https://android.googlesource.com/platform/packages/modules/adb/+/HEAD/docs/dev/services.md)
specifies that a host `tcp:<port>` forward listens on `localhost:<port>`. The
official [ADB manual](https://android.googlesource.com/platform/packages/modules/adb/+/refs/tags/android-16.0.0_r4/docs/user/adb.1.md)
documents `tcp:0` allocation, eliminating the application's port probe.
`exec-in` is binary-safe on Windows, but the current official
[command implementation](https://android.googlesource.com/platform/packages/modules/adb/+/HEAD/client/commandline.cpp)
implements it as copying stdin to a raw `exec:` service and returning without a
structured remote status channel. It is therefore a poor primary choice for a
product whose most important missing feature is reliable diagnosis.

Selected topology:

```text
AudioShare.exe (standard user)
  |-- launch and supervise bundled adb.exe
  |-- `adb forward --no-rebind tcp:0 localabstract:audioshare_<nonce>`
  |-- launch app_process; wait for structured READY line with deadline
  |-- connect OUTBOUND to 127.0.0.1:<adb-assigned-port>
  v
ADB-owned localhost forward over USB
  v
Android LocalServerSocket("audioshare_<nonce>")
  |-- accept one session
  |-- versioned handshake
  `-- validate and play raw PCM with AudioTrack
```

Every session receives an unpredictable socket name and a generation ID. Only
the exact `tcp:<assigned-port>` mapping created for that generation is removed.

## 5. Proposed connection state machine

Public phases:

```text
Idle
  -> CheckingADB
  -> WaitingForAuthorizedDevice
  -> PreparingCapture
  -> PushingPayload
  -> StartingAndroidServer
  -> CreatingForward
  -> ConnectingTransport
  -> NegotiatingProtocol
  -> Streaming
  -> Stopping
  -> Idle
```

Every phase has a finite deadline, cancellable operation, start/end timestamp,
and diagnostic result. Any failure transitions to `Failed`, containing:

- phase and human-readable recovery action;
- ADB operation and sanitized arguments;
- exit code, timeout flag, duration, bounded stdout, and bounded stderr;
- device serial and reported device state;
- protocol/native error code when applicable.

A monotonically increasing session generation prevents callbacks and futures
from an older attempt mutating current state.

Device discovery distinguishes: no device, authorized `device`, unauthorized,
offline, multiple devices, and ADB executable/daemon failure. Polls are
serialized and skipped while the previous poll is active.

## 6. Structured ADB layer

Introduce an injectable `AdbCommandRunner` and immutable `AdbCommandResult`:

```text
operation, executable, arguments, exitCode,
stdout, stderr, duration, timedOut, startFailure
```

The production runner uses `Process.start`, drains stdout and stderr
concurrently, applies a per-operation timeout, kills and awaits timed-out
processes, and preserves bounded output for diagnostics. The fake runner drives
deterministic tests for every nonzero exit, timeout, malformed output, and
cancel/reconnect race.

The bundled ADB executable and DLLs are resolved from a versioned runtime folder
next to the application, not copied to `%TEMP%`. Startup validates their
presence and recorded SHA-256 values. An optional system-ADB override can be
considered later; it is excluded initially to keep the supported runtime
deterministic.

The pinned bundle is ADB 1.0.41 / platform-tools 33.0.3-8952118. Its own help
confirms `forward [--no-rebind]`, host-side `tcp:0`, `localabstract:`, exact
`forward --remove`, and USB-only `-d` selection. This is command-surface evidence,
not a completed transport POC; an Android device must still prove allocation,
binary integrity, throughput, reconnect, cleanup, and socket ownership.

USB-only mode launches every ADB child with a deliberately constructed
environment. It does not inherit `ADB_SERVER_SOCKET`,
`ANDROID_ADB_SERVER_ADDRESS`, `ANDROID_ADB_SERVER_PORT`, `ANDROID_SERIAL`, or
other settings that can redirect device/server selection. The implementation
must verify the pinned binary's actual behavior for `ADB_MDNS=0`,
`ADB_MDNS_AUTO_CONNECT=0`, and `ADB_EMU=0` before treating those variables as
effective controls. It never invokes `adb -a`, `connect`, `pair`, `tcpip`, or
automatic network discovery.

Device discovery uses `adb devices -l` and preserves USB metadata and every
authorization/offline state. The primary UI accepts only a verified USB
transport; network ADB devices and emulators are labeled but never silently
selected. If exactly one authorized USB phone exists it can be selected
automatically; multiple phones require a choice.

The application does not kill or restart an ambient shared ADB server merely to
enforce preferences, because that could disrupt Android Studio or other tools.
Preflight reports an incompatible or non-local server rather than changing
machine policy. A private server port remains a POC question because competing
servers can contend for the same USB interface.

Server supervision retains stdout/stderr, parses a single versioned readiness
line after the LocalServerSocket is bound, and monitors process exit. Shutdown
first closes the stream, waits briefly for EOF-driven server exit, and only then
uses a session-specific, verified PID fallback. Broad process kills and
`--remove-all` are prohibited.

## 7. Windows system-audio capture design

### Capture scope and endpoint selection

The product mode is **System Audio (All Apps)**. It never selects `idplayer.exe`
or another source process. The preferred implementation activates
`VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK` with
`PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE`, excluding AudioShare's own
host PID. In that inverse mode, Windows supplies all other ordinary render
streams through one endpoint-independent capture client.

Activation and canonical-format initialization are the feature probe; a version
string is not the runtime gate. If global activation is unavailable, the current
compatibility path follows the default console render endpoint with ordinary
WASAPI loopback. That fallback is broad Windows 10/11 compatibility, but it does
not capture an application explicitly routed to another output endpoint. A
complete legacy fallback therefore still requires endpoint enumeration,
per-endpoint queues, conversion, mixing, duplicate policy, hotplug handling, and
drift measurement across independent clocks.

If global activation and the endpoint fallback both fail, capture fails with an
actionable native HRESULT. The application will not install or emulate a virtual
audio device because that would violate the no-driver/no-admin constraints.

### WASAPI ownership and format normalization

A dedicated capture thread owns the complete COM/WASAPI lifetime:

- initialize COM on that thread;
- asynchronously activate the virtual process-loopback device there and wait
  through an agile completion handler;
- use an explicit 48 kHz stereo PCM16 format because the virtual client does not
  implement `GetMixFormat`/`IsFormatSupported`;
- on fallback, enumerate/activate the default `IMMDevice` there;
- initialize a shared-mode loopback client with
  `AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK`;
- obtain, use, and release `IAudioCaptureClient` on that same thread;
- pair every successful `GetBuffer` with `ReleaseBuffer` on that thread; and
- stop/reset/release the audio client and uninitialize COM before the thread
  exits.

Windows 10 version 1703 and later supports event-driven endpoint loopback. The
capture loop drains every queued packet on each event and handles silent,
discontinuous, timestamp-error, service-stopped, and device-invalidated flags
explicitly. The global path is independent of default-device changes; the
compatibility path still needs controlled default-device-change reactivation.
Both current modes request Windows engine conversion directly into canonical
PCM. Multi-endpoint fallback work must still validate actual endpoint formats
and normalize PCM16/24/32 or float32, including multichannel layouts.

The capture thread copies complete WASAPI packets into a bounded real-time
queue and never performs blocking socket writes. A separate sender thread owns
the outbound ADB-forwarded socket. When the phone cannot keep up, the queue uses
a documented latency-preserving policy, records dropped frames, and never grows
without bound. This also provides the seam for long-session clock-drift
measurement and correction if hardware evidence shows it is needed.

Microsoft's [Loopback Recording documentation](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)
defines shared-mode endpoint loopback and event-driven support. Microsoft's
[Application Loopback sample](https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/ApplicationLoopback)
documents endpoint-independent include/exclude process-tree activation. Its
[`IAudioCaptureClient` documentation](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nn-audioclient-iaudiocaptureclient)
requires release on the thread that obtained the service, while
[`GetBuffer`](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer)
requires each buffer pair to remain on one thread.

## 8. Wire protocol and playback

Replace the implicit integer header with a fixed, little-endian, versioned
protocol containing magic, protocol version, message length/type, generation
nonce, sample rate, channel count, sample format, and frame size. Both sides
reject unknown versions, impossible lengths, unsupported formats, and invalid
rates before allocating or initializing playback.

The Android server binds its nonce-scoped LocalServerSocket and emits/flushed a
READY record before the host creates the forward/connect sequence. The host and
server exchange HELLO/ACCEPT or structured REJECT messages before PCM begins.
EOF is normal session shutdown. Short reads/writes, zero-progress writes, and
AudioTrack initialization failures are bounded failures rather than loops.

Keep uncompressed 48 kHz stereo PCM16 for the first implementation. Its payload
rate is 1,536,000 bits/s (192,000 bytes/s), modest for USB ADB and simpler to
verify than introducing a codec.

Android's `AudioTrack` guidance recommends creating sufficient capacity and
tuning the effective buffer while watching underruns. Define two measured modes:

- Low latency: initially 2× platform minimum capacity, tune effective frames
  toward 1–2× minimum only when underrun tests pass.
- Stable: a larger effective buffer for devices that underrun.

Expose actual buffer frames, pre-roll frames, underrun delta, byte rate, and
first-audio latency. Do not promise sub-100 ms end-to-end latency until measured
on the target Samsung device. See the official
[AudioTrack reference](https://developer.android.com/reference/android/media/AudioTrack).

## 9. Portable, non-admin Windows release

The Windows runner manifest will explicitly request:

```xml
<requestedExecutionLevel level="asInvoker" uiAccess="false" />
```

The build creates a staging directory from declared inputs and zips the entire
directory. Required contents include the Flutter runner/runtime, native capture
DLL, `data/`, versioned ADB runtime, Android server payload, licenses, checksums,
and troubleshooting/readme material. A packaging test launches validation from
an extracted path containing spaces and fails when any manifest entry is absent
or altered.

Microsoft's [application manifest documentation](https://learn.microsoft.com/en-us/windows/win32/sbscs/application-manifests)
defines `requestedExecutionLevel`; declaring `asInvoker` makes the intended
non-elevated execution contract explicit.

## 10. Test and acceptance plan

### Baseline verification completed for this review

With the installed Android Studio JBR and Android SDK supplied through the
process environment, the unmodified Android server completed:

```powershell
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
.\gradlew.bat :server:assembleRelease :server:lintRelease --no-daemon
```

Result: `BUILD SUCCESSFUL in 54s`; 47 actionable tasks (45 executed, 2
up-to-date), and the Android lint report contained no errors or warnings. The
build emitted an SDK XML tool-version warning and Gradle deprecation warning;
neither failed this baseline. The build's finalizer rewrites
`client/assets/server`; that generated delta was removed after verification so
the only review change is this document.

Flutter, Dart, CMake, and the Visual Studio Windows toolchain are unavailable in
this shell, so the desktop application has not been rebuilt here. No physical
Android device, real Windows output endpoint, restrictive Windows policy, or
firewall acceptance test has been exercised in this review phase.

### Automated, hardware-independent

- structured ADB result tests: success, nonzero exit, start failure, timeout,
  large concurrent stdout/stderr, malformed output;
- connection state-machine tests for failures and timeout at every phase;
- generation tests: disconnect/reconnect and device-switch races;
- device parser tests for unauthorized, offline, no/multiple devices;
- protocol golden vectors, truncation, invalid length/version/format, and fuzz
  tests on both sides;
- Android AudioTrack tests around invalid minimum buffer, uninitialized track,
  zero/partial writes, and clean EOF;
- endpoint-enumeration, default-device-change, device invalidation, audio-service
  interruption, and restart tests;
- format vectors for PCM16/24/32, float32, 44.1/48 kHz, stereo, silence, and
  multichannel downmixing;
- native lifecycle stress tests with repeated connect/disconnect and forced
  socket backpressure;
- packaging manifest/checksum and explicit non-admin manifest tests.

The first implementation step must create the injectable ADB runner and failing
regression tests. A fake `push` nonzero result, a server that never emits READY,
and a stale connection completion after disconnect must each deterministically
reach `Failed`/Idle rather than Connecting/Streaming.

### Required target-machine acceptance

Run on the locked-down Windows machine with a physical Samsung device:

1. Standard user; no elevation prompt; install nothing.
2. Windows Defender Firewall enabled with no AudioShare allow rule.
3. Network adapters/Wi-Fi disabled where operationally possible; USB debugging
   remains the only transport.
4. Verify the AudioShare PID owns no listening socket. Verify the selected ADB
   forward is loopback-only and no process sends PCM over a LAN interface.
5. Start with no device, unauthorized device, offline device, unplug during each
   connection phase, reconnect, restart ADB, and change/reconnect the Windows
   default render endpoint during playback.
6. Confirm the UI reports global mode, then play simultaneous audio from
   multiple applications plus a Windows system sound. Route one application to
   another endpoint and confirm both remain captured. Separately force/test
   compatibility mode and verify its explicit default-output-only label.
7. Measure capture-to-speaker latency, first-audio time, underruns, and sustained
   stability for both buffer modes. Record device model, Android version, sample
   route, and test duration.
8. Extract the release to a clean directory with spaces and launch it without
   the source tree, Android SDK, Flutter, or Internet access.

Passing unit/build tests does not prove firewall behavior, physical-device
latency, or process isolation. Those claims remain blocked until this matrix is
run on the target hardware.

## 11. Implementation sequence and review gates

1. **Reliability foundation:** injectable structured ADB runner, device-state
   model, connection generations, explicit phases, deadlines, diagnostics, and
   regression tests.
2. **Forward transport:** nonce LocalServerSocket, exact `tcp:0` mapping,
   outbound native connect, versioned handshake, owned-resource cleanup.
3. **Windows capture:** global exclude-tree loopback, event-driven default-output
   fallback, correct COM/thread ownership, format conversion, bounded queue,
   error propagation, followed by legacy multi-endpoint aggregation.
4. **Playback/latency:** protocol validation, AudioTrack failure handling,
   instrumentation, buffer modes, hardware measurements.
5. **Release engineering:** explicit manifest, reproducible portable staging,
   dependency/license/checksum validation, extracted-release smoke test.
6. **Locked-down acceptance:** physical Samsung and firewall matrix, followed by
   a release-readiness report that separates verified facts from open evidence.

Architecture tradeoff: selecting ADB forward is a moderate role reversal rather
than the smallest patch. It is preferred because it removes the application
listener completely while retaining a bidirectional, diagnosable stream and the
existing native PCM pipeline. Global exclude-tree capture is preferred because
it is endpoint-independent; default endpoint loopback remains the compatibility
layer where Windows rejects that feature.

## 12. Reviewer decisions requested

Please approve or correct these points before major code changes:

1. ADB forward is the production transport; reverse and `exec-in` are not.
2. AudioShare must own no listening TCP socket; an ADB-owned loopback endpoint
   is acceptable under the no-LAN/no-firewall-prompt constraint.
3. System Audio (All Apps) is the only product mode; source-process selection is
   out of scope. Excluding AudioShare's own tree is an implementation mechanism,
   not a user-facing filter.
4. Global process loopback is feature-probed first. Ordinary default-endpoint
   WASAPI loopback is the compatibility fallback, and a multi-endpoint legacy
   fallback remains required for the strongest old-Windows interpretation.
5. Raw 48 kHz stereo PCM16 remains the initial format.
6. Latency is a measured acceptance result, not a pre-implementation guarantee.
7. Implementation follows the six gated stages above and preserves honest
   separation between local integration, physical USB, and target-PC evidence.
