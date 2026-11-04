// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation

/// When to try system audio again after it failed for lack of Screen & System Audio Recording.
enum PermissionRetry {
    /// Only while the permission text is up, system audio is the chosen source, and it isn't demo mode.
    static func shouldRetry(missing: Bool, isSystem: Bool, label: String) -> Bool { missing && isSystem && label == "system" }
}

/// Release builds are ad-hoc signed (no paid Apple developer account), so macOS ties the Screen & System Audio
/// Recording switch to one exact build. After an update the switch can still show ON for RAVE LIVE while macOS
/// refuses the new build, and toggling it doesn't help. Removing the entry and allowing it again does; this does the
/// removing for the user (`tccutil reset ScreenCapture <our bundle id>`, which only touches RAVE LIVE's own entry).
enum ScreenCapturePermissionReset {
    static func arguments(bundleID: String) -> [String] { ["reset", "ScreenCapture", bundleID] }

    /// Runs tccutil; true when it exited 0.
    @discardableResult
    static func run(bundleID: String = Bundle.main.bundleIdentifier ?? "io.github.jedbrnth-eng.ravelive") -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = arguments(bundleID: bundleID)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }
}
