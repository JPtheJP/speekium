import Foundation
import XCTest
@testable import Speekium

final class UpdateLaunchHealthTests: XCTestCase {
    func testSignalsOnlyToPreparedInstallerHealthFile() throws {
        let temporary = FileManager.default.temporaryDirectory
        let root = temporary.appendingPathComponent(
            "Speekium-installer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let health = root.appendingPathComponent("health")
        XCTAssertTrue(FileManager.default.createFile(atPath: health.path, contents: Data()))
        let token = UUID().uuidString

        XCTAssertTrue(UpdateLaunchHealth.signalIfRequested(arguments: [
            "Speekium",
            UpdateLaunchHealth.fileArgument, health.path,
            UpdateLaunchHealth.tokenArgument, token,
        ]))
        XCTAssertEqual(try String(contentsOf: health, encoding: .utf8), token)
    }

    func testRejectsMissingDuplicateAndUnsafeHealthArguments() throws {
        let temporary = FileManager.default.temporaryDirectory
        let root = temporary.appendingPathComponent(
            "Speekium-installer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let health = root.appendingPathComponent("health")
        XCTAssertTrue(FileManager.default.createFile(atPath: health.path, contents: Data()))
        let token = UUID().uuidString

        XCTAssertNil(UpdateLaunchHealth.request(arguments: ["Speekium"]))
        XCTAssertNil(UpdateLaunchHealth.request(arguments: [
            "Speekium",
            UpdateLaunchHealth.fileArgument, health.path,
            UpdateLaunchHealth.fileArgument, health.path,
            UpdateLaunchHealth.tokenArgument, token,
        ]))
        XCTAssertNil(UpdateLaunchHealth.request(arguments: [
            "Speekium",
            UpdateLaunchHealth.fileArgument, health.path,
            UpdateLaunchHealth.tokenArgument, "not-a-uuid",
        ]))
        XCTAssertNil(UpdateLaunchHealth.request(arguments: [
            "Speekium",
            UpdateLaunchHealth.fileArgument, root.appendingPathComponent("other").path,
            UpdateLaunchHealth.tokenArgument, token,
        ]))
    }
}
