// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation

/// The projectM 4 C API, loaded at runtime with dlopen so RAVE LIVE builds and runs without it
/// (MILKDROP then shows a friendly card) and anyone can swap in their own libprojectM build (LGPL relinking).
/// The library comes from scripts/build_projectm.sh and lives in "RAVE LIVE.app/Contents/Frameworks".
final class MilkDropLib {
    typealias Handle = OpaquePointer
    typealias FailedCallback = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

    let create: @convention(c) () -> Handle?
    let destroy: @convention(c) (Handle) -> Void
    let loadPresetFile: @convention(c) (Handle, UnsafePointer<CChar>, Bool) -> Void
    let setWindowSize: @convention(c) (Handle, Int, Int) -> Void
    let renderFrameFBO: @convention(c) (Handle, UInt32) -> Void
    let pcmAddFloat: @convention(c) (Handle, UnsafePointer<Float>, UInt32, Int32) -> Void
    let pcmMaxSamples: @convention(c) () -> UInt32
    let setPresetDuration: @convention(c) (Handle, Double) -> Void
    let setSoftCutDuration: @convention(c) (Handle, Double) -> Void
    let setHardCutEnabled: @convention(c) (Handle, Bool) -> Void
    let setPresetLocked: @convention(c) (Handle, Bool) -> Void
    let setBeatSensitivity: @convention(c) (Handle, Float) -> Void
    let setFPS: @convention(c) (Handle, Int32) -> Void
    let setMeshSize: @convention(c) (Handle, Int, Int) -> Void
    let setTextureSearchPaths: @convention(c) (Handle, UnsafeMutablePointer<UnsafePointer<CChar>?>?, Int) -> Void
    let setFailedCallback: @convention(c) (Handle, FailedCallback?, UnsafeMutableRawPointer?) -> Void
    let version: String
    let path: String

    /// Shared instance, nil when the library is missing or too old (no render-to-FBO entry point).
    static let shared: MilkDropLib? = MilkDropLib()
    /// Why loading failed (shown on the MILKDROP card), empty when it loaded.
    nonisolated(unsafe) static var loadError = ""

    private init?() {
        var tried: [String] = []
        var handle: UnsafeMutableRawPointer?
        var found = ""
        for p in Self.candidates() {
            tried.append(p)
            if let h = dlopen(p, RTLD_NOW | RTLD_LOCAL) { handle = h; found = p; break }
        }
        guard let h = handle else {
            Self.loadError = "libprojectM-4.dylib not found (looked in \(tried.count) places). Build it with scripts/build_projectm.sh."
            return nil
        }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let create = sym("projectm_create", (@convention(c) () -> Handle?).self),
              let destroy = sym("projectm_destroy", (@convention(c) (Handle) -> Void).self),
              let load = sym("projectm_load_preset_file", (@convention(c) (Handle, UnsafePointer<CChar>, Bool) -> Void).self),
              let size = sym("projectm_set_window_size", (@convention(c) (Handle, Int, Int) -> Void).self),
              let render = sym("projectm_opengl_render_frame_fbo", (@convention(c) (Handle, UInt32) -> Void).self),
              let pcm = sym("projectm_pcm_add_float", (@convention(c) (Handle, UnsafePointer<Float>, UInt32, Int32) -> Void).self),
              let pcmMax = sym("projectm_pcm_get_max_samples", (@convention(c) () -> UInt32).self),
              let dur = sym("projectm_set_preset_duration", (@convention(c) (Handle, Double) -> Void).self),
              let soft = sym("projectm_set_soft_cut_duration", (@convention(c) (Handle, Double) -> Void).self),
              let hard = sym("projectm_set_hard_cut_enabled", (@convention(c) (Handle, Bool) -> Void).self),
              let lock = sym("projectm_set_preset_locked", (@convention(c) (Handle, Bool) -> Void).self),
              let sens = sym("projectm_set_beat_sensitivity", (@convention(c) (Handle, Float) -> Void).self),
              let fps = sym("projectm_set_fps", (@convention(c) (Handle, Int32) -> Void).self),
              let mesh = sym("projectm_set_mesh_size", (@convention(c) (Handle, Int, Int) -> Void).self),
              let tex = sym("projectm_set_texture_search_paths", (@convention(c) (Handle, UnsafeMutablePointer<UnsafePointer<CChar>?>?, Int) -> Void).self),
              let failed = sym("projectm_set_preset_switch_failed_event_callback", (@convention(c) (Handle, FailedCallback?, UnsafeMutableRawPointer?) -> Void).self)
        else {
            Self.loadError = "\(found) is missing projectm_opengl_render_frame_fbo: rebuild it with scripts/build_projectm.sh (applies the RAVE LIVE patch)."
            dlclose(h)
            return nil
        }
        self.create = create; self.destroy = destroy; loadPresetFile = load; setWindowSize = size
        renderFrameFBO = render; pcmAddFloat = pcm; pcmMaxSamples = pcmMax; setPresetDuration = dur
        setSoftCutDuration = soft; setHardCutEnabled = hard; setPresetLocked = lock; setBeatSensitivity = sens
        setFPS = fps; setMeshSize = mesh; setTextureSearchPaths = tex; setFailedCallback = failed
        path = found
        var maj: Int32 = 0, min: Int32 = 0, pat: Int32 = 0
        if let v = sym("projectm_get_version_components", (@convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void).self) {
            v(&maj, &min, &pat)
        }
        version = "\(maj).\(min).\(pat)"
    }

    /// Bundle Frameworks first, then RAVE_PROJECTM_LIB, then a source checkout's vendor/ build (swift run / tests).
    private static func candidates() -> [String] {
        var out: [String] = []
        if let env = ProcessInfo.processInfo.environment["RAVE_PROJECTM_LIB"] { out.append(env) }
        if let fw = Bundle.main.privateFrameworksPath { out.append(fw + "/libprojectM-4.dylib") }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        out.append(exe.appendingPathComponent("../Frameworks/libprojectM-4.dylib").path)
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        out.append(checkout.appendingPathComponent("vendor/projectm/lib/libprojectM-4.dylib").path)
        return out
    }
}
