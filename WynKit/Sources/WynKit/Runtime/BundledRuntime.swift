//
//  BundledRuntime.swift
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

import Foundation
import SemanticVersion

/// The runtime a release Wyn.app carries from 1.1 on, in
/// `Contents/SharedSupport/Runtime` (built by `scripts/stage-runtime.sh`):
///
/// - `Libraries/` — the winecx game-host tree with DXVK, DXMT and Wine Mono
/// - `GPTK/` — Apple's evaluation environment, exactly as Apple ships it
///
/// First launch installs it into Application Support — the `Libraries/` every
/// launch path already reads — instead of downloading a runtime, and wires
/// D3DMetal in through the same `GPTKInstaller` a user-supplied DMG goes
/// through. Nothing ever runs from the bundle or writes into it: Wyn rewrites
/// its runtime tree after install (renderer wiring, the MoltenVK shim), and a
/// notarized bundle has to stay exactly as it was signed.
///
/// A source build has no `Runtime/`, so everything here reports "not bundled"
/// and setup keeps downloading the hash-pinned runtime as before.
public enum BundledRuntime {
    public enum InstallError: LocalizedError, Equatable {
        case notBundled
        case notGameHost(String)
        case alreadyInstalled(String)

        public var errorDescription: String? {
            switch self {
            case .notBundled:
                return "This Wyn.app does not carry a runtime (a source build). Run: wyn runtime install"
            case .notGameHost(let detail):
                return "The runtime inside Wyn.app failed its identity check: \(detail)"
            case .alreadyInstalled(let path):
                return """
                A Wine runtime is already installed at \(path). It is left alone: it may be \
                hand-tuned, and a running Steam may be using it. To replace it with the one \
                inside Wyn.app: wyn runtime install --bundled --replace
                """
            }
        }
    }

    /// `Runtime/` of the Wyn.app this process belongs to, if it has one.
    public static var root: URL? {
        candidateRoots().first(where: isRuntimeRoot)
    }

    public static var isAvailable: Bool { root != nil }

    public static var librariesFolder: URL? { root?.appending(path: "Libraries") }

    /// Apple's evaluation environment: `License.rtf`, `Acknowledgements.rtf`, `redist/`.
    public static var gptkFolder: URL? {
        guard let gptk = root?.appending(path: "GPTK"),
              FileManager.default.fileExists(atPath: gptk.appending(path: "redist").path(percentEncoded: false))
        else { return nil }
        return gptk
    }

    public static var version: SemanticVersion? {
        guard let plist = librariesFolder?.appending(path: "WynWineVersion.plist"),
              let data = try? Data(contentsOf: plist),
              let info = try? PropertyListDecoder().decode(WynWineVersion.self, from: data)
        else { return nil }
        return info.version
    }

    /// Where a runtime can be, in the order it is trusted:
    /// - the app itself (`Bundle.main` is Wyn.app)
    /// - the CLI inside the app, `Wyn.app/Contents/Resources/wyn`, whose
    ///   `Bundle.main` is only the directory it sits in
    /// - a CLI copied to `~/.local/bin` by "Install Command Line Tool…", which
    ///   has no bundle at all and belongs to the installed app
    static func candidateRoots(
        sharedSupportURL: URL? = Bundle.main.sharedSupportURL,
        executableURL: URL? = Bundle.main.executableURL,
        installedApps: [URL] = [InstalledApp.bundleURL]
    ) -> [URL] {
        var roots: [URL] = []
        if let shared = sharedSupportURL {
            roots.append(shared.appending(path: "Runtime"))
        }
        if let exe = executableURL?.resolvingSymlinksInPath() {
            let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
            roots.append(contents.appending(path: "SharedSupport").appending(path: "Runtime"))
        }
        for app in installedApps {
            roots.append(app.appending(path: "Contents/SharedSupport/Runtime"))
        }
        return roots
    }

    static func isRuntimeRoot(_ url: URL) -> Bool {
        let wine64 = url.appending(path: "Libraries/Wine/bin/wine64")
        return FileManager.default.fileExists(atPath: wine64.path(percentEncoded: false))
    }

    /// Copy the bundled runtime into Application Support and wire D3DMetal in.
    ///
    /// Never replaces an installed runtime unless `replacing` is true. Whatever
    /// is at `Libraries/` may be a tree someone tuned by hand, and it is what a
    /// running wineserver was started from; swapping it underneath that is how
    /// prefixes get re-provisioned mid-session.
    public static func install(replacing: Bool = false) throws {
        guard let libraries = librariesFolder else { throw InstallError.notBundled }

        let report = GameHostIdentity.inspectWineRoot(libraries.appending(path: "Wine"))
        guard report.isFOSSGPTKHost else {
            throw InstallError.notGameHost(report.refusal ?? "not a FOSS winecx tree")
        }

        let installed = WynWineInstaller.libraryFolder
        if FileManager.default.fileExists(atPath: installed.path(percentEncoded: false)), !replacing {
            throw InstallError.alreadyInstalled(installed.path(percentEncoded: false))
        }

        // installFromDirectory refuses a source carrying Apple GPTK files, which
        // is why the bundle keeps them in GPTK/ and not inside Libraries/.
        // FileManager copies with clonefile on APFS, so on the usual single-volume
        // Mac this is near-instant and costs no disk until something changes.
        try WynWineInstaller.installFromDirectory(libraries)
        RuntimeManager.activeSource = .bundled

        if let gptk = gptkFolder {
            _ = try GPTKInstaller.install(from: gptk)
            // GPTK install is availability only and deliberately never selects
            // a renderer. Here that is not a choice: in this one-tree runtime
            // Wine's builtin d3d11/dxgi/d3d12/d3d10 *are* GPTK's PE stubs, so
            // their unix halves must point at libd3dshared or everything that
            // loads them as builtins breaks — starting with Steam, whose launch
            // on the game tree refuses with "D3DMetal is installed but not
            // selected" (found in the first real 1.1 install, 27 Sep 2026).
            // DXMT and DXVK launches load native DLLs from the bottle and are
            // unaffected: the smoke test presents through DXMT in this state.
            try RendererWiring.set(.d3dMetal)
        }
        clearQuarantine(under: installed)
    }

    /// An app dragged out of a downloaded disk image carries
    /// `com.apple.quarantine` on its files, and FileManager's copy (a clone on
    /// APFS) keeps it. The copies are the same signed bytes as the bundle they
    /// came from, which Gatekeeper already assessed as one notarized, stapled
    /// unit before this code could run. Left quarantined, each would be assessed
    /// again on its own at first exec or dlopen — and a stapled ticket travels
    /// with the app, not with a copied file, so that re-check needs the network.
    static func clearQuarantine(under root: URL) {
        let attribute = "com.apple.quarantine"
        func clear(_ url: URL) {
            _ = url.withUnsafeFileSystemRepresentation { path in
                path.map { removexattr($0, attribute, XATTR_NOFOLLOW) }
            }
        }
        clear(root)
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in files {
            clear(url)
        }
    }
}
