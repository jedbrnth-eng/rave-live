// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
import RaveAudio
@testable import RaveLiveApp

final class PermissionTests: XCTestCase {
    func testRetryOnlyWhileSystemAudioWaitsForPermission() {
        XCTAssertTrue(PermissionRetry.shouldRetry(missing: true, isSystem: true, label: "system"))
        XCTAssertFalse(PermissionRetry.shouldRetry(missing: false, isSystem: true, label: "system"))   // already working
        XCTAssertFalse(PermissionRetry.shouldRetry(missing: true, isSystem: false, label: "system"))   // user picked a mic
        XCTAssertFalse(PermissionRetry.shouldRetry(missing: true, isSystem: true, label: "demo"))      // demo feed
    }

    func testResetTouchesOnlyOurOwnEntry() {
        XCTAssertEqual(ScreenCapturePermissionReset.arguments(bundleID: "io.github.jedbrnth-eng.ravelive"),
                       ["reset", "ScreenCapture", "io.github.jedbrnth-eng.ravelive"])
    }

    func testFixTextPointsAtTheResetItem() {
        // A switch that shows ON for an older build is the common stuck case: the on-screen text must name the fix.
        XCTAssertTrue(CapturePermission.fixInstructions.contains("Reset System Audio Permission"))
        XCTAssertTrue(AudioMenu.resetPermissionTitle.hasPrefix("Reset System Audio Permission"))
        XCTAssertTrue(CapturePermission.fixInstructions.contains("press M"))
    }
}
