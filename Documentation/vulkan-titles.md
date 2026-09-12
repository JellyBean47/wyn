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

**Wyn ships this, as source.** `Tools/fly_mvkshim.c`, built by
`scripts/build-mvkshim.sh` into `Tools/bin/fly_mvkshim.dylib` (universal,
`@rpath/libMoltenVK.dylib` install name, exactly nine exports — CI checks the
list), bundled into `Wyn.app/Contents/Resources` by `scripts/build.sh`, and
installed into the launching tree by
`WynWineInstaller.ensureVulkanFeatureShim`. `ProfileApplicator.prepareVulkanShim`
calls it from `SteamLauncher.launchGame` for any profile
`ProfileValidator.isVulkanNative` recognises, so a Vulkan title no longer needs a
hand-copied dylib and the catalog claim no longer depends on one.

It was written from scratch against the published Vulkan specification, and it
replaces an Aug 2026 binary (135,200 bytes, md5
`e8e03ea1b3976f1db16580f5dc3e0bcd`, universal) recovered from a parked
`Libraries.vk` tree for which **no source ever existed on disk**. That binary
was found inside a CrossOver 26.2.0 tree, which is worth stating plainly since
the location invites the wrong conclusion: it carried this project's own
`FLY_MVKSHIM_*` namespace, exported nine symbols against CrossOver's
556-export patched MoltenVK, contained no CodeWeavers strings, and
`FLY_MVKSHIM` appears nowhere in CodeWeavers' published source dump. The tree
was where it was stored, not where it came from. Nothing CodeWeavers wrote is
in Wyn.

`Tools/fly_mvkshim_probe.c` re-runs the proof rather than asking you to trust
it: it does what id Tech does at startup — create an instance, take the first
device, ask for `depthBounds` and `shaderCullDistance`, then request them in
`vkCreateDevice`. Against stock MoltenVK 1.4.1 on an Apple M4 it prints
`VK_ERROR_FEATURE_NOT_PRESENT` (exit 1); through the shim, `VK_SUCCESS`
(exit 0).

```sh
clang -arch x86_64 -O2 -o /tmp/probe Tools/fly_mvkshim_probe.c
arch -x86_64 /tmp/probe "<tree>/Wine/lib/libMoltenVK.real.dylib"   # expect exit 1
FLY_MVKSHIM_REAL="<tree>/Wine/lib/libMoltenVK.real.dylib" \
  arch -x86_64 /tmp/probe Tools/bin/fly_mvkshim.dylib              # expect exit 0
```

x86_64 because the MoltenVK in both live Wine trees is x86_64-only — Wine runs
that side. Youngblood and
DOOM (2016) are bundled as verified with notes that name the shim. Shipping
the shim (installed by `WynWineInstaller`, selected per profile) is the
remaining feature. See
`wyn-handovers/FINDING-20260911-idtech-blocked-on-moltenvk.md`.

## Results with the shim

- **Wolfenstein: Youngblood — verified 11 Sep 2026.** Device created, played by
  a person, and it wrote `savegame.user/…/SLOT0/PROFILE/progression.bin` at
  23:19. Two fragment pipelines fail to compile (`Shader library compile failed
  (Error code 3)`), which is the likely price of dropping cull distance; it did
  not stop play. Catalog id `wolfenstein-youngblood`.
- **DOOM (2016) — verified 12 Sep 2026.** Same shim. The 91% hang was not
  graphics: `--direct` leaves the process with no COM apartment, so XAudio2 2.7
  never initialises (401 `apartment not initialised` in 45 s). `wyn play
  doom-2016` through Steam gives it one. Also copy `DOOMx64vk.exe` over
  `DOOMx64.exe` (`DOOMx64.exe.wyn-bak` keeps the OpenGL original) because
  `-applaunch` runs Steam's default option. Wrote `DOOMConfig.local`
  (`r_renderAPI 1`) at 00:06 and `profile.bin` at 00:08. Catalog id
  `doom-2016`.

## Two launch-path facts these titles exposed

1. **`-applaunch` runs Steam's default launch option, not the exe the profile
   resolved.** For DOOM that is `DOOMx64.exe` (OpenGL). Copy the Vulkan binary
   over it, or Steam will never start `DOOMx64vk.exe`. `--direct` runs the
   resolved exe — **except on DOOM**, where `--direct` is the 91% hang (no COM
   apartment for XAudio2). Youngblood can `--direct`; DOOM must go through
   Steam.
2. **A `--direct` launch needs Steam up and logged in on the same tree.**
   `--direct` uses the game tree; without a logged-in Steam there, a Denuvo
   title exits immediately with `e06d7363` before any graphics work happens.

## OpenGL is a hard ceiling, separately

`DOOMx64.exe` asks for an OpenGL core context newer than macOS provides:

```
ERROR_INVALID_VERSION_ARB
FATAL ERROR: wglCreateContextAttribsARB failed
```

Apple's OpenGL stops at 4.1 and id Tech 6 wants 4.3+. No Wine build or shim
changes that — for these engines Vulkan is the only path worth pursuing.
