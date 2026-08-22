#!/usr/bin/env python3
"""Apply Tools/win32u-shm-present-force-flush.patch.md as a reversible binary patch
to frankea Libraries.steam win32u.so (no Wine rebuild required).

Edits (Mach-O x86_64 frankea wine-11.0 / HACK 23950):
  1) shm_surface_flush SMTO: flags 3→1 (drop ABORTIFHUNG), timeout 500→5000
  2) process_surface_message success path → trampoline → flush_window_surfaces(TRUE)

Usage:
  python3 Tools/apply-win32u-shm-force-flush.py          # apply full patch
  python3 Tools/apply-win32u-shm-force-flush.py --smto   # SMTO only (no flush cave)
  python3 Tools/apply-win32u-shm-force-flush.py --restore

Kill frankea wineserver before replacing the .so.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys

LIVE = os.path.expanduser(
    "~/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/lib/wine/x86_64-unix/win32u.so"
)
BAK_SUFFIX = ".pre-force-flush.bak"
WORK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin")


def real_live() -> str:
    return os.path.realpath(LIVE)


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def codesign(path: str) -> None:
    subprocess.check_call(["codesign", "-s", "-", "--force", path])


def expect(data: bytearray, off: int, want: bytes, label: str) -> None:
    got = bytes(data[off : off + len(want)])
    if got != want:
        raise SystemExit(f"UNEXPECTED {label} @ {hex(off)}: got {got.hex()} want {want.hex()}")


def apply_smto(data: bytearray) -> None:
    expect(
        data,
        0x1A87E,
        bytes([0x41, 0xB8, 0x03, 0x00, 0x00, 0x00, 0x41, 0xB9, 0xF4, 0x01, 0x00, 0x00]),
        "SMTO mov r8d,3 / r9d,500",
    )
    data[0x1A880] = 0x01  # SMTO_BLOCK only
    data[0x1A886:0x1A88A] = struct.pack("<I", 5000)


def apply_flush_cave(data: bytearray) -> None:
    expect(data, 0x16DD6, bytes([0xEB, 0x26]), "PSM short jmp to epilogue")
    expect(data, 0x16E0B, bytes([0x0F, 0x1F, 0x44, 0x00, 0x00]), "5-byte nop gap")
    if data[0x17661] != 0x66:
        raise SystemExit(f"UNEXPECTED cave pad @ 0x17661: {data[0x17661:0x17670].hex()}")

    # success path → trampoline @ 0x16e0b
    data[0x16DD7] = 0x33
    # trampoline → cave @ 0x17661
    data[0x16E0B:0x16E10] = bytes([0xE9]) + struct.pack("<i", 0x17661 - (0x16E0B + 5))
    # cave: mov edi,1; call flush_window_surfaces@0x175e0; jmp epilogue@0x16dfe
    cave = bytearray([0xBF, 0x01, 0x00, 0x00, 0x00])
    cave += bytes([0xE8]) + struct.pack("<i", 0x175E0 - (0x17666 + 5))
    cave += bytes([0xE9]) + struct.pack("<i", 0x16DFE - (0x1766B + 5))
    assert len(cave) == 15
    data[0x17661:0x17670] = cave


def install(data: bytes, work_name: str) -> None:
    live = real_live()
    bak = live + BAK_SUFFIX
    os.makedirs(WORK_DIR, exist_ok=True)
    work = os.path.join(WORK_DIR, work_name)
    with open(work, "wb") as f:
        f.write(data)
    if not os.path.exists(bak):
        shutil.copy2(live, bak)
        print("backup:", bak, sha256(bak))
    else:
        print("backup exists:", bak, sha256(bak))
    tmp = live + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.chmod(tmp, 0o755)
    codesign(tmp)
    os.replace(tmp, live)
    print("installed:", live, sha256(live))
    print("work copy:", work)


def restore() -> None:
    live = real_live()
    bak = live + BAK_SUFFIX
    if not os.path.exists(bak):
        raise SystemExit(f"no backup at {bak}")
    tmp = live + ".tmp"
    shutil.copy2(bak, tmp)
    codesign(tmp)
    os.replace(tmp, live)
    print("restored from", bak, "->", live, sha256(live))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--smto", action="store_true", help="SMTO timeout/flags only")
    ap.add_argument("--restore", action="store_true")
    args = ap.parse_args()

    if args.restore:
        restore()
        return 0

    live = real_live()
    bak = live + BAK_SUFFIX
    base = bak if os.path.exists(bak) else live
    data = bytearray(open(base, "rb").read())
    # Always patch from pristine backup bytes
    if os.path.exists(bak):
        data = bytearray(open(bak, "rb").read())

    apply_smto(data)
    name = "win32u.smto-only.so"
    if not args.smto:
        apply_flush_cave(data)
        name = "win32u.force-flush.so"
    install(bytes(data), name)
    print("OK — kill frankea wineserver before launching Connect")
    return 0


if __name__ == "__main__":
    sys.exit(main())
