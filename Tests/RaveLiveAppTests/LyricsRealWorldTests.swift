// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

/// Real-world lyrics cases from Jed's first test (YouTube in a browser, a 15-min upload, LRCLIB 503s, lyrics left off):
/// the app must always say why there are no lyrics, clean YouTube titles, sync music videos with an intro, and back off
/// politely when LRCLIB is overloaded. Fixtures are made up (public repo).
final class LyricsRealWorldTests: XCTestCase {

    // MARK: YouTube / browser titles

    func testBrowserBundleIDs() {
        for b in ["app.zen-browser.zen", "com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "org.mozilla.firefox",
                  "company.thebrowser.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"] {
            XCTAssertTrue(TrackTitle.isBrowser(b), b)
        }
        for b in ["com.spotify.client", "com.apple.Music", "com.soundcloud.desktop", ""] { XCTAssertFalse(TrackTitle.isBrowser(b), b) }
    }

    func testYouTubeTitleCleaning() {
        func id(_ t: String, _ a: String, _ b: String = "app.zen-browser.zen") -> [String] {
            let r = TrackTitle.lookupIdentity(title: t, artist: a, bundleID: b); return [r.title, r.artist]
        }
        XCTAssertEqual(id("Made Up (Official Video)", "Nobody"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Made Up [Official Music Video]", "Nobody"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Made Up [Music Video]", "Nobody"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Made Up (Lyrics)", "Nobody"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Made Up (Lyric Video)", "Nobody"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Made Up (Official Audio)", "Nobody"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Made Up ft. Someone", "Nobody"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Made Up feat Someone (Official Video)", "Nobody"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Made Up (ft Someone)", "Nobody"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Made Up | Official Video", "Nobody"), ["Made Up", "Nobody"])
        // "Artist - Title" in the title field: the channel repeats the artist, or is a label / uploader channel
        XCTAssertEqual(id("Nobody - Made Up (Official Video)", "Nobody"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Nobody - Made Up (Official Video)", "NobodyVEVO"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Nobody – Made Up", "Some Label Records"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Nobody x Somebody - Made Up (Directed by A Person)", "Some Label"), ["Made Up", "Nobody x Somebody"])
        // auto-generated "Artist - Topic" channels and VEVO / "Official" channel names are the artist fallback
        XCTAssertEqual(id("Made Up", "Nobody - Topic"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Made Up", "NobodyVEVO"), ["Made Up", "Nobody"])
        XCTAssertEqual(id("Made Up", "Nobody Official"), ["Made Up", "Nobody"])
        // " - Remastered" style tails are not an "Artist - Title" split
        XCTAssertEqual(id("Made Up - Remastered 2011", "Nobody"), ["Made Up", "Nobody"])
        // real players keep their tags: no splitting on " - "
        XCTAssertEqual(id("Nobody - Made Up", "Nobody", "com.spotify.client"), ["Nobody - Made Up", "Nobody"])
        XCTAssertEqual(id("Stay (With Me)", "Nobody", "com.apple.Music"), ["Stay (With Me)", "Nobody"])
    }

    func testYouTubeVideoWordsAreNotRemixes() {
        XCTAssertFalse(TrackTitle.hasRemixMarker("Made Up (Official Music Video)"))
        XCTAssertFalse(TrackTitle.hasRemixMarker("Nobody - Made Up [Lyrics]"))
        XCTAssertTrue(TrackTitle.hasRemixMarker("Made Up (Slowed + Reverb)"))
        XCTAssertTrue(TrackTitle.hasRemixMarker("Nobody - Made Up (Somebody Remix) [Official Video]"))
    }

    // MARK: gate: music-video intros and long uploads

    func testGateMusicVideoIntro() {
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Made Up (Official Video)", trackDuration: 224, matchDuration: 199, video: true), .intro(25))
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Made Up", trackDuration: 199 + 90, matchDuration: 199, video: true), .intro(90))
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Made Up", trackDuration: 199 + 91, matchDuration: 199, video: true), .lengthDiffers)
        // a real player 25 s longer is another cut (extended), not a video intro
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Made Up", trackDuration: 224, matchDuration: 199, video: false), .lengthDiffers)
        // shorter than the song: another cut
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Made Up", trackDuration: 180, matchDuration: 199, video: true), .lengthDiffers)
        // within ±3 s is still a plain match
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Made Up", trackDuration: 201, matchDuration: 199, video: true), .show)
        // a remix never gets an intro sync
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Made Up (Remix)", trackDuration: 224, matchDuration: 199, video: true), .remix)
    }

    func testGateLongVideoOrMix() {
        // Jed's case: a 15-min YouTube upload vs the 3:19 studio record
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Made Up", trackDuration: 897.7, matchDuration: 199, video: true), .longVideo)
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Made Up", trackDuration: 897.7, matchDuration: 199, video: false), .longVideo)
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Made Up", trackDuration: 398.1, matchDuration: 199, video: true), .longVideo)
        XCTAssertEqual(LyricsGate.decide(rawTitle: "Made Up", trackDuration: 397, matchDuration: 199, video: true), .lengthDiffers)
    }

    // MARK: what the user is told (never a silent nothing)

    func testHintTextForEveryState() {
        typealias C = LyricsController
        let ctx = C.HintContext(trackDuration: 897.7, matchDuration: 199, video: true, introOffset: 0, forced: false, forceKey: "L")
        XCTAssertEqual(C.hint(.off, ctx), "Lyrics off (Y)")
        XCTAssertEqual(C.hint(.looking, ctx), "Looking up lyrics…")
        XCTAssertEqual(C.hint(.busy, ctx), "Lyrics server busy, retrying")
        XCTAssertEqual(C.hint(.notFound, ctx), "No synced lyrics found")
        XCTAssertEqual(C.hint(.offline, ctx), "Lyrics offline, retrying")
        XCTAssertEqual(C.hint(.instrumental, ctx), "Instrumental: no lyrics")
        XCTAssertEqual(C.hint(.remix, ctx), "Skipped: remix/edit. Press L to sync anyway")
        XCTAssertEqual(C.hint(.longVideo, ctx), "Skipped: long video/mix (14:57, the song is 3:19). Press L to sync anyway")
        let diff = C.HintContext(trackDuration: 290, matchDuration: 161, video: true, introOffset: 0, forced: false, forceKey: "L")
        XCTAssertEqual(C.hint(.lengthDiffers, diff), "Skipped: video length 4:50 doesn't match the song (2:41). Press L to sync anyway")
        let player = C.HintContext(trackDuration: 290, matchDuration: 161, video: false, introOffset: 0, forced: false, forceKey: "Shift-L")
        XCTAssertEqual(C.hint(.lengthDiffers, player), "Skipped: track length 4:50 doesn't match the song (2:41). Press Shift-L to sync anyway")
        XCTAssertEqual(C.hint(.noLength, ctx), "Skipped: the player reports no track length. Press L to sync anyway")
        let intro = C.HintContext(trackDuration: 224, matchDuration: 199, video: true, introOffset: 25, forced: false, forceKey: "L")
        XCTAssertEqual(C.hint(.synced, intro), "Synced with a 0:25 video intro (Shift -/= ±1 s)")
        let forced = C.HintContext(trackDuration: 897.7, matchDuration: 199, video: true, introOffset: 0, forced: true, forceKey: "L")
        XCTAssertEqual(C.hint(.synced, forced), "Synced anyway (Shift -/= ±1 s, L undoes)")
        let exact = C.HintContext(trackDuration: 200, matchDuration: 199, video: false, introOffset: 0, forced: false, forceKey: "L")
        XCTAssertNil(C.hint(.synced, exact))                        // the lyrics themselves are the message
        XCTAssertNil(C.hint(.waiting, exact))
    }

    func testCardNotesAreShort() {
        let ctx = LyricsController.HintContext(trackDuration: 897.7, matchDuration: 199, video: true, introOffset: 0, forced: false, forceKey: "L")
        for s: LyricsController.LyricsState in [.off, .looking, .busy, .synced, .remix, .lengthDiffers, .longVideo, .noLength, .instrumental, .notFound, .offline] {
            let n = LyricsController.cardNote(s, ctx)
            XCTAssertNotNil(n, "\(s)")
            XCTAssertLessThanOrEqual(n?.count ?? 0, 26, "\(s): \(n ?? "")")   // fits the card's note slot
        }
        XCTAssertEqual(LyricsController.cardNote(.off, ctx), "lyrics off (Y)")
    }

    func testDebugLine() {
        let line = LyricsController.debugLine(app: "Zen", title: "Made Up", artist: "Nobody", trackDuration: 897.7, matchDuration: 199,
                                              decision: "skipped: long video/mix", offset: 0)
        XCTAssertEqual(line, "Zen · \"Made Up\" / Nobody · 14:57 vs 3:19 · skipped: long video/mix")
        let none = LyricsController.debugLine(app: "Music", title: "A", artist: "B", trackDuration: nil, matchDuration: nil, decision: "looking up", offset: 25)
        XCTAssertEqual(none, "Music · \"A\" / B · ? vs ? · looking up · offset +25.0 s")
    }

    // MARK: LRCLIB overload: exponential backoff + jitter, Retry-After honoured, search after a failed get

    func testBackoffDelays() {
        let b = LRCLIBClient.backoff
        XCTAssertEqual(b(0, nil, 0.6, 0), 0.6, accuracy: 1e-9)
        XCTAssertEqual(b(1, nil, 0.6, 0), 1.2, accuracy: 1e-9)
        XCTAssertEqual(b(2, nil, 0.6, 0), 2.4, accuracy: 1e-9)
        XCTAssertEqual(b(2, nil, 0.6, 1), 2.4 * 1.3, accuracy: 1e-9)       // at most +30 % jitter (LRCLIB docs)
        XCTAssertEqual(b(0, 2, 0.6, 0), 2, accuracy: 1e-9)                // Retry-After wins when longer
        XCTAssertEqual(b(9, nil, 0.6, 1), 8 * 1.3, accuracy: 1e-9)          // capped
        XCTAssertNil(LRCLIBClient.backoffOrGiveUp(0, 45, 0.6, 0))          // a long Retry-After is left to the app-level retry
    }

    final class Net: @unchecked Sendable {
        var requests: [URLRequest] = []
        var slept: [Double] = []
        var answer: (URLRequest, Int) -> LRCLIBClient.HTTPReply
        init(_ a: @escaping (URLRequest, Int) -> LRCLIBClient.HTTPReply) { answer = a }
        func client() -> LRCLIBClient {
            LRCLIBClient(host: "https://lrc.example",
                         richTransport: { [self] req in requests.append(req); return answer(req, requests.count) },
                         retryDelay: 0.6, sleep: { [self] s in slept.append(s) }, jitter: { 0.5 })
        }
        var paths: [String] { requests.map { $0.url?.path ?? "" } }
    }
    static let rec = #"{"id":77,"trackName":"Made Up","artistName":"Nobody","albumName":null,"duration":199,"instrumental":false,"plainLyrics":"la","syncedLyrics":"[00:01.00]la"}"#

    func testOverloadedServerBacksOffThenSucceeds() async {
        let net = Net { req, n in
            if req.url?.path == "/api/get" { return .init(data: Data(#"{"name":"ServerOverloaded"}"#.utf8), status: 503, retryAfter: 1) }
            return n < 5 ? .init(data: Data(), status: 503, retryAfter: nil) : .init(data: Data("[\(Self.rec)]".utf8), status: 200, retryAfter: nil)
        }
        let busy = Counter()
        let r = await net.client().lookupDetailed(title: "Made Up", artist: "Nobody", album: nil, duration: 199, onBusy: { busy.n += 1 })
        guard case .synced(let x) = r.result else { return XCTFail("\(r.result) \(net.paths)") }
        XCTAssertEqual(x.id, 77)
        XCTAssertFalse(r.cacheable)                                                      // get never answered
        XCTAssertEqual(net.paths, ["/api/get", "/api/get", "/api/search", "/api/search", "/api/search"])
        XCTAssertEqual(net.slept.count, 3)
        XCTAssertEqual(net.slept[0], 1 * 1.15, accuracy: 1e-9)                           // Retry-After 1 s (> 0.6) + 15 % jitter
        XCTAssertEqual(net.slept[1], 0.6 * 1.15, accuracy: 1e-9)                         // search: own exponential ladder
        XCTAssertEqual(net.slept[2], 1.2 * 1.15, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(busy.n, 1)
    }

    func testAllServerErrorsIsBusyNotOffline() async {
        let net = Net { _, _ in .init(data: Data(), status: 503, retryAfter: nil) }
        let r = await net.client().lookupDetailed(title: "Made Up", artist: "Nobody", album: nil, duration: 199)
        XCTAssertEqual(r.result, .busy)
        XCTAssertFalse(r.cacheable)
        XCTAssertLessThanOrEqual(net.requests.count, 6)                                 // bounded per lookup
        XCTAssertFalse(LyricsCache.shouldStore(.busy, cacheable: true, gate: nil))
    }

    func test429LongRetryAfterStopsAndReportsIt() async {
        let net = Net { _, _ in .init(data: Data(), status: 429, retryAfter: 45) }
        let r = await net.client().lookupDetailed(title: "Made Up", artist: "Nobody", album: nil, duration: 199)
        XCTAssertEqual(r.result, .busy)
        XCTAssertEqual(r.retryAfter ?? 0, 45, accuracy: 1e-9)
        XCTAssertTrue(net.slept.isEmpty, "\(net.slept)")                                 // didn't sit on a 45 s sleep
        XCTAssertEqual(net.paths, ["/api/get"])                                         // and sent nothing more
    }

    func testAppRetryAfterBusyHonoursRetryAfter() {
        XCTAssertEqual(LyricsController.retryDelay(attempt: 0, busy: true, retryAfter: nil), 10)
        XCTAssertEqual(LyricsController.retryDelay(attempt: 1, busy: true, retryAfter: nil), 20)
        XCTAssertEqual(LyricsController.retryDelay(attempt: 0, busy: true, retryAfter: 45), 45)
        XCTAssertEqual(LyricsController.retryDelay(attempt: 20, busy: true, retryAfter: nil), 600)
        XCTAssertEqual(LyricsController.retryDelay(attempt: 0, busy: false, retryAfter: nil), 30)   // offline unchanged
    }

    func testRetryAfterHeaderParsing() {
        XCTAssertEqual(LRCLIBClient.parseRetryAfter("1"), 1)
        XCTAssertEqual(LRCLIBClient.parseRetryAfter(" 12 "), 12)
        XCTAssertNil(LRCLIBClient.parseRetryAfter(nil))
        XCTAssertNil(LRCLIBClient.parseRetryAfter("soon"))
        XCTAssertNil(LRCLIBClient.parseRetryAfter("-3"))
        let soon = LRCLIBClient.parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT")          // HTTP date in the past: no wait
        XCTAssertEqual(soon ?? 0, 0, accuracy: 1e-9)
    }

    final class Counter: @unchecked Sendable { var n = 0 }
}
