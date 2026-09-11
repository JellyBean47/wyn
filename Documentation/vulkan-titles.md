# Vulkan titles, and the MoltenVK feature wall

Most of this catalog is D3D → D3DMetal/DXMT/DXVK. A few titles are **Vulkan
natively** — id Tech, mainly — and for those the translation layer is not in the
picture at all. What matters is `winevulkan` → MoltenVK → Metal, and the layer
field in a profile only decides which launch path Wyn takes.

Measured 11 Sep 2026 on Apple M4 / macOS 26.5.1, MoltenVK 1.4.1.

## The wall

Metal has no equivalent for two Vulkan features id Tech asks for, so MoltenVK
refuses the device outright:

```
[mvk-error] VK_ERROR_FEATURE_NOT_PRESENT: vkCreateDevice(): Requested physical
device feature specified by the 39th flag in VkPhysicalDeviceFeatures is not
available on this device.
```

By spec order — and confirmed by the shim below, which names them — the 39th
flag is **`shaderCullDistance`** and the 15th is **`depthBounds`**. MoltenVK
never enables either on Apple silicon: it hard-codes
`_properties.limits.maxCullDistances = 0; // unsupported`, and its `depthBounds
= true` is gated on `MVK_USE_METAL_PRIVATE_API` **and** an AMD vendor ID.

| title | asks for | without the shim |
|---|---|---|
| Wolfenstein: Youngblood | 39th | `Startup failure: error while initializing the graphics driver` |
| DOOM (2016) | 15th + 39th | same, and its OpenGL exe is a separate dead end (below) |

## The shim

`fly-mvkshim` is a small interposer that sits in front of MoltenVK: it reports
those features as present to the game, then **strips them from the
`VkDeviceCreateInfo`** before forwarding. The game believes it got them and
MoltenVK is never asked for what it cannot do.

It exports `vkGetPhysicalDeviceFeatures`, `…Features2`, `…Features2KHR`,
`vkCreateDevice`, `vkGetInstanceProcAddr`, `vkGetDeviceProcAddr` and the
`vk_icd*` trio, and reads three env vars: `FLY_MVKSHIM_FORCE` (feature list),
`FLY_MVKSHIM_REAL` (path to the real library), `FLY_MVKSHIM_QUIET`.

Install per tree — `winevulkan` dlopens `libMoltenVK.dylib` from
`<tree>/Wine/lib/`, so the drop-in needs no configuration:

```sh
cd "<tree>/Wine/lib"
cp libMoltenVK.dylib libMoltenVK.dylib.stock.bak      # keep the real one
cp libMoltenVK.dylib.stock.bak libMoltenVK.real.dylib
cp <shim> libMoltenVK.dylib
```

It works in front of the **current** MoltenVK — 1.4.1 — so no downgrade is
needed. Log from a working session:

```
fly-mvkshim: forcing shaderCullDistance (39th flag)
fly-mvkshim: forcing depthBounds (15th flag)
fly-mvkshim: active; real library …/Wine/lib/libMoltenVK.real.dylib
[mvk-info] Created VkDevice to run on GPU Apple M4 …
fly-mvkshim: vkCreateDevice: dropped forced features from the request -> VK_SUCCESS
```

**Wyn does not ship this.** The only copy on this machine is an Aug 2026 binary
(135,200 bytes, md5 `e8e03ea1b3976f1db16580f5dc3e0bcd`, universal) recovered
from a parked `Libraries.vk` tree; no source exists on disk. Youngblood is
bundled as verified anyway, with notes that name the shim; DOOM (2016) stays a
user profile until it actually plays. See
`wyn-handovers/FINDING-20260911-idtech-blocked-on-moltenvk.md`. Shipping the
shim (installed by `WynWineInstaller`, selected per profile) is the remaining
feature.

## Results with the shim

- **Wolfenstein: Youngblood — verified 11 Sep 2026.** Device created, played by
  a person, and it wrote `savegame.user/…/SLOT0/PROFILE/progression.bin` at
  23:19. Two fragment pipelines fail to compile (`Shader library compile failed
  (Error code 3)`), which is the likely price of dropping cull distance; it did
  not stop play. Catalog id `wolfenstein-youngblood`.
- **DOOM (2016) — device yes, game no.** It gets a device and past render init,
  then spins: one core at ~105%, RSS drifting down, no file I/O, no window.
  `sample` cannot unwind Wine stacks, so the next step is
  `MVK_CONFIG_LOG_LEVEL=3` / `WINEDEBUG=+vulkan` to separate pipeline
  compilation from a fence that never signals.

## Two launch-path facts these titles exposed

1. **`-applaunch` runs Steam's default launch option, not the exe the profile
   resolved.** Wyn's log said `DOOMx64vk.exe`; Steam started `DOOMx64.exe`.
   `--direct` runs the resolved exe. Any title shipping several executables is
   exposed to this, not just DOOM.
2. **A `--direct` launch needs Steam up and logged in on the same tree.**
   `--direct` uses the game tree; without a logged-in Steam there, a Denuvo
   title exits immediately with `e06d7363` before any graphics work happens.
   `wyn steam launch` first, then `wyn play <id> --direct`.

## OpenGL is a hard ceiling, separately

`DOOMx64.exe` asks for an OpenGL core context newer than macOS provides:

```
ERROR_INVALID_VERSION_ARB
FATAL ERROR: wglCreateContextAttribsARB failed
```

Apple's OpenGL stops at 4.1 and id Tech 6 wants 4.3+. No Wine build or shim
changes that — for these engines Vulkan is the only path worth pursuing.
