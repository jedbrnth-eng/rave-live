// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import Foundation

/// The user's MilkDrop presets: scanning, search, favourites, ratings, the "broken" list, picking, and the
/// one-click download of the projectM "cream of the crop" pack. Everything lives in
/// ~/Library/Application Support/RAVE LIVE/MilkDrop/ (presets/ for the pack, "My Presets" for the user's own .milk files).
final class MilkDropLibrary: @unchecked Sendable {
    struct Preset {
        let url: URL
        let key: String          // path relative to its root folder (stable across machines), used for favourites/ratings
        let name: String
        let author: String
        let category: String
    }

    /// The pack offered by "Get MilkDrop presets…". Presets are mostly unlicensed community works that projectM treats as
    /// public domain (removal on author request); we download on the user's click and never commit them.
    static let packURL = URL(string: "https://github.com/projectM-visualizer/presets-cream-of-the-crop/archive/refs/heads/master.zip")!
    static let packInfo = "projectM \"cream of the crop\": about 9,800 presets, a 32 MB download (about 130 MB on disk)"
    /// Pack categories that are made for loud moments vs. calm ones (folder names in cream of the crop).
    static let loudCategories: Set<String> = ["Sparkle", "Supernova", "Dancer", "Waveform", "Geometric"]
    static let calmCategories: Set<String> = ["Reaction", "Hypnotic", "Drawing", "Fractal", "Particles"]
    /// Folders never picked automatically: the pack's "fade to black" transition presets.
    static let skipCategories: Set<String> = ["! Transition"]

    static let root: URL = {
        // RAVE_MILKDROP_ROOT moves everything elsewhere (tests, portable setups)
        if let r = ProcessInfo.processInfo.environment["RAVE_MILKDROP_ROOT"] { return URL(fileURLWithPath: r, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath)
        return base.appendingPathComponent("RAVE LIVE/MilkDrop", isDirectory: true)
    }()
    static var packDir: URL { root.appendingPathComponent("presets", isDirectory: true) }
    static var userDir: URL { root.appendingPathComponent("My Presets", isDirectory: true) }
    /// Presets shipped inside the app bundle (Contents/Resources/MilkDrop). Empty today: bundling a curated set in the
    /// DMG is a one-line change in make_app.sh (copy a folder of .milk files to that path).
    static var bundledDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("MilkDrop", isDirectory: true) }

    private let lock = NSLock()
    private(set) var presets: [Preset] = []
    private var byKey: [String: Int] = [:]
    /// Extra folders (`--milk-dir`), scanned in addition to the standard ones.
    var extraDirs: [URL] = []

    // persisted state
    private struct Store: Codable { var favorites: [String] = []; var ratings: [String: Int] = [:]; var broken: [String: String] = [:] }
    private var store = Store()
    private let storeURL: URL
    private var rng = SystemRandomNumberGenerator()
    private var recent: [String] = []

    /// `--milk-store <file>` keeps test runs away from the user's favourites/ratings.
    static var defaultStoreURL: URL {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--milk-store"), i + 1 < a.count { return URL(fileURLWithPath: NSString(string: a[i + 1]).expandingTildeInPath) }
        return root.appendingPathComponent("library.json")
    }

    init(storeURL: URL = MilkDropLibrary.defaultStoreURL) {
        self.storeURL = storeURL
        if let d = try? Data(contentsOf: storeURL), let s = try? JSONDecoder().decode(Store.self, from: d) { store = s }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return presets.count }
    var isEmpty: Bool { count == 0 }

    /// Rescan all preset folders (fast: ~10k files in well under a second).
    func scan() {
        var found: [Preset] = []
        var roots = [Self.packDir, Self.userDir] + extraDirs
        if let b = Self.bundledDir { roots.append(b) }
        let fm = FileManager.default
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            let rootPath = root.standardizedFileURL.path
            for case let u as URL in en where u.pathExtension.lowercased() == "milk" {
                var rel = u.standardizedFileURL.path
                if rel.hasPrefix(rootPath + "/") { rel = String(rel.dropFirst(rootPath.count + 1)) }
                found.append(Self.describe(url: u, rel: rel))
            }
        }
        found.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        var idx: [String: Int] = [:]
        for (i, p) in found.enumerated() { idx[p.key] = i }
        lock.lock(); presets = found; byKey = idx; lock.unlock()
    }

    /// "Author - Title.milk" is the community naming convention; category = the pack folder it sits in.
    static func describe(url: URL, rel: String) -> Preset {
        let base = url.deletingPathExtension().lastPathComponent
        var author = "", name = base
        if let r = base.range(of: " - ") {
            author = String(base[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            name = String(base[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        let parts = rel.split(separator: "/").map(String.init)
        // pack layout: presets-cream-of-the-crop-master/<Category>/<Sub>/file.milk
        var category = parts.count > 1 ? parts[parts.count - 2] : ""
        if let i = parts.firstIndex(where: { $0.hasPrefix("presets-") }), i + 2 < parts.count { category = parts[i + 1] }
        return Preset(url: url, key: rel, name: name, author: author, category: category)
    }

    // MARK: - search, favourites, ratings, broken

    func search(_ q: String, favoritesOnly: Bool = false) -> [Preset] {
        lock.lock(); let all = presets; let favs = Set(store.favorites); lock.unlock()
        let terms = q.lowercased().split(separator: " ").map(String.init)
        return all.filter { p in
            if favoritesOnly && !favs.contains(p.key) { return false }
            if terms.isEmpty { return true }
            let hay = (p.name + " " + p.author + " " + p.category).lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }
    func preset(forKey k: String) -> Preset? { lock.lock(); defer { lock.unlock() }; return byKey[k].map { presets[$0] } }
    func preset(at url: URL) -> Preset {
        let path = url.standardizedFileURL.path
        lock.lock(); let hit = presets.first { $0.url.standardizedFileURL.path == path }; lock.unlock()
        return hit ?? Self.describe(url: url, rel: path)
    }
    func isFavorite(_ p: Preset) -> Bool { lock.lock(); defer { lock.unlock() }; return store.favorites.contains(p.key) }
    @discardableResult func toggleFavorite(_ p: Preset) -> Bool {
        lock.lock()
        let on: Bool
        if let i = store.favorites.firstIndex(of: p.key) { store.favorites.remove(at: i); on = false } else { store.favorites.append(p.key); on = true }
        lock.unlock(); save(); return on
    }
    func rating(_ p: Preset) -> Int { lock.lock(); defer { lock.unlock() }; return store.ratings[p.key] ?? 0 }
    func setRating(_ p: Preset, _ r: Int) { lock.lock(); store.ratings[p.key] = r == 0 ? nil : max(1, min(5, r)); lock.unlock(); save() }
    func brokenReason(_ p: Preset) -> String? { lock.lock(); defer { lock.unlock() }; return store.broken[p.key] }
    var brokenCount: Int { lock.lock(); defer { lock.unlock() }; return store.broken.count }
    func markBroken(_ p: Preset, reason: String) { lock.lock(); store.broken[p.key] = reason; lock.unlock(); save() }
    func clearBroken() { lock.lock(); store.broken = [:]; lock.unlock(); save() }

    private func save() {
        lock.lock(); let s = store; lock.unlock()
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: storeURL, options: .atomic) }
    }

    // MARK: - picking

    /// Weighted random pick for automatic changes: skips broken, transition-to-black and 1-star presets,
    /// favours favourites (x4) and higher ratings, avoids the last 64 picks (at most half the library), and on loud moments prefers loud categories.
    func pick(loud: Bool) -> Preset? {
        lock.lock(); defer { lock.unlock() }
        guard !presets.isEmpty else { return nil }
        // avoid recent picks, but never more than half the library (small user folders must still rotate)
        let favs = Set(store.favorites), avoid = Set(recent.suffix(min(64, presets.count / 2)))
        let want = loud ? Self.loudCategories : Self.calmCategories
        var best: Preset?
        var bestScore = -1.0
        // sample instead of scoring all ~10k presets every phrase (small libraries: score every preset)
        let candidates: [Int] = presets.count <= 400 ? Array(0..<presets.count) : (0..<400).map { _ in Int.random(in: 0..<presets.count, using: &rng) }
        for i in candidates {
            let p = presets[i]
            if store.broken[p.key] != nil || Self.skipCategories.contains(p.category) || avoid.contains(p.key) { continue }
            let r = store.ratings[p.key] ?? 0
            if r == 1 { continue }
            var w = favs.contains(p.key) ? 4.0 : 1.0
            if r > 0 { w *= Double(r) / 3 }
            if want.contains(p.category) { w *= 2 }
            let score = w * Double.random(in: 0.5..<1, using: &rng)
            if score > bestScore { bestScore = score; best = p }
        }
        if let b = best { recent.append(b.key); if recent.count > 64 { recent.removeFirst() } }
        return best
    }

    /// Neighbour in the sorted list (for [ / ]), skipping broken presets.
    func neighbour(of key: String?, step: Int) -> Preset? {
        lock.lock(); defer { lock.unlock() }
        guard !presets.isEmpty else { return nil }
        var i = key.flatMap { byKey[$0] } ?? (step > 0 ? -1 : 0)
        for _ in 0..<presets.count {
            i = ((i + step) % presets.count + presets.count) % presets.count
            if store.broken[presets[i].key] == nil { return presets[i] }
        }
        return nil
    }

    /// Deterministic sample for the test sweep (`--milk-sweep N`).
    func sample(_ n: Int, seed: UInt64) -> [Preset] {
        lock.lock(); var all = presets; lock.unlock()
        var s = seed
        for i in stride(from: all.count - 1, to: 0, by: -1) {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            all.swapAt(i, Int(s % UInt64(i + 1)))
        }
        return Array(all.prefix(n))
    }

    // MARK: - download + folders

    enum DownloadState { case idle, downloading(Double), unpacking, failed(String), done(Int) }
    private(set) var download: DownloadState = .idle
    private var task: URLSessionDownloadTask?
    private var progressObs: NSKeyValueObservation?

    /// Download + unpack the pack into packDir (replacing an older copy). Progress is polled through `download`.
    func downloadPack(completion: @escaping (Bool) -> Void) {
        if case .downloading = download { return }
        download = .downloading(0)
        let t = URLSession.shared.downloadTask(with: Self.packURL) { [weak self] tmp, resp, err in
            guard let self else { return }
            guard let tmp, err == nil, (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400 else {
                self.download = .failed(err?.localizedDescription ?? "HTTP error"); completion(false); return
            }
            self.download = .unpacking
            let fm = FileManager.default
            let zip = fm.temporaryDirectory.appendingPathComponent("ravelive-milkdrop-\(UUID().uuidString).zip")
            let staging = Self.root.appendingPathComponent(".unpack", isDirectory: true)
            do {
                try fm.moveItem(at: tmp, to: zip)
                try? fm.removeItem(at: staging)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", zip.path, staging.path]
                try p.run(); p.waitUntilExit()
                try? fm.removeItem(at: zip)
                guard p.terminationStatus == 0 else { throw NSError(domain: "unzip", code: Int(p.terminationStatus)) }
                try? fm.removeItem(at: Self.packDir)
                try fm.moveItem(at: staging, to: Self.packDir)
            } catch {
                try? fm.removeItem(at: staging)
                self.download = .failed("unpack failed: \(error.localizedDescription)"); completion(false); return
            }
            self.scan()
            self.download = .done(self.count)
            completion(true)
        }
        progressObs = t.progress.observe(\.fractionCompleted) { [weak self] pr, _ in self?.download = .downloading(pr.fractionCompleted) }
        task = t
        t.resume()
    }

    /// Ask (showing the size) and then download. Main thread.
    func confirmAndDownload(completion: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = "Get MilkDrop presets?"
        a.informativeText = Self.packInfo + ", from github.com/projectM-visualizer/presets-cream-of-the-crop.\n\n"
            + "They go into ~/Library/Application Support/RAVE LIVE/MilkDrop. The presets are community works collected by the projectM team; authors can ask for removal."
        a.addButton(withTitle: "Download"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        downloadPack(completion: completion)
    }

    /// Opens "My Presets" in Finder (created on first use) so people can drop their own .milk files in.
    func openUserFolder() {
        try? FileManager.default.createDirectory(at: Self.userDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.userDir)
    }
}
