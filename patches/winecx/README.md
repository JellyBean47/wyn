# winecx patches (applied)

Wyn's runtime is winecx at `WINECX_COMMIT` (`scripts/runtime-pins.env`) with
these patches applied in name order, and nothing else. They are real source
patches, unlike the notes in `patches/wine/`.

- `scripts/build-foss-game-host.sh` applies them to a clean checkout of the
  pin and refuses any other change (`scripts/winecx-series.sh`).
- The built tree records what it was built from in
  `share/wine/wyn-winecx-source.txt`; `scripts/stage-runtime.sh` checks that
  against the checkout.
- `scripts/package-sources.sh` puts them in the corresponding-source archive
  next to the pinned tree.

Each patch is `git format-patch` output from a commit on top of the pin; its
message says what it changes and what was measured.

| Patch | What |
| --- | --- |
| `0001-ntdll-macos-gsbase-mode.patch` | `%gs` is the TEB in Windows code (upstream's model) except in D3DMetal processes, which keep the pthread TSD. Fixes DOOM (2016) at 91%. `WINE_GSBASE=teb` or `tsd` pins the mode; `WINEDEBUG=+gsbase` logs it. |

To change a patch: check out the pin, `git am` the series, edit, commit, and
`git format-patch --zero-commit -N <pin>` back into this directory.
