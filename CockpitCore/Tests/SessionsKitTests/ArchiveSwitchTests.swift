import XCTest
import CockpitShared
@testable import SessionsKit

/// The Claude config directory can move while the app runs. The index stays in one
/// `sessions.db`, so the one service has to follow the new archive rather than a second
/// service opening the same file next to it.
final class ArchiveSwitchTests: XCTestCase {

    private var fixture: TranscriptFixture!

    override func setUpWithError() throws {
        fixture = try TranscriptFixture()
    }

    override func tearDown() {
        fixture = nil
    }

    func testSetPathsIndexesTheNewArchiveAndForgetsTheOldOne() async throws {
        let service = fixture.service()
        try fixture.write([
            Line.user(uuid: "old-u", text: "ancienne archive", at: TestClock.offset(0), sessionId: "sess-old"),
        ], to: "\(Line.project)/sess-old.jsonl")
        try await service.index()

        let otherPaths = ClaudePaths(
            home: fixture.home, configDir: fixture.home.appendingPathComponent("other-claude", isDirectory: true))
        let newFile = otherPaths.projectsDir.appendingPathComponent("\(Line.project)/sess-new.jsonl")
        try FileManager.default.createDirectory(
            at: newFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Line.user(uuid: "new-u", text: "nouvelle archive", at: TestClock.offset(10), sessionId: "sess-new")
             + "\n").write(to: newFile, atomically: true, encoding: .utf8)

        await service.setPaths(otherPaths)
        try await service.index()

        let ids = try await service.listSessions(SessionFilter()).map(\.id)
        XCTAssertEqual(ids, ["sess-new"], "only the archive now configured is listed")
    }

    /// Without a busy timeout a second connection fails at once with "database is locked"
    /// while another one writes.
    func testConnectionWaitsForALockInsteadOfFailing() throws {
        let store = try SessionStore(databaseURL: fixture.databaseURL)
        let timeout = try store.scalar("PRAGMA busy_timeout") as? Int64
        XCTAssertEqual(timeout, 5_000)
    }
}
