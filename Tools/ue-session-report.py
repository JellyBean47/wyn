#!/usr/bin/env python3
"""Summarise what an Unreal game session actually did, from its own log.

Written because a two-hour Solarpunk session that felt fine was in fact running
on the wrong translation layer, and nothing said so. The profile asked for
D3DMetal; the game ran on DXVK, because Steam had been started on the frankea
Wine tree and the game landed in that wineserver. The only place that fact
existed was one line of the game's log.

So the first thing this prints is which layer really ran. The two identify
themselves by the fake adapter they present:

    D3DMetal  ->  "AMD Compatibility Mode"    VendorId 0x1002
    DXVK      ->  "NVIDIA GeForce 6800"       VendorId 0x10de

Everything after that is the measurement you need to compare one run against
another: frame rate over time, the resolution actually being rendered, and
whether anything is capping the frame rate. Numbers from two runs are only
comparable if they were produced the same way, which is the whole reason this
is a script and not a pile of greps.

Usage:
    Tools/ue-session-report.py <path to Game.log>
    Tools/ue-session-report.py <path to Game.log> --dxvk <path to dxvk.log>

Frame rate is derived from UE's own log prefix, `[timestamp][frame]`. It is a
sampling estimate, not an instrumented counter: it measures the frames the
engine advanced between two log lines. Over a long session with steady logging
that tracks real frame rate closely; over a quiet minute it has little to go
on, so minutes with under 20 seconds of covered time are dropped rather than
reported as though they meant something.
"""

from __future__ import annotations

import argparse
import collections
import os
import re
import sys

# UE log line prefix: [2026.09.04-18.11.57:343][  0]
PREFIX = re.compile(
    r"^\[(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2}):(\d{3})\]\[\s*(\d+)\]"
)

# The adapter each translation layer pretends to be.
LAYER_BY_VENDOR = {
    "1002": "D3DMetal (Apple GPTK)",
    "10de": "DXVK (DXVK-macOS -> MoltenVK -> Metal)",
    "8086": "Intel-presenting layer (unexpected here)",
}

MIN_SECONDS_PER_MINUTE_BUCKET = 20.0


def parse_frames(path):
    """Return (per-minute [(label, fps)], total frames, span seconds)."""
    buckets = collections.defaultdict(lambda: [0, 0.0])
    prev_t = prev_f = None
    first_t = last_t = None
    total = 0

    with open(path, errors="ignore") as handle:
        for line in handle:
            match = PREFIX.match(line)
            if not match:
                continue
            hh, mm, ss, ms = (int(match.group(i)) for i in (4, 5, 6, 7))
            t = hh * 3600 + mm * 60 + ss + ms / 1000.0
            frame = int(match.group(8))

            if first_t is None:
                first_t = t
            last_t = t

            if prev_t is not None:
                dt = t - prev_t
                df = frame - prev_f
                # A new level or a restarted engine resets the counter; a long
                # gap is a load screen or an idle menu. Neither is frame rate.
                if 0 < df < 10_000 and 0 < dt < 5:
                    buckets[f"{hh:02d}:{mm:02d}"][0] += df
                    buckets[f"{hh:02d}:{mm:02d}"][1] += dt
                    total += df
            prev_t, prev_f = t, frame

    rows = [
        (label, frames / seconds)
        for label, (frames, seconds) in sorted(buckets.items())
        if seconds >= MIN_SECONDS_PER_MINUTE_BUCKET
    ]
    span = (last_t - first_t) if first_t is not None else 0.0
    if span < 0:  # crossed midnight
        span += 24 * 3600
    return rows, total, span


def scan_settings(path):
    """Pull the handful of lines that say how the game was configured."""
    found = {
        "adapter": None,
        "vendor": None,
        "rhi": None,
        "setres": None,
        "screen_percentage": None,
        "cpu_gpu": None,
    }
    adapter_re = re.compile(r"Description\s*:\s*(.+?)\s*$")
    vendor_re = re.compile(r"VendorId\s*:\s*([0-9a-fA-F]{4})\b")

    with open(path, errors="ignore") as handle:
        for line in handle:
            if found["adapter"] is None and "Description" in line and "RHI" in line:
                m = adapter_re.search(line)
                if m:
                    found["adapter"] = m.group(1)
            if found["vendor"] is None and "VendorId" in line:
                m = vendor_re.search(line)
                if m:
                    found["vendor"] = m.group(1).lower()
            if found["rhi"] is None and "Using Default RHI" in line:
                found["rhi"] = line.strip().split("Using Default RHI:")[-1].strip()
            if found["setres"] is None and "r.setres" in line:
                m = re.search(r"r\.setres:(\S+?)\]", line)
                if m:
                    found["setres"] = m.group(1)
            if "r.ScreenPercentage" in line:
                m = re.search(r'r\.ScreenPercentage\s*=\s*"?(\d+)', line)
                if m:
                    found["screen_percentage"] = m.group(1)
            if found["cpu_gpu"] is None and "LogInit: OS:" in line:
                found["cpu_gpu"] = line.strip()
    return found


def read_game_user_settings(log_path):
    """GameUserSettings.ini sits two directories up from Saved/Logs."""
    saved = os.path.dirname(os.path.dirname(os.path.abspath(log_path)))
    ini = os.path.join(saved, "Config", "Windows", "GameUserSettings.ini")
    if not os.path.exists(ini):
        return None, {}
    keys = (
        "bUseVSync",
        "FrameRateLimit",
        "ResolutionSizeX",
        "ResolutionSizeY",
        "FullscreenMode",
        "sg.ResolutionQuality",
    )
    values = {}
    with open(ini, errors="ignore") as handle:
        for line in handle:
            name, _, value = line.strip().partition("=")
            if name in keys and name not in values:
                values[name] = value
    return ini, values


def describe(rows):
    """min / p25 / median / p75 / max over per-minute fps values."""
    values = sorted(value for _, value in rows)
    n = len(values)
    return (f"min {values[0]:.1f}   p25 {values[n // 4]:.1f}   "
            f"median {values[n // 2]:.1f}   p75 {values[(3 * n) // 4]:.1f}   "
            f"max {values[-1]:.1f}")


def summarise_dxvk(path):
    counts = collections.Counter()
    with open(path, errors="ignore") as handle:
        for line in handle:
            if line.startswith(("err:", "warn:")):
                counts[re.sub(r"\d+", "N", line.strip())] += 1
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log", help="the game's own UE log")
    parser.add_argument("--dxvk", help="a DXVK log to summarise alongside it")
    parser.add_argument("--timeline", action="store_true",
                        help="print fps per minute — the only way to see a setting "
                             "change mid-session")
    parser.add_argument("--split", metavar="HH:MM",
                        help="report separately either side of this UTC time. UE logs "
                             "in UTC; a South African clock is two hours ahead of it")
    args = parser.parse_args()

    if not os.path.exists(args.log):
        sys.exit(f"no such log: {args.log}")

    settings = scan_settings(args.log)

    print("== which translation layer actually ran ==")
    vendor = settings["vendor"]
    layer = LAYER_BY_VENDOR.get(vendor, "unrecognised — check the adapter name")
    print(f"  adapter : {settings['adapter'] or '(not found)'}")
    print(f"  vendor  : 0x{vendor}" if vendor else "  vendor  : (not found)")
    print(f"  => {layer}")
    if settings["rhi"]:
        print(f"  RHI     : {settings['rhi']}")
    if settings["cpu_gpu"]:
        print(f"  {settings['cpu_gpu'].split('LogInit: ')[-1]}")

    print()
    print("== frame rate ==")
    rows, total, span = parse_frames(args.log)
    print(f"  session : {span / 60:.1f} min of log timestamps")
    print(f"  frames  : {total:,} counted")
    if rows:
        print(f"  minutes : {len(rows)} with enough coverage to measure")
        print(f"  fps     : {describe(rows)}")
    else:
        print("  fps     : not enough log coverage to measure")

    if args.split and rows:
        before = [r for r in rows if r[0] < args.split]
        after = [r for r in rows if r[0] >= args.split]
        print()
        print(f"  split at {args.split} UTC:")
        print(f"    before ({len(before)} min): "
              f"{describe(before) if before else 'no coverage'}")
        print(f"    after  ({len(after)} min): "
              f"{describe(after) if after else 'no coverage'}")

    if args.timeline and rows:
        print()
        print("  per minute (UTC):")
        for label, value in rows:
            bar = "#" * int(round(value / 4))
            print(f"    {label}  {value:6.1f}  {bar}")

    print()
    print("== what it was rendering ==")
    print(f"  r.setres          : {settings['setres'] or '(not set)'}")
    print(f"  r.ScreenPercentage: {settings['screen_percentage'] or '(not set)'}")
    if settings["setres"] and settings["screen_percentage"]:
        try:
            width, height = (int(v) for v in settings["setres"].lower().split("x")[:2])
            scale = int(settings["screen_percentage"]) / 100
            print(f"  effective render  : ~{int(width * scale)}x{int(height * scale)}")
        except ValueError:
            pass

    ini, values = read_game_user_settings(args.log)
    if values:
        print(f"  GameUserSettings  : {ini}")
        for key in sorted(values):
            print(f"    {key} = {values[key]}")
        limit = values.get("FrameRateLimit")
        if limit and rows:
            try:
                if float(limit) > 0 and max(v for _, v in rows) > float(limit) * 1.1:
                    print(f"    NOTE: frames exceed FrameRateLimit={limit} — the cap is not holding")
            except ValueError:
                pass
        if values.get("bUseVSync", "").lower() == "false":
            print("    NOTE: VSync off — frames above the display refresh are heat, not smoothness")

    if args.dxvk and os.path.exists(args.dxvk):
        print()
        print("== translation-layer log noise ==")
        counts = summarise_dxvk(args.dxvk)
        total_noise = sum(counts.values())
        print(f"  {total_noise:,} err/warn lines written during the session")
        for message, count in counts.most_common(5):
            print(f"    {count:>8,}  {message[:96]}")


if __name__ == "__main__":
    main()
