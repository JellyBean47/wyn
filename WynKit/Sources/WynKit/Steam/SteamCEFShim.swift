//
//  SteamCEFShim.swift
//  WynKit
//
//  Deploys a steamwebhelper.exe wrapper that injects
//  `--disable-gpu --in-process-gpu` so Steam's CEF UI works under
//  Wine/GPTK on Apple Silicon. Avoid `--single-process` — it often
//  deadlocks (RtlWaitForCriticalSection / "steamwebhelper is not responding").
//  Override via host FLY_CEF_FLAGS / AETHER_CEF_FLAGS (forwarded into Wine).
//  Pattern from notpop/steam-on-m1-wine, wisnuub/Steam-Win-Silicon.

import Foundation

public enum SteamCEFShim {
    /// Bundled / repo-built shim PE (x86_64 Windows).
    public static var bundledShimURL: URL? {
        // #filePath = .../WynKit/Sources/WynKit/Steam/SteamCEFShim.swift
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Steam
            .deletingLastPathComponent() // WynKit
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // WynKit pkg
            .appending(path: "Tools/bin/steamwebhelper_shim.exe")

        let fromCwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Tools/bin/steamwebhelper_shim.exe")

        return [fromSource, fromCwd].first {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
    }

    private static func cefDir(in bottle: Bottle) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
            .appending(path: "bin")
            .appending(path: "cef")
            .appending(path: "cef.win64")
    }

    /// True when steamwebhelper.exe is our small shim (not Valve's multi-MB PE).
    public static func isInstalled(in bottle: Bottle) -> Bool {
        let fm = FileManager.default
        let helper = cefDir(in: bottle).appending(path: "steamwebhelper.exe")
        let real = cefDir(in: bottle).appending(path: "steamwebhelper_real.exe")
        guard fm.fileExists(atPath: real.path(percentEncoded: false)),
              fm.fileExists(atPath: helper.path(percentEncoded: false)),
              let attrs = try? fm.attributesOfItem(atPath: helper.path(percentEncoded: false)),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue < 500_000
    }

    /// Ensure CEF dir has shim as steamwebhelper.exe and Valve binary as steamwebhelper_real.exe.
    /// Always re-applies the shim if Steam restored the Valve PE.
    @discardableResult
    public static func install(into bottle: Bottle, debug: Bool = false) throws -> Bool {
        let fm = FileManager.default
        let dir = cefDir(in: bottle)
        let helper = dir.appending(path: "steamwebhelper.exe")
        let real = dir.appending(path: "steamwebhelper_real.exe")
        let marker = dir.appending(path: ".fly-cef-shim")

        guard let shim = bundledShimURL else {
            if debug {
                print("[wyn:debug] CEF shim: Tools/bin/steamwebhelper_shim.exe not found (mingw build)")
            }
            return false
        }

        let helperExists = fm.fileExists(atPath: helper.path(percentEncoded: false))
        let realExists = fm.fileExists(atPath: real.path(percentEncoded: false))
        guard helperExists || realExists else {
            if debug { print("[wyn:debug] CEF shim: steamwebhelper.exe missing — skip") }
            return false
        }

        if isInstalled(in: bottle),
           let shimData = try? Data(contentsOf: shim),
           let helperData = try? Data(contentsOf: helper),
           shimData == helperData {
            if debug { print("[wyn:debug] CEF shim: already installed (--disable-gpu --in-process-gpu)") }
            return true
        }

        // Capture Valve PE once into *_real.exe
        if !realExists {
            let attrs = try fm.attributesOfItem(atPath: helper.path(percentEncoded: false))
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if size < 500_000 {
                if debug {
                    print("[wyn:debug] CEF shim: helper looks like a shim but no _real — abort")
                }
                return false
            }
            try fm.moveItem(at: helper, to: real)
        }

        // Steam bootstrapper often restores helper → always force our shim on top.
        if fm.fileExists(atPath: helper.path(percentEncoded: false)) {
            try fm.removeItem(at: helper)
        }
        try fm.copyItem(at: shim, to: helper)
        try "fly-cef-shim=disable-gpu,in-process-gpu\n".write(to: marker, atomically: true, encoding: .utf8)

        if debug {
            let sz = (try? fm.attributesOfItem(atPath: helper.path(percentEncoded: false))[.size] as? NSNumber)?.intValue ?? 0
            print("[wyn:debug] CEF shim: installed steamwebhelper (\(sz) bytes) → --disable-gpu --in-process-gpu")
            print("[wyn:debug] CEF shim: override with FLY_CEF_FLAGS; steam args need -noverifyfiles")
        }
        return true
    }

    /// Restore Valve's steamwebhelper when using frankea Steam Wine (shim not needed).
    @discardableResult
    public static func uninstall(from bottle: Bottle, debug: Bool = false) throws -> Bool {
        let fm = FileManager.default
        let dir = cefDir(in: bottle)
        let helper = dir.appending(path: "steamwebhelper.exe")
        let real = dir.appending(path: "steamwebhelper_real.exe")
        let marker = dir.appending(path: ".fly-cef-shim")

        guard fm.fileExists(atPath: real.path(percentEncoded: false)) else {
            if debug { print("[wyn:debug] CEF shim: no steamwebhelper_real.exe — nothing to restore") }
            return false
        }

        if fm.fileExists(atPath: helper.path(percentEncoded: false)) {
            try fm.removeItem(at: helper)
        }
        try fm.moveItem(at: real, to: helper)
        try? fm.removeItem(at: marker)
        if debug { print("[wyn:debug] CEF shim: restored Valve steamwebhelper.exe") }
        return true
    }
}
