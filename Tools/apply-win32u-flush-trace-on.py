#!/usr/bin/env python3
"""Force-on three win32u TRACE sites without enabling WINEDEBUG=+win globally.

NOPs the `je` after `test channel_flags, 8` so these always log to stderr:
  - window_surface_flush "Flushing hwnd …"
  - create_shm_surface entry TRACE
  - process_surface_message "Flushing %p window surface"

Keeps force-flush cave intact (patches on top of current live / force-flush bak).

Usage:
  python3 Tools/apply-win32u-flush-trace-on.py
  python3 Tools/apply-win32u-flush-trace-on.py --restore
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess

LIVE = os.path.expanduser(
    "~/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/lib/wine/x86_64-unix/win32u.so"
)
BAK_SUFFIX = ".pre-flush-trace-on.bak"
WORK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin", "win32u.flush-trace-on.so")

# (offset of je near, expected je bytes)
SITES = [
    (0x15254, bytes([0x0F, 0x84, 0x9B, 0x00, 0x00, 0x00]), "window_surface_flush TRACE je"),
    (0x1693B, None, "create_shm_surface TRACE je"),  # fill after probe
    (0x16CF1, None, "process_surface_message TRACE je"),
]


def real_live() -> str:
    return os.path.realpath(LIVE)


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def codesign(path: str) -> None:
    subprocess.check_call(["codesign", "-s", "-", "--force", path])


def probe_je(data: bytes, test_off: int) -> tuple[int, bytes]:
    """testb is 7 bytes; je near follows."""
    if data[test_off : test_off + 2] != bytes([0xF6, 0x05]):
        # allow already-patched (nops)
        if data[test_off + 7 : test_off + 13] == bytes([0x90] * 6):
            return test_off + 7, bytes([0x90] * 6)
        raise SystemExit(f"UNEXPECTED testb @ {hex(test_off)}: {data[test_off:test_off+10].hex()}")
    je_off = test_off + 7
    if data[je_off] == 0x0F and data[je_off + 1] == 0x84:
        return je_off, bytes(data[je_off : je_off + 6])
    if data[je_off] == 0x74:  # short je
        return je_off, bytes(data[je_off : je_off + 2])
    raise SystemExit(f"UNEXPECTED je @ {hex(je_off)}: {data[je_off:je_off+8].hex()}")


def apply(data: bytearray) -> None:
    # window_surface_flush
    je_off, je = probe_je(data, 0x1524D)
    if je[0] != 0x90:
        if je_off != 0x15254:
            raise SystemExit(f"window_surface_flush je moved to {hex(je_off)}")
        data[je_off : je_off + len(je)] = bytes([0x90] * len(je))

    # create_shm_surface — testb at 0x16934
    je_off, je = probe_je(data, 0x16934)
    if je[0] != 0x90:
        data[je_off : je_off + len(je)] = bytes([0x90] * len(je))

    # process_surface_message — testb at 0x16cea
    je_off, je = probe_je(data, 0x16CEA)
    if je[0] != 0x90:
        data[je_off : je_off + len(je)] = bytes([0x90] * len(je))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--restore", action="store_true")
    args = ap.parse_args()

    live = real_live()
    bak = live + BAK_SUFFIX

    if args.restore:
        if not os.path.isfile(bak):
            raise SystemExit(f"no bak {bak}")
        shutil.copy2(bak, live)
        codesign(live)
        print(f"restored {live} {sha256(live)}")
        print("NOTE: restore returns to pre-trace-on snapshot (should still include force-flush).")
        return

    if not os.path.isfile(bak):
        shutil.copy2(live, bak)
        print(f"backup {bak} {sha256(bak)}")
    else:
        print(f"backup exists {bak} {sha256(bak)}")

    data = bytearray(open(bak, "rb").read())
    apply(data)
    os.makedirs(os.path.dirname(WORK), exist_ok=True)
    open(WORK, "wb").write(data)
    codesign(WORK)
    shutil.copy2(WORK, live)
    codesign(live)
    print(f"installed {live} {sha256(live)}")
    print("OK — kill frankea wineserver; launch Connect WITHOUT WINEDEBUG=+win")


if __name__ == "__main__":
    main()
