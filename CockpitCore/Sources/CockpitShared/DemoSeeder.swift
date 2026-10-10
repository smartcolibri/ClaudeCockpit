import Foundation
import SQLite3

/// Installs the bundled sample data the demo mode reads, so the app can be explored with no
/// Claude Code archive and no folder grant (App Review has neither).
///
/// The bundle (`Resources/Demo`, written by `Scripts/make-demo-data.swift`) holds a
/// `manifest.json` naming the instant its timestamps were written against and the fictional
/// home its paths start with, and a `home/` tree. Directories that must start with a dot are stored as `_dot_<name>`, so neither the
/// app bundle copy nor a Finder view can hide them.
///
/// Seeding always starts from scratch: the previous copy and the demo app data (the session
/// index) are dropped, the tree is copied, then every timestamp is moved so the sample looks
/// recent — a session written on the anchor's day lies between the start of today and `now`,
/// older ones keep their day offset and time of day — and every path under the fictional home
/// is pointed at the copy, so the sample's projects are the folders the app scans.
public enum DemoSeeder {

    public enum SeedError: Error, LocalizedError {
        case missingManifest(URL)
        case sqlite(String)

        public var errorDescription: String? {
            switch self {
            case .missingManifest(let url): "Données d'exemple introuvables (\(url.path))."
            case .sqlite(let message): "Base RTK d'exemple illisible : \(message)"
            }
        }
    }

    /// Prefix standing for a leading dot in the bundled tree.
    static let dotPrefix = "_dot_"

    /// Where the app keeps the demo: next to its own data, inside the container when sandboxed.
    public static var defaultRoot: URL {
        ClaudePaths.processAppSupportDir.appendingPathComponent("demo", isDirectory: true)
    }

    /// Replaces whatever is at `root` with a fresh copy of the bundle at `source`, retimed
    /// against `now`. On failure nothing is left behind.
    public static func seed(
        from source: URL, into root: URL, now: Date = Date(), calendar: Calendar = .current
    ) throws {
        let manifest = try readManifest(source)
        try remove(root: root)
        do {
            let paths = ClaudePaths.demo(root: root)
            let homes = manifest.home.map { (sample: $0, copy: paths.home.path) }
            try copyTree(from: source.appendingPathComponent("home", isDirectory: true), to: paths.home)
            try FileManager.default.createDirectory(at: paths.appSupportDir, withIntermediateDirectories: true)
            try rewriteTranscripts(in: paths.projectsDir, anchor: manifest.anchor, now: now, calendar: calendar, homes: homes)
            for database in paths.rtkDatabaseCandidates where FileManager.default.fileExists(atPath: database.path) {
                try rewriteRTK(database, anchor: manifest.anchor, now: now, homes: homes)
            }
        } catch {
            try? remove(root: root)
            throw error
        }
    }

    /// Deletes the demo copy and its app data. Nothing there is not an error.
    public static func remove(root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    // MARK: - Time

    /// Where an instant written against `anchor` lands against `now`.
    ///
    /// Days are counted in UTC on the anchor's side (that is how the generator writes them)
    /// and in `calendar` on `now`'s side. An instant on the anchor's day keeps its distance to
    /// the anchor, squeezed when the current day is shorter so far than that distance — it
    /// always lands between the start of today and `now`. An older one keeps its day offset
    /// and its time of day, held inside its day when that day is short (a DST change).
    static func retime(_ date: Date, anchor: Date, now: Date, calendar: Calendar) -> Date {
        let anchorDay = utc.startOfDay(for: anchor)
        let dayOffset = utc.dateComponents([.day], from: anchorDay, to: utc.startOfDay(for: date)).day ?? 0
        let today = calendar.startOfDay(for: now)
        if dayOffset >= 0 {
            let before = max(0, anchor.timeIntervalSince(date))
            let anchorElapsed = anchor.timeIntervalSince(anchorDay)
            let elapsed = now.timeIntervalSince(today)
            let scale = anchorElapsed > 0 ? min(1, elapsed / anchorElapsed) : 1
            return now.addingTimeInterval(-before * scale)
        }
        let timeOfDay = date.timeIntervalSince(utc.startOfDay(for: date))
        let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? today
        return min(day.addingTimeInterval(timeOfDay), nextDay.addingTimeInterval(-1))
    }

    /// How a whole session moves: by one delta, so its lines keep their order and spacing,
    /// chosen to bring its last line where `retime` puts it. A session of the anchor's day too
    /// long for the day so far (early in the morning) is squeezed between the start of today
    /// and that point instead, so none of it falls on yesterday.
    static func sessionMapping(
        first: Date, last: Date, anchor: Date, now: Date, calendar: Calendar
    ) -> (Date) -> Date {
        let end = retime(last, anchor: anchor, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let span = last.timeIntervalSince(first)
        if end >= today, span > 0, end.addingTimeInterval(-span) < today {
            let scale = end.timeIntervalSince(today) / span
            return { today.addingTimeInterval($0.timeIntervalSince(first) * scale) }
        }
        let delta = end.timeIntervalSince(last)
        return { $0.addingTimeInterval(delta) }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func readManifest(_ source: URL) throws -> (anchor: Date, home: String?) {
        let manifest = source.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["anchor"] as? String,
              let anchor = ISO8601DateFormatter().date(from: raw)
        else { throw SeedError.missingManifest(manifest) }
        return (anchor, object["home"] as? String)
    }

    /// `sample` (a whole path component) replaced by `copy`, for a path stored as is.
    private static func rehome(_ path: String, _ homes: (sample: String, copy: String)?) -> String {
        guard let homes, path == homes.sample || path.hasPrefix(homes.sample + "/") else { return path }
        return homes.copy + path.dropFirst(homes.sample.count)
    }

    // MARK: - Copy

    private static func copyTree(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let base = source.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = manager.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let item as URL in walker {
            let full = item.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { continue }
            let relative = full.dropFirst(base.count + 1).split(separator: "/").map { component in
                component.hasPrefix(dotPrefix) ? "." + component.dropFirst(dotPrefix.count) : String(component)
            }
            let target = relative.reduce(destination) { $0.appendingPathComponent($1) }
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: item, to: target)
            }
        }
    }

    // MARK: - Transcripts

    private static let timestampField = try! NSRegularExpression(pattern: #""timestamp":"([^"]+)""#)
    private static let startTimeField = try! NSRegularExpression(pattern: #""startTime":(\d+)"#)

    /// Moves every `timestamp` (and `cost-state`'s `startTime`) of a session with
    /// `sessionMapping`; a sub-agent transcript moves with its parent. Paths under the sample
    /// home, wherever they appear in a line, are pointed at the copy.
    private static func rewriteTranscripts(
        in projects: URL, anchor: Date, now: Date, calendar: Calendar, homes: (sample: String, copy: String)?
    ) throws {
        var files: [String: [URL]] = [:]
        let base = projects.standardizedFileURL.resolvingSymlinksInPath().path
        let walker = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: nil)
        while let item = walker?.nextObject() as? URL {
            guard item.pathExtension == "jsonl" else { continue }
            // `<project>/<session>.jsonl` or `<project>/<session>/subagents/agent-….jsonl`.
            let parts = item.standardizedFileURL.resolvingSymlinksInPath().path
                .dropFirst(base.count + 1).split(separator: "/")
            guard parts.count >= 2 else { continue }
            let session = parts.count == 2 ? String(parts[1].dropLast(".jsonl".count)) : String(parts[1])
            files["\(parts[0])/\(session)", default: []].append(item)
        }
        let samplePath = homes.map {
            try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: $0.sample) + #"(?=[/"])"#)
        }
        // The copy's path goes into JSON strings: a quote or backslash in it must be escaped.
        let copyPath = homes.map {
            NSRegularExpression.escapedTemplate(for: $0.copy
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\""))
        }
        for group in files.values {
            let texts = try group.map { try String(contentsOf: $0, encoding: .utf8) }
            let dates = texts.flatMap { stamps(in: $0) }
            guard let first = dates.min(), let last = dates.max() else { continue }
            let move = sessionMapping(first: first, last: last, anchor: anchor, now: now, calendar: calendar)
            for (url, text) in zip(group, texts) {
                var result = shift(text, with: move)
                if let samplePath, let copyPath {
                    result = samplePath.stringByReplacingMatches(
                        in: result, range: NSRange(result.startIndex..., in: result), withTemplate: copyPath)
                }
                try result.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func stamps(in text: String) -> [Date] {
        let range = NSRange(text.startIndex..., in: text)
        return timestampField.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { parseISO(String(text[$0])) }
        }
    }

    private static func shift(_ text: String, with move: (Date) -> Date) -> String {
        var result = replace(timestampField, in: text) { raw in
            parseISO(raw).map { "\"timestamp\":\"\(formatISO(move($0)))\"" }
        }
        result = replace(startTimeField, in: result) { raw in
            Double(raw).map {
                let moved = move(Date(timeIntervalSince1970: $0 / 1000))
                return "\"startTime\":\(Int64((moved.timeIntervalSince1970 * 1000).rounded()))"
            }
        }
        return result
    }

    /// Replaces each match whose first group `transform` accepts; the others stay as they are.
    private static func replace(
        _ pattern: NSRegularExpression, in text: String, _ transform: (String) -> String?
    ) -> String {
        var result = ""
        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let group = Range(match.range(at: 1), in: text),
                  let replacement = transform(String(text[group])) else { continue }
            result += text[cursor..<whole.lowerBound] + replacement
            cursor = whole.upperBound
        }
        return result + text[cursor...]
    }

    private static func parseISO(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func formatISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - RTK

    /// Rewrites the `timestamp` column of rtk's `commands` table, row by row, in rtk's own
    /// format (microseconds, explicit UTC offset), and `project_path` when the table has it.
    /// rtk buckets its days in UTC, so that is the calendar used here whatever the user's
    /// time zone.
    private static func rewriteRTK(
        _ database: URL, anchor: Date, now: Date, homes: (sample: String, copy: String)?
    ) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw SeedError.sqlite("ouverture impossible")
        }
        defer { sqlite3_close(handle) }
        func check(_ code: Int32) throws {
            guard code == SQLITE_OK || code == SQLITE_DONE else {
                throw SeedError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
        }

        var columns: Set<String> = []
        var info: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, "PRAGMA table_info(commands)", -1, &info, nil))
        while sqlite3_step(info) == SQLITE_ROW { columns.insert(String(cString: sqlite3_column_text(info, 1))) }
        sqlite3_finalize(info)
        let project = columns.contains("project_path") ? "project_path" : "''"

        var rows: [(id: Int64, timestamp: String, project: String)] = []
        var select: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, "SELECT id, timestamp, \(project) FROM commands", -1, &select, nil))
        while sqlite3_step(select) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(select, 0),
                         String(cString: sqlite3_column_text(select, 1)),
                         sqlite3_column_text(select, 2).map { String(cString: $0) } ?? ""))
        }
        sqlite3_finalize(select)

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let sql = project == "project_path"
            ? "UPDATE commands SET timestamp = ?, project_path = ? WHERE id = ?"
            : "UPDATE commands SET timestamp = ? WHERE id = ?"
        var update: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &update, nil))
        defer { sqlite3_finalize(update) }
        try check(sqlite3_exec(handle, "BEGIN", nil, nil, nil))
        for row in rows {
            guard let date = parseRTK(row.timestamp) else { continue }
            let moved = formatRTK(retime(date, anchor: anchor, now: now, calendar: utc))
            sqlite3_reset(update)
            sqlite3_bind_text(update, 1, moved, -1, transient)
            if project == "project_path" {
                sqlite3_bind_text(update, 2, rehome(row.project, homes), -1, transient)
                sqlite3_bind_int64(update, 3, row.id)
            } else {
                sqlite3_bind_int64(update, 2, row.id)
            }
            try check(sqlite3_step(update))
        }
        try check(sqlite3_exec(handle, "COMMIT", nil, nil, nil))
    }

    /// `2026-03-18T17:20:00.123456+00:00` → a date (the fraction kept to the microsecond).
    private static func parseRTK(_ raw: String) -> Date? {
        guard raw.count >= 19, let whole = ISO8601DateFormatter().date(from: String(raw.prefix(19)) + "Z") else { return nil }
        let rest = raw.dropFirst(19)
        guard rest.hasPrefix(".") else { return whole }
        let digits = rest.dropFirst().prefix { $0.isNumber }
        return whole.addingTimeInterval((Double("0." + digits) ?? 0))
    }

    private static func formatRTK(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        let micros = Int(((date.timeIntervalSince1970 - seconds) * 1_000_000).rounded(.down))
        let whole = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds)).dropLast()
        return String(format: "%@.%06d+00:00", String(whole), micros)
    }
}
