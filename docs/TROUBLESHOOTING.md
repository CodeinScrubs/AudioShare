# AudioShare USB Troubleshooting

Work through these layers in order. Do not disable Windows Firewall, antivirus,
EDR, UAC, or organizational security controls.

## 1. USB and ADB

- Use a data-capable cable and a direct PC USB port.
- If the phone is absent, confirm USB debugging is enabled and that Windows has
  a suitable ADB driver. A missing driver may require an administrator to install.
- If shown as **unauthorized**, unlock the phone, accept **Allow USB debugging?**,
  and optionally select **Always allow from this computer**.
- If shown as **offline**, unplug/reconnect the cable, unlock the phone, and wait
  for the state to change. AudioShare supervises `adb track-devices` and should
  update without a restart.
- Wi-Fi ADB devices and emulators are intentionally displayed as ignored and
  cannot be selected in automatic USB mode.

## 2. Companion launch

- Select **Install companion** only for an authorized USB phone.
- If an app has the expected package/version but its installed base APK does
  not exactly match the one bundled with this Windows build, AudioShare treats
  it as missing. Reinstall the bundled companion; do not bypass this check.
- If the installed companion is newer than the bundled artifact, update the
  Windows portable package. AudioShare deliberately does not attempt an Android
  downgrade because `adb install -r` cannot safely replace a newer version.
- If the bundled APK is missing, the Windows package is incomplete.
- If Android rejects installation, capture the exact ADB diagnostic. Do not
  weaken Play Protect or device policy; a signed production APK may be required.
- If AudioShare reports a different publisher signature, uninstall the existing
  AudioShare companion from Android Settings and choose **Install companion**
  again. The host deliberately never uninstalls a phone app without the user.
- If the package is installed but launch is blocked by device policy or Android
  force-stop state, open the companion once and retry.

## 3. USB transport

- A connection phase must finish or fail within a bounded deadline; it must not
  remain at Connecting forever.
- Three identical failures in one minute deliberately stop automatic retries
  and show an actionable error. Fix the reported condition, then use **Retry**
  or reconnect the phone; transient USB failures with a changing fingerprint
  continue to recover automatically.
- AudioShare creates one `adb forward --no-rebind tcp:0 localabstract:<nonce>`
  mapping and removes exactly that host port on cleanup.
- Do not run `adb kill-server` or `forward --remove-all`; another tool may own
  the shared server or other mappings.
- Strict firewall operation must be tested with no AudioShare exception. The
  host should connect outbound only to an ADB-owned loopback port.

## 4. Android speaker

- Raise media volume and disconnect or disable an unwanted Bluetooth route.
- The companion requests and verifies the built-in speaker route. If Android
  selects Bluetooth, wired, or USB audio instead, the stream fails with that
  route named rather than silently playing through the wrong device.
- Keep the foreground playback notification/service allowed by device policy.
- If music or video starts directly on the phone, Android gives that app media
  audio focus. AudioShare deliberately stops once instead of reconnecting in a
  loop. Stop the phone-local media, then click **Connect** again.
- Open the companion once on Android 13+ to grant notification permission if
  you want its Disconnect action visible; USB playback itself does not wait on
  that dialog.
- **Disconnect** stops playback for the current cable session but does not
  erase the remembered phone. Unplug and reconnect the cable to re-enable the
  normal automatic connection path.

## 5. Windows source sound

- This fork captures system audio, not one selected process. Global mode is
  endpoint-independent; the compatibility mixer captures every usable active
  render endpoint. The final fallback is explicitly limited to the default
  Windows render endpoint.
- Confirm the application uses the Windows shared audio engine. Hardware paths
  that bypass that engine are outside WASAPI loopback coverage.

## 6. Windows capture

- Confirm the Windows Audio service and default output device are working.
- In global mode, changing the default output does not require recovery. In the
  multi-endpoint compatibility mode, endpoint notifications trigger a bounded
  rebuild; the final default-output fallback may require reconnecting AudioShare.
- Native errors include a numeric code and the failing WASAPI/transport stage.
- Streaming diagnostics include one capture-discontinuity counter for every
  capture mode; the compatibility mixer also exposes its per-endpoint counter.

## 7. Full stream

- Test Windows system sounds first, then a browser, then Infinit/idplayer.
- Record whether failure follows USB unplug/reconnect, screen off, endpoint
  change, or long playback.
- Collect the exact displayed diagnostic, device state, connection phase, Android
  companion status, and owned ADB forward list. Do not broadly alter shared ADB
  state while collecting evidence.
