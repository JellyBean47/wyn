#!/usr/bin/env python3
"""After NtGdiStretchBlt returns, call flush_window_surfaces(TRUE).

Login StretchBlt may dirty a window surface without the windrv unlock→flush
path (or without idle message flush). Splash ULW flushes itself; login does not.

  python3 Tools/apply-win32u-stretchblt-flush.py
  python3 Tools/apply-win32u-stretchblt-flush.py --restore
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import struct
import subprocess

LIVE = os.path.expanduser(
    "~/Library/Application Support/com.fly.gaming/"
    "Libraries.pre-gptk-aware.bak/Wine/lib/wine/x86_64-unix/win32u.so"
)
BAK_SUFFIX = ".pre-stretchblt-flush.bak"
WORK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin", "win32u.stretchblt-flush.so")

# NtGdiStretchBlt epilogue (mov eax,r14d … ret)
EPI_AT = 0x27CC
EPI_ORIG = bytes(
    [
        0x44, 0x89, 0xF0,                          # mov eax, r14d
        0x48, 0x81, 0xC4, 0xF8, 0x00, 0x00, 0x00,  # add rsp, 0xf8
        0x5B,                                        # pop rbx
        0x41, 0x5C,                                  # pop r12
        0x41, 0x5D,                                  # pop r13
        0x41, 0x5E,                                  # pop r14
        0x41, 0x5F,                                  # pop r15
        0x5D,                                        # pop rbp
        0xC3,                                        # ret
    ]
)
# Cave in __TEXT zero pad (cstring/tail) — not executable DATA
CAVE_AT = 0x17C898
FLUSH = 0x175E0


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def codesign(path: str) -> None:
    subprocess.check_call(["codesign", "--force", "--sign", "-", path], stdout=subprocess.DEVNULL)


def expect(data: bytearray, off: int, want: bytes, label: str) -> None:
    got = bytes(data[off : off + len(want)])
    if got != want:
        raise SystemExit(f"UNEXPECTED {label} @ {hex(off)}: got {got.hex()} want {want.hex()}")


def build_cave() -> bytes:
    # mov edi, 1; call flush_window_surfaces; then original epilogue
    cave = bytearray()
    cave += bytes([0xBF, 0x01, 0x00, 0x00, 0x00])  # mov edi, 1
    call_at = CAVE_AT + len(cave)
    cave += bytes([0xE8]) + struct.pack("<i", FLUSH - (call_at + 5))
    cave += EPI_ORIG
    return bytes(cave)


def apply(data: bytearray) -> None:
    expect(data, EPI_AT, EPI_ORIG, "StretchBlt epilogue")
    cave = build_cave()
    pad = bytes(data[CAVE_AT : CAVE_AT + 64])
    if any(b not in (0x00, 0x90) for b in pad[: len(cave)]):
        if pad[: len(cave)] != cave:
            raise SystemExit(f"UNEXPECTED cave pad @ {hex(CAVE_AT)}: {pad[:32].hex()}")
    data[CAVE_AT : CAVE_AT + len(cave)] = cave
    # jmp cave (E9 rel32) + int3 fill over epilogue
    rel = CAVE_AT - (EPI_AT + 5)
    patch = bytes([0xE9]) + struct.pack("<i", rel)
    patch += b"\xCC" * (len(EPI_ORIG) - 5)
    assert len(patch) == len(EPI_ORIG)
    data[EPI_AT : EPI_AT + len(EPI_ORIG)] = patch


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--restore", action="store_true")
    args = ap.parse_args()
    live = LIVE
    bak = live + BAK_SUFFIX

    if args.restore:
        if not os.path.isfile(bak):
            raise SystemExit(f"missing {bak}")
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
    # Ensure we start from force-flush-only (not always-flush / stretch already)
    if data[EPI_AT] == 0xE9:
        raise SystemExit("StretchBlt epilogue already patched — --restore first")
    apply(data)
    os.makedirs(os.path.dirname(WORK), exist_ok=True)
    open(WORK, "wb").write(data)
    shutil.copy2(WORK, live)
    codesign(live)
    print("patched StretchBlt→flush_window_surfaces", live, sha256(live))


if __name__ == "__main__":
    main()
