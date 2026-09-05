# Work-PC silent connection investigation — 2026-09-05

## Status

**Not yet resolved on the affected work PC.** The user reports that AudioShare
connects but remains silent. Photos show an enabled `GDM-245LN` display-audio
output selected at volume 98. Lack of audible PC speakers is not evidence of
a missing Windows render endpoint. The actual AudioShare diagnostic report
and work-PC Windows build are still needed.

The local test build is labelled `workpc-test-20260905`. It uses the unchanged,
signed RC4 Android companion (version code 7). It is not a new stable release
and has not been verified on the affected PC.

## Verified defect and fix

The last-resort default-output path previously initialized an event-driven
loopback client, then ignored wait timeouts. Older Windows loopback clients
can initialize successfully without delivering capture notifications.
The multi-output path already polls its endpoints, but that mode can be
unavailable on old systems without its high-resolution timer support.

A real WASAPI test on the development PC forced the default-output path and
suppressed capture notifications: capture mode was 3, but PCM bytes and
captured frames remained zero even while an external process played a sound.
This reproduces a specific silent-success bug, not the complete work-PC incident.

The default-output path now uses timer-driven shared loopback: no event flag
or event handle, a 100 ms capture-buffer capacity cushion, and a 10 ms polling
wait that can be interrupted immediately by Stop. Available packets are read
at each tick rather than waiting for the buffer to fill. Global and
multi-output event-driven initialization are unchanged. Timer wake scheduling
may add some latency; end-to-end latency on legacy hardware remains unmeasured.

The regression target `capture_no_events_test` forces this default-output path
and **requires real non-silent PCM by default**. It cannot pass just because
capture starts. It also independently suppresses capture-event waiting, so
reintroducing an event-only loop fails on modern test machines too. Build with:

```powershell
cmake --build client/build/windows/x64 --config Debug --target capture_no_events_test
```

Run `client/build/windows/x64/Debug/capture_no_events_test.exe` while a separate
application plays an ordinary Windows sound. Run it without sound as a negative
control: it must fail. This executable and its test DLL are never packaged.
Hosted CI compiles this target; it does not claim hardware playback coverage.

## Diagnostics and regression boundaries

- The UI reports whether Windows supplied no PCM, supplied quiet PCM, or
  recently supplied a meaningful signal. Quiet playback does not reconnect,
  steal phone audio focus, or change volume/output settings.
- Reports include Windows version, capture mode, global activation HRESULT,
  signal age, and Android receive/write/playback progress.
- Copy copies the displayed snapshot; Refresh deliberately updates it.
- Automated tests cover silence-to-signal changes without reconnecting and
  report refresh/copy/clipboard-failure behavior at a narrow window size.
- No Android production code, authentication, ADB authorization, package
  signature validation, protocol, or automatic retry policy was changed.

## Test this build on the affected PC

1. Close any older AudioShare window. Extract the complete test ZIP into a new
   folder, keeping all files together. Do not replace only the EXE or DLL.
2. Run `audioshare.exe` normally, connect the phone, and approve USB debugging.
   Leave the matching RC4 companion installed if already present.
3. Play a normal PC browser video for 15 seconds. Raise phone media volume.
4. If still silent, open the graph icon beside Disconnect and click **Copy
   report**. Wait five seconds, click **Refresh**, and copy a second report.
   Send both reports and the Windows `winver` build to your helper.
5. Also try an ordinary Windows sound using the existing Sound control panel's
   Test button. Record whether neither source works or only one fails.

Do not disable security controls, change system-wide drivers, or repeatedly
reinstall the companion without diagnostic evidence. See
[Troubleshooting](TROUBLESHOOTING.md#connected-but-the-phone-is-silent).

## References

- [Microsoft loopback recording](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)
- [IAudioClient initialization and buffering contract](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-initialize)

These establish the compatibility mechanism; they do not establish the cause
of this user's work-PC failure.
