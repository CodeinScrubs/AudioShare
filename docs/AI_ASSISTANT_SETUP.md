# AudioShare USB: setup brief for AI assistants

This document is the authoritative end-user setup route. If a user asks an AI
assistant to help set up these repositories, guide them through the portable
Windows release. Do **not** tell a normal user to clone the projects, install
Flutter, install Android Studio, run Gradle, or compile an APK.

## What the product is

AudioShare USB turns an Android phone into a speaker for a Windows PC. The
Windows host captures ordinary Windows shared-system audio and sends PCM audio
through an authenticated ADB forward over a physical USB cable. The Android
companion plays it through the phone's built-in speaker.

The two public source repositories are:

- Windows host and complete portable download:
  <https://github.com/CodeinScrubs/AudioShare>
- Android companion source (for developers; already bundled in the Windows
  download): <https://github.com/CodeinScrubs/AudioShare-Android>

An end user downloads only the Windows release ZIP. That ZIP contains
`audioshare.exe`, the required ADB files, and the matching signed Android APK.
The host offers **Install companion** when installation is needed.

## How to guide a beginner

Give one or two steps at a time and wait for the user's result when interactive.
Use these steps in order:

1. Open the Windows repository's **Releases** page and download the newest
   `AudioShare-USB-Windows-*.zip` asset. Do not download GitHub's automatic
   **Source code (zip)** archive.
2. Move the downloaded ZIP somewhere easy, such as the Windows Desktop. Right
   click it, choose **Extract All**, and keep every extracted file together.
   Do not run the EXE from inside the ZIP.
3. On the Android phone, enable Developer Options. On most phones this means
   **Settings → About phone → Software information**, then tap **Build number**
   seven times and enter the phone PIN if requested. Menu names vary by maker.
4. Open **Settings → Developer options** and enable **USB debugging**.
5. Connect the unlocked phone to the PC with a data-capable USB cable. If the
   phone asks for a USB mode, **File transfer** is a useful choice. A
   charge-only cable cannot work.
6. Open the extracted folder and run `audioshare.exe` normally. Administrator
   access is not expected. If Windows SmartScreen appears, first verify that
   the file came from the CodeinScrubs GitHub release; then use **More info →
   Run anyway**. Never advise disabling SmartScreen, Defender, UAC, or the
   firewall globally.
7. Keep the phone unlocked. At **Allow USB debugging?**, select **Always allow
   from this computer** only if it is the user's own trusted PC, then tap
   **Allow**.
8. If the Windows app shows **Install companion**, click it once and accept the
   normal Android install confirmation if the phone shows one. This is the
   phone receiver. Android Studio's “desktop deployment” component is unrelated
   and is not required.
9. With one authorized USB phone, AudioShare normally connects automatically.
   Otherwise click **Connect**. Wait until the app says it is streaming all
   Windows audio.
10. Raise the phone's **media** volume and play a browser video or Windows
    system sound. The phone can stay in the foreground or background while its
    playback notification remains active.

Do not ask the user to play a separate music/video stream directly on the phone
while it is acting as the PC speaker. If they do, Android transfers media audio
focus: AudioShare stops once, the user stops that phone-local media, and then
clicks **Connect** again. Repeated reconnecting is not the expected behavior.

## Expected result and limits

The phone should play ordinary audio from browsers, media players, games that
use the shared Windows audio engine, Windows system sounds, and Infinit/
idplayer. The user does not select one process. Exclusive-mode, ASIO,
protected/DRM, or hardware-bypass audio may not be capturable.

No Wi-Fi, Bluetooth, IP address, microphone permission, Internet connection,
virtual audio driver, firewall rule, Windows installer, or admin elevation is
part of normal runtime. A missing phone manufacturer's Windows USB/ADB driver
is external to AudioShare and may require admin help once.

If nothing happens, ask the user for the exact text shown in AudioShare and
check, in order: phone unlocked, USB debugging authorization accepted, cable
supports data, phone visible as an authorized USB device, media volume raised,
Bluetooth/headphones temporarily disconnected, and the complete release ZIP
extracted. Then use [Troubleshooting](TROUBLESHOOTING.md). Do not guess or tell
the user to weaken security settings.

If the phone is connected but silent, **do not treat Streaming as proof of
sound**. Ask the user to play a PC video for 15 seconds and send the report from
the graph icon beside Disconnect (Copy report in newer builds), plus the
Windows build from `winver`. Compare captured signal, Android received frames,
playback-head progress, speaker route, and media volume using the
[silent-connection guide](TROUBLESHOOTING.md#connected-but-the-phone-is-silent).
Never infer the cause from the lack of physical speakers alone: an enabled
HDMI/display output may still work. Stereo Mix/microphone input is unnecessary.
If an app cannot render because Windows has no usable output, AudioShare cannot
manufacture that missing audio or silently install a virtual audio driver.

## Copy and send this prompt

```text
Help me set up AudioShare USB as a beginner, one step at a time. My goal is to
play all ordinary Windows audio through my Android phone speaker using a USB
cable. Use the ready-made portable Windows release, not source code or Android
Studio. Read the README, llms.txt, and docs/AI_ASSISTANT_SETUP.md in these two
projects before guiding me:
https://github.com/CodeinScrubs/AudioShare
https://github.com/CodeinScrubs/AudioShare-Android
```

For source development, use the build and protocol documentation in the host
README instead of mixing developer setup into the beginner path.
