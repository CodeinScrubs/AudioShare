# AudioShare USB Companion Architecture

Status: selected product direction; physical ADB/Android 14 POCs remain required
before firewall, launch, routing, or latency claims.

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
the daily target is: log in, host runs in the tray, connect the remembered phone,
and system audio starts without opening either UI or entering an IP address.

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
               built-in speaker preference
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
- check package/protocol compatibility;
- generate a unique short socket name and 256-bit token;
- create `forward --no-rebind tcp:0 localabstract:<socket>`;
- explicitly launch the bridge Activity over ADB;
- connect outbound to the returned `127.0.0.1` port and authenticate;
- start system endpoint loopback and stream framed PCM; and
- remove only this session's exact mapping during teardown.

Every asynchronous connection attempt carries a monotonically increasing
generation. A stale native READY callback cannot revive an unplugged or replaced
session. Missing companion is a stable explicit-install state; other transient
phase failures clean up the owned mapping and retry with bounded exponential
backoff. The UI does not report `streaming` until the native DLL exposes a
non-inactive capture mode.

The launch ordering will be finalized by the device POC. A forward can be
created before or after the Android socket exists, but the production state
machine must have finite phase deadlines either way.

## Android boundaries

The separate `client android app` Git repository contains the companion. Its
initial POC uses:

- Kotlin through AGP 9.1 built-in Kotlin support;
- target/compile SDK 36 and minimum SDK 26;
- an exported, no-history bridge Activity with no privileged operation;
- an unexported `mediaPlayback` foreground service;
- `LocalServerSocket` in Android's abstract namespace;
- a randomized session token verified with constant-time comparison;
- a bounded parser and eight-chunk playback queue;
- `AudioTrack` streaming PCM with low-latency mode and built-in-speaker
  preference; and
- a watchdog that closes a receiver when the host never connects.

Only `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_MEDIA_PLAYBACK` are declared.
Audio is memory-to-AudioTrack only. There is no network, microphone, camera,
location, storage, Bluetooth, analytics, telemetry, or cloud dependency.

Open Android POC items include locked-screen ADB launch, force-stop behavior,
audio focus, route confirmation, notification-denied behavior, screen-off/Doze,
watchdog timing, AudioTrack failure propagation, repeated reconnect, and
long-run drift/underrun evidence.

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
discontinuities, and rebuild count are exposed through FFI diagnostics. On
older/incompatible Windows, the compatibility mixer opens every usable active
render endpoint and rebuilds on `IMMNotificationClient` events; only when no
endpoint can be opened does it follow the default console render endpoint.
Independent-clock drift correction and duplicate mirrored-output suppression are
still measurement-driven follow-up work.

## Evidence gate

Hardware-independent companion compilation, unit tests, lint, APK manifest
inspection, and release build can be completed locally. An authorized Android
device is still required to prove `adb forward`, automatic Android 14 launch,
speaker routing, screen-off operation, binary throughput, reconnect, and exact
mapping cleanup. The restricted Windows target is required to prove no Defender
prompt, standard-user policy acceptance, and final latency.
