# AudioShare USB Companion Architecture

Status: selected product direction; physical ADB/Android 14 POCs remain required
before firewall, launch, routing, or latency claims.

## Product scope

AudioShare becomes a two-part product:

1. a portable standard-user Windows host; and
2. an installed native Android companion.

The user's explicit capture requirement overrides stale `idplayer.exe` language
in external review briefs: the Windows host captures **System Audio (All Apps)**
from the selected/default Windows render endpoint. It does not filter by process
and does not depend on Application Loopback or Windows build 20348.

After one-time APK installation, USB-debugging enablement, and PC authorization,
the daily target is: log in, host runs in the tray, connect the remembered phone,
and system audio starts without opening either UI or entering an IP address.

## Selected topology

```text
all applications + Windows sounds on selected render endpoint
                         |
             event-driven WASAPI loopback
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

- supervise `adb track-devices -l` with restart/backoff;
- classify transports and react only to the remembered authorized USB phone;
- check package/protocol compatibility;
- generate a unique short socket name and 256-bit token;
- create `forward --no-rebind tcp:0 localabstract:<socket>`;
- explicitly launch the bridge Activity over ADB;
- connect outbound to the returned `127.0.0.1` port and authenticate;
- start system endpoint loopback and stream framed PCM; and
- remove only this session's exact mapping during teardown.

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
- event-driven shared-mode endpoint loopback with all COM/WASAPI lifetime on
  the capture thread;
- canonical 48 kHz stereo PCM16 requested through Windows shared-mode engine
  conversion;
- a bounded capture-to-transport queue with live-edge policy; and
- explicit transport, capture, signal, and playback states.

The current implementation follows the Windows default console render endpoint.
Manual endpoint selection and endpoint-change recovery are still planned.
Simultaneous multi-endpoint mixing is not promised because endpoints have
independent clocks and may contain duplicate audio.

## Evidence gate

Hardware-independent companion compilation, unit tests, lint, APK manifest
inspection, and release build can be completed locally. An authorized Android
device is still required to prove `adb forward`, automatic Android 14 launch,
speaker routing, screen-off operation, binary throughput, reconnect, and exact
mapping cleanup. The restricted Windows target is required to prove no Defender
prompt, standard-user policy acceptance, and final latency.
