import XCTest
import CockpitShared
@testable import SessionsKit

/// Stars, custom names and hidden flags are the only things in this database the user made,
/// and no re-index can bring them back. These tests pin the cases where a pass could take
/// them away.
final class DataLossGuardTests: XCTestCase {

    private var fixture: TranscriptFixture!
    private var service: SessionService!

    override func setUpWithError() throws {
        fixture = try TranscriptFixture()
        service = fixture.service()
    }

    override func tearDown() {
        service = nil
        fixture = nil
    }

    /// Two sessions, one starred and one renamed.
    private func writeAndMark() async throws {
        try fixture.writeDemoSession()
        try fixture.write([
            Line.user(uuid: "k-u", text: "deuxième projet", at: TestClock.offset(30),
                      sessionId: "sess-keep"),
        ], to: "\(Line.project)/sess-keep.jsonl")
        try await service.index()
        try await service.setStarred(true, sessionId: Line.session)
        try await service.rename(sessionId: "sess-keep", customName: "Nom que j'ai tapé")
    }

    /// `TranscriptWalker` returns an empty list both when the archive is genuinely empty and
    /// when the enumerator failed — a missing directory, an unmounted volume, a permission
    /// not granted yet. Reading the second as the first once cost every session row.
    func testAnEmptyWalkNeverDeletesAnything() async throws {
        try await writeAndMark()

        // Make the walk come back empty the way a real failure would: the projects directory
        // is simply not there any more.
        let projects = fixture.paths.projectsDir
        let moved = projects.deletingLastPathComponent().appendingPathComponent("projects-absent")
        try FileManager.default.moveItem(at: projects, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: projects) }

        let progress = try await service.index()
        XCTAssertEqual(progress.filesTotal, 0, "le parcours doit bien être vide")

        let starred = try XCTUnwrapAsync(try await service.session(id: Line.session))
        XCTAssertTrue(starred.isStarred, "l'étoile doit survivre à un parcours vide")
        let renamed = try XCTUnwrapAsync(try await service.session(id: "sess-keep"))
        XCTAssertEqual(renamed.customName, "Nom que j'ai tapé")

        var filter = SessionFilter()
        filter.includeSubagents = true
        await XCTAssertEqualAsync(try await service.listSessions(filter).count, 3,
                                  "aucune session ne doit disparaître")
    }

    /// A hidden session is a decision the user made too, and it lives nowhere else.
    func testAnEmptyWalkKeepsHiddenSessionsHidden() async throws {
        try await writeAndMark()
        try await service.hide(sessionId: "sess-keep")

        let projects = fixture.paths.projectsDir
        let moved = projects.deletingLastPathComponent().appendingPathComponent("projects-absent")
        try FileManager.default.moveItem(at: projects, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: projects) }
        try await service.index()

        await XCTAssertNotNilAsync(try await service.session(id: "sess-keep"))
        let listed = try await service.listSessions(SessionFilter())
        XCTAssertFalse(listed.contains { $0.id == "sess-keep" },
                       "la session masquée doit le rester")
    }

    /// Deleting a whole project removes several transcripts at once, a parent and its
    /// sub-agents among them. The cleanup has to survive that, not only a single file.
    func testAWholeProjectCanDisappearAtOnce() async throws {
        try await writeAndMark()
        try fixture.write([
            Line.user(uuid: "other-u", text: "projet gardé", at: TestClock.offset(40),
                      sessionId: "sess-other", cwd: "/Users/test/DevApps/Autre"),
        ], to: "-Users-test-DevApps-Autre/sess-other.jsonl")
        try await service.index()

        // Everything under the demo project goes: the two sessions and the sub-agent.
        try FileManager.default.removeItem(at: fixture.url(Line.project))
        let progress = try await service.index()
        XCTAssertGreaterThan(progress.filesTotal, 0, "le parcours n'est pas vide")

        var filter = SessionFilter()
        filter.includeSubagents = true
        await XCTAssertEqualAsync(try await service.listSessions(filter).map(\.id), ["sess-other"])
        await XCTAssertNilAsync(try await service.session(id: Line.session))
        await XCTAssertNilAsync(try await service.session(id: Line.agentId))
        // The index has to stay usable, not merely non-empty.
        await XCTAssertEqualAsync(try await service.search("licorne", filter: SessionFilter()), [])
        await XCTAssertEqualAsync(try await service.search("gardé", filter: SessionFilter()).count, 1)
    }

    /// The guard must not switch off the ordinary cleanup: a transcript really deleted, while
    /// the others are still there, still has to leave the index.
    func testADeletedTranscriptStillDisappearsWhenOthersRemain() async throws {
        try await writeAndMark()
        try FileManager.default.removeItem(at: fixture.url("\(Line.project)/sess-keep.jsonl"))

        let progress = try await service.index()
        XCTAssertGreaterThan(progress.filesTotal, 0, "le parcours n'est pas vide")

        await XCTAssertNilAsync(try await service.session(id: "sess-keep"))
        let survivor = try XCTUnwrapAsync(try await service.session(id: Line.session))
        XCTAssertTrue(survivor.isStarred, "les autres sessions ne sont pas touchées")
    }

    /// A transcript that leaves takes its content with it, but not the name the user gave it:
    /// if it comes back — a restored backup, a project moved back — the name is still there.
    func testATranscriptThatComesBackFindsItsCustomName() async throws {
        try await writeAndMark()
        let path = fixture.url("\(Line.project)/sess-keep.jsonl")
        let parked = fixture.home.appendingPathComponent("sess-keep.jsonl")
        try FileManager.default.moveItem(at: path, to: parked)
        try await service.index()
        await XCTAssertNilAsync(try await service.session(id: "sess-keep"))

        try FileManager.default.moveItem(at: parked, to: path)
        try await service.index()
        let back = try XCTUnwrapAsync(try await service.session(id: "sess-keep"))
        XCTAssertEqual(back.customName, "Nom que j'ai tapé")
    }

    /// Renaming a project folder moves every transcript under it to a new path. The new path
    /// carries the same session ids, so it must replace the old one, not erase the session.
    func testAMovedProjectKeepsItsSessionsAndTheirStars() async throws {
        try await writeAndMark()
        let before = try await service.messageCount(sessionId: Line.session)
        XCTAssertGreaterThan(before, 0)

        try FileManager.default.moveItem(
            at: fixture.url(Line.project), to: fixture.url("-Users-test-DevApps-Renamed"))
        try await service.index()
        try await service.index()   // the second pass is the one that used to see nothing

        let moved = try XCTUnwrapAsync(try await service.session(id: Line.session))
        XCTAssertTrue(moved.isStarred, "l'étoile doit suivre le transcript déplacé")
        await XCTAssertEqualAsync(try await service.messageCount(sessionId: Line.session), before)
        let renamed = try XCTUnwrapAsync(try await service.session(id: "sess-keep"))
        XCTAssertEqual(renamed.customName, "Nom que j'ai tapé")
        await XCTAssertEqualAsync(try await service.subagentMessages(agentId: Line.agentId).count, 2)
        let messages = try await service.messages(sessionId: Line.session, limit: 500)
        let agentCall = try XCTUnwrap(messages.flatMap(\.blocks).first { $0.toolName == "Agent" })
        XCTAssertEqual(agentCall.subagentId, Line.agentId)
        await XCTAssertEqualAsync(try await service.search("parseur", filter: SessionFilter()).count, 1)
    }

    /// Empty tool results and images are stored as blocks but never enter the full-text
    /// index. Purging must not send FTS5 a `'delete'` for them: each one lowers its document
    /// count, and on a small index the count hits zero and SQLite reports the file malformed —
    /// which made a renamed project folder fail every pass from then on.
    func testPurgingASessionWithUnindexedBlocksDoesNotCorruptTheSearchIndex() async throws {
        try fixture.write([
            Line.user(uuid: "e-u", text: "lance les tests", at: TestClock.offset(0)),
            Line.assistant(uuid: "e-a", at: TestClock.offset(1), blocks: [
                ["type": "tool_use", "id": "toolu_e", "name": "Bash", "input": ["command": "true"]],
            ], messageId: "msg_e"),
            Line.toolResult(uuid: "e-r", at: TestClock.offset(2), toolUseId: "toolu_e", text: ""),
        ], to: "\(Line.project)/\(Line.session).jsonl")
        try await service.index()
        let before = try await service.messageCount(sessionId: Line.session)

        try FileManager.default.moveItem(
            at: fixture.url(Line.project), to: fixture.url("-Users-test-DevApps-Renamed"))
        try await service.index()
        try await service.index()

        await XCTAssertEqualAsync(try await service.messageCount(sessionId: Line.session), before)
        await XCTAssertEqualAsync(
            try await service.search("tests", filter: SessionFilter()).count, 1)
    }

    /// A schema bump rebuilds the index, and must carry the user's marks across exactly like
    /// `index(full: true)` does.
    func testASchemaBumpKeepsStarsNamesAndHiddenSessions() async throws {
        try await writeAndMark()
        try await service.hide(sessionId: "sess-keep")
        service = nil

        // Pretend an older build wrote this file. `init` stamps the current version, so the
        // stale one is written afterwards.
        let old = try SessionStore(databaseURL: fixture.databaseURL)
        try old.setMetaValue(String(SessionStore.schemaVersion - 1), for: "schema_version")
        XCTAssertEqual(SessionStore.storedSchemaVersion(at: fixture.databaseURL),
                       SessionStore.schemaVersion - 1)

        let upgraded = fixture.service()
        try await upgraded.index()
        XCTAssertEqual(SessionStore.storedSchemaVersion(at: fixture.databaseURL),
                       SessionStore.schemaVersion)

        let starred = try XCTUnwrapAsync(try await upgraded.session(id: Line.session))
        XCTAssertTrue(starred.isStarred, "l'étoile doit survivre à un changement de schéma")
        let hidden = try XCTUnwrapAsync(try await upgraded.session(id: "sess-keep"))
        XCTAssertEqual(hidden.customName, "Nom que j'ai tapé")
        let listed = try await upgraded.listSessions(SessionFilter())
        XCTAssertFalse(listed.contains { $0.id == "sess-keep" }, "la session masquée doit le rester")
        XCTAssertTrue(listed.contains { $0.id == Line.session })
    }
}
