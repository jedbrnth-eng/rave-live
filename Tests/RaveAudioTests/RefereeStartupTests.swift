import XCTest
@testable import RaveAudio

final class RefereeStartupTests: XCTestCase {
    private func script(_ body: String) throws -> String {
        let path = NSTemporaryDirectory() + "fake-referee-\(UUID().uuidString).sh"
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    /// A referee that stays silent must not block startup past the timeout (it used to wait on a blocking read).
    func testSilentRefereeTimesOutInsteadOfHanging() throws {
        let sh = try script("sleep 30")
        let started = Date()
        let r = BeatReferee(python: "/bin/sh", script: sh, startupTimeout: 1.0)
        XCTAssertNil(r, "a referee that never says ready should be rejected")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "startup must respect the timeout")
    }

    func testReadyRefereeStarts() throws {
        let sh = try script("echo '{\"ready\": true}'\nsleep 5")
        let r = BeatReferee(python: "/bin/sh", script: sh, startupTimeout: 5.0)
        XCTAssertNotNil(r)
        r?.stop()
    }

    func testMissingExecutableIsRejected() {
        XCTAssertNil(BeatReferee(python: "/nonexistent/python", script: "/nonexistent.py", startupTimeout: 1.0))
    }
}
