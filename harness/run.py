#!/usr/bin/env python3
"""Run AppKit demo scenarios on an iOS simulator or device, or an Android
emulator or device, and store each result under results/<run>/.

    harness/run.py ios-sim conformance fixtures native
    harness/run.py ios-device all --profile local          # a connected iPhone
    harness/run.py android-emu all --profile local
    harness/run.py ios-sim river --profile gateway --gateway "127.0.0.1:31337,<hex>"
    harness/run.py android-emu startup --cold      # reboot first: startup after a reboot

The app runs the scenario itself (see ios/AppKitDemo/Harness.swift and the
Android Harness.kt), writes <scenario>.json and exits. This script launches
it, collects the file and records the host-side measurements: launch time,
package size and installed size.
"""

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUNDLE_ID = "org.freenet.appkit.demo"
ANDROID_ACTIVITY = f"{BUNDLE_ID}/.MainActivity"
SDK = pathlib.Path(os.environ.get("ANDROID_SDK_ROOT", pathlib.Path.home() / "Library/Android/sdk"))
ADB = str(SDK / "platform-tools/adb")
SCENARIOS = ["conformance", "fixtures", "native", "startup", "lifecycle", "bridge", "river", "atlas", "storage"]
TIMEOUTS = {"conformance": 240, "native": 300, "river": 300, "atlas": 300, "resume": 300, "watch": 400,
            "wasm_instances": 600, "transition": 660, "offline_start": 660, "cellular_start": 660}


# --- Actions during a scenario -------------------------------------------
#
# Each runs on a thread while the app runs the scenario, and records what it
# did and when, so the result can be lined up with the app's own timeline.

def during_action(args, device):
    """Return a function that performs --during on `device`, or None."""
    if not args.during:
        return None
    log = []

    def note(what):
        log.append({"at_ms": time.time() * 1000, "action": what})

    def wait(seconds):
        time.sleep(seconds)

    def ios_resume():
        wait(args.during_delay)
        note("open Settings: the demo moves to the background")
        sh(["xcrun", "simctl", "launch", device, "com.apple.Preferences"], check=False)
        wait(args.during_hold)
        note("open the demo again")
        sh(["xcrun", "simctl", "launch", device, BUNDLE_ID], check=False)

    def ios_device_resume():
        wait(args.during_delay)
        note("open Settings: the demo moves to the background")
        sh(["xcrun", "devicectl", "device", "process", "launch", "--device", device, "com.apple.Preferences"],
           check=False)
        wait(args.during_hold)
        note("open the demo again")
        sh(["xcrun", "devicectl", "device", "process", "launch", "--device", device, "--activate", BUNDLE_ID],
           check=False)

    def android_resume():
        wait(args.during_delay)
        note("home: the demo moves to the background")
        adb(device, "shell", "input", "keyevent", "KEYCODE_HOME", check=False)
        wait(args.during_hold)
        note("open the demo again")
        adb(device, "shell", "am", "start", "-n", ANDROID_ACTIVITY, check=False)

    def android_wifi_toggle():
        wait(args.during_delay)
        note("wifi off: traffic moves to the emulated cellular network")
        adb(device, "shell", "svc", "wifi", "disable", check=False)
        wait(args.during_hold)
        note("wifi on")
        adb(device, "shell", "svc", "wifi", "enable", check=False)

    def android_offline():
        wait(args.during_delay)
        note("wifi and cellular off")
        adb(device, "shell", "svc", "wifi", "disable", check=False)
        adb(device, "shell", "svc", "data", "disable", check=False)
        wait(args.during_hold)
        note("wifi and cellular on")
        adb(device, "shell", "svc", "data", "enable", check=False)
        adb(device, "shell", "svc", "wifi", "enable", check=False)

    actions = {
        ("ios-sim", "resume"): ios_resume,
        ("ios-device", "resume"): ios_device_resume,
        ("android-emu", "resume"): android_resume,
        ("android-device", "resume"): android_resume,
        ("android-emu", "wifi-toggle"): android_wifi_toggle,
        ("android-emu", "offline"): android_offline,
        ("android-device", "wifi-toggle"): android_wifi_toggle,
        ("android-device", "offline"): android_offline,
    }
    action = actions.get((args.target, args.during))
    if action is None:
        sys.exit(f"--during {args.during} is not available on {args.target}")

    def run():
        thread = threading.Thread(target=action, daemon=True)
        thread.start()
        return thread, log

    return run


def sh(cmd, **kw):
    kw.setdefault("check", True)
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    return subprocess.run(cmd, **kw)


# --- iOS -----------------------------------------------------------------

def ios_sim_udid(name):
    devices = json.loads(sh(["xcrun", "simctl", "list", "devices", "available", "-j"]).stdout)["devices"]
    booted, named = None, None
    for runtime, entries in devices.items():
        for d in entries:
            if name and d["name"] == name and "iOS" in runtime:
                named = named or d
            if d["state"] == "Booted" and "iOS" in runtime:
                booted = booted or d
    chosen = named or booted
    if not chosen:
        sys.exit("no iOS simulator found; pass --device")
    return chosen["udid"], chosen["name"]


def ios_sim_boot(udid):
    sh(["xcrun", "simctl", "boot", udid], check=False)
    sh(["xcrun", "simctl", "bootstatus", udid, "-b"])


def ios_app_path(config, sdk):
    return ROOT / f"build/ios/DerivedData/Build/Products/{config}-{sdk}/AppKitDemo.app"


def dir_bytes(path):
    return sum(f.stat().st_size for f in pathlib.Path(path).rglob("*") if f.is_file())


def ios_sim_run(args, scenario, udid, run_dir):
    launch_args = ["-appkit.scenario", scenario, "-appkit.exitWhenDone", "YES", "-appkit.profile", args.profile,
                   "-appkit.alerts", "granted"]
    if args.gateway:
        launch_args += ["-appkit.gateway", args.gateway]
    if args.backend:
        launch_args += ["-appkit.backend", args.backend]
    if args.watch_seconds:
        launch_args += ["-appkit.watchSeconds", str(args.watch_seconds)]
    during = during_action(args, udid)
    thread, actions = during() if during else (None, [])
    started = time.time()
    proc = subprocess.run(
        ["xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", udid, BUNDLE_ID, *launch_args],
        capture_output=True, text=True, timeout=TIMEOUTS.get(scenario, 180))
    wall = time.time() - started
    (run_dir / f"{scenario}.log").write_text(proc.stdout + proc.stderr)
    container = sh(["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"]).stdout.strip()
    result_file = pathlib.Path(container) / "Documents/appkit-results" / f"{scenario}.json"
    if not result_file.exists():
        return {"scenario": scenario, "error": "the app wrote no result", "passed": False}
    result = json.loads(result_file.read_text())
    if thread:
        thread.join(timeout=5)
    result["host"] = {"wall_s": wall, "actions": actions}
    return result


def ios_device_udid(name):
    out = ROOT / "harness/.run/devices.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    sh(["xcrun", "devicectl", "list", "devices", "--json-output", str(out)])
    for d in json.loads(out.read_text())["result"]["devices"]:
        hw, props = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
        tunnel = d.get("connectionProperties", {}).get("tunnelState")
        if hw.get("reality") != "physical" or hw.get("platform") != "iOS" or tunnel != "connected":
            continue
        if name and name not in (props.get("name"), hw.get("marketingName"), hw.get("udid")):
            continue
        return hw["udid"], hw.get("marketingName") or props.get("name", "iphone")
    sys.exit("no connected iPhone; connect and unlock it, or pass --device <name>")


def ios_device_run(args, scenario, udid, run_dir):
    launch_args = ["-appkit.scenario", scenario, "-appkit.exitWhenDone", "YES", "-appkit.profile", args.profile,
                   "-appkit.alerts", "granted"]
    if args.gateway:
        launch_args += ["-appkit.gateway", args.gateway]
    if args.backend:
        launch_args += ["-appkit.backend", args.backend]
    if args.watch_seconds:
        launch_args += ["-appkit.watchSeconds", str(args.watch_seconds)]
    during = during_action(args, udid)
    thread, actions = during() if during else (None, [])
    started = time.time()
    proc = subprocess.run(
        ["xcrun", "devicectl", "device", "process", "launch", "--device", udid, "--terminate-existing",
         "--console", BUNDLE_ID, "--", *launch_args],
        capture_output=True, text=True, timeout=TIMEOUTS.get(scenario, 180) + 60)
    wall = time.time() - started
    (run_dir / f"{scenario}.log").write_text(proc.stdout + proc.stderr)
    result = None
    for line in proc.stdout.splitlines():
        if line.startswith("APPKIT_RESULT "):
            result = json.loads(line[len("APPKIT_RESULT "):])
    if result is None:
        local = run_dir / f".{scenario}.device.json"
        subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", udid,
                        "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
                        "--source", f"Documents/appkit-results/{scenario}.json", "--destination", str(local)],
                       capture_output=True, text=True)
        if local.exists():
            candidate = json.loads(local.read_text())
            local.unlink()
            if candidate.get("started_at_ms", 0) >= started * 1000 - 5000:
                result = candidate
    if result is None:
        return {"scenario": scenario, "error": "the app wrote no result", "passed": False}
    if thread:
        thread.join(timeout=5)
    result["host"] = {"wall_s": wall, "actions": actions}
    return result


# --- Android -------------------------------------------------------------

def adb(serial, *cmd, **kw):
    return sh([ADB, "-s", serial, *cmd], **kw)


def android_serial(serial):
    if serial:
        return serial
    out = sh([ADB, "devices"]).stdout.splitlines()[1:]
    devices = [line.split()[0] for line in out if line.strip().endswith("device")]
    if not devices:
        sys.exit("no Android device or emulator is connected")
    return devices[0]


def android_run(args, scenario, serial, run_dir):
    adb(serial, "logcat", "-c", check=False)
    extras = ["--es", "appkit.scenario", scenario, "--ez", "appkit.exitWhenDone", "true",
              "--es", "appkit.profile", args.profile, "--es", "appkit.alerts", "granted"]
    if args.gateway:
        extras += ["--es", "appkit.gateway", args.gateway]
    if args.backend:
        extras += ["--es", "appkit.backend", args.backend]
    if args.watch_seconds:
        extras += ["--ei", "appkit.watchSeconds", str(args.watch_seconds)]
    during = during_action(args, serial)
    external = f"/sdcard/Android/data/{BUNDLE_ID}/files/appkit-results/{scenario}.json"
    internal = f"files/appkit-results/{scenario}.json"
    adb(serial, "shell", "rm", "-f", external, check=False)
    adb(serial, "shell", "run-as", BUNDLE_ID, "rm", "-f", internal, check=False)
    started = time.time()
    launch = adb(serial, "shell", "am", "start", "-W", "-S", "-n", ANDROID_ACTIVITY, *extras).stdout
    launch_times = dict(re.findall(r"^(\w+): (\d+)", launch, re.M))
    thread, actions = during() if during else (None, [])
    deadline = started + TIMEOUTS.get(scenario, 180)
    result = None
    while time.time() < deadline:
        pid = adb(serial, "shell", "pidof", BUNDLE_ID, check=False).stdout.strip()
        got = adb(serial, "exec-out", "cat", external, check=False)
        if got.returncode != 0 or not got.stdout.strip().startswith("{"):
            got = adb(serial, "exec-out", "run-as", BUNDLE_ID, "cat", internal, check=False)
        if got.returncode == 0 and got.stdout.strip().startswith("{"):
            try:
                result = json.loads(got.stdout)
                if not pid or result.get("finished_at_ms"):
                    break
            except json.JSONDecodeError:
                pass
        time.sleep(1)
    log = adb(serial, "logcat", "-d", "-s", "AppKitDemo:*", "AppKitHarness:*", "freenet:*", check=False).stdout
    (run_dir / f"{scenario}.log").write_text(launch + "\n" + log)
    if result is None:
        return {"scenario": scenario, "error": "the app wrote no result", "passed": False}
    if thread:
        thread.join(timeout=5)
    result["host"] = {"wall_s": time.time() - started, "am_start": launch_times, "actions": actions}
    return result


def android_package_size(serial):
    paths = adb(serial, "shell", "pm", "path", BUNDLE_ID, check=False).stdout
    sizes = {}
    for line in paths.splitlines():
        apk = line.replace("package:", "").strip()
        out = adb(serial, "shell", "stat", "-c", "%s", apk, check=False).stdout.strip()
        if out.isdigit():
            sizes[pathlib.PurePosixPath(apk).name] = int(out)
    stats = adb(serial, "shell", "dumpsys", "diskstats", check=False).stdout
    return {"apk_bytes": sizes}


# --- main ----------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("target", choices=["ios-sim", "ios-device", "android-emu", "android-device"])
    parser.add_argument("scenarios", nargs="+")
    parser.add_argument("--profile", default="local", choices=["local", "gateway", "public"])
    parser.add_argument("--gateway", help="ip:port,public-key-hex for the gateway profile")
    parser.add_argument("--backend", choices=["cranelift", "pulley"])
    parser.add_argument("--device", help="iOS simulator or iPhone name (default: iPhone 17, or the connected iPhone)")
    parser.add_argument("--serial", help="adb serial")
    parser.add_argument("--config", default="Release", choices=["Debug", "Release"])
    parser.add_argument("--cold", action="store_true", help="reboot the device before the first scenario")
    parser.add_argument("--fresh", action="store_true", help="uninstall first: an empty store, as after install")
    parser.add_argument("--label", help="suffix for the results folder")
    parser.add_argument("--watch-seconds", type=int, help="duration of the watch scenario")
    parser.add_argument("--during", choices=["resume", "wifi-toggle", "offline"],
                        help="act on the device while the scenario runs")
    parser.add_argument("--during-delay", type=float, default=25, help="seconds before the action")
    parser.add_argument("--during-hold", type=float, default=20, help="seconds the action lasts")
    args = parser.parse_args()
    scenarios = SCENARIOS if args.scenarios == ["all"] else args.scenarios

    stamp = dt.datetime.now().strftime("%Y-%m-%d")
    results = []
    if args.target == "ios-device":
        udid, name = ios_device_udid(args.device)
        app = ios_app_path(args.config, "iphoneos")
        if not app.exists():
            sys.exit(f"{app} is missing; run DEVELOPMENT_TEAM=<team> harness/build-ios-app.sh {args.config} device")
        if args.fresh:
            sh(["xcrun", "devicectl", "device", "uninstall", "app", "--device", udid, BUNDLE_ID], check=False)
        sh(["xcrun", "devicectl", "device", "install", "app", "--device", udid, str(app)])
        label = f"{stamp}-ios-device-{name.replace(' ', '-').lower()}"
        package = {"app_bytes": dir_bytes(app), "config": args.config}
        run = lambda s, d: ios_device_run(args, s, udid, d)
    elif args.target == "ios-sim":
        udid, name = ios_sim_udid(args.device or "iPhone 17")
        if args.cold:
            sh(["xcrun", "simctl", "shutdown", udid], check=False)
        ios_sim_boot(udid)
        app = ios_app_path(args.config, "iphonesimulator")
        if not app.exists():
            sys.exit(f"{app} is missing; run harness/build-ios-app.sh {args.config}")
        if args.fresh:
            sh(["xcrun", "simctl", "uninstall", udid, BUNDLE_ID], check=False)
        sh(["xcrun", "simctl", "install", udid, str(app)])
        label = f"{stamp}-ios-sim-{name.replace(' ', '-').lower()}"
        package = {"app_bytes": dir_bytes(app), "config": args.config}
        run = lambda s, d: ios_sim_run(args, s, udid, d)
    else:
        serial = android_serial(args.serial)
        if args.cold:
            adb(serial, "reboot")
            adb(serial, "wait-for-device")
            while adb(serial, "shell", "getprop", "sys.boot_completed", check=False).stdout.strip() != "1":
                time.sleep(2)
        model = adb(serial, "shell", "getprop", "ro.product.model").stdout.strip()
        abi = adb(serial, "shell", "getprop", "ro.product.cpu.abi").stdout.strip()
        out_dir = ROOT / f"android/demo/build/outputs/apk/{args.config.lower()}"
        apk = out_dir / f"demo-{abi}-{args.config.lower()}.apk"
        if not apk.exists():
            apk = out_dir / f"demo-universal-{args.config.lower()}.apk"
        if not apk.exists():
            sys.exit(f"{apk} is missing; run harness/build-android-app.sh {args.config}")
        if args.fresh:
            adb(serial, "uninstall", BUNDLE_ID, check=False)
        adb(serial, "install", "-r", "-t", str(apk))
        label = f"{stamp}-{args.target}-{model.replace(' ', '-').lower()}"
        package = {"apk_file_bytes": apk.stat().st_size, "config": args.config, **android_package_size(serial)}
        run = lambda s, d: android_run(args, s, serial, d)

    if args.label:
        label += f"-{args.label}"
    run_dir = ROOT / "results" / label
    run_dir.mkdir(parents=True, exist_ok=True)
    for scenario in scenarios:
        print(f"==> {scenario}", flush=True)
        result = run(scenario, run_dir)
        result.setdefault("scenario", scenario)
        result["harness"] = {"profile": args.profile, "cold": args.cold and scenario == scenarios[0],
                             "fresh_install": args.fresh,
                             "config": args.config, "package": package, "during": args.during}
        name = scenario + (f"-{args.during}" if args.during else "")
        (run_dir / f"{name}.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        status = "passed" if result.get("passed") else ("failed" if "passed" in result else "recorded")
        print(f"    {status}" + (f": {result['error']}" if result.get("error") else ""), flush=True)
        results.append(result)
    print(f"results in {run_dir.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
