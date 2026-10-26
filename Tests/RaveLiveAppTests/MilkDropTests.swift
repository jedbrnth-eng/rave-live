// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

final class MilkDropDirectorTests: XCTestCase {
    /// Drive the director at 60 fps over a 128 BPM beat clock; return (beat, phase, action) for every change.
    private func run(_ d: inout MilkDropDirector, beats: Double, from start: Double = 0, locked: Bool = true,
                     dropAt: Double? = nil, jump: (at: Double, by: Int)? = nil) -> [(Int, Double, MilkDropDirector.Action)] {
        var out: [(Int, Double, MilkDropDirector.Action)] = []
        let bpm = 128.0, fps = 60.0
        var offset = 0
        var t = start * 60 / bpm
        var lastClock = -1.0
        while t * bpm / 60 < start + beats {
            let clock = t * bpm / 60
            if let j = jump, lastClock < j.at, clock >= j.at { offset += j.by }
            let b = Int(floor(clock)) + offset, ph = clock - floor(clock)
            let drop = dropAt.map { lastClock < $0 && clock >= $0 } ?? false
            let a = d.step(beat: b, phase: ph, beatLocked: locked, dropStarted: drop, now: t)
            if a != .none { out.append((b, ph, a)) }
            lastClock = clock
            t += 1 / fps
        }
        return out
    }

    func testBlendsOnlyOnPhraseDownbeatsAfterHold() {
        var d = MilkDropDirector()
        let ch = run(&d, beats: 200)
        XCTAssertFalse(ch.isEmpty)
        for (b, ph, a) in ch {
            XCTAssertEqual(a, .blend)
            XCTAssertEqual(MilkDropDirector.mod(b, 16), 0, "change at beat \(b) is not on a phrase line")
            XCTAssertLessThan(ph, 0.1, "change at beat \(b) started mid-beat")
        }
        for i in 1..<ch.count { XCTAssertGreaterThanOrEqual(ch[i].0 - ch[i - 1].0, 32) }
    }

    func testDropIsAHardCutAndResetsTheHold() {
        var d = MilkDropDirector()
        let ch = run(&d, beats: 120, dropAt: 70.0)
        let cuts = ch.filter { $0.2 == .cut }
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].0, 70)
        // nothing blends within 32 beats of the drop
        XCTAssertTrue(ch.filter { $0.2 == .blend && $0.0 > 70 && $0.0 < 102 }.isEmpty)
    }

    func testCounterRealignmentDoesNotShortenTheHold() {
        var d = MilkDropDirector()
        // a +12 beat realignment right after the change at beat 32 must not let a blend fire at the next phrase line (48+)
        let ch = run(&d, beats: 120, jump: (at: 33.5, by: 12))
        let blends = ch.map { $0.0 }
        for i in 1..<blends.count { XCTAssertGreaterThanOrEqual(blends[i] - blends[i - 1], 32, "\(blends)") }
        // and a jump that lands mid-beat on a phrase line never starts a change there
        for (_, ph, _) in ch { XCTAssertLessThan(ph, 0.25) }
    }

    func testFlipFloppingBarEstimateIsIgnored() {
        // the renderer's bar estimate flips by +2 / -2 beats at phase ~0.18 every few beats (seen in demo mode)
        var d = MilkDropDirector()
        var changes: [(Double, MilkDropDirector.Action)] = []
        var t = 0.0
        while t < 120 * 60 / 128 {
            let clock = t * 128 / 60, whole = Int(floor(clock)), ph = clock - floor(clock)
            let flipped = (whole / 2) % 2 == 1 && !(whole % 2 == 0 && ph < 0.18)
            let a = d.step(beat: whole + (flipped ? 2 : 0), phase: ph, beatLocked: true, dropStarted: false, now: t)
            if a != .none { changes.append((clock, a)) }
            t += 1.0 / 60
        }
        XCTAssertFalse(changes.isEmpty)
        for (c, _) in changes { XCTAssertLessThan(c - floor(c), 0.1, "change at clock \(c) is mid-beat") }
        for i in 1..<changes.count { XCTAssertGreaterThanOrEqual(changes[i].0 - changes[i - 1].0, 31.9) }
    }

    func testLockedPresetNeverChanges() {
        var d = MilkDropDirector(); d.locked = true
        XCTAssertTrue(run(&d, beats: 200, dropAt: 100).isEmpty)
    }

    func testUnlockedFallsBackToTimer() {
        var d = MilkDropDirector(); d.unlockedHoldSeconds = 10
        let ch = run(&d, beats: 128, locked: false)   // 60 s at 128 BPM
        XCTAssertEqual(ch.count, 5)                    // 10, 20, 30, 40, 50 s
    }

    func testHoldFollowsIntensity() {
        XCTAssertEqual(MilkDropDirector.hold(intensity: 0, energy: 0.9), 64)
        XCTAssertEqual(MilkDropDirector.hold(intensity: 1, energy: 0.9), 32)
        XCTAssertEqual(MilkDropDirector.hold(intensity: 2, energy: 0.9), 16)
        XCTAssertEqual(MilkDropDirector.hold(intensity: 2, energy: 0.3), 32)
        XCTAssertEqual(MilkDropDirector.blendSeconds(bpm: 120), 4, accuracy: 1e-9)   // 2 bars
    }
}

final class MilkDropLibraryTests: XCTestCase {
    func testDescribeParsesAuthorTitleAndCategory() {
        let rel = "presets-cream-of-the-crop-master/Reaction/Cloudy/cope + flexi - colorful marble (ghost mix).milk"
        let p = MilkDropLibrary.describe(url: URL(fileURLWithPath: "/x/" + rel), rel: rel)
        XCTAssertEqual(p.author, "cope + flexi")
        XCTAssertEqual(p.name, "colorful marble (ghost mix)")
        XCTAssertEqual(p.category, "Reaction")
        let own = MilkDropLibrary.describe(url: URL(fileURLWithPath: "/x/my thing.milk"), rel: "my thing.milk")
        XCTAssertEqual(own.author, ""); XCTAssertEqual(own.name, "my thing")
    }

    func testScanSearchFavouritesBrokenAndPicking() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("milktest-\(UUID().uuidString)")
        let pack = dir.appendingPathComponent("presets-test/Sparkle/Sub"), trans = dir.appendingPathComponent("presets-test/! Transition/x")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trans, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<6 { try "[preset00]\n".write(to: pack.appendingPathComponent("Author\(i) - Glow \(i).milk"), atomically: true, encoding: .utf8) }
        try "[preset00]\n".write(to: trans.appendingPathComponent("Fade - to black.milk"), atomically: true, encoding: .utf8)
        let lib = MilkDropLibrary(storeURL: dir.appendingPathComponent("store.json"))
        lib.extraDirs = [dir]
        lib.scan()
        XCTAssertEqual(lib.search("").filter { $0.key.hasPrefix("presets-test") }.count, 7)
        XCTAssertEqual(lib.search("author3 glow").count, 1)
        let p0 = try XCTUnwrap(lib.search("Glow 0").first)
        XCTAssertTrue(lib.toggleFavorite(p0))
        XCTAssertEqual(lib.search("", favoritesOnly: true).map { $0.key }, [p0.key])
        lib.markBroken(p0, reason: "test")
        for _ in 0..<50 {
            let p = try XCTUnwrap(lib.pick(loud: true))
            XCTAssertNotEqual(p.key, p0.key, "broken presets are skipped")
            XCTAssertNotEqual(p.category, "! Transition", "fade-to-black transitions are never picked")
        }
        // state survives a reload
        let again = MilkDropLibrary(storeURL: dir.appendingPathComponent("store.json"))
        again.extraDirs = [dir]; again.scan()
        XCTAssertTrue(again.isFavorite(p0)); XCTAssertEqual(again.brokenReason(p0), "test")
    }
}
