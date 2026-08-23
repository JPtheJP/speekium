import XCTest
@testable import WhisprStream

final class SemanticVersionTests: XCTestCase {
    func testAcceptsStableGitHubTagAndComparesComponents() {
        XCTAssertEqual(SemanticVersion("v1.2.3")?.description, "1.2.3")
        XCTAssertLessThan(SemanticVersion("1.2.9")!, SemanticVersion("1.3.0")!)
        XCTAssertLessThan(SemanticVersion("1.9.9")!, SemanticVersion("2.0.0")!)
    }

    func testRejectsIncompleteAndPrereleaseVersions() {
        XCTAssertNil(SemanticVersion("1.2"))
        XCTAssertNil(SemanticVersion("v1.2.3-beta.1"))
        XCTAssertNil(SemanticVersion("vv1.2.3"))
        XCTAssertNil(SemanticVersion("latest"))
    }
}
