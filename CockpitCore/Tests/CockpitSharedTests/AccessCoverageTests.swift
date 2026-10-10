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
        XCTAssertEqual(AccessCoverage.evaluate(selection: claude.appendingPathComponent("projects"), expected: home, required: claude), .unrelated)    }

    /// "Réautoriser" must never trade the grant the app depends on for one that misses it.
    func testReplacingAGrantKeepsTheRequiredFolderCovered() {
        let claude = URL(fileURLWithPath: "/Users/x/.claude")
        // The home covered the Claude folder: the replacement has to as well.
        XCTAssertFalse(AccessCoverage.replacementKeepsRequired(
            old: "/Users/x", new: URL(fileURLWithPath: "/Users/x/Documents"), required: claude, grantedPaths: ["/Users/x"]))
        XCTAssertTrue(AccessCoverage.replacementKeepsRequired(
            old: "/Users/x", new: URL(fileURLWithPath: "/Users/x"), required: claude, grantedPaths: ["/Users/x"]))
        XCTAssertTrue(AccessCoverage.replacementKeepsRequired(
            old: "/Users/x", new: URL(fileURLWithPath: "/Users/x/.claude"), required: claude, grantedPaths: ["/Users/x"]))
        // Another grant still covers it: anything goes.
        XCTAssertTrue(AccessCoverage.replacementKeepsRequired(
            old: "/Users/x/.claude", new: URL(fileURLWithPath: "/tmp"), required: claude,
            grantedPaths: ["/Users/x/.claude", "/Users/x"]))
        // An RTK or project-root grant never covered it: swapping it is always fine.
        XCTAssertTrue(AccessCoverage.replacementKeepsRequired(
            old: "/Users/x/Library/Application Support/rtk", new: URL(fileURLWithPath: "/opt/rtk"),
            required: claude, grantedPaths: ["/Users/x/.claude", "/Users/x/Library/Application Support/rtk"]))
    }

    /// A Claude config directory on another volume: picking the home covers what was asked
    /// for but not what the app cannot work without, so it must never read as `.full`.
    func testSelectionVerdictWhenRequiredLiesOutsideExpected() {
        let home = URL(fileURLWithPath: "/Users/x")
        let external = URL(fileURLWithPath: "/Volumes/Data/claude")
        XCTAssertEqual(AccessCoverage.evaluate(selection: home, expected: home, required: external), .requiredElsewhere)
        XCTAssertEqual(AccessCoverage.evaluate(selection: URL(fileURLWithPath: "/Users"), expected: home, required: external), .requiredElsewhere)
        XCTAssertEqual(AccessCoverage.evaluate(selection: external, expected: home, required: external), .partial)
        XCTAssertEqual(AccessCoverage.evaluate(selection: URL(fileURLWithPath: "/"), expected: home, required: external), .full)
        XCTAssertEqual(AccessCoverage.evaluate(selection: URL(fileURLWithPath: "/Volumes/Other"), expected: home, required: external), .unrelated)
    }
}
