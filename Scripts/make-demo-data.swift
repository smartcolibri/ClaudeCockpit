#!/usr/bin/env swift
//
//  make-demo-data.swift — sample data for Cockpit for Claude's demo mode
//
//  Writes ClaudeCockpit/Resources/Demo/: a manifest naming the anchor instant, and a
//  fictional home holding Claude Code transcripts (three projects, eight sessions with
//  sub-agents, edits, titles and costs), skills / agents / commands at every level, a
//  plugin, and an rtk history.db over seven UTC days. Everything is invented and in
//  English; no path or name comes from a real machine.
//
//  Timestamps are written against a fixed anchor; `DemoSeeder` moves them next to the
//  current date when the demo starts. Directories that start with a dot are written as
//  `_dot_<name>` so the app bundle copy keeps them; the seeder restores the dot.
//
//  Deterministic: same script, same output (sorted JSON keys, fixed ids, seeded numbers).
//
//  Usage: ./Scripts/make-demo-data.swift
//
import Foundation
import SQLite3

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Output
// ─────────────────────────────────────────────────────────────────────────────

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let outputDir = scriptDir.deletingLastPathComponent()
    .appendingPathComponent("ClaudeCockpit/Resources/Demo", isDirectory: true)
let homeDir = outputDir.appendingPathComponent("home", isDirectory: true)
let claudeDir = homeDir.appendingPathComponent("_dot_claude", isDirectory: true)
let projectsDir = claudeDir.appendingPathComponent("projects", isDirectory: true)
let fm = FileManager.default

/// Wednesday 2026-03-18, 17:30 UTC. Sessions on this UTC day are "today" once seeded.
let anchorString = "2026-03-18T17:30:00Z"
let anchor = ISO8601DateFormatter().date(from: anchorString)!
let demoUser = "/Users/demo"

func write(_ text: String, to url: URL) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

// Start clean: only the two things this script owns.
try? fm.removeItem(at: homeDir)
try? fm.removeItem(at: outputDir.appendingPathComponent("manifest.json"))
write("{\"anchor\":\"\(anchorString)\"}\n", to: outputDir.appendingPathComponent("manifest.json"))

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Transcript lines
// ─────────────────────────────────────────────────────────────────────────────

let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func encode(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

struct Project {
    let name: String
    let branch: String
    var cwd: String { "\(demoUser)/DevApps/\(name)" }
    var directory: String { cwd.replacingOccurrences(of: "/", with: "-") }
}

let weather = Project(name: "weather-app", branch: "feat/hourly-forecast")
let notes = Project(name: "notes-api", branch: "main")
let site = Project(name: "marketing-site", branch: "redesign")

/// Writes one session line by line, moving its own clock forward as it goes.
final class Session {
    let id: String
    let project: Project
    let model: String
    let agentId: String?
    private(set) var clock: Date
    private(set) var lines: [String] = []
    private var serial = 0
    private var firstLine: Date?
    private var linesAdded = 0
    private var linesRemoved = 0
    /// API-price cost of the turns written so far (the app's default pricing), so the
    /// `cost-state` line agrees with what the Usage screen computes from the same tokens.
    private(set) var cost = 0.0

    init(id: String, project: Project, model: String, start: Date, agentId: String? = nil) {
        self.id = id
        self.project = project
        self.model = model
        self.clock = start
        self.agentId = agentId
    }

    private func next(_ prefix: String) -> String {
        serial += 1
        // A sub-agent shares its parent's session id, so its own id keeps the uuids apart.
        return String(format: "%@-%@-%03d", agentId ?? id, prefix, serial)
    }

    private func envelope(_ type: String, after seconds: Double) -> [String: Any] {
        clock = clock.addingTimeInterval(seconds)
        if firstLine == nil { firstLine = clock }
        var object: [String: Any] = [
            "type": type, "uuid": next("u"), "sessionId": id,
            "timestamp": iso.string(from: clock), "cwd": project.cwd,
            "gitBranch": project.branch, "version": "2.1.80", "slug": "\(project.name)-session",
        ]
        if let agentId {
            object["agentId"] = agentId
            object["isSidechain"] = true
        }
        return object
    }

    func user(_ text: String, after seconds: Double = 20) {
        var object = envelope("user", after: seconds)
        object["message"] = ["role": "user", "content": text]
        lines.append(encode(object))
    }

    /// One assistant line; every line gets its own `message.id` so usage counts each turn.
    func assistant(_ blocks: [[String: Any]], after seconds: Double = 25, input: Int = 12, output: Int,
                   cacheRead: Int, cacheWrite: Int) {
        var object = envelope("assistant", after: seconds)
        object["message"] = [
            "id": "msg_\(next("m"))", "role": "assistant", "model": model, "type": "message",
            "content": blocks, "stop_reason": "end_turn",
            "usage": [
                "input_tokens": input, "output_tokens": output,
                "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": cacheWrite,
            ],
        ]
        lines.append(encode(object))
        // $/MTok: input, output, cache write, cache read.
        let price: [Double] = model.contains("opus") ? [5, 25, 6.25, 0.5]
            : model.contains("haiku") ? [1, 5, 1.25, 0.1] : [3, 15, 3.75, 0.3]
        cost += (Double(input) * price[0] + Double(output) * price[1]
                 + Double(cacheWrite) * price[2] + Double(cacheRead) * price[3]) / 1_000_000
    }

    /// Adds a sub-agent's turns to the session total, as Claude Code's own counter does.
    func absorb(_ agent: Session) { cost += agent.cost }

    func toolResult(_ toolUseId: String, _ text: String, isError: Bool = false, after seconds: Double = 6) {
        var object = envelope("user", after: seconds)
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": toolUseId, "content": text]
        if isError { block["is_error"] = true }
        object["message"] = ["role": "user", "content": [block]]
        lines.append(encode(object))
    }

    // MARK: Blocks

    func text(_ value: String) -> [String: Any] { ["type": "text", "text": value] }
    func thinking(_ value: String) -> [String: Any] { ["type": "thinking", "thinking": value, "signature": "demo"] }

    /// A tool call; returns the block and its id for the matching result.
    func tool(_ name: String, _ input: [String: Any]) -> ([String: Any], String) {
        let toolId = "toolu_\(next("t"))"
        return (["type": "tool_use", "id": toolId, "name": name, "input": input], toolId)
    }

    func edit(_ file: String, old: String, new: String) -> ([String: Any], String) {
        linesAdded += new.split(separator: "\n").count
        linesRemoved += old.split(separator: "\n").count
        return tool("Edit", ["file_path": "\(project.cwd)/\(file)", "old_string": old, "new_string": new])
    }

    func writeFile(_ file: String, _ content: String) -> ([String: Any], String) {
        linesAdded += content.split(separator: "\n").count
        return tool("Write", ["file_path": "\(project.cwd)/\(file)", "content": content])
    }

    // MARK: Session metadata

    func title(_ value: String) { lines.append(encode(["type": "ai-title", "aiTitle": value, "sessionId": id])) }

    func prLink(_ number: Int) {
        lines.append(encode([
            "type": "pr-link", "sessionId": id, "prNumber": number,
            "prUrl": "https://github.com/example/\(project.name)/pull/\(number)",
            "prRepository": "example/\(project.name)", "timestamp": iso.string(from: clock),
        ]))
    }

    func costState() {
        lines.append(encode([
            "type": "cost-state", "sessionId": id, "totalCostUSD": NSDecimalNumber(string: String(format: "%.4f", cost)),
            "totalLinesAdded": linesAdded, "totalLinesRemoved": linesRemoved,
            "startTime": Int64((firstLine ?? clock).timeIntervalSince1970 * 1000),
        ]))
    }

    /// `<project>/<session>.jsonl`, or `<project>/<parent>/subagents/agent-<id>.jsonl`.
    func save(parent: String? = nil) {
        let relative: String
        if let parent, let agentId {
            relative = "\(project.directory)/\(parent)/subagents/agent-\(agentId).jsonl"
        } else {
            relative = "\(project.directory)/\(id).jsonl"
        }
        write(lines.joined(separator: "\n") + "\n", to: projectsDir.appendingPathComponent(relative))
    }
}

/// `anchor` shifted by whole days plus a UTC time of day ("HH:mm").
func at(day: Int, _ time: String) -> Date {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let parts = time.split(separator: ":").compactMap { Int($0) }
    let midnight = utc.startOfDay(for: anchor).addingTimeInterval(Double(day) * 86_400)
    return midnight.addingTimeInterval(Double(parts[0] * 3600 + parts[1] * 60))
}

/// Sessions written on the anchor's day must end before it, or they would land in the future.
func checkToday(_ session: Session) {
    precondition(session.clock < anchor, "\(session.id) ends after the anchor")
}

let opus = "claude-opus-4-6"
let sonnet = "claude-sonnet-4-6"
let haiku = "claude-haiku-4-5"

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Sessions
// ─────────────────────────────────────────────────────────────────────────────

// 1. weather-app, today, with an Explore sub-agent.
do {
    let s = Session(id: "7c1e9a40-5b2d-4f8e-9a61-0d3c2b1a8e01", project: weather, model: opus, start: at(day: 0, "17:12"))
    s.user("Add an hourly forecast strip under the current conditions card. Use the existing WeatherService and keep it accessible.")
    let (explore, exploreId) = s.tool("Agent", [
        "description": "Map the forecast code", "subagent_type": "Explore",
        "prompt": "Find where WeatherService fetches forecasts and which views consume them.",
    ])
    s.assistant([s.thinking("I should find how forecasts flow from WeatherService to the views before touching the UI."),
                 s.text("Let me map the forecast code first."), explore],
                output: 412, cacheRead: 18_200, cacheWrite: 6_400)

    let agent = Session(id: s.id, project: weather, model: haiku, start: s.clock.addingTimeInterval(4),
                        agentId: "a4f2c9e17b3d58a60")
    agent.user("Find where WeatherService fetches forecasts and which views consume them.", after: 0)
    let (grep, grepId) = agent.tool("Grep", ["pattern": "hourly", "path": "Sources"])
    agent.assistant([agent.text("Searching for hourly data."), grep], after: 8, output: 96, cacheRead: 4_100, cacheWrite: 2_200)
    agent.toolResult(grepId, "Sources/Services/WeatherService.swift:42: func hourly(for location: Location) async throws -> [HourlyPoint]\nSources/Models/HourlyPoint.swift:3: struct HourlyPoint: Identifiable, Codable")
    agent.assistant([agent.text("`WeatherService.hourly(for:)` already returns `[HourlyPoint]` (time, temperature, symbol, precipitation chance). No view consumes it yet; `CurrentConditionsCard` only reads `current(for:)`.")],
                    after: 10, output: 188, cacheRead: 5_300, cacheWrite: 900)
    agent.save(parent: s.id)
    s.absorb(agent)

    s.toolResult(exploreId, "WeatherService.hourly(for:) returns [HourlyPoint]; nothing renders it yet. CurrentConditionsCard reads current(for:) only.\n\nagentId: a4f2c9e17b3d58a60 (use SendMessage with to: 'a4f2c9e17b3d58a60' to continue this agent)",
                 after: 40)
    let (newView, newViewId) = s.writeFile("Sources/Views/HourlyForecastStrip.swift", """
        import SwiftUI

        struct HourlyForecastStrip: View {
            let points: [HourlyPoint]

            var body: some View {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(points) { point in
                            VStack(spacing: 6) {
                                Text(point.time, format: .dateTime.hour())
                                    .font(.caption)
                                Image(systemName: point.symbol)
                                    .symbolRenderingMode(.multicolor)
                                Text(point.temperature, format: .number.precision(.fractionLength(0)))
                                    .font(.headline)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        """)
    s.assistant([s.text("I'll add a horizontally scrolling strip, one cell per hour, each cell read as a single accessibility element."), newView],
                output: 1_240, cacheRead: 24_800, cacheWrite: 3_100)
    s.toolResult(newViewId, "File created successfully at: \(weather.cwd)/Sources/Views/HourlyForecastStrip.swift")
    let (wire, wireId) = s.edit("Sources/Views/HomeView.swift",
        old: "            CurrentConditionsCard(conditions: model.current)\n",
        new: "            CurrentConditionsCard(conditions: model.current)\n            HourlyForecastStrip(points: model.hourly)\n")
    s.assistant([s.text("Now wire it into the home screen."), wire], output: 286, cacheRead: 27_400, cacheWrite: 1_200)
    s.toolResult(wireId, "The file \(weather.cwd)/Sources/Views/HomeView.swift has been updated successfully.")
    let (model, modelId) = s.edit("Sources/ViewModels/HomeViewModel.swift",
        old: "    @Published var current: Conditions?\n",
        new: "    @Published var current: Conditions?\n    @Published var hourly: [HourlyPoint] = []\n")
    s.assistant([model], output: 164, cacheRead: 28_100, cacheWrite: 640)
    s.toolResult(modelId, "The file \(weather.cwd)/Sources/ViewModels/HomeViewModel.swift has been updated successfully.")
    let (build, buildId) = s.tool("Bash", ["command": "xcodebuild -scheme Skyline -destination 'platform=iOS Simulator,name=iPhone 17' build", "description": "Build the app"])
    s.assistant([build], output: 98, cacheRead: 28_900, cacheWrite: 420)
    s.toolResult(buildId, "error: HomeViewModel.swift:58: cannot find 'hourly' in scope", isError: true, after: 50)
    let (fix, fixId) = s.edit("Sources/ViewModels/HomeViewModel.swift",
        old: "        current = try await service.current(for: location)\n",
        new: "        current = try await service.current(for: location)\n        hourly = try await service.hourly(for: location)\n")
    s.assistant([s.text("The refresh never loaded the hourly points. Fixing the load path."), fix],
                output: 236, cacheRead: 29_600, cacheWrite: 980)
    s.toolResult(fixId, "The file \(weather.cwd)/Sources/ViewModels/HomeViewModel.swift has been updated successfully.")
    let (rebuild, rebuildId) = s.tool("Bash", ["command": "xcodebuild -scheme Skyline -destination 'platform=iOS Simulator,name=iPhone 17' build", "description": "Build the app"])
    s.assistant([rebuild], output: 92, cacheRead: 30_200, cacheWrite: 310)
    s.toolResult(rebuildId, "** BUILD SUCCEEDED **", after: 55)
    s.assistant([s.text("Done. The home screen now shows a 24-hour strip under the current conditions card:\n\n- `HourlyForecastStrip` (new) renders one cell per hour, combined for VoiceOver.\n- `HomeViewModel` loads `hourly` alongside `current`.\n- The build passes.")],
                output: 318, cacheRead: 30_900, cacheWrite: 520)
    s.title("Add hourly forecast strip")
    s.costState()
    checkToday(s)
    s.save()
}

// 2. notes-api, today: a pagination bug, a failing test, a PR.
do {
    let s = Session(id: "2b8d4e61-0f7a-4c39-8e25-6a1f9c3d7b02", project: notes, model: sonnet, start: at(day: 0, "09:12"))
    s.user("GET /notes?cursor=… returns the last note of the previous page again. Find out why and fix it.")
    let (read, readId) = s.tool("Read", ["file_path": "\(notes.cwd)/internal/store/notes.go"])
    s.assistant([s.text("Let me look at the cursor query."), read], output: 142, cacheRead: 12_400, cacheWrite: 5_800)
    s.toolResult(readId, "118\tquery := `SELECT id, title, body, created_at FROM notes WHERE created_at <= $1 ORDER BY created_at DESC LIMIT $2`")
    let (fix, fixId) = s.edit("internal/store/notes.go",
        old: "WHERE created_at <= $1 ORDER BY created_at DESC LIMIT $2",
        new: "WHERE (created_at, id) < ($1, $2) ORDER BY created_at DESC, id DESC LIMIT $3")
    s.assistant([s.text("The cursor compares with `<=`, so the boundary row comes back. Notes created in the same second also make `created_at` alone ambiguous; I'll use a keyset on `(created_at, id)`."), fix],
                output: 388, cacheRead: 15_900, cacheWrite: 1_400)
    s.toolResult(fixId, "The file \(notes.cwd)/internal/store/notes.go has been updated successfully.")
    let (test, testId) = s.tool("Bash", ["command": "go test ./internal/...", "description": "Run the store tests"])
    s.assistant([test], output: 74, cacheRead: 16_700, cacheWrite: 520)
    s.toolResult(testId, "--- FAIL: TestListNotesCursor (0.02s)\n    notes_test.go:88: cursor encodes only created_at\nFAIL", isError: true, after: 14)
    let (cursor, cursorId) = s.edit("internal/api/cursor.go",
        old: "func encodeCursor(n Note) string {\n\treturn base64.URLEncoding.EncodeToString([]byte(n.CreatedAt.Format(time.RFC3339Nano)))\n}",
        new: "func encodeCursor(n Note) string {\n\traw := n.CreatedAt.Format(time.RFC3339Nano) + \"|\" + n.ID\n\treturn base64.URLEncoding.EncodeToString([]byte(raw))\n}")
    s.assistant([s.text("The cursor itself has to carry the id too."), cursor], output: 296, cacheRead: 17_800, cacheWrite: 900)
    s.toolResult(cursorId, "The file \(notes.cwd)/internal/api/cursor.go has been updated successfully.")
    let (retest, retestId) = s.tool("Bash", ["command": "go test ./...", "description": "Run all tests"])
    s.assistant([retest], output: 70, cacheRead: 18_600, cacheWrite: 300)
    s.toolResult(retestId, "ok  \texample.com/notes-api/internal/api\t0.41s\nok  \texample.com/notes-api/internal/store\t0.87s", after: 18)
    let (pr, prId) = s.tool("Bash", ["command": "gh pr create --title \"fix: keyset pagination on (created_at, id)\" --fill", "description": "Open the pull request"])
    s.assistant([s.text("Tests pass. Opening the pull request."), pr], output: 120, cacheRead: 19_100, cacheWrite: 260)
    s.toolResult(prId, "https://github.com/example/notes-api/pull/128")
    s.prLink(128)
    s.assistant([s.text("Fixed and opened #128: the cursor now encodes `(created_at, id)` and the query uses a strict keyset comparison, so no row repeats across pages, even for notes created in the same second.")],
                output: 210, cacheRead: 19_500, cacheWrite: 180)
    s.title("Fix duplicated note on paginated list")
    s.costState()
    checkToday(s)
    s.save()
}

// 3. marketing-site, yesterday: pricing page.
do {
    let s = Session(id: "9e3f7a12-6c4b-4d0e-b8a3-1f5e2d9c4a03", project: site, model: sonnet, start: at(day: -1, "13:40"))
    s.user("Rework the pricing page: three plans side by side, yearly/monthly toggle, the middle plan highlighted.")
    let (page, pageId) = s.writeFile("src/pages/pricing.astro", """
        ---
        import Layout from "../layouts/Layout.astro";
        import PlanCard from "../components/PlanCard.astro";
        import plans from "../data/plans.json";
        ---
        <Layout title="Pricing">
          <section class="plans">
            {plans.map((plan) => <PlanCard {...plan} featured={plan.id === "team"} />)}
          </section>
        </Layout>
        """)
    s.assistant([s.text("I'll rebuild the page around a data file so the plans stay in one place."), page],
                output: 640, cacheRead: 9_800, cacheWrite: 7_200)
    s.toolResult(pageId, "File created successfully at: \(site.cwd)/src/pages/pricing.astro")
    let (data, dataId) = s.writeFile("src/data/plans.json", """
        [
          { "id": "starter", "name": "Starter", "monthly": 0, "yearly": 0 },
          { "id": "team", "name": "Team", "monthly": 12, "yearly": 120 },
          { "id": "business", "name": "Business", "monthly": 29, "yearly": 290 }
        ]
        """)
    s.assistant([data], output: 220, cacheRead: 12_600, cacheWrite: 900)
    s.toolResult(dataId, "File created successfully at: \(site.cwd)/src/data/plans.json")
    let (css, cssId) = s.edit("src/components/PlanCard.astro",
        old: ".card { border: 1px solid var(--line); }",
        new: ".card { border: 1px solid var(--line); border-radius: 14px; }\n.card.featured { border-color: var(--accent); box-shadow: 0 12px 32px rgb(0 0 0 / 0.12); }")
    s.assistant([s.text("Highlighting the Team plan."), css], output: 260, cacheRead: 13_400, cacheWrite: 600)
    s.toolResult(cssId, "The file \(site.cwd)/src/components/PlanCard.astro has been updated successfully.")
    s.assistant([s.text("The pricing page now reads its plans from `src/data/plans.json`, shows them side by side and highlights Team. The yearly toggle reuses the existing `Toggle` component.")],
                output: 180, cacheRead: 13_900, cacheWrite: 200)
    s.title("Redesign pricing page")
    s.costState()
    s.save()
}

// 4. weather-app, two days ago: offline cache, with a sub-agent writing tests.
do {
    let s = Session(id: "4d6a1c85-3e9f-4b72-a0d4-8c2e7f1b5a04", project: weather, model: opus, start: at(day: -2, "10:05"))
    s.user("Cache the last forecast on disk so the app opens with data when offline.")
    let (cache, cacheId) = s.writeFile("Sources/Services/ForecastCache.swift", """
        import Foundation

        actor ForecastCache {
            private let url: URL

            init(directory: URL) {
                url = directory.appendingPathComponent("forecast.json")
            }

            func load() -> Forecast? {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(Forecast.self, from: data)
            }

            func save(_ forecast: Forecast) throws {
                try JSONEncoder().encode(forecast).write(to: url, options: .atomic)
            }
        }
        """)
    s.assistant([s.text("A small actor that stores the last forecast as JSON in Caches."), cache],
                output: 820, cacheRead: 21_000, cacheWrite: 8_800)
    s.toolResult(cacheId, "File created successfully at: \(weather.cwd)/Sources/Services/ForecastCache.swift")
    let (useIt, useItId) = s.edit("Sources/Services/WeatherService.swift",
        old: "        let forecast = try await client.forecast(for: location)\n        return forecast\n",
        new: "        do {\n            let forecast = try await client.forecast(for: location)\n            try? await cache.save(forecast)\n            return forecast\n        } catch {\n            if let cached = await cache.load() { return cached }\n            throw error\n        }\n")
    s.assistant([useIt], output: 410, cacheRead: 24_300, cacheWrite: 1_100)
    s.toolResult(useItId, "The file \(weather.cwd)/Sources/Services/WeatherService.swift has been updated successfully.")
    let (agentCall, agentCallId) = s.tool("Agent", [
        "description": "Write cache tests", "subagent_type": "test-writer",
        "prompt": "Write unit tests for ForecastCache: round trip, missing file, corrupt file.",
    ])
    s.assistant([s.text("Delegating the tests."), agentCall], output: 150, cacheRead: 25_100, cacheWrite: 500)

    let agent = Session(id: s.id, project: weather, model: sonnet, start: s.clock.addingTimeInterval(3),
                        agentId: "a9b1d3e5f7c20486e")
    agent.user("Write unit tests for ForecastCache: round trip, missing file, corrupt file.", after: 0)
    let (tests, testsId) = agent.writeFile("Tests/ForecastCacheTests.swift", """
        import XCTest
        @testable import Skyline

        final class ForecastCacheTests: XCTestCase {
            func testRoundTrip() async throws {
                let cache = ForecastCache(directory: FileManager.default.temporaryDirectory)
                try await cache.save(.sample)
                let loaded = await cache.load()
                XCTAssertEqual(loaded, .sample)
            }
        }
        """)
    agent.assistant([tests], after: 12, output: 520, cacheRead: 6_200, cacheWrite: 3_400)
    agent.toolResult(testsId, "File created successfully at: \(weather.cwd)/Tests/ForecastCacheTests.swift")
    agent.assistant([agent.text("Added `ForecastCacheTests` (round trip; missing and corrupt files return nil).")],
                    after: 8, output: 90, cacheRead: 7_000, cacheWrite: 400)
    agent.save(parent: s.id)
    s.absorb(agent)

    s.toolResult(agentCallId, "Tests written in Tests/ForecastCacheTests.swift.\n\nagentId: a9b1d3e5f7c20486e (use SendMessage with to: 'a9b1d3e5f7c20486e' to continue this agent)",
                 after: 45)
    s.assistant([s.text("The app now falls back to the last cached forecast when the network fails, and the cache has tests.")],
                output: 160, cacheRead: 26_000, cacheWrite: 300)
    s.title("Offline forecast cache")
    s.costState()
    s.save()
}

// 5. notes-api, four days ago: rate limiting.
do {
    let s = Session(id: "6f2c8b37-9a1d-4e58-b7c6-3d0a5e8f2c05", project: notes, model: sonnet, start: at(day: -4, "16:20"))
    s.user("Add per-token rate limiting to the API: 60 requests a minute, 429 with Retry-After.")
    let (mw, mwId) = s.writeFile("internal/api/ratelimit.go", """
        package api

        import (
        \t"net/http"
        \t"strconv"

        \t"golang.org/x/time/rate"
        )

        func RateLimit(limiters *LimiterSet) func(http.Handler) http.Handler {
        \treturn func(next http.Handler) http.Handler {
        \t\treturn http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        \t\t\tlimiter := limiters.For(tokenFrom(r))
        \t\t\tif !limiter.Allow() {
        \t\t\t\tw.Header().Set("Retry-After", strconv.Itoa(1))
        \t\t\t\thttp.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
        \t\t\t\treturn
        \t\t\t}
        \t\t\tnext.ServeHTTP(w, r)
        \t\t})
        \t}
        }
        """)
    s.assistant([s.text("A token-bucket middleware keyed by API token."), mw], output: 760, cacheRead: 11_200, cacheWrite: 6_900)
    s.toolResult(mwId, "File created successfully at: \(notes.cwd)/internal/api/ratelimit.go")
    let (route, routeId) = s.edit("cmd/server/main.go",
        old: "\thandler := api.Routes(store)",
        new: "\thandler := api.RateLimit(api.NewLimiterSet(rate.Every(time.Second), 60))(api.Routes(store))")
    s.assistant([route], output: 190, cacheRead: 14_800, cacheWrite: 700)
    s.toolResult(routeId, "The file \(notes.cwd)/cmd/server/main.go has been updated successfully.")
    s.assistant([s.text("Rate limiting is on: 60 requests per minute per token, `429` with `Retry-After` beyond that.")],
                output: 120, cacheRead: 15_300, cacheWrite: 200)
    s.title("Per-token rate limiting")
    s.costState()
    s.save()
}

// 6. marketing-site, a week ago: RSS feed.
do {
    let s = Session(id: "1a7e3d94-2c6f-4b81-9e0a-5f4b8c2d6e06", project: site, model: haiku, start: at(day: -7, "11:00"))
    s.user("Add an RSS feed for the blog.")
    let (feed, feedId) = s.writeFile("src/pages/rss.xml.ts", """
        import rss from "@astrojs/rss";
        import { getCollection } from "astro:content";

        export async function GET(context) {
          const posts = await getCollection("blog");
          return rss({
            title: "Northwind Blog",
            description: "Product news and guides",
            site: context.site,
            items: posts.map((post) => ({ ...post.data, link: `/blog/${post.slug}/` })),
          });
        }
        """)
    s.assistant([feed], output: 380, cacheRead: 6_100, cacheWrite: 4_200)
    s.toolResult(feedId, "File created successfully at: \(site.cwd)/src/pages/rss.xml.ts")
    s.assistant([s.text("The feed is served at `/rss.xml`.")], output: 60, cacheRead: 6_600, cacheWrite: 120)
    s.title("Blog RSS feed")
    s.costState()
    s.save()
}

// 7. notes-api, ten days ago: database upgrade.
do {
    let s = Session(id: "8c4b2f71-7d3e-4a96-8f1b-2e6c9d0a3b07", project: notes, model: opus, start: at(day: -10, "14:30"))
    s.user("Plan and run the move from Postgres 15 to 17 in docker-compose and CI.")
    let (compose, composeId) = s.edit("docker-compose.yml", old: "    image: postgres:15", new: "    image: postgres:17")
    s.assistant([s.text("Updating the local stack first."), compose], output: 240, cacheRead: 16_400, cacheWrite: 7_600)
    s.toolResult(composeId, "The file \(notes.cwd)/docker-compose.yml has been updated successfully.")
    let (ci, ciId) = s.edit(".github/workflows/ci.yml", old: "        image: postgres:15", new: "        image: postgres:17")
    s.assistant([ci], output: 130, cacheRead: 18_200, cacheWrite: 500)
    s.toolResult(ciId, "The file \(notes.cwd)/.github/workflows/ci.yml has been updated successfully.")
    let (test, testId) = s.tool("Bash", ["command": "docker compose up -d db && go test ./...", "description": "Run tests against Postgres 17"])
    s.assistant([test], output: 80, cacheRead: 18_900, cacheWrite: 300)
    s.toolResult(testId, "ok  \texample.com/notes-api/internal/store\t1.92s", after: 70)
    s.assistant([s.text("Postgres 17 runs locally and in CI; the store tests pass against it.")], output: 110, cacheRead: 19_300, cacheWrite: 200)
    s.title("Upgrade to Postgres 17")
    s.costState()
    s.save()
}

// 8. weather-app, thirteen days ago: CI.
do {
    let s = Session(id: "3e9a5c16-4b8d-4f27-a3e0-7c1d6b9f4e08", project: weather, model: sonnet, start: at(day: -13, "08:45"))
    s.user("Set up a GitHub Actions workflow that builds and tests the app on every pull request.")
    let (wf, wfId) = s.writeFile(".github/workflows/ci.yml", """
        name: CI
        on: [pull_request]
        jobs:
          test:
            runs-on: macos-15
            steps:
              - uses: actions/checkout@v4
              - run: xcodebuild test -scheme Skyline -destination 'platform=iOS Simulator,name=iPhone 17'
        """)
    s.assistant([wf], output: 300, cacheRead: 8_400, cacheWrite: 5_100)
    s.toolResult(wfId, "File created successfully at: \(weather.cwd)/.github/workflows/ci.yml")
    s.assistant([s.text("Every pull request now builds and runs the test suite on macOS.")], output: 70, cacheRead: 8_900, cacheWrite: 150)
    s.title("CI on pull requests")
    s.costState()
    s.save()
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Skills, agents, commands, plugin
// ─────────────────────────────────────────────────────────────────────────────

func skill(_ directory: URL, _ name: String, _ description: String, _ body: String) {
    write("---\nname: \(name)\ndescription: \(description)\n---\n\n# \(name)\n\n\(body)\n",
          to: directory.appendingPathComponent("skills/\(name)/SKILL.md"))
}

func flat(_ directory: URL, _ kind: String, _ name: String, _ description: String, _ body: String) {
    write("---\nname: \(name)\ndescription: \(description)\n---\n\n\(body)\n",
          to: directory.appendingPathComponent("\(kind)/\(name).md"))
}

// Global level.
skill(claudeDir, "swiftui-previews", "Generate SwiftUI previews covering every state of a view",
      "For each view, add `#Preview` blocks for the loading, empty, error and populated states, using the sample fixtures of the project.")
skill(claudeDir, "api-contract-check", "Compare an HTTP handler with its OpenAPI description",
      "Read the handler, list status codes and fields it returns, and report any mismatch with `openapi.yaml`.")
skill(claudeDir, "release-notes", "Draft user-facing release notes from merged pull requests",
      "Group changes by Added / Changed / Fixed, keep one line each, and leave internal refactors out.")
flat(claudeDir, "agents", "code-reviewer", "Reviews a diff for bugs, missing tests and unclear naming",
     "You review the current diff. Report correctness problems first, then missing tests, then naming. Quote the lines you mean.")
flat(claudeDir, "agents", "test-writer", "Writes focused unit tests for the code it is pointed at",
     "Write the smallest set of tests that pins the behaviour down: one happy path, the edges, one failure.")
flat(claudeDir, "agents", "doc-writer", "Updates README and inline docs after a change",
     "Read the diff and update the README sections and doc comments it makes stale. Nothing else.")
flat(claudeDir, "commands", "commit", "Write a conventional commit for the staged changes",
     "Look at `git diff --staged` and write a conventional commit message: type, short summary, body only if needed.")
flat(claudeDir, "commands", "standup", "Summarise yesterday's work for the daily stand-up",
     "List the sessions and commits since yesterday morning as three short bullets: done, doing, blocked.")

// Library (inactive, kept for later).
let library = claudeDir.appendingPathComponent("skillmanager/library", isDirectory: true)
skill(library, "legacy-migrations", "Port old SQL migration files to the current migration tool",
      "Convert each numbered `.sql` file into the current tool's format, keeping the order and the down steps.")
flat(library, "agents", "perf-auditor", "Profiles a slow endpoint and proposes fixes",
     "Measure first, then propose at most three changes ranked by expected gain.")
flat(library, "commands", "changelog", "Append the latest changes to CHANGELOG.md",
     "Read the commits since the last tag and add them under a new heading.")

// Project level.
let weatherClaude = homeDir.appendingPathComponent("DevApps/weather-app/_dot_claude", isDirectory: true)
skill(weatherClaude, "forecast-fixtures", "Create realistic forecast fixtures for previews and tests",
      "Generate `Forecast` values for sunny, rainy and stormy days, with 24 hourly points each.")
flat(weatherClaude, "commands", "snapshot", "Record UI snapshots for the main screens",
     "Run the snapshot test target and list the screens whose image changed.")
let notesClaude = homeDir.appendingPathComponent("DevApps/notes-api/_dot_claude", isDirectory: true)
flat(notesClaude, "agents", "db-migrator", "Writes and checks database migrations",
     "Write the migration, its rollback, and a test that runs both against a disposable database.")
flat(notesClaude, "commands", "ship", "Run the checks and open a pull request",
     "Run `go vet`, `go test ./...`, then open a pull request with a conventional title.")
let siteClaude = homeDir.appendingPathComponent("DevApps/marketing-site/_dot_claude", isDirectory: true)
skill(siteClaude, "seo-audit", "Check pages for titles, descriptions and broken links",
      "For every page: one `<title>`, a meta description under 160 characters, no broken internal link.")
flat(siteClaude, "commands", "lighthouse", "Run Lighthouse on the preview build",
     "Build, serve the preview, run Lighthouse on the home and pricing pages, and report the four scores.")

// Plugin.
let plugin = claudeDir.appendingPathComponent("plugins/cache/acme-labs/design-kit/1.2.0", isDirectory: true)
write(encode(["name": "design-kit", "version": "1.2.0", "description": "Design helpers: color contrast and design tokens"]) + "\n",
      to: plugin.appendingPathComponent("_dot_claude-plugin/plugin.json"))
skill(plugin, "color-contrast", "Check text and background colors against WCAG contrast ratios",
      "List every text style with its background and report the pairs below 4.5:1 (3:1 for large text).")
skill(plugin, "design-tokens", "Turn a palette and type scale into design tokens",
      "Emit tokens as JSON and as CSS custom properties, named by role rather than by value.")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - rtk history.db
// ─────────────────────────────────────────────────────────────────────────────

/// A small deterministic generator, so the database is the same on every run.
struct Seeded {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

let rtkDir = homeDir.appendingPathComponent("Library/Application Support/rtk", isDirectory: true)
try! fm.createDirectory(at: rtkDir, withIntermediateDirectories: true)
let database = rtkDir.appendingPathComponent("history.db")

var handle: OpaquePointer?
precondition(sqlite3_open(database.path, &handle) == SQLITE_OK)
func exec(_ sql: String) {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
        fatalError(error.map { String(cString: $0) } ?? "sqlite error")
    }
}
// rtk's schema. Plain rollback journal: one file, nothing to carry beside it.
exec("""
    PRAGMA journal_mode = DELETE;
    CREATE TABLE commands (
        id INTEGER PRIMARY KEY,
        timestamp TEXT NOT NULL,
        original_cmd TEXT NOT NULL,
        rtk_cmd TEXT NOT NULL,
        input_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        saved_tokens INTEGER NOT NULL,
        savings_pct REAL NOT NULL,
        exec_time_ms INTEGER DEFAULT 0,
        project_path TEXT DEFAULT ''
    );
    CREATE INDEX idx_timestamp ON commands(timestamp);
    """)

/// (command, rtk filter, typical input tokens, kept fraction in percent)
let commands: [(String, String, Int, Int)] = [
    ("git status", "rtk git status", 900, 25),
    ("git diff", "rtk git diff", 6_400, 22),
    ("git log -20", "rtk git log", 3_200, 30),
    ("cat Sources/Services/WeatherService.swift", "rtk read", 4_800, 45),
    ("grep -rn hourly Sources", "rtk grep", 2_600, 28),
    ("go test ./...", "rtk go test", 7_800, 8),
    ("npm run build", "rtk npm run", 5_400, 15),
    ("npx vitest run", "rtk vitest", 9_600, 4),
    ("ls -la", "rtk ls", 700, 40),
    ("xcodebuild build", "rtk xcodebuild", 14_000, 10),
]
let rtkProjects = [weather.cwd, notes.cwd, site.cwd]
var random = Seeded(state: 20_260_318)
var rows: [(Date, Int)] = []
let rowsPerDay = [14, 9, 3, 17, 11, 6, 12]  // day 0 back to day -6; a quiet day in between
for (offset, count) in rowsPerDay.enumerated() where count > 0 {
    // Day 0 stops before the anchor (17:30); the other days span the working day.
    let window = offset == 0 ? (8 * 60, 17 * 60 + 20) : (8 * 60, 19 * 60)
    for _ in 0..<count {
        let minute = window.0 + random.next(window.1 - window.0)
        let date = at(day: -offset, String(format: "%02d:%02d", minute / 60, minute % 60))
            .addingTimeInterval(Double(random.next(60)))
        rows.append((date, random.next(commands.count)))
    }
}
rows.sort { $0.0 < $1.0 }

let rtkFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter
}()

exec("BEGIN")
for (index, (date, pick)) in rows.enumerated() {
    let (command, filter, base, kept) = commands[pick]
    let input = base + random.next(base / 2 + 1)
    let output = max(1, input * (kept + random.next(6)) / 100)
    let saved = input - output
    let pct = Double(saved) * 100 / Double(input)
    let stamp = rtkFormatter.string(from: date) + String(format: ".%06d+00:00", random.next(1_000_000))
    let project = rtkProjects[random.next(rtkProjects.count)]
    exec("""
        INSERT INTO commands (id, timestamp, original_cmd, rtk_cmd, input_tokens, output_tokens,
          saved_tokens, savings_pct, exec_time_ms, project_path)
        VALUES (\(index + 1), '\(stamp)', '\(command)', '\(filter)', \(input), \(output), \(saved),
          \(String(format: "%.2f", pct)), \(40 + random.next(900)), '\(project)');
        """)
}
exec("COMMIT")
sqlite3_close(handle)

print("Demo data written to \(outputDir.path)")
