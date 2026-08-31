# AudioShare USB Companion Architecture

Status: implemented production direction. Real Android emulator transport,
route, screen-off, and cleanup POCs pass. An initial physical Samsung run now
proves the authorized USB-cable and audible built-in-speaker path; repeated
reconnect, screen-off endurance, measured latency, and restricted-Windows
firewall/policy acceptance remain open.

## Product scope

AudioShare becomes a two-part product:

1. a portable standard-user Windows host; and
2. an installed native Android companion.

The user's explicit capture requirement overrides stale `idplayer.exe` language:
the Windows host captures **System Audio (All Apps)**. On supported Windows it
uses Application Process Loopback in exclude mode, targeting AudioShare's own
process tree so every other ordinary render stream is included. Activation is
feature-probed rather than selected from a version string.

After one-time APK installation, USB-debugging enablement, and PC authorization,
the daily target is: start the host, connect the remembered phone, and system
audio starts without opening the Android UI or entering an IP address. Automatic
Windows startup and tray behavior are future conveniences, not current claims.

## Selected topology

```text
all ordinary applications + Windows sounds
                         |
       global process loopback (preferred)
                          |
      active-endpoint loopback + bounded mixer
                          |
         default-endpoint loopback (last resort)
                         |
          validated format conversion to 48k stereo PCM16
                         |
                bounded realtime queue
                         |
             Windows outbound TCP client
                         |
              127.0.0.1:<ADB tcp:0>
                         |
                 ADB forward over USB
                         |
       randomized Android abstract LocalServerSocket
                         |
       versioned authenticated full-duplex protocol
                         |
                 bounded playback queue
                         |
                    AudioTrack
                         |
          verified built-in speaker route
```

The Android companion has no IP listener and no `INTERNET` permission. The
Windows host owns no listening socket. ADB owns the expected localhost-only
smart socket and forward endpoint.

## One-time and daily lifecycle

One time:

- extract the Windows portable release;
- enable USB debugging and approve the PC's ADB key;
- explicitly install the bundled, matching companion APK;
- remember the selected USB device;
- run transport/speaker and Windows-capture self-tests; and
- optionally enable a reversible current-user Startup shortcut.

Daily:

- validate the extracted ADB/APK runtime before starting device work;
- supervise `adb track-devices -l` with a polling recovery path;
- classify transports, prefer the remembered authorized USB phone, and select
  the sole authorized USB phone automatically when no remembered choice exists;
- check package/protocol compatibility and require the installed base APK's
  SHA-256 to match the artifact bundled with this host build;
- generate a unique short socket name and 256-bit token;
- create `forward --no-rebind tcp:0 localabstract:<socket>`;
- explicitly launch the bridge Activity over ADB;
- connect outbound to the returned `127.0.0.1` port and authenticate;
- start system endpoint loopback and stream framed PCM; and
- remove only this session's exact mapping during teardown.

Release creation separately verifies the production APK's package/version,
cryptographic signature, and pinned signer-certificate SHA-256. The portable
bundle includes project and third-party license material, operator docs, and a
complete file checksum manifest; the packaging script revalidates an extracted
ZIP from a path containing spaces and proves altered or missing files fail.

Every asynchronous connection attempt carries a monotonically increasing
generation. A stale native READY callback cannot revive an unplugged or replaced
session. Missing companion is a stable explicit-install state; other transient
phase failures clean up the owned mapping and retry with bounded exponential
backoff. The UI does not report `streaming` until the native DLL exposes a
non-inactive capture mode.

The production ordering creates the randomized ADB forward before launching the
Android bridge. Because ADB can accept the Windows TCP connection before the
Android abstract socket exists, the native transport retries the complete
connect + HELLO + READY transaction within a finite eight-second deadline.

## Android boundaries

The separate `client android app` Git repository contains the companion. Its
initial POC uses:

- Kotlin through AGP 9.3.2 built-in Kotlin support and checksum-pinned Gradle
  9.7.1;
- target/compile SDK 36 and minimum SDK 26;
- an exported, no-history bridge Activity gated by the shell-only `DUMP`
  permission;
- an unexported `mediaPlayback` foreground service;
- `LocalServerSocket` in Android's abstract namespace;
- a randomized session token verified with constant-time comparison;
- a bounded parser and duration-based live-edge queue that retains only the
  newest 40 ms (or one indivisible PCM chunk), with a separate 32-chunk hard
  memory limit;
- `AudioTrack` streaming PCM with low-latency mode, a 40 ms target buffer and
  20 ms API-31+ start threshold, required built-in-speaker selection,
  media-audio focus handling, and periodic verification of the actual route;
- a session-scoped partial wake lock for screen-off playback; and
- a watchdog that closes a receiver when the host never connects.

Only `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`,
`POST_NOTIFICATIONS`, and `WAKE_LOCK` are declared. Audio is
memory-to-AudioTrack only. There is no network, microphone, camera, location,
storage, Bluetooth, analytics, telemetry, or cloud dependency.

Open physical-device items include force-stop policy, notification-denied
behavior on the target Samsung, repeated cable reconnect, measured latency, and
long-run drift/underrun evidence. Initial audible route and physical USB transport
are hardware tested. The emulator has already
exercised cold install, ADB launch, playback-head and route readiness, error
propagation, exact cleanup, and a 60-second screen-off session.

## Windows boundaries

The host retains the reliability design from `LOCKED_DOWN_WINDOWS_DESIGN.md`:

- structured ADB results, timeouts, bounded output, and generation ownership;
- USB-only device classification and sanitized ADB child environments;
- no `remove-all`, `kill-server`, wireless ADB workflow, or ambient-server
  disruption;
- endpoint-independent global process loopback where Windows accepts it, with
  event-driven active-endpoint aggregation and a default-endpoint last resort;
- all COM/WASAPI and asynchronous activation lifetime on the capture thread;
- canonical 48 kHz stereo PCM16 requested through Windows shared-mode engine
  conversion;
- a bounded capture-to-transport queue with live-edge policy; and
- explicit transport, capture, signal, and playback states.

The global path excludes the host's own process tree and is not tied to a
physical endpoint. The active mode, endpoint count, queue drops, mixer underruns,
discontinuities, rebuild count, host queue high-water, Android buffer/focus/
route counters, and heartbeat RTT are exposed through FFI diagnostics. On
older/incompatible Windows, the compatibility mixer opens every usable active
render endpoint and rebuilds on `IMMNotificationClient` events; only when no
endpoint can be opened does it follow the default console render endpoint.
Independent-clock drift correction and duplicate mirrored-output suppression are
still measurement-driven follow-up work.

## Evidence gate

Companion compilation, unit tests, lint, APK inspection, ADB forwarding,
authenticated streaming, emulated speaker routing, screen-off wake-lock
continuity, and exact mapping cleanup have local evidence. A physical Galaxy A52s
now proves the initial actual-cable and audible built-in-speaker path. The
restricted Windows target and extended phone tests are still required to prove
no Defender prompt, standard-user policy acceptance, reconnect endurance, and
final latency.
