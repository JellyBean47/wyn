//
//  Wine+VirtualDesktop.swift
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
//  Run a game inside Wine's own desktop window, so a macOS focus change has no
//  native surface to destroy.
//

import Foundation
import os.log
#if canImport(AppKit)
import AppKit
#endif

extension Wine {

    /// Why this exists, measured on DOOM (2016) 12 Sep 2026: a title in
    /// exclusive fullscreen tears its surface down when macOS focus changes, and
    /// winemac hands the rebuilt surface a **new** `WineMetalView`. The Wine log
    /// recorded `Created 2 swapchain images … WineMetalView (0x600003891f20)` at
    /// startup and a second one on `(0x60000388aac0)` at the moment of the
    /// alt-tab, with no errors of any kind — no `VK_ERROR_SURFACE_LOST`, no
    /// `OUT_OF_DATE`. The game then kept rendering at 206% CPU into the view
    /// that was no longer on screen: black screen, window gone, process healthy.
    ///
    /// Nothing about that is DOOM-specific. Which view a rebuilt surface lands
    /// on is winemac's business, and `army-men-rts` already documents the same
    /// class of failure on a completely different path ("Exclusive crashes on
    /// focus loss: [VID RESTORE SURFACES: Alt-Tab] null deref") — with a Wine
    /// virtual desktop as the measured workaround, hand-written in its notes
    /// because this setting did not exist.
    ///
    /// Inside a Wine desktop there is no native surface to lose, so a focus
    /// change is a non-event. The cost is exclusive fullscreen: no display mode
    /// switch, so it is borderless-fullscreen at the desktop's size. That is why
    /// it is opt-in rather than the default.
    public struct VirtualDesktop: Equatable, Sendable {
        public var name: String
        public var size: String

        public init(name: String, size: String) {
            self.name = name
            self.size = size
        }
    }

    /// `WxH`, or nil if the string is not that. Rejects rather than corrects: a
    /// desktop silently sized 0x0 or 99999x1 is worse than a launch that says
    /// the setting is wrong.
    static func parseVirtualDesktopSize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = trimmed.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              (640...16384).contains(width), (480...16384).contains(height)
        else { return nil }
        return "\(width)x\(height)"
    }

    /// The main display in pixels, for when no size is configured.
    static func mainDisplaySize() -> String {
        #if canImport(AppKit)
        if let screen = NSScreen.main {
            let scale = screen.backingScaleFactor
            let width = Int((screen.frame.width * scale).rounded())
            let height = Int((screen.frame.height * scale).rounded())
            if let parsed = parseVirtualDesktopSize("\(width)x\(height)") { return parsed }
        }
        #endif
        return "1920x1080"
    }

    /// Wine desktop names reach a registry key and a window title, so keep them
    /// to something boring. Derived from the executable so two games run in two
    /// desktops rather than fighting over one.
    static func virtualDesktopName(for exe: URL) -> String {
        let stem = exe.deletingPathExtension().lastPathComponent
        let allowed = stem.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let name = String(String.UnicodeScalarView(allowed)).lowercased()
        return name.isEmpty ? "wyn" : String(name.prefix(24))
    }

    /// The desktop to wrap *this* launch in — `.launch` mode only.
    ///
    /// `.bottle` deliberately returns nil here: that mode works through the
    /// prefix registry instead, so the wrapper must not also be applied or the
    /// game ends up in a desktop inside a desktop.
    static func virtualDesktop(for settings: BottleSettings, exe: URL) -> VirtualDesktop? {
        guard settings.virtualDesktopMode == .launch else { return nil }
        let size = parseVirtualDesktopSize(settings.virtualDesktopSize) ?? mainDisplaySize()
        return VirtualDesktop(name: virtualDesktopName(for: exe), size: size)
    }

    /// The prefix-wide desktop for `.bottle` mode, or nil when that is not the
    /// mode. One stable name per bottle, not per executable: the registry value
    /// is shared by every process in the prefix.
    static func bottleVirtualDesktop(for settings: BottleSettings) -> VirtualDesktop? {
        guard settings.virtualDesktopMode == .bottle else { return nil }
        let size = parseVirtualDesktopSize(settings.virtualDesktopSize) ?? mainDisplaySize()
        return VirtualDesktop(name: "wyn", size: size)
    }

    /// Bring `HKCU\Software\Wine\Explorer` in line with the bottle's mode.
    ///
    /// Done with a live `reg add` rather than by patching `user.reg`, because
    /// Steam is usually already running and a file patch under a live wineserver
    /// is lost when it flushes.
    ///
    /// This is what reaches a Steam-launched game. Each Windows process reads
    /// that key at startup, so writing it before `steam.exe -applaunch` is
    /// enough — Steam does not need restarting, even though its own window
    /// stays where it already was.
    ///
    /// Reconciled on every launch, in both directions: switching back to Off
    /// has to *remove* the value, or a desktop nobody asked for outlives the
    /// setting.
    static func reconcileBottleVirtualDesktop(
        _ desktop: VirtualDesktop?, bottle: Bottle
    ) async {
        let explorer = #"HKCU\Software\Wine\Explorer"#
        do {
            if let desktop {
                try await runWine(
                    ["reg", "add", #"HKCU\Software\Wine\Explorer\Desktops"#,
                     "-v", desktop.name, "-t", "REG_SZ", "-d", desktop.size, "-f"],
                    bottle: bottle
                )
                try await runWine(
                    ["reg", "add", explorer,
                     "-v", "Desktop", "-t", "REG_SZ", "-d", desktop.name, "-f"],
                    bottle: bottle
                )
            } else {
                // Absent is the goal, so a failure here usually means it was
                // already absent. Never fail a launch over it.
                try? await runWine(
                    ["reg", "delete", explorer, "-v", "Desktop", "-f"],
                    bottle: bottle
                )
            }
        } catch {
            Logger.wynKit.warning(
                "virtual desktop registry reconcile failed: \(error.localizedDescription)"
            )
        }
    }

    /// The `wine` argument vector for a launch.
    ///
    /// `start /d <cwd>` is kept **inside** the desktop rather than dropped:
    /// Unreal and most Windows games resolve content through
    /// `GetCurrentDirectory`, and losing the working directory is how a game
    /// comes up unable to find its own `.uproject`. That is why this is one
    /// function — the two halves have to compose, and the obvious way of writing
    /// it (replace `start` with `explorer`) silently breaks CWD.
    static func launchArgumentVector(
        exe: URL,
        args: [String],
        workDirWin: String,
        virtualDesktop desktop: VirtualDesktop?
    ) -> [String] {
        var vector: [String] = []
        if let desktop {
            vector += ["explorer", "/desktop=\(desktop.name),\(desktop.size)"]
        }
        vector += ["start", "/d", workDirWin, "/unix", exe.path(percentEncoded: false)]
        vector += args
        return vector
    }
}
