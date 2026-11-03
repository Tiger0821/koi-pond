#!/usr/bin/env python3
"""Measures what the desktop pond costs (CPU, memory, GPU, power and battery) with few and many animals.

Quits Koi Pond if it's running, runs each setup with `--try-settings` (nothing is saved, and the lock
screen and screen saver are left alone), then opens Koi Pond again. Takes about twenty minutes; keep the
Mac on battery and leave it alone meanwhile, since everything else running shows up in the power figures.

    python3 -I scripts/measure-usage.py [--seconds 180] [--out results.json]
"""
import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build/KoiPond.app"
EXE = APP / "Contents/MacOS/KoiPond"
LOG = Path.home() / "Library/Logs/KoiPond.log"
DOMAIN = "com.koifishwallpaper.koipond"

COUNT_KEYS = ["koiCount", "smallFishCount", "turtleCount", "lilyPadCount", "flowerCount", "plantCount"]
DEFAULT_COUNTS = [12, 24, 1, 14, 5, 18]  # PondSettings defaults
LOW = dict(zip(COUNT_KEYS, [2, 0, 0, 2, 0, 2]))
HIGH = dict(zip(COUNT_KEYS, [40, 60, 4, 40, 15, 60]))  # the Settings sliders' maxima


def output(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def user_settings():
    exported = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True).stdout
    try:
        return json.loads(plistlib.loads(exported)["PondSettings"])
    except Exception:
        return {}


def cpu_seconds(pid):
    text = output("ps", "-o", "time=", "-p", str(pid)).strip()
    if not text:
        return None
    total = 0.0
    for part in text.split(":"):
        total = total * 60 + float(part)
    return total


def battery():
    """The battery gauge's running total of whole-Mac power (mW, summed once a second), which it publishes
    about once a minute."""
    try:
        info = plistlib.loads(subprocess.run(["ioreg", "-rn", "AppleSmartBattery", "-a"], capture_output=True).stdout)[0]
        telemetry = info["PowerTelemetryData"]
        return {
            "on_battery": not info.get("ExternalConnected", True),
            "load_total": telemetry["AccumulatedSystemLoad"],
            "load_count": telemetry["SystemLoadAccumulatorCount"],
            # Mac laptop batteries are three cells in series, about 11.45 V nominal.
            "capacity_wh": info.get("BatteryData", {}).get("FullChargeCapacity", 0) / 1000 * 11.45,
        }
    except Exception:
        return None


def average_power(readings):
    """Mean whole-Mac watts between the first and last gauge updates published during the measurement.
    The reading already there at the start is skipped: it covers the minute before, which may be the
    previous setup."""
    updates = []
    for reading in readings:
        key = (reading["load_total"], reading["load_count"])
        if not updates or updates[-1] != key:
            updates.append(key)
    updates = updates[1:]
    if len(updates) < 2 or updates[-1][1] == updates[0][1]:
        return None, 0
    return (updates[-1][0] - updates[0][0]) / (updates[-1][1] - updates[0][1]) / 1000, updates[-1][1] - updates[0][1]


def gpu_busy():
    match = re.search(r'"Device Utilization %"=(\d+)', output("ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"))
    return int(match.group(1)) if match else None


def footprint_mb(pid):
    """Current and peak physical footprint, the figure Activity Monitor shows as Memory."""
    found = {peak: float(n) * {"K": 1 / 1024, "M": 1, "G": 1024}[unit] for peak, n, unit in
             re.findall(r"Physical footprint( \(peak\))?:\s+([\d.]+)([KMG])", output("vmmap", "-summary", str(pid)))}
    return found.get(""), found.get(" (peak)")


def parse_top(text, pids):
    """Per-process (cpu %, memory MB, energy impact) samples and whole-Mac busy %, minus top's first sample,
    which has no interval behind it."""
    samples = {pid: [] for pid in pids}
    busy = []
    for line in text.splitlines():
        match = re.match(r"CPU usage: ([\d.]+)% user, ([\d.]+)% sys", line)
        if match:
            busy.append(float(match.group(1)) + float(match.group(2)))
            continue
        match = re.match(r"(\d+)\s+([\d.]+)\s+([\d.]+)([BKMG])[+-]?\s+([\d.]+)$", line.strip())
        if match and int(match.group(1)) in samples:
            mb = float(match.group(3)) * {"B": 1 / 2**20, "K": 1 / 1024, "M": 1, "G": 1024}[match.group(4)]
            samples[int(match.group(1))].append((float(match.group(2)), mb, float(match.group(5))))
    return {pid: values[1:] for pid, values in samples.items()}, busy[1:]


def mean(values):
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else None


def measure(seconds, interval, pond_pid):
    window_server = int(output("pgrep", "-x", "WindowServer").split()[0])
    pids = [window_server] + ([pond_pid] if pond_pid else [])
    top_args = ["top", "-l", str(seconds // interval + 1), "-s", str(interval), "-stats", "pid,cpu,mem,power"]
    for pid in pids:
        top_args += ["-pid", str(pid)]
    start_cpu = {pid: cpu_seconds(pid) for pid in pids}
    started = time.monotonic()
    power, gpu = [], []
    with tempfile.TemporaryFile("w+") as top_out:
        top = subprocess.Popen(top_args, stdout=top_out, text=True)
        while top.poll() is None:
            power.append(battery())
            gpu.append(gpu_busy())
            time.sleep(2)
        top_out.seek(0)
        tops, busy = parse_top(top_out.read(), pids)
    elapsed = time.monotonic() - started
    end_cpu = {pid: cpu_seconds(pid) for pid in pids}

    def cpu_pct(pid):
        if start_cpu[pid] is None or end_cpu[pid] is None:
            return None
        return (end_cpu[pid] - start_cpu[pid]) / elapsed * 100

    power = [p for p in power if p]
    watts, covered = average_power(power)
    result = {
        "seconds": round(elapsed, 1),
        "mac_cpu_busy_pct": mean(busy),
        "gpu_busy_pct": mean(gpu),
        "on_battery": bool(power) and all(p["on_battery"] for p in power),
        "power_w": watts,
        "power_seconds_covered": covered,
        "battery_capacity_wh": power[0]["capacity_wh"] if power else None,
        "window_server_cpu_pct": cpu_pct(window_server),
    }
    if pond_pid:
        samples = tops[pond_pid]
        now, peak = footprint_mb(pond_pid)
        result.update({
            "pond_cpu_pct": cpu_pct(pond_pid),
            "pond_memory_mb": mean([s[1] for s in samples]),
            "pond_memory_end_mb": now,
            "pond_memory_peak_mb": peak,
            "pond_energy_impact": mean([s[2] for s in samples]),
        })
    return result


def frame_rate_logged(since):
    if not LOG.exists():
        return None
    with LOG.open("rb") as log:
        log.seek(since)
        rates = re.findall(rb"moving at (\d+) fps", log.read())
    return int(rates[-1]) if rates else None


def run_setup(name, settings, args, folder):
    pond = None
    log_start = LOG.stat().st_size if LOG.exists() else 0
    if settings is not None:
        path = Path(folder) / (re.sub(r"\W+", "-", name) + ".json")
        path.write_text(json.dumps(settings))
        pond = subprocess.Popen([str(EXE), "--try-settings", str(path)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"{name}: warming up {args.warmup} s, then measuring {args.seconds} s", flush=True)
    try:
        time.sleep(args.warmup)
        if pond and pond.poll() is not None:
            sys.exit(f"Koi Pond quit during '{name}'; see {LOG}")
        result = measure(args.seconds, args.interval, pond.pid if pond else None)
    finally:
        if pond:
            pond.terminate()
            pond.wait(timeout=10)
    result["setup"] = name
    if settings is not None:
        counts = [settings.get(k, d) for k, d in zip(COUNT_KEYS, DEFAULT_COUNTS)]
        result["counts"] = dict(zip(COUNT_KEYS, counts))
        result["entities"] = sum(counts)
        result["fps"] = frame_rate_logged(log_start)
    time.sleep(3)
    return result


def show(value, digits=1, suffix=""):
    return "–" if value is None else f"{value:.{digits}f}{suffix}"


def report(results):
    idle = mean([r["power_w"] for r in results if "entities" not in r])
    idle_gpu = mean([r["gpu_busy_pct"] for r in results if "entities" not in r])
    idle_ws = mean([r["window_server_cpu_pct"] for r in results if "entities" not in r])
    capacity = next((r["battery_capacity_wh"] for r in results if r["battery_capacity_wh"]), None)
    rows = [["Setup", "Animals+plants", "FPS", "Pond CPU", "WindowServer +CPU", "GPU +busy", "Pond memory",
             "Energy impact", "Power", "+Power", "Battery life"]]
    for r in results:
        pond = "entities" in r
        extra = r["power_w"] - idle if pond and r["power_w"] is not None and idle is not None else None
        life = capacity / r["power_w"] if capacity and r["power_w"] and r["on_battery"] else None
        rows.append([
            r["setup"],
            str(r["entities"]) if pond else "–",
            str(r["fps"] or "–") if pond else "–",
            show(r.get("pond_cpu_pct"), suffix="%"),
            show(r["window_server_cpu_pct"] - idle_ws if pond and idle_ws is not None else None, suffix="%"),
            show(r["gpu_busy_pct"] - idle_gpu if pond and idle_gpu is not None else None, 0, "%"),
            f"{show(r.get('pond_memory_mb'), 0)} MB" if pond else "–",
            show(r.get("pond_energy_impact")),
            show(r["power_w"], 2, " W"),
            show(extra, 2, " W"),
            show(life, 1, " h"),
        ])
    widths = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    for i, row in enumerate(rows):
        print("  ".join(cell.ljust(width) for cell, width in zip(row, widths)))
        if i == 0:
            print("  ".join("-" * width for width in widths))
    if capacity:
        print(f"\nBattery life is the full battery ({capacity:.0f} Wh now) divided by the power measured, "
              f"so it assumes the Mac stays as idle as during the test.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seconds", type=int, default=180,
                        help="measuring time per setup; the power gauge updates once a minute, so keep it over 150")
    parser.add_argument("--warmup", type=int, default=20, help="settling time before each measurement")
    parser.add_argument("--interval", type=int, default=5, help="seconds between top samples")
    parser.add_argument("--out", type=Path, help="also write the results as JSON")
    args = parser.parse_args()
    if not EXE.exists():
        sys.exit("Build the app first: scripts/build-app.sh")

    base = {**user_settings(), "paused": False}
    setups = [
        ("Idle, no pond", None),
        ("Low", {**base, **LOW}),
        ("Your counts", base),
        ("High", {**base, **HIGH}),
        ("High, 120 fps", {**base, **HIGH, "onBattery": "keepRunning", "frameRate": 120}),
        ("Idle again", None),
    ]
    # Keep the display awake for the whole run; a sleeping display rests the pond.
    subprocess.Popen(["caffeinate", "-di", "-w", str(os.getpid())])
    was_running = bool(output("pgrep", "-x", "KoiPond").strip())
    subprocess.run(["pkill", "-x", "KoiPond"])
    while output("pgrep", "-x", "KoiPond").strip():
        time.sleep(0.5)
    results = []
    try:
        with tempfile.TemporaryDirectory() as folder:
            for name, settings in setups:
                results.append(run_setup(name, settings, args, folder))
    finally:
        if was_running:
            subprocess.run(["open", str(APP)])
    print()
    report(results)
    if args.out:
        args.out.write_text(json.dumps(results, indent=2))
        print(f"Results written to {args.out}")


if __name__ == "__main__":
    main()
