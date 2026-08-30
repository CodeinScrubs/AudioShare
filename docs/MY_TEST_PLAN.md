# Manual Acceptance Test Plan

Record Windows build, phone model/Android version, ADB version, timestamps, and
pass/fail evidence. A test is not passed merely because the app launches.

## Part 1: Development laptop

1. Start with no phone attached. Launch AudioShare as a normal user and confirm
   it reports no devices without UAC or a firewall prompt.
2. Connect the Samsung with a data cable but do not authorize it. Confirm the UI
   says to unlock the phone and approve USB debugging.
3. Approve the PC without restarting AudioShare. Confirm the device changes to
   authorized USB and becomes selectable.
4. Select Connect. If the companion is absent, use **Install companion** and
   confirm Android shows the app afterward.
5. Connect and play a Windows system sound. Confirm it plays on the phone speaker.
6. Record the capture label. On supported Windows it should say **global mode**;
   on older compatibility systems it should say **all active outputs** with the
   endpoint count; **default output** means the last-resort branch.
7. Play browser audio, then two applications simultaneously. Confirm both are
   audible.
8. If Infinit is available, play idplayer content and confirm it is included
   without selecting a process.
9. On global mode, route a second application to another active Windows output
   endpoint and confirm both endpoints are captured. Force the multi-endpoint
   compatibility mode and repeat, recording endpoint count, drops, underruns,
   discontinuities, and rebuild count. If the final default-output mode is
   forced, record its explicit single-endpoint limitation.
10. Turn Windows Wi-Fi off and repeat. No Internet should be required.
11. Turn the phone screen off for 10 minutes. Confirm playback and the foreground
   service remain active.
12. Unplug USB during playback. Confirm bounded failure and exact mapping cleanup.
13. Reconnect the remembered phone. Confirm automatic recovery without opening
    either UI or pressing Connect.
14. Repeat connect/disconnect 25 times and compare host handles, threads, sockets,
    memory, Android threads/heap, and `adb forward --list` for monotonic leaks.
15. Run a two-hour stream. Record underruns, host/phone dropped-frame counters,
    latency at start/end, drift, CPU, and memory.

## Part 2: Restricted target PC

1. Extract the unsigned ZIP to an allowed user folder; do not install a service,
   driver, virtual audio device, or firewall rule.
2. Launch as the ordinary target user. Confirm no UAC prompt.
3. With Defender Firewall enabled and no AudioShare allow rule, launch and connect
   the authorized Samsung. Confirm no **Allow access** dialog appears.
4. During streaming, map listening and connected sockets to PIDs. Confirm
   AudioShare owns no listener, ADB listeners are loopback-only, and no audio
   connection targets LAN/Wi-Fi/Internet addresses.
5. Confirm the APK permissions contain no `INTERNET` and list every exported
   component. Expected exported components are the launcher Activity and the
   narrowly scoped bridge Activity; PlaybackService must be unexported.
6. Play a Windows system sound, browser audio, and Infinit/idplayer content.
   Confirm all are heard from the phone speaker.
7. Measure end-to-end latency with a visible/audio transient. Repeat at least 20
   times and report median, 95th percentile, glitches, and dropped frames.
8. Lock the phone, disconnect/reconnect USB, close/reopen the host, and restart
   idplayer. Confirm recovery behavior for each case.
9. Change the Windows default output endpoint. Global mode should continue
   without reconnecting; the multi-endpoint mode should rebuild on a device
   notification, while the final default-output mode requires recovery testing.
10. Inspect diagnostics for deliberately broken ADB executable, unauthorized and
    offline states, missing companion, failed launch, failed forward, handshake
    timeout, WASAPI failure, USB unplug, and AudioTrack failure.

## Required evidence labels

Label every result as one of: STATICALLY VERIFIED, UNIT TESTED, BUILD TESTED,
INTEGRATION TESTED, HARDWARE TESTED, or MANUAL TEST REQUIRED. Attach command
output/screenshots where practical and never convert an unrun item into a pass.
