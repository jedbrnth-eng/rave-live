// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

/// All lyric text in these fixtures is made up. Never paste real song lyrics here: the repo is public.
final class LyricsTests: XCTestCase {

    // MARK: LRC parser

    func testParsesBasicLinesInOrder() {
        let lrc = """
        [ti:Made Up Song]
        [ar:Nobody]
        [00:05.20]Purple toasters hum at dawn
        [00:01.00]Count the marbles, one by one
        [00:09.75]Kettles whistle in the snow
        """
        let lines = LRC.parse(lrc)
        XCTAssertEqual(lines.map(\.text), ["Count the marbles, one by one", "Purple toasters hum at dawn", "Kettles whistle in the snow"])
        XCTAssertEqual(lines.map(\.time), [1.0, 5.2, 9.75])
    }

    func testMultipleTimestampsOnOneLine() {
        let lines = LRC.parse("[00:12.00][00:45.50][01:02.25]Hooray for the paper moon\n[00:20.00]Teacups in the rain")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.map(\.time), [12.0, 20.0, 45.5, 62.25])
        XCTAssertEqual(lines[2].text, "Hooray for the paper moon")
    }

    func testOffsetTagShiftsLinesEarlier() {
        // LRC convention: a positive offset (ms) makes the lyrics appear sooner.
        let lines = LRC.parse("[offset:+500]\n[00:10.00]Yellow kites\n[00:20.00]Green balloons")
        XCTAssertEqual(lines.map(\.time), [9.5, 19.5])
        let late = LRC.parse("[offset:-250]\n[00:10.00]Yellow kites")
        XCTAssertEqual(late.first?.time ?? 0, 10.25, accuracy: 1e-9)
    }

    func testBlankAndMalformedLines() {
        let lrc = """

        [00:01.00]First made-up line
        just text with no tag
        [aa:bb.cc]broken tag
        [00:03.00]
        [00:04.5]Short fraction
        [00:05]No fraction at all
        [00:06:50]Colon fraction
        [00:07.123]Three digit fraction
        [61:xx]nope
           \t
        """
        let lines = LRC.parse(lrc)
        XCTAssertEqual(lines.map(\.time), [1.0, 3.0, 4.5, 5.0, 6.5, 7.123])
        XCTAssertEqual(lines[1].text, "")        // a timed blank line clears the screen (instrumental gap)
        XCTAssertEqual(lines[2].text, "Short fraction")
        XCTAssertTrue(LRC.parse("").isEmpty)
        XCTAssertTrue(LRC.parse("no lrc here\n[ar:Nobody]").isEmpty)
    }

    func testCRLFAndTrimming() {
        let lines = LRC.parse("[00:01.00]  Windmill waltz  \r\n[00:02.00]Second\r\n")
        XCTAssertEqual(lines.map(\.text), ["Windmill waltz", "Second"])
    }

    // MARK: line at time

    func testLineAtTime() {
        let lines = LRC.parse("[00:10.00]a\n[00:20.00]b\n[00:30.00]c")
        XCTAssertNil(LRC.index(at: 9.99, in: lines))
        XCTAssertEqual(LRC.index(at: 10, in: lines), 0)
        XCTAssertEqual(LRC.index(at: 19.99, in: lines), 0)
        XCTAssertEqual(LRC.index(at: 20, in: lines), 1)
        XCTAssertEqual(LRC.index(at: 25, in: lines), 1)
        XCTAssertEqual(LRC.index(at: 3600, in: lines), 2)
        XCTAssertNil(LRC.index(at: 5, in: []))
    }

    // MARK: title cleaning

    func testCleanTitle() {
        let cases: [(String, String)] = [
            ("Pursuit of Happiness (feat. MGMT & Ratatat)", "Pursuit of Happiness"),
            ("Song Name (Steve Aoki Remix)", "Song Name"),
            ("Song Name [Edit]", "Song Name"),
            ("Song Name - Extended Mix", "Song Name"),
            ("Song Name feat. Somebody Else", "Song Name"),
            ("Song Name ft. Somebody", "Song Name"),
            ("[1234567] Song Name", "Song Name"),
            ("Song Name [ABC123]", "Song Name"),
            ("Song Name (Official Video)", "Song Name"),
            ("Song Name - Remastered 2011", "Song Name"),
            ("Song Name (Radio Edit) [Clean]", "Song Name"),
            ("m.A.A.d city", "m.A.A.d city"),
            ("APT.", "APT."),
            ("  Two   Spaces  ", "Two Spaces"),
        ]
        for (raw, want) in cases { XCTAssertEqual(TrackTitle.clean(raw), want, raw) }
    }

    func testArtists() {
        XCTAssertEqual(TrackTitle.cleanArtist("Kid Cudi feat. MGMT"), "Kid Cudi")
        XCTAssertEqual(TrackTitle.cleanArtist("Kid Cudi"), "Kid Cudi")
        XCTAssertEqual(TrackTitle.primaryArtist("Future, Metro Boomin & Kendrick Lamar"), "Future")
        XCTAssertEqual(TrackTitle.primaryArtist("ROSÉ & Bruno Mars"), "ROSÉ")
        XCTAssertEqual(TrackTitle.primaryArtist("Peso Pluma x Someone"), "Peso Pluma")
        XCTAssertEqual(TrackTitle.primaryArtist("Simon & Garfunkel"), "Simon")
    }

    // MARK: remix guard

    func testRemixMarkers() {
        let yes = ["Like That (DJ Snake Remix)", "Song [Edit]", "Song (Bootleg)", "Song - VIP", "Song (Flip)", "Song (Mashup)",
                   "Song x Other (Mash-Up)", "Song (Jersey Club Edit)", "Song - RMX", "Song (Rework)", "Song (Re-Edit)",
                   "Song Remix", "song (my remix) [clean]", "Song {VIP Mix}"]
        let no = ["Flip Reverse", "Pursuit of Happiness (feat. MGMT & Ratatat)", "Song - Extended Mix", "Editorial", "VIPER",
                  "Song (Original Mix)", "Remixed Feelings?",
                  // same arrangement as the original; the ±3 s length check still catches any that differ
                  "Song (Radio Edit)", "Song - Radio Edit", "Song (Clean Edit)", "Song [Explicit Edit]", "Song (Single Edit)", "Song (Dirty Edit)"]
        for t in yes { XCTAssertTrue(TrackTitle.hasRemixMarker(t), t) }
        for t in no { XCTAssertFalse(TrackTitle.hasRemixMarker(t), t) }
    }

    func testGate() {
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Song", trackDuration: 200, matchDuration: 202.9), .show)
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Song", trackDuration: 200, matchDuration: 197), .show)   // exactly 3 s
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Song", trackDuration: 200, matchDuration: 203.5), .lengthDiffers)
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Song (Remix)", trackDuration: 200, matchDuration: 200), .remix)
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Song", trackDuration: nil, matchDuration: 200), .noLength)
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Song", trackDuration: 0, matchDuration: 200), .noLength)
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Song", trackDuration: 200, matchDuration: nil), .noLength)
    }

    // MARK: LRCLIB JSON + client

    static let recordJSON = """
    {"id":42,"name":"Made Up","trackName":"Made Up","artistName":"Nobody","albumName":"Nowhere","duration":201.0,
     "instrumental":false,"plainLyrics":"Purple toasters\\nhum at dawn","syncedLyrics":"[00:01.00]Purple toasters\\n[00:03.00]hum at dawn"}
    """

    func testDecodesRecord() throws {
        let r = try JSONDecoder().decode(LRCLIBRecord.self, from: Data(Self.recordJSON.utf8))
        XCTAssertEqual(r.id, 42); XCTAssertEqual(r.duration, 201); XCTAssertFalse(r.instrumental)
        XCTAssertEqual(LRC.parse(r.syncedLyrics ?? "").count, 2)
        let nulls = #"{"id":7,"trackName":"Hum","artistName":"Nobody","albumName":null,"duration":null,"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#
        let n = try JSONDecoder().decode(LRCLIBRecord.self, from: Data(nulls.utf8))
        XCTAssertTrue(n.instrumental); XCTAssertNil(n.syncedLyrics); XCTAssertNil(n.duration)
    }

    func testPickBestPrefersSyncedClosestDuration() {
        func rec(_ id: Int, _ d: Double?, synced: Bool) -> LRCLIBRecord {
            LRCLIBRecord(id: id, trackName: "t", artistName: "a", albumName: nil, duration: d, instrumental: false,
                         plainLyrics: "x", syncedLyrics: synced ? "[00:01.00]x" : nil)
        }
        let list = [rec(1, 373, synced: true), rec(2, 296, synced: false), rec(3, 295, synced: true), rec(4, 233, synced: true)]
        XCTAssertEqual(LRCLIBClient.pickBest(list, duration: 296)?.id, 3)
        XCTAssertEqual(LRCLIBClient.pickBest(list, duration: nil)?.id, 1)
        XCTAssertNil(LRCLIBClient.pickBest([rec(9, 200, synced: false)], duration: 200))
    }

    /// Fake transport: answers by path, records every request.
    final class FakeNet: @unchecked Sendable {
        var requests: [URLRequest] = []
        var answer: (URLRequest) throws -> (Data, Int)
        init(_ a: @escaping (URLRequest) throws -> (Data, Int)) { answer = a }
        func transport() -> LRCLIBClient.Transport { { [self] req in requests.append(req); return try answer(req) } }
        var paths: [String] { requests.map { $0.url?.path ?? "" } }
    }

    func testGetSuccessSendsUserAgentAndDuration() async {
        let net = FakeNet { _ in (Data(Self.recordJSON.utf8), 200) }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookup(title: "Made Up", artist: "Nobody", album: "Nowhere", duration: 201)
        guard case .synced(let rec) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(rec.id, 42)
        XCTAssertEqual(net.paths, ["/api/get"])
        let req = net.requests[0]
        XCTAssertEqual(req.url?.host, "lrc.example")
        XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("RAVE LIVE/") == true)
        XCTAssertTrue(req.url?.query?.contains("duration=201") == true, req.url?.absoluteString ?? "")
        XCTAssertLessThanOrEqual(req.timeoutInterval, 8)
    }

    func test503FallsBackToSearch() async {
        let search = "[" + Self.recordJSON + "]"
        let net = FakeNet { req in req.url?.path == "/api/get" ? (Data("busy".utf8), 503) : (Data(search.utf8), 200) }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookup(title: "Made Up (feat. Someone)", artist: "Nobody", album: nil, duration: 200)
        guard case .synced(let rec) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(rec.id, 42)
        XCTAssertEqual(net.paths, ["/api/get", "/api/get", "/api/search"])     // one retry, then search
        XCTAssertTrue(net.requests.last?.url?.query?.contains("track_name=Made%20Up") == true, net.requests.last?.url?.absoluteString ?? "")
    }

    func test404FallsBackToSearchThenNotFound() async {
        let net = FakeNet { req in req.url?.path == "/api/get" ? (Data("{}".utf8), 404) : (Data("[]".utf8), 200) }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookup(title: "Nope", artist: "Nobody", album: nil, duration: 100)
        XCTAssertEqual(r, .notFound)
        XCTAssertEqual(net.paths, ["/api/get", "/api/search"])
    }

    func testOfflineWhenNetworkFails() async {
        let net = FakeNet { _ in throw URLError(.cannotFindHost) }
        let c = LRCLIBClient(host: "https://no-such-host.invalid", transport: net.transport(), retryDelay: 0)
        let r = await c.lookup(title: "Made Up", artist: "Nobody", album: nil, duration: 200)
        XCTAssertEqual(r, .offline)
    }

    func testAllServerErrorsIsOffline() async {
        let net = FakeNet { _ in (Data(), 503) }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookup(title: "Made Up", artist: "Nobody", album: nil, duration: 200)
        XCTAssertEqual(r, .offline)
    }

    func testInstrumental() async {
        let j = #"{"id":7,"trackName":"Hum","artistName":"Nobody","albumName":null,"duration":200,"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#
        let net = FakeNet { _ in (Data(j.utf8), 200) }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookup(title: "Hum", artist: "Nobody", album: nil, duration: 200)
        XCTAssertEqual(r, .instrumental)
    }

    func testPlainOnlyTriesSearchForSynced() async {
        let plain = #"{"id":8,"trackName":"Hum","artistName":"Nobody","albumName":null,"duration":200,"instrumental":false,"plainLyrics":"la la","syncedLyrics":null}"#
        let net = FakeNet { req in req.url?.path == "/api/get" ? (Data(plain.utf8), 200) : (Data("[\(plain)]".utf8), 200) }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookup(title: "Hum", artist: "Nobody", album: nil, duration: 200)
        XCTAssertEqual(r, .plainOnly)
        XCTAssertEqual(net.paths, ["/api/get", "/api/search"])
    }

    /// A 503 on /api/get means the exact lookup never happened: the result is good to show but not to keep.
    func testServerErrorOnGetIsNotCacheable() async {
        let search = "[" + Self.recordJSON + "]"
        let net = FakeNet { req in req.url?.path == "/api/get" ? (Data("busy".utf8), 503) : (Data(search.utf8), 200) }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookupDetailed(title: "Made Up", artist: "Nobody", album: nil, duration: 200)
        XCTAssertFalse(r.cacheable)
        let ok = FakeNet { _ in (Data(Self.recordJSON.utf8), 200) }
        let r2 = await LRCLIBClient(host: "https://lrc.example", transport: ok.transport(), retryDelay: 0)
            .lookupDetailed(title: "Made Up", artist: "Nobody", album: nil, duration: 201)
        XCTAssertTrue(r2.cacheable)
    }

    /// Words like "With", "Live", "Video" can be part of the real title: try the title with them first.
    func testCleanKeepsAmbiguousWordsInLenientMode() {
        XCTAssertEqual(TrackTitle.clean("Stay (With Me)", strict: false), "Stay (With Me)")
        XCTAssertEqual(TrackTitle.clean("Song (Live Forever)", strict: false), "Song (Live Forever)")
        XCTAssertEqual(TrackTitle.clean("Song (feat. Someone)", strict: false), "Song")
        XCTAssertEqual(TrackTitle.clean("Song (Official Video)", strict: false), "Song")
        XCTAssertEqual(TrackTitle.clean("Stay (With Me)"), "Stay")                  // strict (default) unchanged
    }

    func testGetTriesLenientTitleFirst() async {
        let net = FakeNet { req in
            (req.url?.query ?? "").contains("track_name=Stay%20%28With%20Me%29") ? (Data(Self.recordJSON.utf8), 200) : (Data("{}".utf8), 404)
        }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookup(title: "Stay (With Me)", artist: "Nobody", album: nil, duration: 201)
        guard case .synced = r else { return XCTFail("\(r)") }
        XCTAssertEqual(net.paths, ["/api/get"])
    }

    func testSearchFallsBackToStrictTitle() async {
        let search = "[" + Self.recordJSON + "]"
        let net = FakeNet { req in
            if req.url?.path == "/api/get" { return (Data("{}".utf8), 404) }
            return (req.url?.query ?? "").contains("%28Live%29") ? (Data("[]".utf8), 200) : (Data(search.utf8), 200)
        }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookup(title: "Made Up (Live)", artist: "Nobody", album: nil, duration: 200)
        guard case .synced = r else { return XCTFail("\(r) \(net.paths)") }
        XCTAssertEqual(net.paths, ["/api/get", "/api/get", "/api/search", "/api/search"])
        XCTAssertEqual(TrackTitle.clean("Song (HD)", strict: false), "Song")
        XCTAssertEqual(TrackTitle.clean("Song (Audio)", strict: false), "Song")
    }

    func testCancelledLookupSendsNothingMore() async {
        let net = FakeNet { _ in (Data("{}".utf8), 404) }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let t = Task { () -> LRCLIBClient.Lookup in
            withUnsafeCurrentTask { $0?.cancel() }
            return await c.lookupDetailed(title: "Made Up", artist: "Nobody", album: nil, duration: 200)
        }
        let r = await t.value
        XCTAssertTrue(net.requests.isEmpty, "\(net.paths)")
        XCTAssertFalse(r.cacheable)
    }

    /// Only keep a synced match the remix/length gate would actually show; a wrong-length match from search is not stored.
    func testShouldStore() throws {
        let rec = try JSONDecoder().decode(LRCLIBRecord.self, from: Data(Self.recordJSON.utf8))
        XCTAssertTrue(LyricsCache.shouldStore(.synced(rec), cacheable: true, gate: .show))
        XCTAssertFalse(LyricsCache.shouldStore(.synced(rec), cacheable: true, gate: .lengthDiffers))
        XCTAssertFalse(LyricsCache.shouldStore(.notFound, cacheable: false, gate: nil))
        XCTAssertTrue(LyricsCache.shouldStore(.notFound, cacheable: true, gate: nil))
        XCTAssertFalse(LyricsCache.shouldStore(.offline, cacheable: true, gate: nil))
    }

    func testPlainOnlyExpiresLikeNotFound() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rl-lyrics-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = LyricsCache(dir: dir)
        cache.store(.plainOnly, "p", now: Date().timeIntervalSince1970 - LyricsCache.notFoundTTL - 10)
        XCTAssertNil(cache.load("p"))
        cache.store(.plainOnly, "q")
        XCTAssertEqual(cache.load("q"), .plainOnly)
    }

    // MARK: cache

    func testCacheRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rl-lyrics-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = LyricsCache(dir: dir)
        let key = LyricsCache.key(title: "Made Up", artist: "Nobody", duration: 200.4)
        XCTAssertEqual(key, LyricsCache.key(title: "made up", artist: "NOBODY", duration: 200.0))
        XCTAssertNil(cache.load(key))
        let rec = try JSONDecoder().decode(LRCLIBRecord.self, from: Data(Self.recordJSON.utf8))
        cache.store(.synced(rec), key)
        XCTAssertEqual(cache.load(key), .synced(rec))
        cache.store(.offline, "other")            // offline is never cached
        XCTAssertNil(cache.load("other"))
        cache.store(.notFound, "nf")
        XCTAssertEqual(cache.load("nf"), .notFound)
    }
}
