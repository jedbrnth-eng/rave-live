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
    /// Writing to a sidecar that has died used to raise an uncatchable Objective-C exception / SIGPIPE.
    /// The sidecar stays alive through startup (so init succeeds on any machine speed), then we stop it
    /// deliberately; nothing here depends on how fast a process exits.
    func testSendToDeadSidecarFailsGracefully() throws {
        let path = NSTemporaryDirectory() + "fake-referee-\(UUID().uuidString).sh"
        try "#!/bin/sh\necho '{\"ready\": true}'\nexec sleep 30\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let r = try XCTUnwrap(BeatReferee(python: "/bin/sh", script: path, startupTimeout: 10))
        r.stop()                              // terminate the sidecar: its stdin pipe now has no reader
        Thread.sleep(forTimeInterval: 0.5)    // let the OS tear the process down
        let big = Data(count: 1 << 20)        // larger than a pipe buffer, so the write really hits the dead pipe
        XCTAssertFalse(r.send(big))
    }
}
