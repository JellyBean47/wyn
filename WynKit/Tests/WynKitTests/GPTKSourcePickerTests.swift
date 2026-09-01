import Foundation
import Testing
@testable import WynKit

/// The Finder dialog itself cannot be unit-tested — it needs a human. Everything
/// that decides *whether* it opens, *where* it opens, and what gets remembered
/// afterwards is pure logic and is tested here.
///
/// `.serialized` and the per-test preference suite are not ceremony: the
/// remembered folder is process-wide state, so parallel tests overwrite each
/// other's value, and `.standard` would write into the real user's preferences
/// during a test run.
@Suite("GPTK source picker", .serialized)
final class GPTKSourcePickerTests {
    private let suiteName: String
    private let isolatedDefaults: UserDefaults
    private var scratch: [URL] = []

    init() {
        suiteName = "com.fly.gaming.tests.\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: suiteName)!
        GPTKSourcePicker.defaults = isolatedDefaults
    }

    deinit {
        for url in scratch {
            try? FileManager.default.removeItem(at: url)
        }
        isolatedDefaults.removePersistentDomain(forName: suiteName)
        GPTKSourcePicker.defaults = .standard
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "wyn-gptk-picker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch.append(dir)
        return dir
    }

    private func touch(_ url: URL) throws {
        try Data().write(to: url)
    }

    /// URL equality is a trap here: a directory URL may or may not carry a
    /// trailing slash depending on how it was built. Compare the paths.
    private func samePath(_ a: URL?, _ b: URL?) -> Bool {
        func norm(_ url: URL?) -> String? {
            guard let url else { return nil }
            var p = url.standardizedFileURL.path(percentEncoded: false)
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            return p
        }
        return norm(a) == norm(b)
    }

    // MARK: - Candidate scoring in an arbitrary folder

    /// The whole point of the feature: a GPTK sitting in Documents must be found
    /// by the same rules that find one in Downloads.
    @Test func exactFilenameWinsInAnyFolder() throws {
        let dir = try makeTempDir()
        try touch(dir.appending(path: "gptk-notes.txt"))
        try touch(dir.appending(path: GPTKInstaller.downloadsFileName))

        let found = GPTKInstaller.gptkCandidate(in: dir)
        #expect(found?.lastPathComponent == GPTKInstaller.downloadsFileName)
    }

    @Test func prefersThreePointZeroDmgOverOlderNames() throws {
        let dir = try makeTempDir()
        try touch(dir.appending(path: "Game_Porting_Toolkit_2.1.dmg"))
        try touch(dir.appending(path: "Game_Porting_Toolkit_3.0_beta.dmg"))

        let found = GPTKInstaller.gptkCandidate(in: dir)
        #expect(found?.lastPathComponent == "Game_Porting_Toolkit_3.0_beta.dmg")
    }

    @Test func ignoresFilesThatAreNotGPTK() throws {
        let dir = try makeTempDir()
        try touch(dir.appending(path: "Xcode_16.dmg"))
        try touch(dir.appending(path: "invoice.pdf"))

        #expect(GPTKInstaller.gptkCandidate(in: dir) == nil)
    }

    @Test func missingFolderIsNotACandidate() {
        let ghost = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(GPTKInstaller.gptkCandidate(in: ghost) == nil)
    }

    // MARK: - Remembering where GPTK actually lives

    @Test func remembersParentFolderOfAChosenFile() throws {
        let dir = try makeTempDir()
        let dmg = dir.appending(path: GPTKInstaller.downloadsFileName)
        try touch(dmg)

        GPTKSourcePicker.remember(source: dmg)
        #expect(samePath(GPTKSourcePicker.rememberedFolder, dir))
    }

    /// A directory redist is its own folder — remembering its parent would point
    /// one level too high and stop finding it.
    @Test func remembersDirectoryRedistItself() throws {
        let dir = try makeTempDir()
        GPTKSourcePicker.remember(source: dir)
        #expect(samePath(GPTKSourcePicker.rememberedFolder, dir))
    }

    /// External drive unplugged, folder renamed. A stale pointer must not shadow
    /// ~/Downloads forever.
    @Test func deletedFolderIsForgottenAutomatically() throws {
        let dir = try makeTempDir()
        GPTKSourcePicker.remember(source: dir)
        #expect(GPTKSourcePicker.rememberedFolder != nil)

        try FileManager.default.removeItem(at: dir)
        #expect(GPTKSourcePicker.rememberedFolder == nil)
        #expect(GPTKSourcePicker.rememberedCandidate() == nil)
    }

    @Test func forgetClearsIt() throws {
        let dir = try makeTempDir()
        GPTKSourcePicker.remember(source: dir)
        GPTKSourcePicker.forget()
        #expect(GPTKSourcePicker.rememberedFolder == nil)
    }

    @Test func nonexistentSourceIsNotRemembered() {
        GPTKSourcePicker.remember(source: URL(fileURLWithPath: "/nope-\(UUID().uuidString)/x.dmg"))
        #expect(GPTKSourcePicker.rememberedFolder == nil)
    }

    @Test func rememberedCandidateFindsTheFileInThatFolder() throws {
        let dir = try makeTempDir()
        let dmg = dir.appending(path: GPTKInstaller.downloadsFileName)
        try touch(dmg)

        GPTKSourcePicker.remember(source: dmg)
        #expect(samePath(GPTKSourcePicker.rememberedCandidate(), dmg))
    }

    /// Remembering ~/Downloads is a no-op — it is already searched, and returning
    /// it here would just duplicate the same result under a second name.
    @Test func rememberingDownloadsDoesNotDoubleUp() {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
        GPTKSourcePicker.remember(source: downloads)
        #expect(GPTKSourcePicker.rememberedCandidate() == nil)
    }

    // MARK: - Where the picker opens

    @Test func pickerStartsAtRememberedFolderWhenSet() throws {
        let dir = try makeTempDir()
        GPTKSourcePicker.remember(source: dir)
        #expect(samePath(GPTKSourcePicker.pickerStartFolder(), dir))
    }

    /// With nothing remembered the picker must land on Downloads, not the home
    /// folder — that is the whole reason Downloads is the documented default.
    @Test func pickerFallsBackToDownloadsWhenNothingRemembered() {
        GPTKSourcePicker.forget()
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")

        if FileManager.default.fileExists(atPath: downloads.path(percentEncoded: false)) {
            #expect(samePath(GPTKSourcePicker.pickerStartFolder(), downloads))
        } else {
            #expect(samePath(
                GPTKSourcePicker.pickerStartFolder(),
                FileManager.default.homeDirectoryForCurrentUser
            ))
        }
    }

    // MARK: - AppleScript quoting

    /// A folder called `My "GPTK" \ stuff` must not break out of the string
    /// literal and turn a path into script.
    @Test func escapesQuotesAndBackslashes() {
        let escaped = GPTKSourcePicker.escapeForAppleScript(#"My "GPTK" \ stuff"#)
        #expect(escaped == #"My \"GPTK\" \\ stuff"#)
    }

    @Test func leavesOrdinaryPathsAlone() {
        let path = "/Users/someone/Documents/Game_Porting_Toolkit_3.0.dmg"
        #expect(GPTKSourcePicker.escapeForAppleScript(path) == path)
    }
}
