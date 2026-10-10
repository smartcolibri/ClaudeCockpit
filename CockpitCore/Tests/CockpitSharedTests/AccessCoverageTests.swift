import XCTest
@testable import CockpitShared

final class AccessCoverageTests: XCTestCase {
    func testPathInsideRootComparesWholeComponents() {
        XCTAssertTrue(AccessCoverage.isPath("/Users/x", inside: "/Users/x"))
        XCTAssertTrue(AccessCoverage.isPath("/Users/x/.claude/skills", inside: "/Users/x"))
        XCTAssertTrue(AccessCoverage.isPath("/Users/x/.claude/", inside: "/Users/x/"))
        XCTAssertFalse(AccessCoverage.isPath("/Users/xy", inside: "/Users/x"))
        XCTAssertFalse(AccessCoverage.isPath("/Users", inside: "/Users/x"))
        XCTAssertTrue(AccessCoverage.isPath("/Users/x/a/../b", inside: "/Users/x/b"))
        XCTAssertTrue(AccessCoverage.isPath("/anything", inside: "/"))
    }

    func testCoverageNeedsAGrantOnlyWhenSandboxed() {
        let claude = URL(fileURLWithPath: "/Users/x/.claude")
        XCTAssertTrue(AccessCoverage.isCovered(claude, grantedPaths: [], sandboxed: false))
        XCTAssertFalse(AccessCoverage.isCovered(claude, grantedPaths: [], sandboxed: true))
        XCTAssertTrue(AccessCoverage.isCovered(claude, grantedPaths: ["/Users/x"], sandboxed: true))
        XCTAssertTrue(AccessCoverage.isCovered(claude, grantedPaths: ["/tmp", "/Users/x/.claude"], sandboxed: true))
        XCTAssertFalse(AccessCoverage.isCovered(claude, grantedPaths: ["/Users/x/.claude/projects"], sandboxed: true))
    }

    func testSelectionVerdict() {
        let home = URL(fileURLWithPath: "/Users/x")
        let claude = home.appendingPathComponent(".claude")
        XCTAssertEqual(AccessCoverage.evaluate(selection: home, expected: home, required: claude), .full)
        XCTAssertEqual(AccessCoverage.evaluate(selection: URL(fileURLWithPath: "/Users"), expected: home, required: claude), .full)
        XCTAssertEqual(AccessCoverage.evaluate(selection: claude, expected: home, required: claude), .partial)
        XCTAssertEqual(AccessCoverage.evaluate(selection: claude, expected: claude, required: claude), .full)
        XCTAssertEqual(AccessCoverage.evaluate(selection: home.appendingPathComponent("Documents"), expected: home, required: claude), .unrelated)
        XCTAssertEqual(AccessCoverage.evaluate(selection: claude.appendingPathComponent("projects"), expected: home, required: claude), .unrelated)
    }
}
