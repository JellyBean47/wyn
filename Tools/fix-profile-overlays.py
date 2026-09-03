#!/usr/bin/env python3
"""Turn debug overlays and unmeasured D3DMetal knobs off across the catalog.

Run once. `ProfileCatalogValidationTests` is what keeps it that way.

72 profiles shipped with Metal's stat HUD drawn over the game and MetalFX on —
the same combination `satisfactory.json` sets to "0" because MetalFX on crawls
to ~0.1-2 fps and then SIGILLs in D3DMCommandQueue::ExecuteCommandLists.

Only `satisfactory` is marked verified, because it is the only profile whose
values came from measurement rather than inference. Everything else is a
guess and now says so.
"""

import json
import pathlib
import sys

PROFILES = pathlib.Path(__file__).resolve().parents[1] / \
    "WynKit/Sources/WynKit/Resources/Profiles"

OVERLAY_OFF = ["MTL_HUD_ENABLED", "D3DM_SHOW_HUD_STATS"]
RISK_OFF = ["D3DM_ENABLE_METALFX", "D3DM_ENABLE_ASYNC_COMMIT"]
TRUTHY = {"1", "true", "yes", "on"}

# The one profile whose settings were measured on the machine, with a note
# recording what was seen. Everything else is inference until a launch says so.
VERIFIED = {"satisfactory"}


def main() -> int:
    changed = []
    for path in sorted(PROFILES.glob("*.json")):
        raw = path.read_text(encoding="utf-8")
        data = json.loads(raw)
        before = json.dumps(data, sort_keys=True)

        env = data.get("environment") or {}
        for key in OVERLAY_OFF + RISK_OFF:
            if str(env.get(key, "")).strip().lower() in TRUTHY:
                env[key] = "0"
        if env:
            data["environment"] = env

        bottle = data.get("bottle")
        if isinstance(bottle, dict) and bottle.get("metalHud") is True:
            bottle["metalHud"] = False
            data["bottle"] = bottle

        data["status"] = "verified" if data.get("id") in VERIFIED else "guessed"

        if json.dumps(data, sort_keys=True) != before:
            path.write_text(
                json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            changed.append(path.name)

    print(f"{len(changed)} profile(s) changed of {len(list(PROFILES.glob('*.json')))}")
    for name in changed:
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
