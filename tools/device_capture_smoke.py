#!/usr/bin/env python3
"""Opt-in hardware test: production Windows DLL -> USB -> signed phone app.

Not a Flutter UI test. A separate process must play ordinary Windows audio.
Never installs apps, changes volume, or removes another tool's ADB forwards.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import threading
import time


PACKAGE = "com.audioshare.usbcompanion"
CALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_char_p)
U64 = (
    "CapturedFrames", "DroppedChunks", "TransportBytesSent",
    "AndroidReceivedFrames", "AndroidDroppedFrames", "AndroidWrittenFrames",
    "AndroidPlaybackHeadFrames", "CaptureDiscontinuities",
)
U32 = (
    "CaptureMode", "CapturePeakPermille", "LastNonSilentAgeMilliseconds",
    "HostQueueHighWaterFrames", "AndroidUnderrunCount", "AndroidRoutedDeviceType",
    "AndroidFocusState", "AndroidMediaVolume", "AndroidMediaVolumeMax",
    "AndroidPlayState", "AndroidLastWriteProgressAgeMilliseconds",
    "AndroidLastPlaybackAdvanceAgeMilliseconds",
)


def run(args: argparse.Namespace) -> None:
    bundle = args.bundle.resolve(strict=True)
    environment = {key: value for key, value in os.environ.items()
                   if not key.upper().startswith("ADB_")
                   and key.upper() not in ("ANDROID_SERIAL", "ANDROID_ADB_SERVER_ADDRESS",
                                           "ANDROID_ADB_SERVER_PORT")}
    environment.update(ADB_MDNS="0", ADB_MDNS_AUTO_CONNECT="0", ADB_EMU="0")

    def adb(*command: str) -> str:
        result = subprocess.run(
            [str(bundle / "adb.exe"), "-s", args.serial, *command],
            capture_output=True, text=True, timeout=20, env=environment,
        )
        # Launch arguments contain the authentication token: never print them.
        if result.returncode:
            raise RuntimeError(f"ADB operation {command[0]} failed (exit {result.returncode})")
        return result.stdout.strip()

    installed = adb("shell", "pm", "path", PACKAGE)
    apk_paths = [line.removeprefix("package:") for line in installed.splitlines()
                 if line.startswith("package:") and line.endswith("/base.apk")]
    if len(apk_paths) != 1:
        raise RuntimeError("Install the bundled release companion using AudioShare first")
    with (bundle / "android" / "audioshare-companion.apk").open("rb") as bundled_apk:
        bundled_hash = hashlib.file_digest(bundled_apk, "sha256").hexdigest()
    phone_hash = adb("shell", "sha256sum", apk_paths[0]).split()[0]
    if phone_hash.lower() != bundled_hash:
        raise RuntimeError("Installed companion does not match the selected portable bundle")
    if f"{PACKAGE}/com.audioshare.usbcompanion.PlaybackService" in adb(
        "shell", "dumpsys", "activity", "services", PACKAGE
    ):
        raise RuntimeError("Disconnect the existing AudioShare session before this test")

    dll_path = (args.dll or bundle / "audio_capture.dll").resolve(strict=True)
    library = ctypes.CDLL(str(dll_path))
    functions = {}
    for name, result_type, arguments in (
        ("Initialize", ctypes.c_int, []),
        ("Connect", ctypes.c_int, [ctypes.c_int, ctypes.c_char_p, CALLBACK]),
        ("Start", ctypes.c_int, []),
        ("Cleanup", None, []),
        ("GetLastErrorCode", ctypes.c_int, []),
        ("GetLastErrorMessage", ctypes.c_char_p, []),
        *(("Get" + name, ctypes.c_uint64, []) for name in U64),
        *(("Get" + name, ctypes.c_uint32, []) for name in U32),
    ):
        function = getattr(library, "AudioCapture_" + name)
        function.restype = result_type
        function.argtypes = arguments
        functions[name] = function

    def check_error() -> None:
        if code := functions["GetLastErrorCode"]():
            message = functions["GetLastErrorMessage"]().decode("utf-8", "replace")
            raise RuntimeError(f"Native error {code}: {message}")

    def snapshot() -> dict:
        check_error()
        return {name: functions["Get" + name]() for name in U64 + U32}

    originally_awake = "mWakefulness=Awake" in adb("shell", "dumpsys", "power")
    try:
        for cycle in range(1, args.cycles + 1):
            port = None
            ready = threading.Event()
            status = []

            @CALLBACK
            def connected(value: bytes) -> None:
                status.append(value.decode("ascii", "replace"))
                ready.set()

            try:
                if functions["Initialize"]() != 1:
                    check_error()
                    raise RuntimeError("Native initialization failed")
                token = secrets.token_hex(32)
                socket_name = "as_1_capturetest_" + secrets.token_hex(6)
                port = int(adb("forward", "--no-rebind", "tcp:0",
                               "localabstract:" + socket_name).splitlines()[-1])
                launch = adb(
                    "shell", "am", "start", "-W", "-n",
                    f"{PACKAGE}/com.audioshare.usbcompanion.BridgeActivity",
                    "-a", "com.audioshare.usbcompanion.LAUNCH_SESSION",
                    "--es", "socket_name", socket_name, "--es", "token_hex", token,
                    "--el", "generation", str(cycle),
                )
                if "Error:" in launch or "Exception" in launch:
                    raise RuntimeError("Companion activity launch failed")
                if functions["Connect"](port, token.encode("ascii"), connected) != 1:
                    check_error()
                    raise RuntimeError("Native connection failed")
                if not ready.wait(15) or status != ["ready"]:
                    check_error()
                    raise RuntimeError("Native handshake did not become ready exactly once")
                if functions["Start"]() != 1:
                    check_error()
                    raise RuntimeError("Capture did not start")
                if args.screen_off:
                    adb("shell", "input", "keyevent", "223")  # sleep, never a toggle
                started = time.monotonic()
                last_head = None
                while time.monotonic() - started < args.duration:
                    time.sleep(min(10, max(0.1, args.duration - (time.monotonic() - started))))
                    values = snapshot()
                    if values["CaptureMode"] != args.expect_mode:
                        raise RuntimeError(f"Unexpected capture mode: {values['CaptureMode']}")
                    if (values["LastNonSilentAgeMilliseconds"] >= 5000
                            or values["CapturedFrames"] == 0):
                        raise RuntimeError("No recent Windows signal: play sound from a separate process")
                    if (values["AndroidReceivedFrames"] == 0
                            or values["AndroidWrittenFrames"] == 0
                            or values["AndroidPlaybackHeadFrames"] == 0
                            or (last_head is not None
                                and values["AndroidPlaybackHeadFrames"] <= last_head)):
                        raise RuntimeError("Android playback did not make progress")
                    last_head = values["AndroidPlaybackHeadFrames"]
                    if (values["AndroidRoutedDeviceType"] != 2
                            or values["AndroidFocusState"] != 1
                            or values["AndroidPlayState"] != 3):
                        raise RuntimeError("Phone is not playing with speaker route and audio focus")
                    if values["AndroidMediaVolume"] == 0:
                        raise RuntimeError("Phone media volume is muted")
                    if values["DroppedChunks"] or values["AndroidDroppedFrames"]:
                        raise RuntimeError("PCM was dropped: " + json.dumps(values))
                    power = adb("shell", "dumpsys", "power")
                    if "AudioShare:UsbPlayback" not in power:
                        raise RuntimeError("Playback wake lock is missing")
                    if args.screen_off and "mWakefulness=Awake" in power:
                        # Capture only relevant power fields before restoring
                        # the original screen state overwrites the wake cause.
                        wake_fields = [line.strip() for line in power.splitlines()
                                       if any(key in line for key in
                                              ("mWakefulness=", "mLastWakeUpReason",
                                               "mLastSleepReason", "mStayOn="))]
                        print(json.dumps({"screen_off_failure": wake_fields,
                                          "elapsed": round(time.monotonic() - started),
                                          **values}), flush=True)
                        raise RuntimeError("Display woke during the screen-off test")
                    print(json.dumps({"cycle": cycle, "elapsed": round(time.monotonic() - started),
                                      "screen_off_sampled": args.screen_off, **values}), flush=True)
            finally:
                functions["Cleanup"]()
                if port is not None:
                    adb("forward", "--remove", f"tcp:{port}")
                # Wait for the EOF/STOP cleanup, but don't force-stop the app.
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if f"{PACKAGE}/com.audioshare.usbcompanion.PlaybackService" not in adb(
                        "shell", "dumpsys", "activity", "services", PACKAGE
                    ):
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError("Phone playback service did not stop")
                if port is not None and any(
                    row.split()[:2] == [args.serial, f"tcp:{port}"]
                    for row in adb("forward", "--list").splitlines()
                ):
                    raise RuntimeError("Owned ADB forward remained after cleanup")
            check_error()
            print(f"DEVICE_CAPTURE_CYCLE_OK cycle={cycle} service_stopped=True forward_removed=True", flush=True)
    finally:
        if args.screen_off and originally_awake:
            adb("shell", "input", "keyevent", "224")  # wake without unlocking
    print("DEVICE_CAPTURE_SMOKE_OK", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--dll", type=Path, help="Test-only forced-mode DLL override")
    parser.add_argument("--expect-mode", type=int, choices=(1, 2, 3), default=1)
    parser.add_argument("--duration", type=int, default=30)
    parser.add_argument("--cycles", type=int, default=1)
    parser.add_argument("--screen-off", action="store_true")
    args = parser.parse_args()
    if os.name != "nt" or not 10 <= args.duration <= 7200 or not 1 <= args.cycles <= 20:
        parser.error("Requires Windows, duration10..7200 seconds, cycles1..20")
    try:
        run(args)
        return 0
    except Exception as error:
        print(f"DEVICE_CAPTURE_SMOKE_FAILED: {error}", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
