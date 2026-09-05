//
//  MCPGuidance.swift
//  WynKit
//
//  What the server tells the model before it does anything.
//
//  Two things live here, and they are the *soft* half of keeping a model on
//  path. The hard half is elsewhere and matters more: ProfileValidator refuses
//  bad settings, save_profile forces `status: guessed`, and executable names
//  are checked against the files on disk. Those hold whatever the model
//  intends. Guidance only changes how often it tries something that gets
//  refused, and how good the drafts are when it doesn't.
//
//  Worth keeping short. `instructions` is injected into every session that
//  connects, so every sentence is paid for repeatedly.
//

import Foundation

public enum MCPGuidance {

    /// Sent in `initialize`. MCP clients hand this to the model as server-level
    /// context, which makes it the closest thing to a system prompt Wyn gets.
    public static let instructions = """
    Wyn runs Windows games on macOS through Wine. A "profile" is the per-game \
    settings Wyn launches with: which executable, which translation layer, \
    environment variables, launch arguments.

    HOW TO ADD OR FIX A GAME

    1. list_installed_games — the game is usually already installed, so its real \
       name and Steam app id can be read rather than guessed.
    2. inspect_game_files — read the engine, the executables and the shipped \
       libraries off disk. Do this before deciding anything.
    3. Draft a profile from what you saw.
    4. validate_profile — checks without writing.
    5. save_profile — same checks, and it writes.
    6. Tell the person to launch it from Wyn. That is the only thing that finds \
       out whether the profile was right.

    LOOK, DON'T RECALL

    What you can read from the install directory beats what you remember about \
    the game. "Ships vulkan-1.dll and no d3d12.dll" is checkable; "this game \
    needs MetalFX" is not. 72 profiles once shipped with a setting that crashes \
    the one game anybody had actually measured, written confidently from \
    knowledge rather than observation. Prefer the file listing every time, and \
    say plainly when you are guessing.

    CHOOSING A LAYER

    - Vulkan-native game (ships vulkan-1.dll, no d3d12.dll) → the MoltenVK path: \
      translationLayer "dxvk" with dxvk false. D3DMetal cannot translate Vulkan.
    - D3D12 game → "d3dmetal". DXVK does not do D3D12.
    - D3D11 game, or nothing conclusive → "d3dmetal". It is the default, not the \
      fallback, and the gap is large: measured on the same game, same settings, \
      same resolution, D3DMetal held 119.7 fps median where DXVK managed 45.4. \
      DXVK also could not create a fullscreen swapchain on that title at all.

    THE PROFILE DOES NOT DECIDE THE LAYER

    The Wine tree the bottle is running decides it. `WINEDLLOVERRIDES d3d11=b` \
    asks for *builtin*, and builtin is D3DMetal only in the game-host tree; if \
    Steam was started on the frankea tree the game gets the bottle's own native \
    DXVK instead — silently, with a correct-looking profile.

    This is not hypothetical. A d3dmetal profile ran a two-hour session on DXVK \
    at a third of the frame rate, and the only symptom was a warm Mac.

    So never conclude a layer is in use because the profile names it. After a \
    launch, call read_session_performance: it reads the adapter out of the \
    game's own log, which is the only reliable answer.

      D3DMetal reports "AMD Compatibility Mode" (VendorId 0x1002)
      DXVK     reports "NVIDIA GeForce 6800"    (VendorId 0x10de)

    PERFORMANCE IS PART OF THE JOB

    A profile that launches is not a profile that is finished. Read \
    read_session_performance and judge the frame rate *against the resolution \
    that produced it* — 45 fps is fine at 4K and alarming at 576x324.

    Slow at a low resolution is the signature of a structural problem, not of \
    settings being too high. Check the layer first. Do not tell someone to \
    lower their settings to fix it; that is the diagnosis that cost a day.

    Frames above the display's refresh rate are also worth naming: they are \
    discarded, and they cost power and heat for nothing. VSync in the game's \
    own settings is the fix. Do not reach for -ExecCmds to force a cap.

    THE FIRST LAUNCH IS A DIAGNOSTIC

    Do not draft the profile you think the game deserves. Draft the one least \
    likely to crash, so the first launch answers "does this reach a loaded map \
    at all". Improving from a working baseline is cheap; guessing your way to \
    one takes three or four launches. Specifically, in a first profile:

    - avxEnabled FALSE. It sets ROSETTA_ADVERTISE_AVX=1; some binaries then emit \
      an instruction Rosetta will not run and die instantly with \
      EXCEPTION_ILLEGAL_INSTRUCTION. Per-title, and total when it happens.
    - launchArgs "-windowed -ResX=1280 -ResY=720". Fullscreen swapchain creation \
      is the most fragile operation in this stack — measured failing under both \
      d3dmetal (ACCESS_VIOLATION at frame 1) and dxvk (swapchain E_FAIL) on the \
      same game that works windowed.
    - enhancedSync "msync", windowsVersion "win10" (118 and 119 of 119).
    - winetricks ["vcrun2019", "vcrun2022"]. Declares a dependency; Wyn checks \
      it against the bottle's registry but never installs it. Only verbs it can \
      check (vcrun2015/2017/2019/2022, dotnet40-48).
    - On Unreal, ALWAYS set unrealProject. It is what points diagnostics and \
      read_session_performance at Saved/Logs/<Project>.log; without it there is \
      no way to find out which layer ran or how fast.

    Tell the person the plan: get one working launch, then relax one knob at a \
    time in this order — drop -windowed, raise resolution, try avxEnabled true. \
    One change per launch, or you will not know which one did it.

    Documentation/adding-a-game.md has the long version, including how to read a \
    crash without blaming the wrong line.

    RULES THAT WILL REFUSE YOUR PROFILE

    - Debug overlays off: MTL_HUD_ENABLED, D3DM_SHOW_HUD_STATS and metalHud draw \
      developer overlays on top of the game.
    - D3DM_ENABLE_METALFX and D3DM_ENABLE_ASYNC_COMMIT must be "0". Measured: \
      MetalFX on crawls to ~0.1-2 fps and then crashes.
    - Never -ExecCmds, xinput*=d, FG.InputMode, ForceMouse, wineserver -k, \
      wineboot -u.
    - On d3dmetal, the d3d DLL overrides must be builtin ("=b"), never native \
      first ("=n,b"). Under dxmt native-first is correct.
    - exePatterns must match a file the game actually ships. This is checked.

    STATUS, AND WHAT YOU CANNOT DO

    guessed → launched → verified.

    Everything you write is saved as "guessed", whatever you put in the field. \
    You cannot mark a profile launched or verified, and neither can a confident \
    explanation. Wyn promotes to "launched" by itself once the game has run for \
    a minute on this machine. "verified" means a person measured something and \
    wrote down what they saw. Do not tell anyone a profile works because it \
    looks right — say it is a starting point that has not been run.

    Read read_launch_evidence before claiming anything about how well a game \
    runs here. It is the only real data there is.
    """

    // MARK: - Prompts

    public struct Prompt {
        public let name: String
        public let description: String
        /// name, description, required
        public let arguments: [(String, String, Bool)]
        public let body: (String?) -> String
    }

    public static var all: [Prompt] {
        [
            Prompt(
                name: "add_game",
                description: "Work out a Wyn profile for a game by reading its installed files.",
                arguments: [("game", "Name of the game, if you know which one.", false)]
            ) { game in
                let target = game.map { "The game is \"\($0)\"." }
                    ?? "Ask which game if it is not obvious from what is installed."
                return """
                Add a Wyn profile for a game. \(target)

                Work in this order, and do not skip step 2 — everything good \
                about the result comes from reading the files rather than \
                recalling the game.

                1. list_installed_games. Match the name to what is installed and \
                   take its Steam app id from there. If nothing matches, say so \
                   and stop; a profile for a game that is not installed cannot \
                   be checked.
                2. inspect_game_files on that app id. Note the engine, which \
                   executable actually looks like the game (the biggest binary is \
                   often a crash reporter, and a suspiciously small <Game>.exe \
                   next to a large <Game>-Win64-Shipping.exe is a prereq shim), \
                   and which graphics libraries ship with it.
                3. Draft the profile from what step 2 showed, starting from the \
                   safe baseline below rather than from what the game "should" \
                   want. Say which parts came off disk and which are inference — \
                   that difference is the whole point.
                4. validate_profile, and fix anything it returns.
                5. save_profile.
                6. Tell me to launch it from Wyn, that it stays a guess until it \
                   has run, and that once it has you will call \
                   read_session_performance — because a profile that launches on \
                   the wrong layer at a third of the frame rate looks exactly \
                   like success from here.

                THE BASELINE. Change only what step 2 gives you a reason to \
                change — the exe patterns, the layer if the game is Vulkan-native \
                or D3D12, unrealProject on Unreal, -NO_EOS_OVERLAY if it ships \
                EOS. Leave the rest exactly as it is:

                  windowsVersion  "win10"
                  translationLayer "d3dmetal"   (dxvk false, dxvkAsync false)
                  enhancedSync    "msync"
                  avxEnabled      false
                  metalHud        false
                  WINEDLLOVERRIDES "d3d11,dxgi,d3d12,d3d10,atidxx64,nvapi64,nvngx=b"
                  MTL_HUD_ENABLED / D3DM_ENABLE_METALFX /
                    D3DM_ENABLE_ASYNC_COMMIT / D3DM_SHOW_HUD_STATS  all "0"
                  winetricks      ["vcrun2019", "vcrun2022"]
                  launchArgs      "-windowed -ResX=1280 -ResY=720"

                This exists because the last game added took four launches — AVX \
                on died with EXCEPTION_ILLEGAL_INSTRUCTION, fullscreen died at \
                frame 1, switching to DXVK was worse — and every one of those \
                failures is ruled out by the baseline above. Aim for one launch.
                """
            },
            Prompt(
                name: "review_profile",
                description: "Check an existing profile against the game's installed files.",
                arguments: [("id", "Profile id, e.g. \"satisfactory\".", true)]
            ) { id in
                let target = id ?? "the profile"
                return """
                Review the Wyn profile "\(target)".

                1. get_profile \(target).
                2. inspect_game_files for its Steam app id.
                3. Compare them. Do the exePatterns match real files? Does the \
                   translation layer suit what the game actually ships — a \
                   Vulkan-native game on d3dmetal is wrong, since D3DMetal does \
                   not translate Vulkan.
                4. validate_profile on it as it stands.
                5. read_launch_evidence to see whether this machine has ever run \
                   it, and with which settings.

                Report what is wrong and what you would change. Do not save \
                anything unless I ask.
                """
            },
            Prompt(
                name: "tune_profile",
                description: "Improve a profile that already launches, one setting at a time.",
                arguments: [("id", "Profile id of a game that has already run.", true)]
            ) { id in
                let target = id ?? "the profile"
                return """
                Improve the Wyn profile "\(target)". It already launches — this \
                is the second half of adding a game, and the rule is one change \
                per launch.

                1. read_launch_evidence for \(target). If this machine has never \
                   run it, stop and say so: there is no baseline to improve on \
                   and changing settings now just resumes guessing.
                2. read_session_performance \(target). CHECK THE LAYER FIRST. If \
                   it is not the one the profile asks for, stop — nothing about \
                   the frame rate means anything yet, and the fix is to quit \
                   Steam and relaunch, not to change the profile.
                3. get_profile \(target).
                4. Read the frame rate against the resolution that produced it. \
                   Slow at a low resolution is structural, not a settings \
                   problem, and lowering settings further is the wrong move. \
                   Fast with VSync off means frames being thrown away as heat, \
                   and the fix is VSync in the game's own settings — never \
                   -ExecCmds.
                5. Propose exactly ONE change, taking the first that still \
                   applies from this order:
                     a. drop -windowed from launchArgs
                     b. raise -ResX / -ResY toward the display's resolution
                     c. set avxEnabled true
                   Nothing after that. MetalFX and D3DM_ENABLE_ASYNC_COMMIT stay \
                   "0" — that is measured, not caution, and the validator refuses \
                   them anyway. In-game quality settings are the person's to \
                   change, not yours: say what the headroom allows and let them \
                   decide.
                6. save_profile with that one change, and tell me to launch it.
                7. When I report back, read_session_performance again and compare \
                   like for like. If it regressed, revert and stop — a game that \
                   plays windowed at 720p is worth shipping. If it held, go round \
                   again from step 5.

                What "it held" means: same or better median frame rate at the \
                same resolution, on the same layer, with no new hitches. A window \
                appearing is not evidence, and neither is a frame rate measured \
                against a different resolution. Do not blame the last line before \
                a crash without checking whether it also appears in a healthy \
                run — that mistake has already cost one investigation.
                """
            }
        ]
    }
}
