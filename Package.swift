// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RaveLive",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "RaveAudio", targets: ["RaveAudio"]),
        .executable(name: "rave-probe", targets: ["RaveProbe"]),
    ],
    targets: [
        .target(name: "RaveAudio", path: "Sources/RaveAudio"),
        .executableTarget(name: "RaveProbe", dependencies: ["RaveAudio"], path: "Sources/RaveProbe"),
        .executableTarget(name: "RaveLiveApp", dependencies: ["RaveAudio"], path: "Sources/RaveLiveApp"),
        .testTarget(name: "RaveAudioTests", dependencies: ["RaveAudio"], path: "Tests/RaveAudioTests"),
    ]
)
