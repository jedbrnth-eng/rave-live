// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation
import Metal
import QuartzCore

/// Shader Lab: user `.metal` files in ~/Library/Application Support/RAVE LIVE/Shaders/ become Classic presets listed after
/// the built-ins. The folder is polled twice a second (catches in-place saves and editors that save by rename), each changed
/// file is compiled off the main thread, and a failed compile keeps the last good version running and reports the error with
/// the user's own line numbers (the file is spliced in after a `#line 1` directive). Contract: docs/SHADERS.md.
final class UserShaderLibrary {
    static let shared = UserShaderLibrary()

    struct Entry {
        let name: String                 // file name without .metal
        let url: URL
        var modified: Date
        var pipeline: MTLRenderPipelineState?
        var error: String?               // last compile error (nil = the current file compiled)
        var errorLines: [String] = []    // "line 12: message" + the offending source line
        var failedAt: Double = 0         // CACurrentMediaTime of the last failed compile
    }
    private(set) var entries: [Entry] = []
    /// Bumped whenever the list or a pipeline changes (lets the renderer react cheaply).
    private(set) var generation = 0
    var device: MTLDevice? { didSet { if oldValue == nil && device != nil { start() } } }
    let folder: URL
    private let queue = DispatchQueue(label: "rave.shaderlab", qos: .userInitiated)
    private var timer: Timer?
    private var compiling: Set<String> = []

    private init() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--shaderdir"), a.count > i + 1 {
            folder = URL(fileURLWithPath: NSString(string: a[i + 1]).expandingTildeInPath, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath)
            folder = base.appendingPathComponent("RAVE LIVE", isDirectory: true).appendingPathComponent("Shaders", isDirectory: true)
        }
    }

    /// Example shaders shipped in the app bundle (Resources/Shaders), or the repo's community/shaders when run from a checkout.
    static var bundledExamples: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Shaders"), FileManager.default.fileExists(atPath: r.path) { return r }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("community/shaders")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    private func start() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            // First launch: create the folder and copy the examples + starter template in, so there is something to open.
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if let src = Self.bundledExamples, let files = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
                for f in files where f.pathExtension == "metal" || f.lastPathComponent == "README.txt" {
                    try? fm.copyItem(at: f, to: folder.appendingPathComponent(f.lastPathComponent))
                }
            }
            NSLog("Shader Lab: created %@", folder.path)
        }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Picks up new, changed and deleted `.metal` files. Files starting with `_` (like `_template.metal`) are skipped.
    func poll() {
        guard let device else { return }
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "metal" && !$0.lastPathComponent.hasPrefix("_") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var next: [Entry] = []
        var changed = false
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if var e = entries.first(where: { $0.name == name }) {
                if e.modified != mod && !compiling.contains(name) { e.modified = mod; compile(name: name, url: url, device: device) }
                next.append(e)
            } else {
                next.append(Entry(name: name, url: url, modified: mod)); changed = true
                compile(name: name, url: url, device: device)
            }
        }
        if next.map(\.name) != entries.map(\.name) { changed = true }
        entries = next
        if changed { generation += 1 }
    }

    private func compile(name: String, url: URL, device: MTLDevice) {
        compiling.insert(name)
        queue.async { [weak self] in
            let t0 = Date()
            var pso: MTLRenderPipelineState?
            var err: String?
            var lines: [String] = []
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                do {
                    let lib = try device.makeLibrary(source: Self.wrap(text, file: url.lastPathComponent), options: nil)
                    let d = MTLRenderPipelineDescriptor()
                    d.vertexFunction = lib.makeFunction(name: "rave_vert")
                    d.fragmentFunction = lib.makeFunction(name: "rave_frag")
                    d.colorAttachments[0].pixelFormat = .rgba16Float
                    pso = try device.makeRenderPipelineState(descriptor: d)
                } catch {
                    err = "\(error)"
                    lines = Self.describe(error: "\(error)", file: url.lastPathComponent, source: text)
                }
            } else { err = "could not read the file"; lines = ["could not read \(url.lastPathComponent)"] }
            let ms = Date().timeIntervalSince(t0) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.compiling.remove(name)
                guard let i = self.entries.firstIndex(where: { $0.name == name }) else { return }
                if let pso {
                    self.entries[i].pipeline = pso; self.entries[i].error = nil; self.entries[i].errorLines = []
                    NSLog("Shader Lab: compiled %@ in %.0f ms", name, ms)
                } else {
                    self.entries[i].error = err; self.entries[i].errorLines = lines; self.entries[i].failedAt = CACurrentMediaTime()
                    NSLog("Shader Lab: %@ failed to compile (%@): %@", name, self.entries[i].pipeline == nil ? "nothing to show" : "keeping the last good version", lines.joined(separator: " | "))
                }
                self.generation += 1
            }
        }
    }

    /// Pulls "file:LINE:COL: error: message" lines out of the Metal compiler log and attaches the offending source line.
    static func describe(error: String, file: String, source: String) -> [String] {
        let src = source.components(separatedBy: "\n")
        var out: [String] = []
        for raw in error.components(separatedBy: "\n") {
            guard let r = raw.range(of: file + ":") else { continue }
            let rest = raw[r.upperBound...]
            let parts = rest.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count >= 4, let line = Int(parts[0]) else { continue }
            let kind = parts[2].trimmingCharacters(in: .whitespaces)
            guard kind == "error" else { continue }
            out.append("line \(line): \(parts[3].trimmingCharacters(in: .whitespaces))")
            if line >= 1 && line <= src.count { out.append("    \(line) | " + src[line - 1].trimmingCharacters(in: .whitespaces)) }
            if out.count >= 8 { break }
        }
        if out.isEmpty {   // linker-style errors (e.g. no `rave` function) carry no line
            let msg = error.components(separatedBy: "\n").first { $0.contains("error") } ?? error
            out.append(msg.count > 160 ? String(msg.prefix(160)) + "…" : msg)
            if !source.contains("rave(") { out.append("the file needs a function:  float4 rave(Rave r) { ... }") }
        }
        return out
    }

    /// The user's file is spliced between a prelude (types, helpers) and the entry point that fills `Rave` from the uniforms.
    static func wrap(_ user: String, file: String) -> String {
        prelude + "\n#line 1 \"\(file)\"\n" + user + "\n#line 1 \"rave_epilogue\"\n" + epilogue
    }

    /// Uniform layout (floats) shared with VisualsRenderer.encodeUser. Keep in sync with docs/SHADERS.md.
    static let uniformCount = 36
    static let prelude = #"""
#include <metal_stdlib>
using namespace metal;
struct RaveVOut { float4 pos [[position]]; float2 uv; };
vertex RaveVOut rave_vert(uint vid [[vertex_id]]) {
    float2 q = float2((vid << 1) & 2, vid & 2);
    RaveVOut o; o.pos = float4(q * 2.0 - 1.0, 0, 1); o.uv = float2(q.x, q.y); return o;
}
struct Rave {
    float2 uv;          // 0..1, origin bottom-left (like Shadertoy)
    float2 p;           // centred: x -aspect..aspect, y -1..1 (y up)
    float2 resolution;  // pixels
    float aspect;       // width / height
    float time;         // seconds
    float dt;           // seconds since the last frame
    float frame;        // frame counter
    float beat;         // beat clock in beats (continuous; whole numbers land on the beat)
    float beatPhase;    // 0..1 inside the current beat (0 = on the beat)
    float barPhase;     // 0..1 inside the current 4-beat bar (0 = the downbeat)
    float bpm;          // tempo (0 until locked)
    float bass, mid, high, energy;   // 0..1 levels
    float kick, snare, hat;          // envelopes: 1 on a hit, then decay
    float build, drop;               // 0..1 song structure (build-up, drop)
    float hue;                       // slowly drifting palette offset
    float variation;                 // random 0..1, new every time the preset is shown
    int pointerCount;                // mouse + camera hands (0..3)
    float3 pointer[3];               // x, y in `p` units, strength (0.5 hover, 1 pressed / hand)
    float3 click;                    // last click / pinch: x, y in `p` units, age in seconds (99 = none)
    texture2d<float> spectrumTex, waveformTex, previousTex;
    sampler smp;
};
// ---- helpers
float spectrum(Rave r, float x) { return r.spectrumTex.sample(r.smp, float2(clamp(x, 0.0, 1.0), 0.5)).r; }   // x 0 = bass .. 1 = treble, 0..1
float waveform(Rave r, float x) { return r.waveformTex.sample(r.smp, float2(clamp(x, 0.0, 1.0), 0.5)).r; }   // x 0..1 -> sample -1..1
float4 previous(Rave r, float2 uv) { return r.previousTex.sample(r.smp, float2(uv.x, 1.0 - uv.y)); }          // your last frame (feedback)
float3 palette(float t) { return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67))); }                   // rainbow cosine palette
float3 palette(float t, float3 a, float3 b, float3 c, float3 d) { return a + b * cos(6.28318 * (c * t + d)); }
float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
float noise(float2 p) { float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), f.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), f.x), f.y); }
float2 rotate(float2 p, float a) { float c = cos(a), s = sin(a); return float2(c * p.x - s * p.y, s * p.x + c * p.y); }
float beatPulse(Rave r, float sharpness) { return exp(-r.beatPhase * sharpness); }   // 1 on the beat, fades out
constant float PI = 3.14159265;
float4 rave(Rave r);
"""#
    static let epilogue = #"""
fragment float4 rave_frag(RaveVOut in [[stage_in]], constant float *U [[buffer(0)]],
                          texture2d<float> sp [[texture(0)]], texture2d<float> wv [[texture(1)]], texture2d<float> pv [[texture(2)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    Rave r;
    r.uv = in.uv; r.resolution = float2(U[0], U[1]); r.aspect = U[0] / max(U[1], 1.0);
    r.p = float2((in.uv.x * 2.0 - 1.0) * r.aspect, in.uv.y * 2.0 - 1.0);
    r.time = U[2]; r.dt = U[3]; r.beat = U[4]; r.beatPhase = U[5]; r.barPhase = U[6]; r.bpm = U[7];
    r.bass = U[8]; r.mid = U[9]; r.high = U[10]; r.energy = U[11]; r.kick = U[12]; r.snare = U[13]; r.hat = U[14];
    r.build = U[15]; r.drop = U[16]; r.frame = U[17]; r.hue = U[18]; r.variation = U[19]; r.pointerCount = int(U[20]);
    for (int i = 0; i < 3; i++) r.pointer[i] = float3(U[21 + 3 * i], U[22 + 3 * i], U[23 + 3 * i]);
    r.click = float3(U[30], U[31], U[32]);
    r.spectrumTex = sp; r.waveformTex = wv; r.previousTex = pv; r.smp = s;
    float4 c = rave(r);
    return float4(max(c.rgb, 0.0), 1.0);
}
"""#
}
