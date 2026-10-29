// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation

/// Synced lyrics: LRC parsing, title cleaning, the remix guard, the LRCLIB client and the on-disk cache.
/// Everything here is pure or injectable so it is unit-tested; the overlay (LyricsOverlay.swift) only draws.

struct LyricLine: Equatable, Codable {
    let time: Double; let text: String
    /// Per-word times from enhanced LRC `<mm:ss.xx>` tags (nil = line timing only, the usual case on LRCLIB).
    var words: [TimedWord]? = nil
}

enum LRC {
    private static let timeTag = try! NSRegularExpression(pattern: #"^(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?$"#)
    private static let wordTag = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)

    /// Parses LRC text. Several timestamps on one line give one entry each, `[offset:±ms]` is applied
    /// (positive = lyrics sooner), timed blank lines are kept as "" (they clear the screen), anything else is skipped.
    /// A real song's LRC is a few KB (enhanced LRC with word tags maybe 20 KB). Anything bigger is broken or hostile and is
    /// cut here, so parsing it on the main thread can't stall the show for seconds.
    static let maxBytes = 128 * 1024, maxLines = 2000
    static func parse(_ text: String) -> [LyricLine] {
        var out: [(Int, LyricLine)] = []
        var offsetMs = 0.0
        var text = text
        if text.utf8.count > maxBytes {                          // keep whole lines only
            let head = text.utf8.prefix(maxBytes)
            let cut = head.lastIndex(of: UInt8(ascii: "\n")) ?? head.endIndex
            text = String(decoding: text.utf8[..<cut], as: UTF8.self)
        }
        for raw in text.components(separatedBy: "\n") {
            if out.count >= maxLines { break }
            var rest = Substring(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            var times: [Double] = []
            var sawOther = false
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: rest.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
                rest = rest[rest.index(after: close)...]
                if let t = time(tag) { times.append(t); continue }
                if tag.lowercased().hasPrefix("offset:") {
                    let v = tag.dropFirst(7).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
                    if let ms = Double(v), ms.isFinite, abs(ms) <= 60_000 { offsetMs = ms }   // "-inf"/"nan" parse as Doubles
                }
                sawOther = true
                break
            }
            guard !times.isEmpty, !sawOther else { continue }
            var line = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            var words: [TimedWord]?
            if line.contains("<") {                                  // enhanced LRC: per-word <mm:ss.xx> tags
                words = times.count == 1 ? wordTimes(line, lineTime: times[0]) : nil
                line = wordTag.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
                line = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            }
            for t in times { out.append((out.count, LyricLine(time: t, text: line, words: words))) }
        }
        let shift = offsetMs / 1000
        return out.sorted { $0.1.time != $1.1.time ? $0.1.time < $1.1.time : $0.0 < $1.0 }
            .map { LyricLine(time: max(0, $0.1.time - shift), text: $0.1.text,
                             words: $0.1.words?.map { TimedWord(text: $0.text, start: max(0, $0.start - shift), end: max(0, $0.end - shift)) }) }
    }

    /// Words with their `<mm:ss.xx>` start times. Text before the first tag starts at the line time; several words after one
    /// tag share the span to the next tag; a trailing tag gives the last word its end. nil when the tags make no sense.
    static func wordTimes(_ s: String, lineTime: Double) -> [TimedWord]? {
        let ns = s as NSString
        let ms = wordTag.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return nil }
        var segs: [(Double, String)] = []
        var cursor = 0, t = lineTime
        for m in ms {
            segs.append((t, ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
            let tag = ns.substring(with: m.range).dropFirst().dropLast()
            guard let v = time(String(tag)) else { return nil }
            t = v; cursor = m.range.location + m.range.length
        }
        segs.append((t, ns.substring(from: cursor)))
        var out: [TimedWord] = []
        for (i, (start, text)) in segs.enumerated() {
            let toks = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let nextT = i + 1 < segs.count ? segs[i + 1].0 : start + 0.5 * Double(max(1, toks.count))
            let step = (nextT - start) / Double(max(1, toks.count))
            for (k, w) in toks.enumerated() { out.append(TimedWord(text: w, start: start + step * Double(k), end: start + step * Double(k + 1))) }
        }
        for i in 1..<max(1, out.count) where out[i].start < out[i - 1].start { return nil }   // out-of-order tags: ignore them
        for i in 0..<out.count where i + 1 < out.count { out[i].end = out[i + 1].start }
        if let last = out.last, last.end < last.start { return nil }                   // trailing tag goes backwards
        return out.isEmpty ? nil : out
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
    private static let qualifier = #"feat\.?|ft\.?|featuring|with|remix|rmx|edit|mix|version|remaster(ed)?|official|video|audio|lyrics?|clean|explicit|dirty|instrumental|vip|bootleg|flip|mash-?up|rework|refix|radio|extended|original|live|prod\.?|bonus|visuali[sz]er|hq|hd|4k|directed\s+by|dir\.|m/?v"#
    /// The same list minus words that are often part of a real title ("Stay (With Me)", "(Live Forever)", "(Video Games)").
    private static let strongQualifier = #"feat\.?|ft\.?|featuring|remix|rmx|edit|mix|remaster(ed)?|official|lyrics?|clean|explicit|dirty|instrumental|vip|bootleg|flip|mash-?up|rework|refix|radio|extended|prod\.?|visuali[sz]er|audio|hq|hd|4k|music\s+video|directed\s+by|dir\.|m/?v"#
    private static let group = re(#"\s*[\(\[\{]([^\(\)\[\]\{\}]*)[\)\]\}]"#)
    private static let qualifierWord = re("\\b(" + qualifier + ")(\\b|\\s|$)")
    private static let strongQualifierWord = re("\\b(" + strongQualifier + ")(\\b|\\s|$)")
    private static let idLike = re(#"^\s*[A-Za-z0-9_\-]*\d[A-Za-z0-9_\-]*\s*$"#)
    private static let dashSuffix = re(#"\s+[-–—]\s+[^-–—]*\b(mix|remix|rmx|edit|version|remaster(ed)?|radio|extended|original|live|mono|stereo|vip|bootleg|flip|rework|refix|demo|instrumental|clean|explicit)\b.*$"#)
    private static let featTail = re(#"\s+(feat\.|ft\.|featuring)\s+.*$"#)
    /// Browser titles also write "feat X" / "ft X" without the dot.
    private static let looseFeatTail = re(#"\s+(feat\.?|ft\.?|featuring)\s+.*$"#)
    /// "Song | Official Video", "Song | Artist" (YouTube title decorations after a bar).
    private static let barTail = re(#"\s+[|｜]\s+.*$"#)
    /// Channel-name decorations: "NobodyVEVO", "Nobody Official", "Nobody - Topic".
    private static let channelTail = re(#"(\s*vevo|\s+official(\s+channel)?|\s+-\s+topic)\s*$"#)
    private static let artistTitleDash = re(#"^(.+?)\s+[-–—]\s+(.+)$"#)
    private static let artistSplit = re(#"\s*(,|;|&|\s+x\s+|\s+vs\.?\s+|\s+/\s+)\s*"#)
    private static let anywhereMarker = re(#"\b(remix|rmx|bootleg|mash-?up|mash up|re-?edit|rework|refix)\b"#)
    private static let qualifierMarker = re(#"\b(edit|vip|flip|dub|blend|sped[\s-]?up|slowed|nightcore|8d)\b"#)
    /// YouTube's auto-generated "<Artist> - Topic" channels (browser playback reports the channel as the artist).
    private static let topicChannel = try! NSRegularExpression(pattern: #"\s+-\s+Topic\s*$"#)
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

    static func cleanArtist(_ a: String) -> String { replace(featTail, in: replace(topicChannel, in: a)).trimmingCharacters(in: .whitespaces) }

    /// First credited artist ("Future, Metro Boomin & Kendrick Lamar" -> "Future") for the search fallback.
    static func primaryArtist(_ a: String) -> String {
        let c = cleanArtist(a)
        let ns = c as NSString
        guard let m = artistSplit.firstMatch(in: c, range: NSRange(location: 0, length: ns.length)), m.range.location > 0 else { return c }
        return ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
    }

    /// Browsers report a YouTube (or SoundCloud, Bandcamp…) video: the title is the video title and the artist the channel.
    static let browserBundleIDs: Set<String> = ["app.zen-browser.zen", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.brave.Browser.beta", "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition", "company.thebrowser.Browser", "company.thebrowser.dia", "com.microsoft.edgemac",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX", "com.vivaldi.Vivaldi", "org.chromium.Chromium", "com.kagi.kagimacOS",
        "org.waterfoxproject.waterfox", "net.imput.helium"]
    static func isBrowser(_ bundleID: String) -> Bool { browserBundleIDs.contains(bundleID) }

    /// Channel name as an artist: "Nobody - Topic", "NobodyVEVO", "Nobody Official" -> "Nobody".
    static func cleanChannel(_ a: String) -> String {
        let c = replace(channelTail, in: a).trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? a.trimmingCharacters(in: .whitespaces) : c
    }
    private static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Title and artist to look up. Real players send proper tags and pass through unchanged. Browsers send the video
    /// title and the channel: drop "| …" tails and loose "ft X", split "Artist - Title" (the channel is often a label or
    /// uploader, so the part before the dash wins), and use the cleaned channel name as the artist otherwise.
    static func lookupIdentity(title: String, artist: String, bundleID: String) -> (title: String, artist: String, videoTitle: String) {
        guard isBrowser(bundleID) else { return (title, artist, title) }
        var t = replace(barTail, in: title).trimmingCharacters(in: .whitespaces)
        if t.isEmpty { t = title }
        var a = cleanChannel(artist)
        let ns = t as NSString
        // "Song - Remastered 2011" is a version tail, not "Artist - Title"
        if !matches(dashSuffix, t), let m = artistTitleDash.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) {
            let left = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let right = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if !a.isEmpty, norm(right) == norm(a) || norm(clean(right, strict: false)) == norm(a) { t = left }   // "Title - Artist"
            else { a = left; t = right }
        }
        let videoTitle = t                                       // the song part, still with its brackets (remix check)
        t = replace(looseFeatTail, in: t)
        // "(ft Someone)" without the dot inside brackets
        t = replace(re(#"\s*[\(\[](feat|ft)\s+[^\)\]]*[\)\]]"#), in: t)
        t = clean(t, strict: false).trimmingCharacters(in: .whitespaces)
        return (t.isEmpty ? title : t, a, videoTitle)
    }

    /// True for remixes, edits, bootlegs, VIPs, flips, mashups and speed versions. "remix", "bootleg", "mashup", "rework"
    /// count anywhere; "edit", "VIP", "flip", "dub", "blend", "sped up", "slowed", "nightcore", "8D" only inside brackets
    /// or after " - " (so "Flip Reverse" is not a remix).
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
/// Videos (browser playback) get two more answers: a music video up to 90 s longer than the song most likely adds an
/// intro, so sync with that offset (`intro(seconds)`); anything over twice the song is a compilation/mix (`longVideo`).
enum LyricsGate: Equatable {
    case show, remix, lengthDiffers, noLength, intro(Double), longVideo
    static let tolerance = 3.0
    static let introMax = 90.0
    static func decide(rawTitle: String, trackDuration: Double?, matchDuration: Double?, video: Bool = false) -> LyricsGate {
        if TrackTitle.hasRemixMarker(rawTitle) { return .remix }
        guard let d = trackDuration, d > 0, let m = matchDuration, m > 0 else { return .noLength }
        let extra = d - m
        if abs(extra) <= tolerance + 1e-9 { return .show }
        if d > 2 * m { return .longVideo }
        if video, extra > 0, extra <= introMax + 1e-9 { return .intro((extra * 10).rounded() / 10) }
        return .lengthDiffers
    }
    /// Short name for logs and the HUD debug line.
    var decision: String {
        switch self {
        case .show: return "synced (length match)"
        case .remix: return "skipped: remix/edit"
        case .lengthDiffers: return "skipped: length differs"
        case .noLength: return "skipped: no track length"
        case .intro(let s): return String(format: "synced: video intro %.1f s assumed", s)
        case .longVideo: return "skipped: long video/mix"
        }
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
    /// `busy`: LRCLIB kept answering 5xx/429 (overloaded) after the backoff; retried later, never cached.
    case synced(LRCLIBRecord), instrumental, plainOnly, notFound, offline, busy
}

/// LRCLIB (https://lrclib.net, free, no key): `/api/get` with the duration first, `/api/search` on a miss or a 5xx.
/// 5xx/429 back off exponentially with up to 30 % jitter and honour `Retry-After` (LRCLIB's docs require both): `/api/get`
/// is retried once, then the lookup moves on to `/api/search`, which gets up to three retries. A `Retry-After` longer than
/// `maxInlineWait` stops the lookup (`.busy` with the wait) so the app retries later instead of hammering the server.
/// A network error means "offline" straight away.
final class LRCLIBClient: @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    struct HTTPReply { var data: Data; var status: Int; var retryAfter: Double? }
    typealias RichTransport = @Sendable (URLRequest) async throws -> HTTPReply
    static let userAgent = "RAVE LIVE/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (https://github.com/jedbrnth-eng/rave-live)"
    static var defaultHost: String { ProcessInfo.processInfo.environment["RAVE_LRCLIB_HOST"] ?? "https://lrclib.net" }
    let host: String
    private let transport: RichTransport
    private let retryDelay: Double
    private let sleep: @Sendable (Double) async -> Void
    private let jitter: @Sendable () -> Double
    static let maxDelay = 8.0
    static let maxInlineWait = 20.0
    let timeout: Double = 6
    /// Default transport session. `timeout` (per request) is an idle timeout, so a server that trickles a byte every few
    /// seconds would never time out; the resource cap ends any request after 12 s. Ephemeral: nothing cached on disk.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 12
        return URLSession(configuration: c)
    }()

    init(host: String = LRCLIBClient.defaultHost, transport: Transport? = nil, richTransport: RichTransport? = nil, retryDelay: Double = 0.6,
         sleep: (@Sendable (Double) async -> Void)? = nil, jitter: (@Sendable () -> Double)? = nil) {
        self.host = host.hasSuffix("/") ? String(host.dropLast()) : host
        self.retryDelay = retryDelay
        self.sleep = sleep ?? { s in try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1e9)) }
        self.jitter = jitter ?? { Double.random(in: 0...1) }
        if let richTransport { self.transport = richTransport }
        else if let transport { self.transport = { req in let (d, c) = try await transport(req); return HTTPReply(data: d, status: c, retryAfter: nil) } }
        else {
            self.transport = { req in
                let (d, r) = try await LRCLIBClient.session.data(for: req)
                let h = r as? HTTPURLResponse
                return HTTPReply(data: d, status: h?.statusCode ?? 0, retryAfter: LRCLIBClient.parseRetryAfter(h?.value(forHTTPHeaderField: "Retry-After")))
            }
        }
    }

    /// Seconds from a `Retry-After` header: delta-seconds or an HTTP date (a past date = 0). nil when absent or unreadable.
    static func parseRetryAfter(_ v: String?, now: Date = Date()) -> Double? {
        guard let t = v?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if let s = Double(t) { return s.isFinite && s >= 0 ? s : nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: t).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Wait before retry `attempt` (0-based): base × 2^attempt, at least `Retry-After`, capped at `maxDelay`, plus up to
    /// 30 % jitter (`jitter` in 0…1) so many clients throttled at once don't retry in one wave.
    static func backoff(_ attempt: Int, _ retryAfter: Double?, _ base: Double, _ jitter: Double) -> Double {
        let exp = base * pow(2, Double(min(10, max(0, attempt))))
        let w = min(maxDelay, max(retryAfter ?? 0, exp))
        return w * (1 + 0.3 * max(0, min(1, jitter)))
    }
    /// nil when the server asked for a longer pause than a lookup should sit through.
    static func backoffOrGiveUp(_ attempt: Int, _ retryAfter: Double?, _ base: Double, _ jitter: Double) -> Double? {
        if let r = retryAfter, r > maxInlineWait { return nil }
        return backoff(attempt, retryAfter, base, jitter)
    }

    private enum Reply { case ok(Data), missing, server, network }
    /// Per-lookup state: who to tell about a busy server, and a `Retry-After` that ended the lookup early.
    private final class Pass: @unchecked Sendable {
        var onBusy: (@Sendable () -> Void)?
        var stopAfter: Double?
        init(_ b: (@Sendable () -> Void)?) { onBusy = b }
    }

    private static let allowed: CharacterSet = { var c = CharacterSet.alphanumerics; c.insert(charactersIn: "-._~"); return c }()
    private func request(_ path: String, _ q: [(String, String)]) -> URLRequest? {
        let query = q.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: Self.allowed) ?? "")" }.joined(separator: "&")
        guard let u = URL(string: host + path + "?" + query) else { return nil }
        var r = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    private func call(_ path: String, _ q: [(String, String)], retries: Int, _ pass: Pass) async -> Reply {
        guard let req = request(path, q) else { return .network }
        if pass.stopAfter != nil { return .server }               // the server asked for a long pause: send nothing more
        var attempt = 0
        while true {
            if Task.isCancelled { return .network }               // lyrics switched off / track changed: send nothing more
            do {
                let r = try await transport(req)
                let code = r.status
                if (200..<300).contains(code) { return .ok(r.data) }
                if code == 404 { return .missing }
                if code >= 500 || code == 429 {
                    pass.onBusy?()
                    guard attempt < retries else { return .server }
                    guard let wait = Self.backoffOrGiveUp(attempt, r.retryAfter, retryDelay, jitter()) else { pass.stopAfter = r.retryAfter; return .server }
                    if retryDelay > 0 || r.retryAfter != nil { await sleep(wait) }
                    attempt += 1
                    continue
                }
                return .missing
            } catch {
                return .network
            }
        }
    }

    /// `cacheable` is false when the answer may be a fluke: the exact `/api/get` lookup hit a server error, or the lookup
    /// was cancelled. Such results are shown but not stored, so one bad minute at LRCLIB doesn't stick to a song.
    struct Lookup {
        let result: LyricsResult; let cacheable: Bool
        /// The server's `Retry-After` when it ended the lookup early (busy).
        var retryAfter: Double? = nil
    }

    func lookup(title: String, artist: String, album: String?, duration: Double?) async -> LyricsResult {
        await lookupDetailed(title: title, artist: artist, album: album, duration: duration).result
    }

    func lookupDetailed(title: String, artist: String, album: String?, duration: Double?, onBusy: (@Sendable () -> Void)? = nil) async -> Lookup {
        if Task.isCancelled { return Lookup(result: .offline, cacheable: false) }
        let pass = Pass(onBusy)
        // Lenient title first ("Stay (With Me)"), then the strict one ("Stay") if they differ.
        let titles = [TrackTitle.clean(title, strict: false), TrackTitle.clean(title)].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let a = TrackTitle.cleanArtist(artist)
        var sawPlain = false, getFailed = false
        if let d = duration, d > 0 {
            for t in titles {
                var q = [("track_name", t), ("artist_name", a)]
                if let al = album?.trimmingCharacters(in: .whitespaces), !al.isEmpty { q.append(("album_name", al)) }
                q.append(("duration", String(Int(d.rounded()))))
                if getFailed { break }                             // the server is struggling: go straight to search
                switch await call("/api/get", q, retries: 1, pass) {
                case .ok(let data):
                    // A 200 that isn't a record (captive portal or proxy login page, truncated body) says nothing about
                    // the song: treat it like a server error so the answer isn't cached.
                    guard let r = try? JSONDecoder().decode(LRCLIBRecord.self, from: data) else { getFailed = true; continue }
                    if r.instrumental { return Lookup(result: .instrumental, cacheable: true) }
                    if r.hasSynced { return Lookup(result: .synced(r), cacheable: true) }
                    sawPlain = sawPlain || r.hasPlain
                case .network: return Lookup(result: .offline, cacheable: false)
                case .server: getFailed = true
                case .missing: break
                }
            }
        }
        if Task.isCancelled { return Lookup(result: .offline, cacheable: false) }
        let cacheable = !getFailed
        // Search with the lenient title, then the strict one if the lenient search found nothing synced.
        var reply = await call("/api/search", [("track_name", titles[0]), ("artist_name", TrackTitle.primaryArtist(a))], retries: 3, pass)
        if case .ok(let d) = reply, Self.decodeList(d) == nil { reply = .network }       // HTML (Wi-Fi login page) / truncated: offline, not an answer
        if titles.count > 1, !Task.isCancelled {
            var hit = false
            if case .ok(let d) = reply { hit = Self.pickBest(Self.decodeList(d) ?? [], duration: duration) != nil }
            if !hit, case .ok = reply {
                reply = await call("/api/search", [("track_name", titles[1]), ("artist_name", TrackTitle.primaryArtist(a))], retries: 3, pass)
                if case .ok(let d) = reply, Self.decodeList(d) == nil { reply = .network }
            }
        }
        switch reply {
        case .ok(let data):
            let list = Self.decodeList(data) ?? []
            if let best = Self.pickBest(list, duration: duration) { return Lookup(result: .synced(best), cacheable: cacheable) }
            if list.contains(where: \.instrumental) && !list.contains(where: \.hasPlain) { return Lookup(result: .instrumental, cacheable: cacheable) }
            return Lookup(result: (sawPlain || list.contains(where: \.hasPlain)) ? .plainOnly : .notFound, cacheable: cacheable)
        case .missing: return Lookup(result: sawPlain ? .plainOnly : .notFound, cacheable: cacheable)
        case .network: return Lookup(result: sawPlain ? .plainOnly : .offline, cacheable: false)
        case .server: return Lookup(result: sawPlain ? .plainOnly : .busy, cacheable: false, retryAfter: pass.stopAfter)
        }
    }

    /// A search body, or nil when it isn't a JSON array of records (only a real `[]` means "nothing found").
    static func decodeList(_ d: Data) -> [LRCLIBRecord]? { try? JSONDecoder().decode([LRCLIBRecord].self, from: d) }

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
        let d = duration ?? 0
        let s = "\(TrackTitle.clean(title).lowercased())|\(TrackTitle.cleanArtist(artist).lowercased())|\(d.isFinite && d > 0 && d < 1e7 ? Int(d.rounded()) : 0)"
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
        guard cacheable, r != .offline, r != .busy else { return false }
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
        case .offline, .busy: return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(e) { try? d.write(to: url(key), options: .atomic) }
    }
}
