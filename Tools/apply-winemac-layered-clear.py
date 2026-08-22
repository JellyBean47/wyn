#!/usr/bin/env python3
"""Apply layered→non-layered clear to frankea winemac.so CreateWindowSurface.

When CreateWindowSurface(..., layered=FALSE) runs, stock frankea only skips setting
layered|ulw_layered — stale bits from splash ULW remain. This patch:

  if (layered) data->flags |= layered|ulw_layered;          /* OR 0x0c */
  else         data->flags &= ~(layered|ulw_layered);       /* AND 0xf3 */

Does **not** clear per_pixel_alpha in the bitfield (that needs sync_window_opacity /
Cocoa); clearing 0x10 here stalled StartView in one A/B. Cocoa sync still via
present_force_inject PRESENT_FORCE_OPAQUE=1 when safe.

Usage:
  python3 Tools/apply-winemac-layered-clear.py
  python3 Tools/apply-winemac-layered-clear.py --restore

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
    "~/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/lib/wine/x86_64-unix/winemac.so"
)
BAK_SUFFIX = ".pre-layered-clear.bak"
WORK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin")

# CreateWindowSurface: test r13d / je+4 / or [rax+0x58],0xc
PATCH_AT = 0x35AE9
ORIG = bytes([0x45, 0x85, 0xED, 0x74, 0x04, 0x80, 0x48, 0x58, 0x0C])
# call cave + 4 nops (preserves following mov [rbp-0x60],rax @ 0x35af2)
CAVE_VA = 0x4E680


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


def build_cave() -> bytes:
    # test r13d,r13d; jz clear; or [rax+0x58],0xc; ret; and [rax+0x58],0xf3; ret
    return bytes(
        [
            0x45,
            0x85,
            0xED,
            0x74,
            0x05,
            0x80,
            0x48,
            0x58,
            0x0C,
            0xC3,
            0x80,
            0x60,
            0x58,
            0xF3,
            0xC3,
        ]
    )


def apply(data: bytearray) -> None:
    expect(data, PATCH_AT, ORIG, "CreateWindowSurface layered test/or")
    # slack should be zeros or unwind padding — require mostly zero
    cave = build_cave()
    pad = bytes(data[CAVE_VA : CAVE_VA + 64])
    if any(b not in (0x00, 0x90) for b in pad[: len(cave)]):
        # allow re-apply if cave already ours
        if pad[: len(cave)] != cave:
            raise SystemExit(f"UNEXPECTED cave pad @ {hex(CAVE_VA)}: {pad[:32].hex()}")

    data[CAVE_VA : CAVE_VA + len(cave)] = cave
    rel = CAVE_VA - (PATCH_AT + 5)
    call = bytes([0xE8]) + struct.pack("<i", rel) + bytes([0x90, 0x90, 0x90, 0x90])
    assert len(call) == 9
    data[PATCH_AT : PATCH_AT + 9] = call


def already_patched(data: bytes) -> bool:
    return data[PATCH_AT] == 0xE8 and bytes(data[CAVE_VA : CAVE_VA + 15]) == build_cave()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--restore", action="store_true")
    args = ap.parse_args()

    live = real_live()
    bak = live + BAK_SUFFIX
    os.makedirs(WORK_DIR, exist_ok=True)
    work = os.path.join(WORK_DIR, "winemac.layered-clear.so")

    if args.restore:
        if not os.path.isfile(bak):
            raise SystemExit(f"no bak at {bak}")
        shutil.copy2(bak, live)
        codesign(live)
        print(f"restored: {live} {sha256(live)}")
        return

    if not os.path.isfile(bak):
        shutil.copy2(live, bak)
        print(f"backup: {bak} {sha256(bak)}")
    else:
        print(f"backup exists: {bak} {sha256(bak)}")

    data = bytearray(open(bak, "rb").read())
    if already_patched(bytes(open(live, "rb").read())):
        # re-derive from bak for idempotent clean apply
        pass
    apply(data)

    open(work, "wb").write(data)
    codesign(work)
    shutil.copy2(work, live)
    codesign(live)
    print(f"installed: {live} {sha256(live)}")
    print(f"work copy: {work}")
    print("OK — kill frankea wineserver before launching Connect")


if __name__ == "__main__":
    main()
