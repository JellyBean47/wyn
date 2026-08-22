#!/usr/bin/env python3
"""Size-gated layered→non-layered clear for frankea winemac.so.

Stock CreateWindowSurface(layered=FALSE) never clears stale layered|ulw bits.
Global clear (§2.14) stalled StartView. This cave only clears when the new
surface is login-sized (width >= 1400), leaving splash 768×512 alone.

  if (layered) OR flags 0x0c;
  else if (surface_width >= 1400) AND flags ~0x0c;  /* clear layered|ulw */
  /* else leave flags */

surface_rect is in rdx (RECT*); width = right-left at [rdx+8]-[rdx].

Usage:
  python3 Tools/apply-winemac-layered-clear-login.py
  python3 Tools/apply-winemac-layered-clear-login.py --restore
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import struct
import subprocess

LIVE = os.path.expanduser(
    "~/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/lib/wine/x86_64-unix/winemac.so"
)
BAK_SUFFIX = ".pre-layered-clear-login.bak"
WORK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin")

PATCH_AT = 0x35AE9
ORIG = bytes([0x45, 0x85, 0xED, 0x74, 0x04, 0x80, 0x48, 0x58, 0x0C])
# Use a different cave than §2.14 (0x4e680) in case that bak still has bytes
CAVE_VA = 0x4E6A0


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
    """
    ; rax = macdrv_win_data*, r13d = layered, r14 = surface_rect* (rdx clobbered)
    test r13d, r13d
    jz   check_size
    or   byte [rax+0x58], 0x0c
    ret
    check_size:
    mov  ecx, [r14+8]      ; right
    sub  ecx, [r14]        ; width
    cmp  ecx, 1400
    jl   done
    and  byte [rax+0x58], 0xf3
    done:
    ret
    """
    return bytes(
        [
            0x45, 0x85, 0xED,          # test r13d,r13d
            0x74, 0x05,                # jz check_size
            0x80, 0x48, 0x58, 0x0C,    # or [rax+0x58],0xc
            0xC3,                      # ret
            # check_size:
            0x41, 0x8B, 0x4E, 0x08,    # mov ecx,[r14+8]
            0x41, 0x2B, 0x0E,          # sub ecx,[r14]
            0x81, 0xF9, 0x78, 0x05, 0x00, 0x00,  # cmp ecx,1400
            0x7C, 0x04,                # jl done
            0x80, 0x60, 0x58, 0xF3,    # and [rax+0x58],0xf3
            0xC3,                      # done: ret
        ]
    )


def apply(data: bytearray) -> None:
    # Prefer stock site; if §2.14 call already there, require restore first
    if data[PATCH_AT] == 0xE8:
        raise SystemExit("CreateWindowSurface already has a call cave — --restore stock winemac first")
    expect(data, PATCH_AT, ORIG, "CreateWindowSurface layered test/or")
    cave = build_cave()
    pad = bytes(data[CAVE_VA : CAVE_VA + 64])
    if any(b not in (0x00, 0x90) for b in pad[: len(cave)]):
        if pad[: len(cave)] != cave:
            raise SystemExit(f"UNEXPECTED cave pad @ {hex(CAVE_VA)}: {pad[:40].hex()}")

    data[CAVE_VA : CAVE_VA + len(cave)] = cave
    rel = CAVE_VA - (PATCH_AT + 5)
    call = bytes([0xE8]) + struct.pack("<i", rel) + bytes([0x90, 0x90, 0x90, 0x90])
    assert len(call) == 9
    data[PATCH_AT : PATCH_AT + 9] = call


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--restore", action="store_true")
    args = ap.parse_args()

    live = real_live()
    bak = live + BAK_SUFFIX
    os.makedirs(WORK_DIR, exist_ok=True)
    work = os.path.join(WORK_DIR, "winemac.layered-clear-login.so")

    if args.restore:
        if not os.path.isfile(bak):
            raise SystemExit(f"no bak at {bak}")
        shutil.copy2(bak, live)
        codesign(live)
        print("restored", live, sha256(live))
        return

    if not os.path.isfile(bak):
        shutil.copy2(live, bak)
        print("bak", bak, sha256(bak))
    else:
        print("keeping bak", bak)

    data = bytearray(open(live, "rb").read())
    apply(data)
    open(work, "wb").write(data)
    shutil.copy2(work, live)
    codesign(live)
    print("patched login-sized layered-clear", live, sha256(live))
    print("cave", build_cave().hex())


if __name__ == "__main__":
    main()
