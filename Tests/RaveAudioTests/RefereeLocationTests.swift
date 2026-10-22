import XCTest
@testable import RaveAudio

final class RefereeLocationTests: XCTestCase {
    private let home = "/home/someone"

    func testEnvironmentOverrideWins() {
        let d = BeatReferee.locateToolsDir(env: ["RAVE_REFEREE_DIR": "/opt/rave"], executable: nil, home: home, exists: { _ in true })
        XCTAssertEqual(d, "/opt/rave")
    }

    func testFindsCheckoutAboveBuildFolder() {
        let exe = URL(fileURLWithPath: "/work/rave/.build/release/RaveLiveApp")
        let d = BeatReferee.locateToolsDir(env: [:], executable: exe, home: home, exists: { $0 == "/work/rave/tools/referee.py" })
        XCTAssertEqual(d, "/work/rave/tools")
    }

    func testFindsCheckoutAboveAppBundle() {
        let exe = URL(fileURLWithPath: "/work/rave/build/RAVE LIVE.app/Contents/MacOS/RaveLiveApp")
        let d = BeatReferee.locateToolsDir(env: [:], executable: exe, home: home, exists: { $0 == "/work/rave/tools/referee.py" })
        XCTAssertEqual(d, "/work/rave/tools")
    }

    func testFallsBackToApplicationSupport() {
        let exe = URL(fileURLWithPath: "/Applications/RAVE LIVE.app/Contents/MacOS/RaveLiveApp")
        let d = BeatReferee.locateToolsDir(env: [:], executable: exe, home: home, exists: { _ in false })
        XCTAssertEqual(d, "/home/someone/Library/Application Support/RAVE LIVE/tools")
    }

    func testEmptyOverrideIsIgnored() {
        let d = BeatReferee.locateToolsDir(env: ["RAVE_REFEREE_DIR": ""], executable: nil, home: home, exists: { _ in false })
        XCTAssertEqual(d, "/home/someone/Library/Application Support/RAVE LIVE/tools")
    }
}

final class RefereeDeadPipeTests: XCTestCase {
    /// Writing to a sidecar that has already exited used to raise an uncatchable Objective-C exception / SIGPIPE.
    func testSendToDeadSidecarFailsGracefully() throws {
        let path = NSTemporaryDirectory() + "fake-referee-\(UUID().uuidString).sh"
        try "#!/bin/sh\necho '{\"ready\": true}'\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let r = try XCTUnwrap(BeatReferee(python: "/bin/sh", script: path, startupTimeout: 5))
        Thread.sleep(forTimeInterval: 0.5)   // let the sidecar exit
        let big = Data(count: 1 << 20)       // larger than a pipe buffer, so the write really hits the dead pipe
        XCTAssertFalse(r.send(big))
    }
}
