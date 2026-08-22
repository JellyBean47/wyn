#!/usr/bin/env python3
"""Always flush window surfaces on windrv unlock (bypass FLUSH_PERIOD ~50ms).

Frankea win32u inlines unlock_surface many times as:
  cmp r15d, 0x33
  jb  <skip>          ; ticks <= 50 → no flush
  mov rdi, [rbx+0x20]
  call window_surface_flush

Layered/ULW splash flushes immediately (alpha_mask path). Login StretchBlt
uses non-layered windrv and may never hit idle flush while CEF is busy.
NOP the jb so every unlock flushes when lock_count hits 0.

  python3 Tools/apply-win32u-always-surface-flush.py
  python3 Tools/apply-win32u-always-surface-flush.py --restore
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
    "~/Library/Application Support/com.fly.gaming/"
    "Libraries.pre-gptk-aware.bak/Wine/lib/wine/x86_64-unix/win32u.so"
)
BAK_SUFFIX = ".pre-always-flush.bak"
WORK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin", "win32u.always-flush.so")

# cmp r15d, 0x33 ; jb rel8
PAT = bytes([0x41, 0x83, 0xFF, 0x33, 0x72])


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def codesign(path: str) -> None:
    subprocess.check_call(["codesign", "--force", "--sign", "-", path], stdout=subprocess.DEVNULL)


def find_sites(data: bytes) -> list[int]:
    sites = []
    start = 0
    while True:
        i = data.find(PAT, start)
        if i < 0:
            break
        # next bytes should be rel8 then mov rdi, [rbx+0x20] (optional check)
        sites.append(i)
        start = i + 1
    return sites


def apply(data: bytearray) -> int:
    sites = find_sites(bytes(data))
    if len(sites) < 10:
        raise SystemExit(f"expected many unlock FLUSH_PERIOD sites, found {len(sites)}")
    for i in sites:
        # NOP the jb rel8 (2 bytes at i+4)
        if data[i : i + 4] != PAT[:4]:
            raise SystemExit(f"pattern drift @ {hex(i)}")
        data[i + 4] = 0x90
        data[i + 5] = 0x90
    return len(sites)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--restore", action="store_true")
    ap.add_argument("--live", default=LIVE)
    args = ap.parse_args()
    live = args.live
    bak = live + BAK_SUFFIX

    if args.restore:
        if not os.path.isfile(bak):
            raise SystemExit(f"missing bak {bak}")
        shutil.copy2(bak, live)
        codesign(live)
        print("restored", live, sha256(live))
        return

    if not os.path.isfile(bak):
        shutil.copy2(live, bak)
        print("bak", bak, sha256(bak))
    else:
        print("keeping existing bak", bak)

    data = bytearray(open(live, "rb").read())
    n = apply(data)
    os.makedirs(os.path.dirname(WORK), exist_ok=True)
    open(WORK, "wb").write(data)
    shutil.copy2(WORK, live)
    codesign(live)
    # verify
    v = open(live, "rb").read()
    left = len(find_sites(v))
    print(f"patched {n} FLUSH_PERIOD jb→nop; remaining cmp+jb patterns={left}")
    print("live", live, sha256(live))
    print("NOTE: leave force-flush intact; this stacks on current win32u.")


if __name__ == "__main__":
    main()
