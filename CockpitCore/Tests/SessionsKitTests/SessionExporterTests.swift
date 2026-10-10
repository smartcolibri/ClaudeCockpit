import XCTest
import CockpitShared
@testable import SessionsKit

final class SessionExporterTests: XCTestCase {

    private var fixture: TranscriptFixture!
    private var session: SessionRef!
    private var messages: [SessionMessage]!
    private var subagents: [String: [SessionMessage]]!

    override func setUp() async throws {
        fixture = try TranscriptFixture()
        try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()
        let found = try await service.session(id: Line.session)
        session = try XCTUnwrap(found)
        messages = try await service.messages(sessionId: Line.session, limit: 500)
        let transcript = try await service.subagentMessages(agentId: Line.agentId)
        subagents = [Line.agentId: transcript]
    }

    override func tearDown() {
        fixture = nil
    }

    private let fr = Locale(identifier: "fr_FR")
    private let en = Locale(identifier: "en_US")

    func testMarkdownCarriesTheHeaderTurnsAndToolCallsInFrench() {
        let markdown = SessionExporter.markdown(
            session: session, messages: messages, subagents: subagents, locale: fr)

        XCTAssertTrue(markdown.hasPrefix("# Correction du parseur"))
        XCTAssertTrue(markdown.contains("**Projet** : /Users/test/DevApps/Demo"))
        XCTAssertTrue(markdown.contains("**Branche** : feat/sessions-viewer"))
        XCTAssertTrue(markdown.contains("[#42](https://github.com/test/demo/pull/42)"))
        XCTAssertTrue(markdown.contains("## Utilisateur"))
        XCTAssertTrue(markdown.contains("## Assistant"))
        XCTAssertTrue(markdown.contains("**Outil : Bash**"))
        XCTAssertTrue(markdown.contains("<summary>Réflexion</summary>"))
        XCTAssertTrue(markdown.contains("<summary>Résultat (erreur)</summary>"))
        XCTAssertTrue(markdown.contains("> Contexte compacté"))
        XCTAssertTrue(markdown.contains("> ⚠︎ Erreur d'API"))
        // The sub-agent transcript is inlined under the call that spawned it.
        XCTAssertTrue(markdown.contains("Sous-agent \(Line.agentId)"))
        XCTAssertTrue(markdown.contains("tout est vert"))
    }

    /// The export follows the app's language, words and numbers alike.
    func testMarkdownIsWrittenInEnglish() {
        let markdown = SessionExporter.markdown(
            session: session, messages: messages, subagents: subagents, locale: en)

        XCTAssertTrue(markdown.contains("**Project**: /Users/test/DevApps/Demo"))
        XCTAssertTrue(markdown.contains("**Branch**: feat/sessions-viewer"))
        XCTAssertTrue(markdown.contains("**Pull requests**: [#42]"))
        XCTAssertTrue(markdown.contains("## User"))
        XCTAssertTrue(markdown.contains("**Tool: Bash**"))
        XCTAssertTrue(markdown.contains("<summary>Thinking</summary>"))
        XCTAssertTrue(markdown.contains("<summary>Result (error)</summary>"))
        XCTAssertTrue(markdown.contains("> Context compacted"))
        XCTAssertTrue(markdown.contains("> ⚠︎ API error"))
        XCTAssertTrue(markdown.contains("Sub-agent \(Line.agentId)"))
        XCTAssertFalse(markdown.contains("Utilisateur"))
        XCTAssertFalse(markdown.contains("Réflexion"))
    }

    func testHTMLIsSelfContainedAndEscaped() {
        let html = SessionExporter.html(
            session: session, messages: messages, subagents: subagents, locale: fr)

        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<html lang=\"fr\">"))
        XCTAssertTrue(html.contains("<style>"), "la feuille de style doit être inline")
        XCTAssertFalse(html.contains("<script"), "aucun script dans un export autonome")
        XCTAssertFalse(html.contains("src=\"http"), "aucune ressource externe")
        XCTAssertTrue(html.contains("Correction du parseur"))
        XCTAssertTrue(html.contains("<summary>Outil : Bash</summary>"))
        XCTAssertTrue(html.contains("Contexte compacté"))
        XCTAssertTrue(html.hasSuffix("</body></html>\n"))

        let english = SessionExporter.html(
            session: session, messages: messages, subagents: subagents, locale: en)
        XCTAssertTrue(english.contains("<html lang=\"en\">"))
        XCTAssertTrue(english.contains("<summary>Tool: Bash</summary>"))
        XCTAssertTrue(english.contains("Context compacted"))
    }

    /// Transcripts are full of angle brackets and quotes; none of them may become markup.
    func testHTMLEscapesTranscriptContent() {
        let hostile = SessionMessage(
            id: "x", sessionId: "s", sequence: 0, timestamp: TestClock.start, role: .user,
            blocks: [ContentBlock(
                id: "x#0", index: 0, kind: .text,
                text: "<script>alert(\"xss\")</script> & 'quote'")])
        let html = SessionExporter.html(session: session, messages: [hostile])

        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
        XCTAssertTrue(html.contains("&#39;quote&#39;"))
    }

    func testHeaderDatesDurationAndCostFollowTheLocale() {
        let french = Dictionary(uniqueKeysWithValues: SessionExporter.header(
            session, words: SessionExporter.Words(locale: fr)))
        let english = Dictionary(uniqueKeysWithValues: SessionExporter.header(
            session, words: SessionExporter.Words(locale: en)))
        XCTAssertEqual(french["Début"], AppFormat.dateTime(session.firstTimestamp, locale: fr))
        XCTAssertEqual(english["Started"], AppFormat.dateTime(session.firstTimestamp, locale: en))
        XCTAssertEqual(french["Durée"], SessionExporter.duration(session.duration, locale: fr))
        XCTAssertEqual(english["Duration"], SessionExporter.duration(session.duration, locale: en))
        XCTAssertEqual(french["Tours"],
                       "\(session.userTurns) utilisateur · \(session.assistantTurns) assistant")
        XCTAssertEqual(english["Turns"],
                       "\(session.userTurns) user · \(session.assistantTurns) assistant")
    }

    /// The export's duration keeps the minutes spelled out, as it always read in French.
    func testDurationSpellsMinutesOut() {
        XCTAssertEqual(SessionExporter.duration(45, locale: fr), "45 s")
        XCTAssertEqual(SessionExporter.duration(600, locale: fr), "10 min")
        XCTAssertEqual(SessionExporter.duration(7_800, locale: fr), "2 h 10 min")
        XCTAssertEqual(SessionExporter.duration(-5, locale: fr), "0 s")
        XCTAssertEqual(SessionExporter.duration(45, locale: en), "45s")
        XCTAssertEqual(SessionExporter.duration(7_800, locale: en), "2h 10 min")
    }

    /// A capped body keeps its stored marker in the index; the export words it in its language.
    func testTruncatedBodyIsWordedInTheExportLanguage() {
        let body = "début" + ContentBlock.truncationMarker
        XCTAssertEqual(SessionExporter.Words(locale: fr).body(body), "début\n… [tronqué]")
        XCTAssertEqual(SessionExporter.Words(locale: en).body(body), "début\n… [truncated]")
        XCTAssertEqual(SessionExporter.Words(locale: en).body("intact"), "intact")
        XCTAssertEqual(ContentBlock.displayable(body, truncated: "x"), "début\n… [x]")
    }

    /// Each count agrees with its own noun; French treats 0 and 1 as singular.
    func testToolCountsAgreeWithTheirNoun() {
        let french = SessionExporter.Words(locale: fr), english = SessionExporter.Words(locale: en)
        XCTAssertEqual(english("\(1) calls"), "1 call")
        XCTAssertEqual(english("\(0) calls"), "0 calls")
        XCTAssertEqual(english("\(1_234) calls"), "1,234 calls")
        XCTAssertEqual(french("\(0) calls"), "0 appel")
        XCTAssertEqual(french("\(2) calls"), "2 appels")
        XCTAssertEqual(french("\(1_234) calls"), "\(AppFormat.integer(1_234, locale: fr)) appels")
        XCTAssertEqual(english("\(3) failed"), "3 failed")
        XCTAssertEqual(french("\(3) failed"), "3 en erreur")
        let fields = Dictionary(uniqueKeysWithValues: SessionExporter.header(session, words: english))
        XCTAssertEqual(fields["Tools"], "\(english("\(session.toolCalls) calls")) · \(english("\(session.toolErrors) failed"))")
    }

    func testExportsAnEmptySessionWithoutCrashing() {
        XCTAssertFalse(SessionExporter.markdown(session: session, messages: []).isEmpty)
        XCTAssertFalse(SessionExporter.html(session: session, messages: []).isEmpty)
    }
}
