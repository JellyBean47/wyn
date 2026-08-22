//
//  SteamArtwork.swift
//  WynKit
//
//  Steam library capsules for the Wyn library UI. Local cache first, then CDN.
//

import Foundation

public enum SteamArtwork {
    /// Portrait / header / logo bytes for a Steam app. Nil if nothing local or on CDN.
    public static func imageData(for appId: Int, in bottle: Bottle?) async -> Data? {
        let root: URL?
        if let bottle {
            root = steamRoot(in: bottle)
        } else {
            root = nil
        }
        return await ArtworkCache.shared.data(for: appId, steamRoot: root)
    }

    public static var diskCacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: WynBrand.supportIdentifier)
            .appending(path: "LibraryArt")
    }

    static func steamRoot(in bottle: Bottle) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
    }
}

private actor ArtworkCache {
    static let shared = ArtworkCache()

    private var memory: [Int: Data] = [:]
    private var inflight: [Int: Task<Data?, Never>] = [:]

    func data(for appId: Int, steamRoot: URL?) async -> Data? {
        if let cached = memory[appId] { return cached }
        if let existing = inflight[appId] {
            return await existing.value
        }
        let task = Task {
            await ArtworkLoader.load(appId: appId, steamRoot: steamRoot)
        }
        inflight[appId] = task
        let data = await task.value
        inflight[appId] = nil
        if let data {
            memory[appId] = data
        }
        return data
    }
}

private enum ArtworkLoader {
    static func load(appId: Int, steamRoot: URL?) async -> Data? {
        if let steamRoot, let data = readLocal(appId: appId, steamRoot: steamRoot) {
            return data
        }
        if let data = readDiskCache(appId: appId) {
            return data
        }
        if let data = await download(appId: appId) {
            writeDiskCache(appId: appId, data: data)
            return data
        }
        return nil
    }

    private static func readLocal(appId: Int, steamRoot: URL) -> Data? {
        let librarycache = steamRoot
            .appending(path: "appcache")
            .appending(path: "librarycache")

        let exact = [
            librarycache.appending(path: "\(appId)_library_600x900.jpg"),
            librarycache.appending(path: "\(appId)_library_600x900.png"),
            librarycache.appending(path: "\(appId)_header.jpg"),
            librarycache.appending(path: "\(appId)_logo.png"),
            librarycache.appending(path: "\(appId)p.jpg"),
        ]
        for url in exact where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            if let data = try? Data(contentsOf: url), data.count > 32 { return data }
        }

        if let hashed = firstMatch(
            in: librarycache.appending(path: "\(appId)"),
            preferring: ["library_600x900", "header", "library_hero", "logo"]
        ) {
            if let data = try? Data(contentsOf: hashed), data.count > 32 { return data }
        }

        return nil
    }

    private static func firstMatch(in directory: URL, preferring needles: [String]) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path(percentEncoded: false)),
              let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return nil }

        let imageExt: Set<String> = ["jpg", "jpeg", "png", "webp"]
        var ranked: [Int: URL] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard imageExt.contains(url.pathExtension.lowercased()) else { continue }
            let name = url.lastPathComponent.lowercased()
            for (index, needle) in needles.enumerated() where name.contains(needle) {
                if ranked[index] == nil { ranked[index] = url }
                break
            }
        }
        return ranked.keys.sorted().first.flatMap { ranked[$0] }
    }

    private static func diskURL(appId: Int, ext: String) -> URL {
        SteamArtwork.diskCacheDirectory.appending(path: "\(appId).\(ext)")
    }

    private static func readDiskCache(appId: Int) -> Data? {
        for ext in ["jpg", "jpeg", "png", "webp"] {
            let url = diskURL(appId: appId, ext: ext)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            if let data = try? Data(contentsOf: url), data.count > 32 { return data }
        }
        return nil
    }

    private static func writeDiskCache(appId: Int, data: Data) {
        let dir = SteamArtwork.diskCacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: diskURL(appId: appId, ext: "jpg"), options: .atomic)
    }

    private static func download(appId: Int) async -> Data? {
        let hosts = [
            "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps",
            "https://cdn.cloudflare.steamstatic.com/steam/apps",
            "https://cdn.akamai.steamstatic.com/steam/apps",
        ]
        let files = ["library_600x900.jpg", "header.jpg"]
        for host in hosts {
            for file in files {
                guard let url = URL(string: "\(host)/\(appId)/\(file)") else { continue }
                if let data = await fetchImage(url) { return data }
            }
        }
        return nil
    }

    private static func fetchImage(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Wyn/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                return nil
            }
            guard data.count > 512 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
