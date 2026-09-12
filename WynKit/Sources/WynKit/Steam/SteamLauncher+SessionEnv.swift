//
//  SteamLauncher+SessionEnv.swift
//  WynKit
//
//  This file is part of Wyn.
//
//  Wyn is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Wyn is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Wyn.
//  If not, see https://www.gnu.org/licenses/.
//
//  A running Steam client's environment is the game's environment. Record what
//  the client was started with, so the next `wyn play` can tell whether it is
//  the environment *this* profile needs.
//

import Foundation
import os.log

extension SteamLauncher {

    /// A game started by `steam.exe -applaunch` inherits the **client**
    /// process's environment and nothing else — `launchSteam(extraEnvironment:)`
    /// exists for exactly that reason. So a client that is already up was
    /// started for some profile, and its D3DMetal knobs are whatever that
    /// profile wanted. Launching a second game through it silently hands that
    /// game the first one's environment.
    ///
    /// Satisfactory is the case that exposed this, 12 Sep 2026.
    /// `gameHostSteamEnvironment` defaults `D3DM_ENABLE_METALFX` to `"1"`;
    /// `satisfactory.json` sets it to `"0"` because MetalFX "crawls ~0.1–2 fps
    /// then RHIThread SIGILL in D3DMCommandQueue::ExecuteCommandLists". A client
    /// already running from an earlier session handed the game the default. The
    /// game reached the main menu, ticked 421 times where 1000 were expected —
    /// the crawl, in its own log — and died at 33 seconds with no `LogExit`, no
    /// UE crash handler and no macOS crash report.
    ///
    /// A running process's environment cannot be read on macOS, so this records
    /// what Wyn started the client with and compares against it later.
    struct SteamSessionEnvRecord: Codable {
        var profileId: String
        var env: [String: String]
        var at: Double
    }

    static func steamSessionEnvURL(in bottle: Bottle) -> URL {
        bottle.url.appending(path: ".wyn-steam-session-env.json")
    }

    /// Keys whose value the *game* reads and inherits from the client.
    ///
    /// `WINEDLLOVERRIDES` is deliberately excluded: the client's copy is
    /// deliberately different from the game's (`steamSafeOverrides` strips the
    /// d3d/dxgi entries, because on the client process they reach steamwebhelper
    /// and kill CEF), so comparing it would report a mismatch on every launch.
    /// `SteamAppId` / `SteamGameId` are excluded too — `-applaunch` tells the
    /// client which app to start, so they do not need the client restarted.
    static func gameVisibleEnvKeys(
        _ env: [String: String],
        profile: GameProfile?
    ) -> Set<String> {
        let prefixes = ["D3DM_", "MTL_", "MVK_"]
        let exact: Set<String> = ["CX_GRAPHICS_BACKEND"]
        let ignored: Set<String> = ["WINEDLLOVERRIDES", "SteamAppId", "SteamGameId"]

        var keys = Set(env.keys.filter { key in
            prefixes.contains(where: { key.hasPrefix($0) }) || exact.contains(key)
        })
        // Whatever the profile itself declares is by definition game-visible.
        if let profile {
            keys.formUnion(profile.environment.keys)
        }
        return keys.subtracting(ignored)
    }

    /// Keys on which a running client disagrees with what this profile needs.
    /// Empty means the client can be reused.
    ///
    /// **No record counts as a mismatch.** A client started by Wyn.app, by hand,
    /// or by a Wyn old enough not to write one cannot be interrogated, and
    /// guessing that it is fine is how the Satisfactory crash happened. Erring
    /// towards a restart costs a Steam relaunch; erring the other way costs the
    /// session.
    static func steamSessionEnvMismatch(
        wanted: [String: String],
        profile: GameProfile?,
        in bottle: Bottle
    ) -> [String] {
        let keys = gameVisibleEnvKeys(wanted, profile: profile)
        guard let data = try? Data(contentsOf: steamSessionEnvURL(in: bottle)),
              let record = try? JSONDecoder().decode(SteamSessionEnvRecord.self, from: data)
        else {
            return keys.isEmpty ? ["(no recorded session)"] : keys.sorted()
        }

        // Compare over the union so a key the running session set and this
        // profile does not — a leftover MVK_ knob, say — is also a mismatch.
        let recordedKeys = gameVisibleEnvKeys(record.env, profile: nil)
        return keys.union(recordedKeys)
            .filter { wanted[$0] != record.env[$0] }
            .sorted()
    }

    static func recordSteamSessionEnv(
        _ env: [String: String],
        profileId: String,
        in bottle: Bottle
    ) {
        let record = SteamSessionEnvRecord(
            profileId: profileId,
            env: env,
            at: Date().timeIntervalSince1970
        )
        do {
            let data = try JSONEncoder().encode(record)
            try data.write(to: steamSessionEnvURL(in: bottle), options: .atomic)
        } catch {
            // Non-fatal: a missing record makes the next launch restart Steam,
            // which is the safe direction. Do not fail a launch over it.
            Logger.wynKit.warning("could not record Steam session env: \(error.localizedDescription)")
        }
    }

    static func forgetSteamSessionEnv(in bottle: Bottle) {
        try? FileManager.default.removeItem(at: steamSessionEnvURL(in: bottle))
    }
}
