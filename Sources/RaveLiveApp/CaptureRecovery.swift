// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation

/// Brings system-audio capture back after ScreenCaptureKit stops on its own (sleep/wake, a display change, the system
/// or another app taking the stream). Before this the stream just ended and the visuals went quiet until a relaunch.
///
/// `interrupted` schedules one restart after a short delay; more interruptions before it fires are folded into it
/// (wake sends several notifications). A failed restart retries with backoff (1, 2, 4 … 30 s). `cancel` (the user
/// picked another source, or started system audio again by hand) drops anything pending. Main queue only.
final class CaptureRestarter {
    typealias Restart = () async throws -> Void
    private let restart: Restart
    private let queue: DispatchQueue
    private(set) var failures = 0
    private(set) var attempts = 0
    private var generation = 0
    private(set) var pending = false
    /// "capture: …" lines for the metrics log and the status text callback (nil = clear the status).
    var log: ((String) -> Void)?
    var onStatus: ((String?) -> Void)?

    init(queue: DispatchQueue = .main, restart: @escaping Restart) { self.queue = queue; self.restart = restart }

    /// First try after `settle` seconds, then 1, 2, 4 … 30 s after failures.
    static func delay(failures: Int, settle: Double) -> Double { failures == 0 ? settle : min(30, pow(2, Double(min(5, failures - 1)))) }

    /// The stream stopped or the system changed under it. `settle`: wait for things to calm down (wake: 1 s).
    func interrupted(_ why: String, settle: Double = 0.5) {
        if pending { log?("capture: \(why) (restart already queued)"); return }
        schedule(why, after: Self.delay(failures: failures, settle: settle))
    }

    /// A deliberate (re)start or a source change: forget pending restarts and the failure count.
    func cancel() { generation += 1; pending = false; failures = 0 }

    private func schedule(_ why: String, after d: Double) {
        generation += 1; pending = true
        let g = generation
        log?(String(format: "capture: %@, restarting in %.1f s", why, d))
        queue.asyncAfter(deadline: .now() + d) { [weak self] in
            guard let self, self.generation == g else { return }
            self.attempts += 1
            Task {
                var err: Error?
                do { try await self.restart() } catch { err = error }
                self.queue.async {
                    guard self.generation == g else { return }      // cancelled while restarting
                    self.pending = false
                    if let err {
                        self.failures += 1
                        let next = Self.delay(failures: self.failures, settle: 0)
                        self.onStatus?(String(format: "System audio stopped (%@). Retrying in %.0f s…", "\(err)", next))
                        self.schedule("restart failed: \(err)", after: next)
                    } else {
                        self.log?("capture: restarted (attempt \(self.attempts), after \(self.failures) failures)")
                        self.failures = 0
                        self.onStatus?(nil)
                    }
                }
            }
        }
    }
}
