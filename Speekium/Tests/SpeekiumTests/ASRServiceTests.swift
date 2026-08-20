import Foundation
import XCTest
@testable import Speekium

final class ASRServiceTests: XCTestCase {
    func testAudioWritesDoNotBlockWhileSidecarIsStillStarting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Speekium-ASRServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("delayed_sidecar.py")
        try """
        import json
        import sys
        import time

        time.sleep(1.5)
        print(json.dumps({"type": "ready", "ms": 1500}), flush=True)
        for line in sys.stdin:
            if json.loads(line).get("cmd") == "quit":
                break
        """.write(to: script, atomically: true, encoding: .utf8)

        let service = ASRService(
            python: URL(fileURLWithPath: "/usr/bin/python3"),
            script: script,
            model: "unused",
            bits: 8,
            context: "",
            shortUtteranceLanguage: .english
        )
        let ready = expectation(description: "delayed sidecar becomes ready")
        service.onEvent = { event in
            if case .ready = event { ready.fulfill() }
        }
        try service.start()
        defer { service.shutdown() }

        // This is larger than a typical OS pipe buffer. Synchronous writes
        // block until the delayed process starts reading; queued writes return
        // without stalling either the audio callback or the app's main thread.
        let chunk = Data(repeating: 0, count: 8_192)
        let startedAt = ProcessInfo.processInfo.systemUptime
        for _ in 0..<16 { service.sendAudio(chunk) }
        let enqueueSeconds = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertLessThan(enqueueSeconds, 0.75)
        wait(for: [ready], timeout: 3)
    }

    func testUnexpectedSidecarExitHasDistinctLifecycleEvent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Speekium-ASRServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("exiting_sidecar.py")
        try """
        import json
        import sys
        import time

        print(json.dumps({"type": "ready", "ms": 1}), flush=True)
        time.sleep(0.1)
        sys.exit(7)
        """.write(to: script, atomically: true, encoding: .utf8)

        let service = ASRService(
            python: URL(fileURLWithPath: "/usr/bin/python3"),
            script: script,
            model: "unused",
            bits: 8,
            context: "",
            shortUtteranceLanguage: .english
        )
        let ready = expectation(description: "sidecar becomes ready")
        let terminated = expectation(description: "unexpected exit is reported")
        service.onEvent = { event in
            switch event {
            case .ready:
                ready.fulfill()
            case .terminated:
                terminated.fulfill()
            default:
                break
            }
        }
        try service.start()
        defer { service.shutdown() }

        wait(for: [ready, terminated], timeout: 3, enforceOrder: true)
    }
}
