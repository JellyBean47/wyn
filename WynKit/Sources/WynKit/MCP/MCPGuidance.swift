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
    - D3D11 game → "dxvk" with dxvk true, or "d3dmetal".
    - D3D12 game → "d3dmetal". DXVK does not do D3D12.
    - Unsure → say so and leave it out rather than inventing one.

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
                   often a crash reporter), and which graphics libraries ship \
                   with it.
                3. Draft the profile from what step 2 showed. Say which parts \
                   came off disk and which are inference — that difference is \
                   the whole point.
                4. validate_profile, and fix anything it returns.
                5. save_profile.
                6. Tell me to launch it from Wyn, and that it stays a guess until \
                   it has actually run.
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
            }
        ]
    }
}
