# Wine patches (source form)

These notes describe intended changes to **Wine** (LGPL-2.1-or-later). They are
not a substitute for applying a proper source diff against a Wine tree.

Do **not** commit patched `win32u.so` or `winemac.so` binaries. Build Wine from
LGPL source, or apply equivalent changes yourself.

Offsets in the accompanying `Tools/apply-win32u-*.py` helpers are specific to
frankea wine-11.0 and are research tools, not a redistributable Wine.

Files:

- `macdrv-present-opaque-alpha.patch.md`
- `win32u-shm-present-force-flush.patch.md`
