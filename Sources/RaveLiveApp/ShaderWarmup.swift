// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation
import Metal
import QuartzCore

/// First launch after an install or update: Metal compiles the visuals from source (about 15 s on an M4 Max under
/// load), and that used to happen inside applicationDidFinishLaunching, before any window was on screen. Now the
/// window opens first (black, with a "Preparing the visuals" note) and every built-in pipeline is compiled here on
/// background threads, in parallel. Metal keeps the results in its shader cache, so the renderer set-up that follows
/// on the main thread finds them ready. Later launches hit the cache and this takes well under a second.
enum ShaderWarmup {
    /// Builds every built-in pipeline set (the same factory functions the renderers call), in parallel, and returns
    /// per-set seconds. Errors are left for the real set-up to report.
    static func run(device: MTLDevice, pixelFormat: MTLPixelFormat) -> [(String, Double)] {
        let jobs: [(String, () -> Void)] = [
            ("visuals", { _ = try? VisualsRenderer.pipelines(device: device, pixelFormat: pixelFormat) }),
            ("aurora", { _ = try? AuroraRenderer.pipelines(device: device, pixelFormat: pixelFormat) }),
            ("stage", { _ = try? Renderer.pipelines(device: device, pixelFormat: pixelFormat) }),
            ("milkdrop", { _ = try? MilkDropRenderer.pipelines(device: device, pixelFormat: pixelFormat) }),
        ]
        var times = [Double](repeating: 0, count: jobs.count)
        times.withUnsafeMutableBufferPointer { t in
            let tp = t
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                let t0 = CACurrentMediaTime()
                jobs[i].1()
                tp[i] = CACurrentMediaTime() - t0
            }
        }
        return zip(jobs.map(\.0), times).map { ($0, $1) }
    }
}
