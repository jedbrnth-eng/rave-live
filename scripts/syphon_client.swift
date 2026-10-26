// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

// Test harness: connects to the Syphon server "RAVE LIVE" like Resolume/OBS would, receives frames for a few seconds,
// prints frame size, frame rate and the non-black share of the last frame, and saves it as a PNG.
// Build + run: scripts/syphon_client.sh [seconds] [out.png]
import AppKit
import Metal
import Syphon

let args = CommandLine.arguments
let seconds = args.count > 1 ? Double(args[1]) ?? 4 : 4
let outPNG = args.count > 2 ? args[2] : "syphon_frame.png"
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!

func runLoop(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

var desc: [String: Any]?
let wait0 = Date()
while desc == nil && Date().timeIntervalSince(wait0) < 15 {
    let servers = SyphonServerDirectory.shared().servers(matchingName: "RAVE LIVE", appName: nil)
    desc = servers.first as? [String: Any]
    if desc == nil { runLoop(0.2) }
}
guard let d = desc else { print("FAIL: no Syphon server named RAVE LIVE after 15 s"); exit(1) }
#if arch(x86_64)
let arch = "x86_64"
#else
let arch = "arm64"
#endif
print("found server: name=\(d[SyphonServerDescriptionNameKey] ?? "?") app=\(d[SyphonServerDescriptionAppNameKey] ?? "?") (client running as \(arch))")

var frames = 0
let lock = NSLock()
let client = SyphonMetalClient(serverDescription: d, device: device, options: nil) { _ in lock.lock(); frames += 1; lock.unlock() }
let t0 = Date()
runLoop(seconds)
let elapsed = Date().timeIntervalSince(t0)
lock.lock(); let n = frames; lock.unlock()
guard let tex = client.newFrameImage() else { print("FAIL: connected but no frame (frames=\(n))"); exit(1) }

// copy to a CPU-readable texture
let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: tex.pixelFormat, width: tex.width, height: tex.height, mipmapped: false)
td.storageMode = .shared
let copy = device.makeTexture(descriptor: td)!
let cb = queue.makeCommandBuffer()!
let blit = cb.makeBlitCommandEncoder()!
blit.copy(from: tex, to: copy); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
let w = copy.width, h = copy.height
var px = [UInt8](repeating: 0, count: w * h * 4)
copy.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
var lit = 0, sum = 0.0
for i in stride(from: 0, to: px.count, by: 4) {
    let m = max(px[i], px[i + 1], px[i + 2])
    if m > 16 { lit += 1 }
    sum += Double(px[i]) + Double(px[i + 1]) + Double(px[i + 2])
}
let nonBlack = Double(lit) / Double(w * h) * 100
print(String(format: "frame %dx%d pixelFormat=%lu  frames received=%d in %.1f s (%.1f fps)  non-black=%.1f%%  mean=%.1f",
             w, h, tex.pixelFormat.rawValue, n, elapsed, Double(n) / elapsed, nonBlack, sum / Double(w * h * 3)))
let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
if let prov = CGDataProvider(data: Data(px) as CFData),
   let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: info, provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outPNG))
    print("saved \(outPNG)")
}
client.stop()
print(nonBlack > 5 && n > 0 ? "PASS" : "FAIL: frame is black")
exit(nonBlack > 5 && n > 0 ? 0 : 1)
