// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

/// `--offscreen` runs on a machine someone is using (and on CI) must not read or write that person's RAVE LIVE data:
/// their Shader Lab folder, MilkDrop favourites, saved look tweaks or saved settings. Setting HOME doesn't help, because
/// FileManager's Application Support lookup and cfprefsd ignore it.
final class OffscreenIsolationTests: XCTestCase {
    private let offscreen = ["RaveLive", "--offscreen", "--demo", "--seconds", "4"]
    private let normal = ["RaveLive"]

    func testOffscreenLeavesTheShaderLabFolderAlone() {
        XCTAssertFalse(UserShaderLibrary.watchesFolder(args: offscreen), "no folder created, polled or compiled")
        XCTAssertTrue(UserShaderLibrary.watchesFolder(args: offscreen + ["--shaderdir", "/tmp/rave-shaders"]), "an explicit folder still works")
        XCTAssertTrue(UserShaderLibrary.watchesFolder(args: normal))
    }

    func testOffscreenMilkDropLibraryStaysOutOfApplicationSupport() throws {
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first).path
        XCTAssertFalse(MilkDropLibrary.rootURL(args: offscreen, env: [:]).path.hasPrefix(support))
        XCTAssertEqual(MilkDropLibrary.rootURL(args: offscreen, env: ["RAVE_MILKDROP_ROOT": "/tmp/rave-milk"]).path, "/tmp/rave-milk")
        XCTAssertTrue(MilkDropLibrary.rootURL(args: normal, env: [:]).path.hasPrefix(support), "normal runs keep the user's library")
    }

    func testOffscreenNeitherReadsNorSavesTweaksOrSettings() {
        XCTAssertFalse(PresetLab.persists(args: offscreen), "saved look tweaks would change Classic frames vs CI")
        XCTAssertTrue(PresetLab.persists(args: normal))
        XCTAssertTrue(Prefs.isFrozen(args: offscreen), "saved settings would change frames, and --tweak would write them")
        XCTAssertFalse(Prefs.isFrozen(args: normal))
        XCTAssertTrue(Prefs.isFrozen(args: ["RaveLive", "--autoquit", "10"]))
    }
}
