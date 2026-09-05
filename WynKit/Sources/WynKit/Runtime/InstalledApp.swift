//
//  InstalledApp.swift
//  WynKit
//
//  Where the installed Wyn.app keeps the native helpers, so the CLI can find
//  them too.
//
//  scripts/build.sh copies steamwebhelper_shim.exe and the present dylibs into
//  Wyn.app/Contents/Resources precisely so the app never has to reach back into
//  a source checkout. `Bundle.main.resourceURL` finds them from inside the app.
//
//  It does not find them from the CLI. A command-line binary's Bundle.main is
//  the directory holding the executable — ~/.local/bin — which has no
//  Resources, so the lookup falls through to the two developer conveniences:
//  a path relative to #filePath, and one relative to the current directory.
//  Both are a checkout, and neither is there for someone who installed Wyn and
//  never cloned it. Worse, on the machine that built it, #filePath usually
//  points somewhere under ~/Desktop or ~/Documents, which macOS gates behind
//  TCC: the file is present, the CLI is told it is not, and the message says
//  the helper is missing.
//
//  Found on 5 September 2026 doing the most ordinary thing there is:
//
//      wyn steam install --bottle Steam-DXMT
//      -> Error: steamwebhelper_shim.exe is missing (Tools/bin/).
//
//  while the file sat in BOTH ~/Desktop/wyn/Tools/bin and
//  /Applications/Wyn.app/Contents/Resources, identical bytes. Without the shim
//  Steam's login window paints black, so every fresh bottle created through the
//  CLI is broken in a way that looks like a Steam or Wine fault.
//
//  The fix is one more candidate: the installed app's Resources directory, by
//  its known path. It is not elegant, but the app is installed at a fixed
//  location by scripts/build.sh, and a helper the project already ships should
//  not be unreachable from the project's own CLI.
//

import Foundation

public enum InstalledApp {

    /// Where scripts/build.sh installs the app.
    public static let bundleURL = URL(fileURLWithPath: "/Applications/Wyn.app")

    /// The installed app's Resources directory — the native helpers live here.
    ///
    /// Not gated by TCC (unlike a checkout under ~/Desktop or ~/Documents), and
    /// present for anyone who ran scripts/build.sh, which is everyone who has a
    /// working install.
    public static var resourcesDirectory: URL {
        bundleURL
            .appending(path: "Contents")
            .appending(path: "Resources")
    }

    /// True when the installed app is actually there. Callers should still test
    /// for the specific helper they want — an app bundle that shipped without
    /// helpers exists but is no use.
    public static var isPresent: Bool {
        FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false))
    }
}
