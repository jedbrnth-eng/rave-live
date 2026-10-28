// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation

/// Synced lyrics: LRC parsing, title cleaning, the remix guard, the LRCLIB client and the on-disk cache.
/// Everything here is pure or injectable so it is unit-tested; the overlay (LyricsOverlay.swift) only draws.

struct LyricLine: Equatable, Codable { let time: Double; let text: String }

enum LRC {
    private static let timeTag = try! NSRegularExpression(pattern: #"^(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?$"#)

    /// Parses LRC text. Several timestamps on one line give one entry each, `[offset:±ms]` is applied
    /// (positive = lyrics sooner), timed blank lines are kept as "" (they clear the screen), anything else is skipped.
    static func parse(_ text: String) -> [LyricLine] {
        var out: [(Int, LyricLine)] = []
        var offsetMs = 0.0
        for raw in text.components(separatedBy: "\n") {
            var rest = Substring(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            var times: [Double] = []
            var sawOther = false
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: rest.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
                rest = rest[rest.index(after: close)...]
                if let t = time(tag) { times.append(t); continue }
                if tag.lowercased().hasPrefix("offset:") {
                    let v = tag.dropFirst(7).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
                    if let ms = Double(v) { offsetMs = ms }
                }
                sawOther = true
                break
            }
            guard !times.isEmpty, !sawOther else { continue }
            let line = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            for t in times { out.append((out.count, LyricLine(time: t, text: line))) }
        }
        let shift = offsetMs / 1000
        return out.sorted { $0.1.time != $1.1.time ? $0.1.time < $1.1.time : $0.0 < $1.0 }
            .map { LyricLine(time: max(0, $0.1.time - shift), text: $0.1.text) }
    }

    private static func time(_ tag: String) -> Double? {
        let ns = tag as NSString
        guard let m = timeTag.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              let mins = Double(ns.substring(with: m.range(at: 1))), let secs = Double(ns.substring(with: m.range(at: 2))), secs < 60 else { return nil }
        var frac = 0.0
        if m.range(at: 3).location != NSNotFound { frac = Double("0." + ns.substring(with: m.range(at: 3))) ?? 0 }
        return mins * 60 + secs + frac
    }

    /// Index of the line showing at time `t` (the last line that started at or before `t`), nil before the first line.
    static func index(at t: Double, in lines: [LyricLine]) -> Int? {
        var lo = 0, hi = lines.count - 1, best: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }
}

enum TrackTitle {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let qualifier = #"feat\.?|ft\.?|featuring|with|remix|rmx|edit|mix|version|remaster(ed)?|official|video|audio|lyrics?|clean|explicit|dirty|instrumental|vip|bootleg|flip|mash-?up|rework|refix|radio|extended|original|live|prod\.?|bonus|visuali[sz]er|hq|hd"#
    /// The same list minus words that are often part of a real title ("Stay (With Me)", "(Live Forever)", "(Video Games)").
    private static let strongQualifier = #"feat\.?|ft\.?|featuring|remix|rmx|edit|mix|remaster(ed)?|official|lyrics?|clean|explicit|dirty|instrumental|vip|bootleg|flip|mash-?up|rework|refix|radio|extended|prod\.?|visuali[sz]er"#
    private static let group = re(#"\s*[\(\[\{]([^\(\)\[\]\{\}]*)[\)\]\}]"#)
    private static let qualifierWord = re("\\b(" + qualifier + ")(\\b|\\s|$)")
    private static let strongQualifierWord = re("\\b(" + strongQualifier + ")(\\b|\\s|$)")
    private static let idLike = re(#"^\s*[A-Za-z0-9_\-]*\d[A-Za-z0-9_\-]*\s*$"#)
    private static let dashSuffix = re(#"\s+[-–—]\s+[^-–—]*\b(mix|remix|rmx|edit|version|remaster(ed)?|radio|extended|original|live|mono|stereo|vip|bootleg|flip|rework|refix|demo|instrumental|clean|explicit)\b.*$"#)
    private static let featTail = re(#"\s+(feat\.|ft\.|featuring)\s+.*$"#)
    private static let artistSplit = re(#"\s*(,|;|&|\s+x\s+|\s+vs\.?\s+|\s+/\s+)\s*"#)
    private static let anywhereMarker = re(#"\b(remix|rmx|bootleg|mash-?up|mash up|re-?edit|rework|refix)\b"#)
    private static let qualifierMarker = re(#"\b(edit|vip|flip|dub|blend)\b"#)
    private static let dashPart = re(#"\s+[-–—]\s+(.*)$"#)
    /// Radio / clean / explicit / single edits keep the original arrangement, so they are not remixes.
    /// The ±3 s length check in LyricsGate still rejects any that were cut differently.
    private static let sameArrangementEdit = re(#"\b(radio|clean|explicit|dirty|single|album)\s+edit\b"#)

    private static func replace(_ r: NSRegularExpression, in s: String, with t: String = "") -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
    }
    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Title for the lyrics lookup: drops (feat. …), (… Remix), [Edit], "- Extended Mix", "- Remastered", bracketed ids.
    /// `strict: false` keeps bracket groups whose only qualifier words can also be real title words (with, live, video…).
    static func clean(_ title: String, strict: Bool = true) -> String {
        var s = title
        let ns = s as NSString
        var cut: [NSRange] = []
        let words = strict ? qualifierWord : strongQualifierWord
        for m in group.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: m.range(at: 1))
            if matches(words, inner) || matches(idLike, inner) { cut.append(m.range) }
        }
        for r in cut.reversed() { s = (s as NSString).replacingCharacters(in: r, with: " ") }
        s = replace(dashSuffix, in: s)
        s = replace(featTail, in: s)
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return s.isEmpty ? title.trimmingCharacters(in: .whitespaces) : s
    }

    static func cleanArtist(_ a: String) -> String { replace(featTail, in: a).trimmingCharacters(in: .whitespaces) }

    /// First credited artist ("Future, Metro Boomin & Kendrick Lamar" -> "Future") for the search fallback.
    static func primaryArtist(_ a: String) -> String {
        let c = cleanArtist(a)
        let ns = c as NSString
        guard let m = artistSplit.firstMatch(in: c, range: NSRange(location: 0, length: ns.length)), m.range.location > 0 else { return c }
        return ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
    }

    /// True for remixes, edits, bootlegs, VIPs, flips and mashups. "remix", "bootleg", "mashup", "rework" count anywhere;
    /// "edit", "VIP", "flip", "dub", "blend" only inside brackets or after " - " (so "Flip Reverse" is not a remix).
    static func hasRemixMarker(_ title: String) -> Bool {
        if matches(anywhereMarker, title) { return true }
        let ns = title as NSString
        var parts = group.matches(in: title, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        if let m = dashPart.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)) { parts.append(ns.substring(with: m.range(at: 1))) }
        return parts.contains { matches(qualifierMarker, replace(sameArrangementEdit, in: $0)) }
    }
}

/// Remix guard: wrongly-timed lyrics look broken, no lyrics just looks like an instrumental.
/// Show synced lyrics only for an unmarked title whose length is within ±3 s of the LRCLIB match.
enum LyricsGate: Equatable {
    case show, remix, lengthDiffers, noLength
    static let tolerance = 3.0
    static func decide(rawTitle: String, trackDuration: Double?, matchDuration: Double?) -> LyricsGate {
        if TrackTitle.hasRemixMarker(rawTitle) { return .remix }
        guard let d = trackDuration, d > 0, let m = matchDuration, m > 0 else { return .noLength }
        return abs(d - m) <= tolerance + 1e-9 ? .show : .lengthDiffers
    }
}

struct LRCLIBRecord: Codable, Equatable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double?
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
    var hasSynced: Bool { !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasPlain: Bool { !(plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum LyricsResult: Equatable {
    case synced(LRCLIBRecord), instrumental, plainOnly, notFound, offline
}

/// LRCLIB (https://lrclib.net, free, no key): `/api/get` with the duration first, `/api/search` on a miss or a 5xx.
/// 5xx/429 are retried once with a short backoff; a network error means "offline" straight away.
final class LRCLIBClient: @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    static let userAgent = "RAVE LIVE/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (https://github.com/jedbrnth-eng/rave-live)"
    static var defaultHost: String { ProcessInfo.processInfo.environment["RAVE_LRCLIB_HOST"] ?? "https://lrclib.net" }
    let host: String
    private let transport: Transport
    private let retryDelay: Double
    let timeout: Double = 6

    init(host: String = LRCLIBClient.defaultHost, transport: Transport? = nil, retryDelay: Double = 0.6) {
        self.host = host.hasSuffix("/") ? String(host.dropLast()) : host
        self.retryDelay = retryDelay
        self.transport = transport ?? { req in
            let (d, r) = try await URLSession.shared.data(for: req)
            return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private enum Reply { case ok(Data), missing, server, network }

    private static let allowed: CharacterSet = { var c = CharacterSet.alphanumerics; c.insert(charactersIn: "-._~"); return c }()
    private func request(_ path: String, _ q: [(String, String)]) -> URLRequest? {
        let query = q.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: Self.allowed) ?? "")" }.joined(separator: "&")
        guard let u = URL(string: host + path + "?" + query) else { return nil }
        var r = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    private func call(_ path: String, _ q: [(String, String)]) async -> Reply {
        guard let req = request(path, q) else { return .network }
        for attempt in 0..<2 {
            if Task.isCancelled { return .network }               // lyrics switched off / track changed: send nothing more
            do {
                let (data, code) = try await transport(req)
                if (200..<300).contains(code) { return .ok(data) }
                if code == 404 { return .missing }
                if code >= 500 || code == 429 {
                    if attempt == 0, retryDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1e9)) }
                    continue
                }
                return .missing
            } catch {
                return .network
            }
        }
        return .server
    }

    /// `cacheable` is false when the answer may be a fluke: the exact `/api/get` lookup hit a server error, or the lookup
    /// was cancelled. Such results are shown but not stored, so one bad minute at LRCLIB doesn't stick to a song.
    struct Lookup { let result: LyricsResult; let cacheable: Bool }

    func lookup(title: String, artist: String, album: String?, duration: Double?) async -> LyricsResult {
        await lookupDetailed(title: title, artist: artist, album: album, duration: duration).result
    }

    func lookupDetailed(title: String, artist: String, album: String?, duration: Double?) async -> Lookup {
        if Task.isCancelled { return Lookup(result: .offline, cacheable: false) }
        // Lenient title first ("Stay (With Me)"), then the strict one ("Stay") if they differ.
        let titles = [TrackTitle.clean(title, strict: false), TrackTitle.clean(title)].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let a = TrackTitle.cleanArtist(artist)
        var sawPlain = false, getFailed = false
        if let d = duration, d > 0 {
            for t in titles {
                var q = [("track_name", t), ("artist_name", a)]
                if let al = album?.trimmingCharacters(in: .whitespaces), !al.isEmpty { q.append(("album_name", al)) }
                q.append(("duration", String(Int(d.rounded()))))
                switch await call("/api/get", q) {
                case .ok(let data):
                    if let r = try? JSONDecoder().decode(LRCLIBRecord.self, from: data) {
                        if r.instrumental { return Lookup(result: .instrumental, cacheable: true) }
                        if r.hasSynced { return Lookup(result: .synced(r), cacheable: true) }
                        sawPlain = sawPlain || r.hasPlain
                    }
                case .network: return Lookup(result: .offline, cacheable: false)
                case .server: getFailed = true
                case .missing: break
                }
            }
        }
        if Task.isCancelled { return Lookup(result: .offline, cacheable: false) }
        let cacheable = !getFailed
        switch await call("/api/search", [("track_name", titles[0]), ("artist_name", TrackTitle.primaryArtist(a))]) {
        case .ok(let data):
            let list = (try? JSONDecoder().decode([LRCLIBRecord].self, from: data)) ?? []
            if let best = Self.pickBest(list, duration: duration) { return Lookup(result: .synced(best), cacheable: cacheable) }
            if list.contains(where: \.instrumental) && !list.contains(where: \.hasPlain) { return Lookup(result: .instrumental, cacheable: cacheable) }
            return Lookup(result: (sawPlain || list.contains(where: \.hasPlain)) ? .plainOnly : .notFound, cacheable: cacheable)
        case .missing: return Lookup(result: sawPlain ? .plainOnly : .notFound, cacheable: cacheable)
        case .server, .network: return Lookup(result: sawPlain ? .plainOnly : .offline, cacheable: false)
        }
    }

    /// Synced, non-instrumental result closest in length to the playing track (first one if the length is unknown).
    static func pickBest(_ list: [LRCLIBRecord], duration: Double?) -> LRCLIBRecord? {
        let c = list.filter { $0.hasSynced && !$0.instrumental }
        guard let d = duration, d > 0 else { return c.first }
        return c.min { abs(($0.duration ?? 1e9) - d) < abs(($1.duration ?? 1e9) - d) }
    }
}

/// Per-track results on disk (Application Support/RAVE LIVE/Lyrics, or `RAVE_LYRICS_CACHE`). Lyrics are fetched at
/// runtime and only ever stored here, never in the repo. "Not found" expires after 3 days; "offline" is never stored.
final class LyricsCache {
    let dir: URL
    static let notFoundTTL: TimeInterval = 3 * 86400

    init(dir: URL) { self.dir = dir }
    static var defaultDir: URL {
        if let p = ProcessInfo.processInfo.environment["RAVE_LYRICS_CACHE"] { return URL(fileURLWithPath: NSString(string: p).expandingTildeInPath) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("RAVE LIVE/Lyrics", isDirectory: true)
    }

    /// Stable file key: FNV-1a of the lower-cased cleaned title, artist and whole-second length.
    static func key(title: String, artist: String, duration: Double?) -> String {
        let s = "\(TrackTitle.clean(title).lowercased())|\(TrackTitle.cleanArtist(artist).lowercased())|\(Int((duration ?? 0).rounded()))"
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    private struct Entry: Codable { var kind: String; var record: LRCLIBRecord?; var saved: Double }
    private func url(_ key: String) -> URL { dir.appendingPathComponent(key + ".json") }

    func load(_ key: String) -> LyricsResult? {
        guard let d = try? Data(contentsOf: url(key)), let e = try? JSONDecoder().decode(Entry.self, from: d) else { return nil }
        switch e.kind {
        case "synced": return e.record.map { .synced($0) }
        case "instrumental": return .instrumental
        case "plainOnly": return Date().timeIntervalSince1970 - e.saved < Self.notFoundTTL ? .plainOnly : nil   // synced lyrics may get added
        case "notFound": return Date().timeIntervalSince1970 - e.saved < Self.notFoundTTL ? .notFound : nil
        default: return nil
        }
    }

    /// Store only answers that are worth keeping: never a fluke (`cacheable` false) or offline, and a synced match only
    /// when the remix/length gate would show it (a wrong-length search hit must not pin the song to "other version").
    static func shouldStore(_ r: LyricsResult, cacheable: Bool, gate: LyricsGate?) -> Bool {
        guard cacheable, r != .offline else { return false }
        if case .synced = r { return gate == .show }
        return true
    }

    func store(_ r: LyricsResult, _ key: String, now: Double = Date().timeIntervalSince1970) {
        let e: Entry
        switch r {
        case .synced(let rec): e = Entry(kind: "synced", record: rec, saved: now)   // callers check shouldStore first
        case .instrumental: e = Entry(kind: "instrumental", record: nil, saved: now)
        case .plainOnly: e = Entry(kind: "plainOnly", record: nil, saved: now)
        case .notFound: e = Entry(kind: "notFound", record: nil, saved: now)
        case .offline: return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(e) { try? d.write(to: url(key), options: .atomic) }
    }
}
