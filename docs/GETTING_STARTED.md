# AudioShare USB: beginner guide

AudioShare turns an Android phone into a speaker for ordinary sound produced by
Windows. The Windows program sends the sound through the USB cable; it does not
use Wi-Fi, Bluetooth, a microphone, or the Internet.

## Download one file

Download the single file named
`AudioShare-USB-Windows-v3.0.0-rc.2.zip` from the
[GitHub Releases page](https://github.com/CodeinScrubs/AudioShare/releases/tag/v3.0.0-rc.2).
The ZIP already contains the Windows program, ADB, and the matching Android
companion APK. You do not need Android Studio to use it.

Windows may show a SmartScreen warning because this portable build is not yet
Authenticode-signed. Check that the download came from the CodeinScrubs
AudioShare release page before choosing **More info** and **Run anyway**. Do not
disable SmartScreen globally.

## First-time setup

Do these steps once:

1. Extract the ZIP to a normal folder you can write to, such as
   `C:\Users\YourName\AudioShare`. Do not run the EXE from inside the ZIP.
2. On the phone, open **Settings → About phone → Software information** and tap
   **Build number** seven times if Developer options are not already enabled.
3. Open **Settings → Developer options**, turn on **USB debugging**, and keep
   the phone unlocked.
4. Connect the phone with a data-capable USB cable. A charge-only cable will
   not work.
5. Run `audioshare.exe` from the extracted folder.
6. When Android asks **Allow USB debugging?**, choose **Allow**. You may select
   **Always allow from this computer** if this is your own PC.
7. If AudioShare shows **Install companion**, click that button once and wait
   for the installation to finish. This is the receiver app that plays sound
   through the phone speaker; it is not Android Studio's “desktop deployment”.
8. AudioShare then launches the companion and connects automatically. Play a
   Windows system sound or browser video and raise the phone's media volume.

If exactly one authorized USB phone is connected, no **Connect** click is needed.
With multiple phones, select the phone you want. The companion app can remain
open or be in the background while the foreground playback notification is
visible.

## Daily use

1. Connect the authorized phone by USB.
2. Start `audioshare.exe`.
3. Play sound in any ordinary Windows application. This includes browsers,
   media players, Windows system sounds, and Infinit/idplayer.

To stop, click **Disconnect** in AudioShare or use the notification's
**Disconnect** action on the phone. Disconnect stops the current cable session
but remembers the phone; unplugging and reconnecting the cable enables automatic
connection again.

## What you do not need

- Android Studio or the Android Studio **desktop deployment** tool.
- A separate installer, Windows service, virtual audio driver, or firewall rule.
- Wi-Fi, an IP address, Bluetooth, or an Internet connection.
- Administrator access, except possibly once to install a missing Android USB
  driver supplied by Windows or your device manufacturer.
- To select `idplayer.exe`; AudioShare captures ordinary Windows system audio,
  not just that one process.

## If you hear nothing

Check these in order:

1. Confirm the phone is unlocked, USB debugging is authorized, and the cable
   supports data.
2. Raise **media** volume on the phone and temporarily disconnect Bluetooth or
   wired headphones.
3. In AudioShare, open the diagnostics view. A healthy session shows
   **Streaming all Windows audio** (global mode), a nonzero Android received
   frame count, and zero or near-zero drop/underrun counters.
4. If the phone says **unauthorized**, unlock it and accept the USB debugging
   prompt. If it says **offline**, unplug/reconnect and wait a few seconds.
5. If AudioShare asks for a newer Windows build, the phone has a newer companion
   than this host supports; download the matching Windows release instead of
   trying to downgrade the phone app.
6. Read [Troubleshooting](TROUBLESHOOTING.md) before changing security settings.
   Do not disable Windows Firewall, Defender, UAC, or organizational controls.

## Important platform limits

AudioShare captures audio that uses the normal Windows shared audio engine. An
application using exclusive-mode, ASIO, a protected/DRM path, or a hardware
driver that bypasses shared WASAPI may not appear in system loopback. A missing
Windows ADB driver or a policy such as AppLocker/WDAC is also outside the
program's control.

For developers and testers, the full build and evidence instructions are in the
repository [README](../README.md) and [manual test plan](MY_TEST_PLAN.md).
