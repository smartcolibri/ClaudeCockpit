// SessionsKit — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Foundation
import CockpitShared

extension SessionExporter {

    /// The language an export is written in: its words come from that language's table in
    /// the module's String Catalog, its numbers and dates from ``AppFormat`` in that locale.
    struct Words {
        let locale: Locale
        let bundle: Bundle

        init(locale: Locale) {
            self.locale = locale
            self.bundle = Bundle.module.localization(for: locale)
        }

        func callAsFunction(_ key: String.LocalizationValue) -> String {
            String(localized: key, bundle: bundle, locale: locale)
        }

        /// `<html lang>`: the language the words were found in.
        var language: String {
            bundle.bundleURL.pathExtension == "lproj"
                ? bundle.bundleURL.deletingPathExtension().lastPathComponent : "en"
        }

        func date(_ date: Date) -> String { AppFormat.dateTime(date, locale: locale) }

        /// `Label: value` — French sets a space before the colon.
        func field(_ label: String, _ value: String) -> String { self("\(label): \(value)") }
    }

    static func header(_ session: SessionRef, words: Words) -> [(String, String)] {
        var fields: [(String, String)] = [
            (words("Project"), session.cwd.isEmpty ? session.projectDir : session.cwd),
            (words("Started"), words.date(session.firstTimestamp)),
            (words("Duration"), duration(session.duration, locale: words.locale)),
            (words("Turns"), words("\(session.userTurns) user · \(session.assistantTurns) assistant")),
            (words("Tools"), words("\(session.toolCalls) calls · \(session.toolErrors) failed")),
            (words("Tokens"), "\(session.totalTokens)"),
        ]
        if let branch = session.gitBranch { fields.append((words("Branch"), branch)) }
        if let version = session.claudeVersion { fields.append(("Claude Code", version)) }
        if let cost = session.costStateUSD {
            fields.append((words("Cost"), AppFormat.money(cost, digits: 4, locale: words.locale)))
        }
        if session.linesAdded > 0 || session.linesRemoved > 0 {
            fields.append((words("Lines"), "+\(session.linesAdded) / −\(session.linesRemoved)"))
        }
        return fields
    }

    /// `2 h 10 min` / `2h 10 min` — the export spells the minutes out, unlike the compact
    /// in-app duration, because the file is read on its own.
    static func duration(_ seconds: TimeInterval, locale: Locale) -> String {
        let french = locale.language.languageCode == .french
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours > 0 { return french ? "\(hours) h \(minutes) min" : "\(hours)h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return french ? "\(total) s" : "\(total)s"
    }

    /// The address to link to, or `nil` when it must be shown as plain text.
    ///
    /// `PRLink.url` is built by `URL(string:)` from a `pr-link` line, and a transcript is not
    /// a trusted document: `URL(string: "javascript:…")` parses happily. Escaping the markup
    /// does nothing about the scheme, so an exported file would carry a live hostile link.
    /// Only the two schemes a pull request can legitimately use are allowed through.
    static func linkable(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url.absoluteString
    }

    /// `2 attachments: api.go, store.go` — the count and the noun agree, and the files are
    /// named, which is the whole reason they are stored rather than counted.
    static func attachmentNote(_ names: [String], words: Words) -> String {
        guard !names.isEmpty else { return "" }
        let count = words("\(names.count) attachments")
        return words.field(count, names.joined(separator: ", "))
    }

    static func roleLabel(_ message: SessionMessage, words: Words) -> String {
        switch message.role {
        case .user: return words("User")
        case .assistant: return words("Assistant")
        case .system: return words("System")
        }
    }

    // MARK: - Markdown

    static func renderMarkdown(
        session: SessionRef, messages: [SessionMessage], subagents: [String: [SessionMessage]],
        words: Words
    ) -> String {
        var out = "# \(session.title)\n\n"
        for (label, value) in header(session, words: words) { out += "- \(words.field("**\(label)**", value))\n" }
        if !session.prLinks.isEmpty {
            out += "- \(words.field("**Pull requests**", ""))"
            out += session.prLinks.map { link -> String in
                guard let address = linkable(link.url) else { return "#\(link.number)" }
                return "[#\(link.number)](\(address))"
            }.joined(separator: ", ") + "\n"
        }
        out += "\n"

        for message in messages {
            out += markdownTurn(message, subagents: subagents, depth: 0, words: words)
        }
        return out
    }

    private static func markdownTurn(
        _ message: SessionMessage, subagents: [String: [SessionMessage]], depth: Int, words: Words
    ) -> String {
        let hashes = String(repeating: "#", count: min(6, depth + 2))
        var out = "\(hashes) \(roleLabel(message, words: words)) — \(words.date(message.timestamp))"
        if let model = message.model { out += " · \(model)" }
        out += "\n\n"

        if message.isCompactBoundary { out += "> \(words("Context compacted"))\n\n" }
        if message.isApiError { out += "> ⚠︎ \(words("API error"))\n\n" }
        if message.isAborted { out += "> ⚠︎ \(words("Interrupted turn"))\n\n" }

        for block in message.blocks {
            switch block.kind {
            case .text:
                out += block.text + "\n\n"
            case .thinking:
                out += "<details><summary>\(words("Thinking"))</summary>\n\n```\n\(block.text)\n```\n\n</details>\n\n"
            case .toolUse:
                out += "**\(words("Tool: \(block.toolName ?? "?")"))**\n\n```json\n\(block.text)\n```\n\n"
                if let agentId = block.subagentId, let transcript = subagents[agentId] {
                    out += "<details><summary>\(words("Sub-agent \(agentId)"))</summary>\n\n"
                    for sub in transcript { out += markdownTurn(sub, subagents: [:], depth: depth + 1, words: words) }
                    out += "</details>\n\n"
                }
            case .toolResult:
                let label = block.isError ? words("Result (error)") : words("Result")
                out += "<details><summary>\(label)</summary>\n\n```\n\(block.text)\n```\n\n</details>\n\n"
            case .image:
                out += "_[image \(block.imageMediaType ?? "")]_\n\n"
            }
        }
        if !message.attachments.isEmpty {
            out += "_\(attachmentNote(message.attachments, words: words))_\n\n"
        }
        return out
    }

    // MARK: - HTML

    /// Self-contained: inline stylesheet, no script, no external asset. Everything that came
    /// out of a transcript is escaped before it reaches the page.
    static func renderHTML(
        session: SessionRef, messages: [SessionMessage], subagents: [String: [SessionMessage]],
        words: Words
    ) -> String {
        var out = """
            <!DOCTYPE html>
            <html lang="\(words.language)"><head><meta charset="utf-8">
            <title>\(escape(session.title))</title>
            <style>
            :root { color-scheme: light dark; }
            body { font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                   margin: 0 auto; padding: 24px; max-width: 900px; }
            h1 { font-size: 22px; margin: 0 0 12px; }
            dl.meta { display: grid; grid-template-columns: max-content 1fr; gap: 2px 12px;
                      margin: 0 0 28px; font-size: 13px; }
            dt { font-weight: 600; opacity: .7; }
            dd { margin: 0; }
            section.turn { border-top: 1px solid rgba(128,128,128,.28); padding: 14px 0; }
            section.turn > h2 { font-size: 13px; margin: 0 0 8px; text-transform: uppercase;
                                letter-spacing: .04em; opacity: .65; }
            section.user > h2 { color: #2f6fb3; }
            section.assistant > h2 { color: #8a5a00; }
            p.flag { margin: 0 0 10px; padding: 6px 10px; border-radius: 6px;
                     background: rgba(200,60,60,.14); font-size: 13px; }
            p.compact { background: rgba(120,120,120,.16); }
            pre { background: rgba(128,128,128,.12); padding: 10px 12px; border-radius: 6px;
                  overflow-x: auto; font-size: 12.5px; }
            details { margin: 8px 0; }
            summary { cursor: pointer; font-size: 13px; opacity: .8; }
            details.error > summary { color: #c0392b; }
            div.text { white-space: pre-wrap; }
            div.sub { border-left: 3px solid rgba(128,128,128,.4); padding-left: 14px; margin-left: 2px; }
            </style></head><body>
            <h1>\(escape(session.title))</h1>
            <dl class="meta">
            """
        for (label, value) in header(session, words: words) {
            out += "<dt>\(escape(label))</dt><dd>\(escape(value))</dd>"
        }
        for link in session.prLinks {
            out += "<dt>PR</dt><dd>"
            if let address = linkable(link.url) {
                out += "<a href=\"\(escape(address))\">#\(link.number)</a>"
            } else {
                out += "#\(link.number) <em>(\(escape(link.url.absoluteString)))</em>"
            }
            out += "</dd>"
        }
        out += "</dl>\n"

        for message in messages { out += htmlTurn(message, subagents: subagents, words: words) }
        out += "</body></html>\n"
        return out
    }

    private static func htmlTurn(
        _ message: SessionMessage, subagents: [String: [SessionMessage]], words: Words
    ) -> String {
        var out = "<section class=\"turn \(message.role.rawValue)\"><h2>\(roleLabel(message, words: words)) — "
        out += "\(escape(words.date(message.timestamp)))"
        if let model = message.model { out += " · \(escape(model))" }
        out += "</h2>\n"

        if message.isCompactBoundary { out += "<p class=\"flag compact\">\(words("Context compacted"))</p>" }
        if message.isApiError { out += "<p class=\"flag\">\(words("API error"))</p>" }
        if message.isAborted { out += "<p class=\"flag\">\(words("Interrupted turn"))</p>" }

        for block in message.blocks {
            switch block.kind {
            case .text:
                out += "<div class=\"text\">\(escape(block.text))</div>"
            case .thinking:
                out += "<details><summary>\(words("Thinking"))</summary><pre>\(escape(block.text))</pre></details>"
            case .toolUse:
                out += "<details><summary>\(escape(words("Tool: \(block.toolName ?? "?")")))</summary><pre>\(escape(block.text))</pre>"
                if let agentId = block.subagentId, let transcript = subagents[agentId] {
                    out += "<div class=\"sub\"><p><strong>\(escape(words("Sub-agent \(agentId)")))</strong></p>"
                    for sub in transcript { out += htmlTurn(sub, subagents: [:], words: words) }
                    out += "</div>"
                }
                out += "</details>"
            case .toolResult:
                let label = block.isError ? words("Result (error)") : words("Result")
                out += "<details class=\"\(block.isError ? "error" : "")\">"
                out += "<summary>\(label)</summary><pre>\(escape(block.text))</pre></details>"
            case .image:
                out += "<p><em>[image \(escape(block.imageMediaType ?? ""))]</em></p>"
            }
        }
        if !message.attachments.isEmpty {
            out += "<p><em>\(escape(attachmentNote(message.attachments, words: words)))</em></p>"
        }
        return out + "</section>\n"
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
