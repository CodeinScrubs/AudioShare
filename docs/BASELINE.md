# AudioShare Custom Fork Baseline

Recorded: 2026-08-29 (Asia/Tehran)

This file pins the source against which the Windows-to-Android USB redesign is
being evaluated. The checked-out source, not values quoted in external briefs,
is authoritative.

## Git identity

```text
fetch remote: https://github.com/ysbing/AudioShare.git
push remote:  DISABLED
branch:       custom
commit:       70db6b531db2c21b5a41a289722aa3996de67ebe
tag:          v2.1.1
log:          70db6b5 optimize macOS permission request
```

The initial worktree was clean. Branch `custom`, local `main`, `upstream/main`,
and tag `v2.1.1` all pointed at the commit above. The existing immutable commit
and tag are the comparison baseline, so no duplicate baseline commit or tag was
created.

At the time this file was added, the only worktree additions were documentation:

```text
?? docs/BASELINE.md
?? docs/LOCKED_DOWN_WINDOWS_DESIGN.md
```

## Confirmed source characteristics

At `70db6b5`:

- Windows audio transport binds `INADDR_ANY` and accepts an Android-initiated
  connection through ADB reverse.
- The Windows socket send buffer constant is 32 KiB.
- Windows capture uses `Sleep(1)` polling and cross-thread `volatile BOOL`
  globals.
- Android uses `AudioTrack` capacity `minBuffer * 2`, reads chunks of
  `minBuffer`, and pre-rolls `minBuffer`.
- Android requests `PERFORMANCE_MODE_LOW_LATENCY` on API 26 and later.
- Dart runs ADB with `Process.run`, stages ADB under `%TEMP%`, and calls
  `adb reverse --remove-all`.
- The bundled Windows binary reports ADB 1.0.41 / platform-tools
  33.0.3-8952118. Its help advertises USB-only `-d`,
  `forward [--no-rebind]`, host-side `tcp:0`, `localabstract:`, and exact
  `forward --remove` support. No server or device operation was started for this
  command-surface check.
- The requested fork behavior is system-wide endpoint loopback: all applications
  and Windows sounds routed to the selected/default Windows render endpoint.
  Process-specific `idplayer.exe` capture is not part of the requested design.

## Baseline verification

The Android server was built without changing source:

```powershell
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
.\gradlew.bat :server:assembleRelease :server:lintRelease --no-daemon
```

Result:

```text
BUILD SUCCESSFUL in 54s
47 actionable tasks: 45 executed, 2 up-to-date
Android lint report: No errors or warnings / No Issues Found
```

Warnings that did not fail the build:

- installed Android tools reported an SDK XML version mismatch warning;
- Gradle reported deprecated features that will be incompatible with Gradle 10.

The Gradle finalizer rewrote the tracked `client/assets/server` binary. That
generated delta was removed after verification so it cannot be mistaken for an
intentional source change.

## Baseline limitations

The current shell does not provide Flutter, Dart, CMake, or the Visual Studio
Windows build toolchain, so the desktop baseline was not rebuilt here. No claim
is made yet for:

- Windows desktop compilation or runtime;
- physical Android/USB operation;
- ADB-forward compatibility of the bundled ADB executable;
- Windows Defender Firewall prompt behavior or socket ownership;
- real system-loopback audio, format conversion, latency, drift, or stability;
- restricted standard-user/organizational-policy acceptance.

Those items require the phase-gated POCs and, where noted, physical target
hardware.
