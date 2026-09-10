//
//  WineMono.swift
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

/// Official WineHQ Mono MSI for wineboot. winecx `addons.c` only skips the hung
/// GUI installer when the **matching** MSI is already in
/// `Libraries/Wine/share/wine/mono/`. Replacing frankea `Libraries/` with FOSS
/// winecx wipes a 10.4.1 copy; restore 11.2.0 from `~/Library/Caches/wyn/`.
/// `wyn steam install` then runs `msiexec /qn` before SteamSetup.
public enum WineMono {
    public enum MonoError: LocalizedError, Equatable {
        case wineMissing
        case downloadFailed
        case hashMismatch(expected: String, actual: String)
        case msiexecFailed

        public var errorDescription: String? {
            switch self {
            case .wineMissing:
                return "Wine is not installed. Run ./scripts/setup.sh first."
            case .downloadFailed:
                return "Could not download Wine Mono from WineHQ."
            case .hashMismatch(let expected, let actual):
                return "Wine Mono MSI SHA-256 mismatch (expected \(expected), got \(actual)). Refusing to install. See DEPENDENCIES.md."
            case .msiexecFailed:
                return "msiexec /qn failed to install Wine Mono into the bottle."
            }
        }
    }

    public static func pinForInstalledWine() -> RuntimeIntegrity.Pin {
        GameHostIdentity.isFOSSGPTKHost()
            ? RuntimeIntegrity.wineMonoWinecx
            : RuntimeIntegrity.wineMonoFrankea
    }

    public static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "wyn")
    }

    public static var datadir: URL {
        WynWineInstaller.libraryFolder
            .appending(path: "Wine")
            .appending(path: "share")
            .appending(path: "wine")
            .appending(path: "mono")
    }

    public static func cacheURL(for pin: RuntimeIntegrity.Pin) -> URL {
        cacheDirectory.appending(path: "wine-mono-\(pin.version)-x86.msi")
    }

    public static func datadirURL(for pin: RuntimeIntegrity.Pin) -> URL {
        datadir.appending(path: "wine-mono-\(pin.version)-x86.msi")
    }

    /// True when the bottle already has a Wine Mono tree (msiexec finished).
    public static func isInstalled(in bottle: Bottle) -> Bool {
        let mono = bottle.url
            .appending(path: "drive_c")
            .appending(path: "windows")
            .appending(path: "mono")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: mono,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return contents.contains { !$0.lastPathComponent.hasPrefix(".") }
    }

    /// Copy a hash-ok MSI from `~/Library/Caches/wyn/` into the live Wine datadir.
    /// No download — used after `GameHostIdentity.install` replaces `Libraries/`.
    public static func restoreDatadirFromCache() throws {
        guard WynWineInstaller.isWynWineInstalled() else { return }
        let pin = pinForInstalledWine()
        let cache = cacheURL(for: pin)
        guard FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)) else { return }
        do {
            try verify(cache, pin: pin)
        } catch {
            try? FileManager.default.removeItem(at: cache)
            return
        }
        try placeInDatadir(from: cache, pin: pin)
    }

    /// Download (if needed), verify SHA-256, and copy into live `share/wine/mono/`.
    @discardableResult
    public static func ensureDatadirPackage() async throws -> URL {
        guard WynWineInstaller.isWynWineInstalled() else {
            throw MonoError.wineMissing
        }
        let pin = pinForInstalledWine()
        let cache = try await cachedMSI(pin: pin)
        try placeInDatadir(from: cache, pin: pin)
        return datadirURL(for: pin)
    }

    /// Stage the matching MSI, then `msiexec /qn` into the bottle if Mono is missing.
    /// Call before the first wine process that would otherwise pop `install_mono`.
    public static func preparePrefix(_ bottle: Bottle) async throws {
        let msi = try await ensureDatadirPackage()
        if isInstalled(in: bottle) { return }
        try await installQuiet(msi: msi, into: bottle)
    }

    private static func cachedMSI(pin: RuntimeIntegrity.Pin) async throws -> URL {
        let fm = FileManager.default
        let cache = cacheURL(for: pin)
        if fm.fileExists(atPath: cache.path(percentEncoded: false)) {
            do {
                try verify(cache, pin: pin)
                return cache
            } catch {
                try fm.removeItem(at: cache)
            }
        }

        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let (tempURL, response) = try await URLSession.shared.download(from: pin.url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MonoError.downloadFailed
        }
        let partial = cache.appendingPathExtension("partial")
        if fm.fileExists(atPath: partial.path(percentEncoded: false)) {
            try fm.removeItem(at: partial)
        }
        try fm.moveItem(at: tempURL, to: partial)
        do {
            try verify(partial, pin: pin)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        if fm.fileExists(atPath: cache.path(percentEncoded: false)) {
            try fm.removeItem(at: cache)
        }
        try fm.moveItem(at: partial, to: cache)
        return cache
    }

    private static func placeInDatadir(from source: URL, pin: RuntimeIntegrity.Pin) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: datadir, withIntermediateDirectories: true)
        let dest = datadirURL(for: pin)
        if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
            do {
                try verify(dest, pin: pin)
                return
            } catch {
                try fm.removeItem(at: dest)
            }
        }
        try fm.copyItem(at: source, to: dest)
        try verify(dest, pin: pin)
    }

    private static func verify(_ file: URL, pin: RuntimeIntegrity.Pin) throws {
        do {
            try RuntimeIntegrity.verifySHA256(of: file, expected: pin.sha256)
        } catch let error as RuntimeIntegrity.IntegrityError {
            if case .hashMismatch(let expected, let actual) = error {
                throw MonoError.hashMismatch(expected: expected, actual: actual)
            }
            throw error
        }
    }

    private static func installQuiet(msi: URL, into bottle: Bottle) async throws {
        _ = try await Wine.runWine(
            ["msiexec", "/i", msi.path(percentEncoded: false), "/qn"],
            bottle: bottle,
            environment: [
                "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
                "WINEDEBUG": "-all"
            ]
        )
        guard isInstalled(in: bottle) else {
            throw MonoError.msiexecFailed
        }
    }

    /// Wine Mono's `CultureInfo.CurrentCulture.NumberFormat` is read-only.
    /// Assetto Corsa's Kunos launcher writes `NumberDecimalSeparator` in
    /// `ControllerSetupSlimDX` anyway, which throws `InvalidOperationException`
    /// ("Instance is read-only") → `XamlParseException` → the "retire from the
    /// race" dialog (measured 6 Sep 2026 20:12). Microsoft .NET 4 hands out a
    /// writable format; this nop's `NumberFormatInfo.VerifyWritable` so Mono
    /// matches that. Bottle-local; wine-mono reinstall undoes it.
    @discardableResult
    public static func allowMutatingReadOnlyNumberFormat(in bottle: Bottle) -> Bool {
        let mscorlib = bottle.url
            .appending(path: "drive_c")
            .appending(path: "windows")
            .appending(path: "mono")
            .appending(path: "mono-2.0")
            .appending(path: "lib")
            .appending(path: "mono")
            .appending(path: "4.5")
            .appending(path: "mscorlib.dll")
        return patchVerifyWritable(at: mscorlib)
    }

    /// `NumberFormatInfo.VerifyWritable` IL: ldarg.0, ldfld, brfalse.s +16,
    /// ldstr, call, newobj, throw, ret. Replace the first opcode with `ret`.
    static func patchVerifyWritable(at url: URL) -> Bool {
        guard var data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        guard let offset = verifyWritableILOffset(in: data) else { return false }
        if data[offset] == 0x2A { return false }
        data[offset] = 0x2A
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    /// File offset of the 25-byte VerifyWritable body, or of an already-patched
    /// copy that starts with `ret` instead of `ldarg.0`.
    static func verifyWritableILOffset(in data: Data) -> Int? {
        data.withUnsafeBytes { buf -> Int? in
            let bytes = buf.bindMemory(to: UInt8.self)
            guard bytes.count >= 25 else { return nil }
            let last = bytes.count - 25
            var i = 0
            while i <= last {
                let first = bytes[i]
                if (first == 0x02 || first == 0x2A)
                    && bytes[i + 1] == 0x7B
                    && bytes[i + 6] == 0x2C
                    && bytes[i + 7] == 0x10
                    && bytes[i + 8] == 0x72
                    && bytes[i + 13] == 0x28
                    && bytes[i + 18] == 0x73
                    && bytes[i + 23] == 0x7A
                    && bytes[i + 24] == 0x2A
                {
                    return i
                }
                i += 1
            }
            return nil
        }
    }
}
