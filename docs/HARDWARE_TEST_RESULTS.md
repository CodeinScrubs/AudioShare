# Physical-device test results

## 2026-08-31: Samsung Galaxy A52s initial audible run

Evidence label: **HARDWARE TESTED** for the items explicitly listed below.

- Phone: Samsung Galaxy A52s (`SM-A528B`), Android 14 / API 34.
- Host: Windows 10 Pro for Workstations 22H2, build 19045.7663.
- Connection: authorized physical USB ADB device using a data cable.
- Build: locally compiled Windows Debug host and matching version-code 4 debug
  companion.
- Installation: AudioShare detected the missing companion and completed the
  explicit one-time installation.
- End-to-end result: ordinary Windows audio was audibly reproduced by the phone
  speaker and was reported by the tester as working very well.
- Capture mode: `globalSystem`.
- Host queue at the diagnostic snapshot: 0 frames / 0.0 ms.
- Host queue high-water mark: 480 frames / 10.0 ms.
- Host dropped chunks: 0.
- Transport bytes sent: 13,708,888 at the captured snapshot.
- USB heartbeat round-trip time: 10 ms.
- Android dropped frames: 0.

The permanently signed `1.0.0-rc.1` APK was then installed on the same phone.
Two authenticated 10-second screen-off protocol runs each delivered 480,000
frames with zero drops and zero underruns, `route=2` (built-in speaker),
`focus=1` (gained), the session wake lock present, and exact service/forward
cleanup. A longer strict run was invalidated when Android reported biometric
wake reason 17 and turned the panel on; targeted power-state instrumentation
attributed that wake to face/fingerprint handling rather than an AudioShare wake
request. The uninstrumented ten-minute screen-off gate remains open.

This proves the initial real-phone Windows capture, USB transport, explicit
companion installation, and audible playback path on this hardware. It does not
by itself prove latency percentiles, screen-off continuity, repeated recovery,
memory stability, restricted-PC behavior, or endurance.

## 2026-08-31: RC4 playback and focus-recovery check

The permanently signed `1.0.0-rc.4` companion (version code 7) was exercised
through the authenticated ADB-forward protocol harness on the same authorized
Galaxy A52s. A 60-second stream delivered 2,880,000 frames with zero Android
drops, zero underruns, confirmed built-in-speaker route (`route=2`), gained
media focus (`focus=1`), and an active session wake lock. Stopping the harness
removed the foreground service and its exact ADB forward. A shorter 15-second
run also delivered 720,000 frames with zero drops; its two initial underruns
were not present in the longer run.

As a targeted failure test, Samsung Music was started during the protocol run.
The companion sent the terminal cause
`AudioTrack playback failed: Android audio focus was lost` back to the harness.
A separate Windows supervisor regression proves that this exact cause becomes
an actionable phone-media error without another companion launch or ADB
forward. That Windows policy assertion is automated test evidence, not a claim
that the complete Windows UI path was exercised during the Samsung Music run.
After phone-local media is stopped, the intended recovery is to click
**Connect**.

This confirms the RC4 companion's focus-error propagation on this phone and the
host's no-reconnect-loop policy in automated regression tests. It does not
prove every OEM's audio-focus policy, the complete Windows UI path, screen-off
continuity, repeated USB recovery, latency percentiles, restricted-PC behavior,
memory stability, or endurance.

## 2026-09-05: RC5 preparation with the connected Galaxy A52s

The installed non-debuggable companion exactly matched the signed Android RC4
APK, SHA-256
`1212b8bfad843e3ad04ee848476f407e98a11a6fa2d571af19b2cdcae519da7b`.
No phone app update or driver/security change was performed.

Two kinds of hardware evidence were collected; neither is a Flutter UI test:

| Test | Observed result |
| --- | --- |
| Protocol harness, 15 seconds | 720,000 frames; zero drops and underruns; speaker route, focus, wake lock; service and owned forward cleaned up. |
| Production Windows DLL -> ADB USB -> phone, three 30-second sessions | Real PC signal and Android playback-head progress in all sessions; zero host/Android drops; final Android underrun counts 0, 7, 7; each service/forward cleaned up. |
| Forced default fallback, Debug DLL, concurrent full build | At approximately 20 seconds, 960 Android frames were dropped (20 ms); host dropped chunks remained zero. The strict harness failed as intended. |
| Forced default fallback, optimized Release DLL, no concurrent build, 60 seconds | 2,879,040 host-captured frames; latest heartbeat reported 2,740,800 received/written frames, head 2,739,072; zero drops/underruns; service/forward cleaned up. |

Android counters above come from periodic heartbeats and therefore lag the
host's final capture snapshot. They are not a sample-exact recording or a
measurement of acoustic latency. The fallback run reported one initial capture
discontinuity. The two different fallback conditions are not a controlled proof
that Debug optimization or build load alone caused the drop.

The connected phone confirms native capture, USB delivery, and speaker-playback
progress on the development PC. It does not resolve the silent work-PC incident,
prove physical cable unplug/replug, or prove every desktop UI interaction.

## Stable-release promotion gates

A 30-second screen-off production-DLL-to-phone run on 2026-09-05 passed with
zero drops/underruns and verified playback/wake-lock/cleanup. An earlier
ten-minute attempt stopped at its first check because the display was awake;
its wake cause was not established. The short run does not close the ten-minute
gate below.

- Ten-minute continuous playback with the phone screen off and final diagnostics.
- Wi-Fi-disabled playback using multiple simultaneous Windows applications.
- Automatic recovery after USB unplug/replug and repeated reconnect cycling.
- At least 20 visible/audio transient measurements with median and p95 latency.
- Two-hour stream with start/end CPU, memory, latency, underrun, and drop counts.
- Ordinary-user launch on a restricted PC with Defender Firewall enabled and no
  firewall/UAC prompt.

Until these gates are recorded, releases must remain prereleases.
