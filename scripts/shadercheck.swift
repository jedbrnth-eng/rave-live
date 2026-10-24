// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

// Compile-checks the Metal source embedded in VisualsShader.swift without launching the app.
// Usage: swift scripts/shadercheck.swift   (prints "OK" or the Metal compiler errors)
import Foundation
import Metal

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/RaveLiveApp/VisualsShader.swift"
let text = try! String(contentsOfFile: path, encoding: .utf8)
guard let a = text.range(of: "#\"\"\"\n"), let b = text.range(of: "\n\"\"\"#", options: .backwards) else { print("no shader literal"); exit(2) }
let src = String(text[a.upperBound..<b.lowerBound])
guard let dev = MTLCreateSystemDefaultDevice() else { print("no Metal device"); exit(2) }
do {
    let lib = try dev.makeLibrary(source: src, options: nil)
    for n in ["vvert", "vwarp", "vcomp", "vsim"] { print(n, lib.makeFunction(name: n) != nil ? "found" : "MISSING") }
    print("OK")
} catch { print("\(error)"); exit(1) }
