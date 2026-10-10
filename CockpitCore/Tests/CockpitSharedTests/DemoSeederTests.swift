import Foundation
import SQLite3
import XCTest
@testable import CockpitShared

final class DemoSeederTests: XCTestCase {
    private var scratch: URL!
    private var source: URL { scratch.appendingPathComponent("Demo", isDirectory: true) }
    private var root: URL { scratch.appendingPathComponent("seeded", isDirectory: true) }
    private var paths: ClaudePaths { ClaudePaths.demo(root: root) }

    /// Wednesday 2026-03-18, 17:30 UTC — the instant every fixture timestamp is written against.
    private static let anchor = iso("2026-03-18T17:30:00Z")
    private static let paris = TimeZone(identifier: "Europe/Paris")!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoSeederTests-\(UUID().uuidString)", isDirectory: true)
        try writeSource()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Paths

    func testDemoPathsKeepEverythingUnderTheRoot() {
        let p = ClaudePaths.demo(root: URL(fileURLWithPath: "/c/demo"))
        XCTAssertEqual(p.home.path, "/c/demo/home")
        XCTAssertEqual(p.claudeDir.path, "/c/demo/home/.claude")
        XCTAssertEqual(p.appSupportDir.path, "/c/demo/appdata")
        XCTAssertEqual(p.rtkDatabaseCandidates.first?.path, "/c/demo/home/Library/Application Support/rtk/history.db")
        XCTAssertEqual(p.defaultProjectRoots.first?.path, "/c/demo/home/DevApps")
    }

    // MARK: Copy

    func testSeedCopiesTheTreeAndRestoresDotDirectories() throws {
        try DemoSeeder.seed(from: source, into: root, now: Self.anchor, calendar: calendar(Self.paris))
        let manager = FileManager.default
        XCTAssertTrue(manager.fileExists(atPath: paths.skillsDir.appendingPathComponent("weather-tips/SKILL.md").path))
        XCTAssertTrue(manager.fileExists(atPath: paths.home.appendingPathComponent("DevApps/notes-api/.claude/commands/ship.md").path))
        XCTAssertTrue(manager.fileExists(atPath: paths.pluginsCacheDir
            .appendingPathComponent("acme/toolkit/1.0.0/.claude-plugin/plugin.json").path))
        XCTAssertFalse(manager.fileExists(atPath: paths.home.appendingPathComponent("_dot_claude").path))
        XCTAssertFalse(manager.fileExists(atPath: paths.home.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(manager.fileExists(atPath: paths.appSupportDir.path))
    }

    func testReseedWipesPreviousCopyAndAppData() throws {
        try DemoSeeder.seed(from: source, into: root, now: Self.anchor, calendar: calendar(Self.paris))
        let stray = paths.skillsDir.appendingPathComponent("stray.md")
        try "x".write(to: stray, atomically: true, encoding: .utf8)
        let index = paths.appSupportDir.appendingPathComponent("sessions.db")
        try "x".write(to: index, atomically: true, encoding: .utf8)

        try DemoSeeder.seed(from: source, into: root, now: Self.anchor, calendar: calendar(Self.paris))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.appSupportDir.path))
    }

    func testRemoveDeletesTheWholeRoot() throws {
        try DemoSeeder.seed(from: source, into: root, now: Self.anchor, calendar: calendar(Self.paris))
        try DemoSeeder.remove(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        // Removing what is not there is not an error.
        XCTAssertNoThrow(try DemoSeeder.remove(root: root))
    }

    // MARK: Transcripts

    func testTodaySessionLandsTodayAndEndsBeforeNow() throws {
        let cal = calendar(Self.paris)
        let now = iso("2026-10-10T13:00:00Z")
        try DemoSeeder.seed(from: source, into: root, now: now, calendar: cal)
        let dates = try timestamps(in: "-Users-demo-DevApps-weather-app/s-today.jsonl")
        XCTAssertEqual(dates.count, 3)
        XCTAssertEqual(dates, dates.sorted())
        let last = try XCTUnwrap(dates.last)
        XCTAssertTrue(cal.isDate(last, inSameDayAs: now))
        XCTAssertLessThanOrEqual(last, now)
        XCTAssertGreaterThan(last, now.addingTimeInterval(-3600), "the last event is recent")
        // Spacing inside the session is kept when the day leaves room for it.
        XCTAssertEqual(dates[2].timeIntervalSince(dates[0]), 55 * 60, accuracy: 0.001)
    }

    func testTodaySessionStaysTodayJustAfterMidnight() throws {
        let cal = calendar(Self.paris)
        // 00:05 in Paris.
        let now = iso("2026-10-09T22:05:00Z")
        try DemoSeeder.seed(from: source, into: root, now: now, calendar: cal)
        let last = try XCTUnwrap(try timestamps(in: "-Users-demo-DevApps-weather-app/s-today.jsonl").last)
        XCTAssertTrue(cal.isDate(last, inSameDayAs: now))
        XCTAssertLessThanOrEqual(last, now)
    }

    func testOlderSessionKeepsItsDayOffset() throws {
        let cal = calendar(Self.paris)
        let now = iso("2026-10-10T13:00:00Z")
        try DemoSeeder.seed(from: source, into: root, now: now, calendar: cal)
        let dates = try timestamps(in: "-Users-demo-DevApps-notes-api/s-old.jsonl")
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: dates[0]), to: cal.startOfDay(for: now)).day
        XCTAssertEqual(days, 3)
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), 10 * 60, accuracy: 0.001)
    }

    func testSubagentMovesWithItsParent() throws {
        let now = iso("2026-10-10T13:00:00Z")
        try DemoSeeder.seed(from: source, into: root, now: now, calendar: calendar(Self.paris))
        let parent = try timestamps(in: "-Users-demo-DevApps-weather-app/s-today.jsonl")
        let child = try timestamps(in: "-Users-demo-DevApps-weather-app/s-today/subagents/agent-ahelper-1.jsonl")
        // Written 20 minutes after the parent's first line.
        XCTAssertEqual(child[0].timeIntervalSince(parent[0]), 20 * 60, accuracy: 0.001)
    }

    func testRewriteKeepsTheOtherFields() throws {
        let now = iso("2026-10-10T13:00:00Z")
        try DemoSeeder.seed(from: source, into: root, now: now, calendar: calendar(Self.paris))
        let text = try String(contentsOf: paths.projectsDir
            .appendingPathComponent("-Users-demo-DevApps-weather-app/s-today.jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 5)
        // A quoted "timestamp" inside message text is content, not a field.
        XCTAssertTrue(lines[0].contains(#"see \"timestamp\":\"2026-03-18T16:35:00.000Z\" here"#))
        XCTAssertEqual(lines[3], #"{"aiTitle":"Add hourly forecast","sessionId":"s-today","type":"ai-title"}"#)
        // cost-state carries its start as epoch milliseconds; it moves with the session.
        let cost = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[4].utf8)) as? [String: Any])
        let start = Date(timeIntervalSince1970: (cost["startTime"] as! Double) / 1000)
        let first = try XCTUnwrap(try timestamps(in: "-Users-demo-DevApps-weather-app/s-today.jsonl").first)
        XCTAssertEqual(start.timeIntervalSince(first), 0, accuracy: 0.001)
        XCTAssertEqual(cost["totalCostUSD"] as? Double, 1.25)
    }

    func testAnchorDaySessionFitsTodayEarlyInTheMorning() throws {
        let cal = calendar(Self.paris)
        // 00:30 in Paris: the 55-minute session has to be squeezed into half an hour.
        let now = iso("2026-10-09T22:30:00Z")
        try DemoSeeder.seed(from: source, into: root, now: now, calendar: cal)
        let dates = try timestamps(in: "-Users-demo-DevApps-weather-app/s-today.jsonl")
            + timestamps(in: "-Users-demo-DevApps-weather-app/s-today/subagents/agent-ahelper-1.jsonl")
        let today = cal.startOfDay(for: now)
        XCTAssertEqual(dates.count, 4)
        for date in dates {
            XCTAssertGreaterThanOrEqual(date, today)
            XCTAssertLessThanOrEqual(date, now)
        }
        let parent = try timestamps(in: "-Users-demo-DevApps-weather-app/s-today.jsonl")
        XCTAssertEqual(parent, parent.sorted())
    }

    func testOlderDayStaysBeforeTodayAfterADSTShift() throws {
        let cal = calendar(Self.paris)
        // Paris skipped an hour on 2026-03-29: that day is 23 hours long.
        let now = iso("2026-03-30T08:00:00Z")
        try DemoSeeder.seed(from: source, into: root, now: now, calendar: cal)
        let dates = try timestamps(in: "-Users-demo-DevApps-notes-api/s-late.jsonl")
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        XCTAssertEqual(dates.count, 2)
        for date in dates {
            XCTAssertLessThan(date, today)
            XCTAssertGreaterThanOrEqual(date, yesterday)
        }
        XCTAssertEqual(dates, dates.sorted())
    }

    // MARK: Paths

    func testSamplePathsPointIntoTheDemoHome() throws {
        try DemoSeeder.seed(from: source, into: root, now: iso("2026-10-10T13:00:00Z"), calendar: calendar(Self.paris))
        let text = try String(contentsOf: paths.projectsDir
            .appendingPathComponent("-Users-demo-DevApps-weather-app/s-today.jsonl"), encoding: .utf8)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.split(separator: "\n")[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["cwd"] as? String, paths.home.path + "/DevApps/weather-app")
        XCTAssertFalse(text.contains("/Users/demo"))

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(paths.rtkDatabaseCandidates[0].path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT project_path FROM commands ORDER BY id", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var projects: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { projects.append(String(cString: sqlite3_column_text(statement, 0))) }
        XCTAssertEqual(projects, [
            paths.home.path + "/DevApps/weather-app", paths.home.path + "/DevApps/notes-api", "/opt/elsewhere",
        ])
    }

    // MARK: RTK

    func testRTKRowsFallInTheLastSevenUTCDays() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 00:05 UTC: today's rows still have to land today, never in the future.
        for now in [iso("2026-10-10T00:05:00Z"), iso("2026-10-10T19:00:00Z")] {
            try DemoSeeder.seed(from: source, into: root, now: now, calendar: calendar(Self.paris))
            let rows = try rtkTimestamps()
            XCTAssertEqual(rows.count, 3)
            for stamp in rows {
                XCTAssertNotNil(stamp.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}\+00:00$"#, options: .regularExpression), stamp)
            }
            let dates = rows.map(Self.rtkDate)
            let today = utc.startOfDay(for: now)
            let offsets = dates.map { utc.dateComponents([.day], from: today, to: utc.startOfDay(for: $0)).day! }
            XCTAssertEqual(offsets, [0, -1, -6], "\(now)")
            XCTAssertTrue(dates.allSatisfy { $0 <= now })
        }
    }

    // MARK: Fixture

    private func writeSource() throws {
        let home = source.appendingPathComponent("home", isDirectory: true)
        try write(#"{"anchor":"2026-03-18T17:30:00Z","home":"/Users/demo"}"#, to: source.appendingPathComponent("manifest.json"))
        try write("---\nname: weather-tips\ndescription: Tips\n---\n",
                  to: home.appendingPathComponent("_dot_claude/skills/weather-tips/SKILL.md"))
        try write("---\nname: ship\ndescription: Ship it\n---\n",
                  to: home.appendingPathComponent("DevApps/notes-api/_dot_claude/commands/ship.md"))
        try write(#"{"description":"Toolkit"}"#,
                  to: home.appendingPathComponent("_dot_claude/plugins/cache/acme/toolkit/1.0.0/_dot_claude-plugin/plugin.json"))

        let projects = home.appendingPathComponent("_dot_claude/projects", isDirectory: true)
        // Today: three lines, 55 minutes apart end to end, the last 5 minutes before the anchor.
        try write([
            line("u1", "2026-03-18T16:30:00.000Z", text: #"see \"timestamp\":\"2026-03-18T16:35:00.000Z\" here"#),
            line("a1", "2026-03-18T17:00:00.000Z"),
            line("a2", "2026-03-18T17:25:00.000Z"),
            #"{"aiTitle":"Add hourly forecast","sessionId":"s-today","type":"ai-title"}"#,
            #"{"sessionId":"s-today","startTime":1773851400000,"totalCostUSD":1.25,"type":"cost-state"}"#,
        ].joined(separator: "\n") + "\n", to: projects.appendingPathComponent("-Users-demo-DevApps-weather-app/s-today.jsonl"))
        try write(line("x1", "2026-03-18T16:50:00.000Z", session: "s-today") + "\n",
                  to: projects.appendingPathComponent("-Users-demo-DevApps-weather-app/s-today/subagents/agent-ahelper-1.jsonl"))
        // The day before, late: on a 23-hour (DST) day it must not spill into today.
        try write([
            line("l1", "2026-03-17T23:30:00.000Z", session: "s-late"),
            line("l2", "2026-03-17T23:40:00.000Z", session: "s-late"),
        ].joined(separator: "\n") + "\n", to: projects.appendingPathComponent("-Users-demo-DevApps-notes-api/s-late.jsonl"))
        // Three days earlier.
        try write([
            line("o1", "2026-03-15T09:00:00.000Z", session: "s-old"),
            line("o2", "2026-03-15T09:10:00.000Z", session: "s-old"),
        ].joined(separator: "\n") + "\n", to: projects.appendingPathComponent("-Users-demo-DevApps-notes-api/s-old.jsonl"))

        let rtk = home.appendingPathComponent("Library/Application Support/rtk", isDirectory: true)
        try FileManager.default.createDirectory(at: rtk, withIntermediateDirectories: true)
        try sqlite(rtk.appendingPathComponent("history.db"), """
            CREATE TABLE commands (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL, original_cmd TEXT NOT NULL,
              rtk_cmd TEXT NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
              saved_tokens INTEGER NOT NULL, savings_pct REAL NOT NULL, project_path TEXT DEFAULT '');
            INSERT INTO commands VALUES (1, '2026-03-18T17:20:00.123456+00:00', 'git status', 'rtk git status', 100, 20, 80, 80.0, '/Users/demo/DevApps/weather-app');
            INSERT INTO commands VALUES (2, '2026-03-17T23:50:00.000000+00:00', 'cat a', 'rtk read', 100, 50, 50, 50.0, '/Users/demo/DevApps/notes-api');
            INSERT INTO commands VALUES (3, '2026-03-12T08:00:00.000000+00:00', 'ls', 'rtk ls', 100, 40, 60, 60.0, '/opt/elsewhere');
            """)
    }

    private func line(_ uuid: String, _ stamp: String, session: String = "s-today", text: String = "hi") -> String {
        #"{"cwd":"/Users/demo/DevApps/weather-app","message":{"content":"\#(text)","role":"user"},"sessionId":"\#(session)","timestamp":"\#(stamp)","type":"user","uuid":"\#(uuid)"}"#
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func timestamps(in relative: String) throws -> [Date] {
        let text = try String(contentsOf: paths.projectsDir.appendingPathComponent(relative), encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return (object?["timestamp"] as? String).map(Self.isoFraction)
        }
    }

    private func rtkTimestamps() throws -> [String] {
        let url = try XCTUnwrap(paths.rtkDatabaseCandidates.first)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT timestamp FROM commands ORDER BY id", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return result
    }

    private func sqlite(_ url: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func iso(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func iso(_ value: String) -> Date { Self.iso(value) }

    private static func isoFraction(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)!
    }

    private static func rtkDate(_ value: String) -> Date {
        isoFraction(String(value.prefix(23)) + "Z")
    }
}
