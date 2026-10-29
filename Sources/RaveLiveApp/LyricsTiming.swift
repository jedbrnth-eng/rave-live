// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation

/// When a lyric line should be on screen, given the song position the Now Playing player reports.
enum LyricsTiming {
    /// Lines go up this long before they are sung. Karaoke and lyric apps lead the voice slightly because reading a line
    /// takes longer than hearing its first syllable; with no lead a line appears to arrive late even when it is on time.
    /// 150 ms is under a 16th note at 100 BPM (so the line still lands with its phrase) and above a 60 Hz frame plus
    /// the Now Playing update jitter.
    static let displayLead = 0.15

    /// The song position the listener hears now.
    ///
    /// The player's own position already accounts for the audio output delay: Chromium's media clock
    /// (`AudioRendererImpl::CurrentMediaTime` = `AudioClock::front_timestamp`, which models the hardware delay) reports
    /// what is playing out of the speakers, and AVFoundation players keep video in sync with Bluetooth audio the same
    /// way. Subtracting the output latency again made lyrics late by the whole Bluetooth delay (~180 ms, Jed 10-29).
    /// If some player did report a pre-output position, not subtracting costs that player its latency minus the
    /// display lead, while subtracting twice costs every compensated player the full latency plus the lead.
    /// The beat-synced visuals still subtract the output latency: they are timed to captured audio, not a player clock.
    static func heardPosition(sourcePosition: Double, bundleID: String, outputLatency: Double, userOffsetMs: Int, videoOffset: Double) -> Double {
        sourcePosition - Double(userOffsetMs) / 1000 - videoOffset
    }

    /// The line to show at `heard`, `displayLead` early.
    static func lineIndex(heard: Double, in lines: [LyricLine]) -> Int? { LRC.index(at: heard + displayLead, in: lines) }
}
