import Foundation
import Testing
@testable import WynKit

/// scripts/build.sh copies the native helpers into Wyn.app/Contents/Resources
/// so nothing has to reach back into a source checkout. The lookup found them
/// from inside the app and nowhere else: a CLI binary's `Bundle.main` is the
/// directory holding the executable — ~/.local/bin — which has no Resources.
///
/// So the installed CLI fell through to two developer conveniences, a path
/// relative to `#filePath` and one relative to the current directory. Both are
/// a checkout. Someone who installed Wyn and never cloned it has neither, and
/// on the machine that built it `#filePath` usually lands under ~/Desktop,
/// which macOS gates behind TCC — the file is there and the CLI is told it is
/// not.
///
/// Found on 5 Sep 2026: `wyn steam install --bottle Steam-DXMT` reported
/// steamwebhelper_shim.exe missing while it sat in both the checkout and the
/// app bundle. Without the shim, Steam's login window paints black, so every
/// fresh bottle made from the CLI looked broken.
@Suite("Bundled helper lookup")
struct BundledHelperLookupTests {

    /// Compared by component rather than by string: `URL(fileURLWithPath:)`
    /// appends a trailing slash when the path exists and is a directory, so the
    /// literal comparison passes or fails depending on whether Wyn.app happens
    /// to be installed on the machine running the tests.
    @Test func theInstalledAppIsWhereBuildScriptPutsIt() {
        #expect(InstalledApp.bundleURL.lastPathComponent == "Wyn.app")
        #expect(InstalledApp.bundleURL.deletingLastPathComponent().lastPathComponent
                == "Applications")
        #expect(InstalledApp.resourcesDirectory.path(percentEncoded: false)
                == "/Applications/Wyn.app/Contents/Resources")
    }

    /// The regression itself: the installed app's Resources must be one of the
    /// places the shim is looked for, or the CLI cannot find a helper the
    /// project already ships.
    @Test func theShimSearchIncludesTheInstalledApp() {
        let paths = SteamCEFShim.shimSearchPaths.map { $0.path(percentEncoded: false) }
        #expect(paths.contains("/Applications/Wyn.app/Contents/Resources/steamwebhelper_shim.exe"))
    }

    /// Same omission, same fix, for the present/rtld dylibs.
    @Test func theToolsBinSearchIncludesTheInstalledApp() {
        let paths = PlatformCatalog.toolsBinSearchPaths().map { $0.path(percentEncoded: false) }
        #expect(paths.contains("/Applications/Wyn.app/Contents/Resources"))
    }

    /// Ordering matters and is easy to get wrong later. A checkout may be
    /// stale, TCC-gated, or absent; the installed app is neither, so it has to
    /// be tried before the two source-relative conveniences. `Bundle.main` still
    /// wins outright, so a running Wyn.app keeps using its own copy.
    @Test func theInstalledAppIsTriedBeforeAnyCheckoutPath() {
        let paths = SteamCEFShim.shimSearchPaths.map { $0.path(percentEncoded: false) }
        let installed = paths.firstIndex {
            $0 == "/Applications/Wyn.app/Contents/Resources/steamwebhelper_shim.exe"
        }
        let checkout = paths.firstIndex { $0.contains("Tools/bin/steamwebhelper_shim.exe") }
        let installedIndex = try? #require(installed)
        let checkoutIndex = try? #require(checkout)
        #expect((installedIndex ?? 0) < (checkoutIndex ?? 0))

        let dirs = PlatformCatalog.toolsBinSearchPaths().map { $0.path(percentEncoded: false) }
        let installedDir = dirs.firstIndex { $0 == "/Applications/Wyn.app/Contents/Resources" }
        let checkoutDir = dirs.firstIndex { $0.hasSuffix("Tools/bin") }
        #expect((installedDir ?? 0) < (checkoutDir ?? 0))
    }

    /// A directory is not a helper. Resources always exists once the app is
    /// installed, so the search must keep testing for the file itself —
    /// otherwise an app bundle that shipped without helpers silently stops the
    /// search and nothing later in the list is ever tried.
    @Test func thePresenceCheckIsForTheFileNotTheDirectory() {
        let dirs = PlatformCatalog.toolsBinSearchPaths()
        #expect(dirs.count >= 3)
        // toolsBinURL only returns a directory that actually holds a helper, so
        // on a machine without one installed it must return nil rather than the
        // bare Resources path.
        if !FileManager.default.fileExists(
            atPath: "/Applications/Wyn.app/Contents/Resources/winemac_rtld_global.dylib"
        ) {
            #expect(PlatformCatalog.toolsBinURL()?.path(percentEncoded: false)
                    != "/Applications/Wyn.app/Contents/Resources")
        }
    }
}
