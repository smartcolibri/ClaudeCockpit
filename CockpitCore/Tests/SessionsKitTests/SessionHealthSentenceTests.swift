import XCTest
import CockpitShared
@testable import SessionsKit

/// The health popover's sentences, pinned per language: each count agrees with its noun and
/// the rate is written in the same locale.
final class SessionHealthSentenceTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let fr = Locale(identifier: "fr_FR")

    func testSentencesInEnglish() {
        XCTAssertEqual(HealthEvidence.toolErrors(count: 14, calls: 325, rate: 14.0 / 325).sentence(locale: en),
                       "14 tool errors out of 325 calls, or 4.3%.")
        XCTAssertEqual(HealthEvidence.toolErrors(count: 1, calls: 1, rate: 1).sentence(locale: en),
                       "1 tool error out of 1 call, or 100.0%.")
        XCTAssertEqual(HealthEvidence.apiErrors(count: 2, turns: 1_234, rate: 2.0 / 1_234).sentence(locale: en),
                       "2 API errors out of 1,234 assistant turns, or 0.2%.")
        XCTAssertEqual(HealthEvidence.abortedTurns(count: 1, turns: 8).sentence(locale: en),
                       "1 interrupted turn out of 8 assistant turns.")
        XCTAssertEqual(HealthEvidence.repeatedFailure(times: 3).sentence(locale: en),
                       "The same tool call failed 3 times in a row.")
        XCTAssertEqual(HealthEvidence.endedOnError.sentence(locale: en), "The session ends on an error.")
        XCTAssertEqual(HealthEvidence.noErrors.sentence(locale: en), "No errors detected.")
    }

    func testSentencesInFrench() {
        let rate = AppFormat.percent(14.0 / 325, digits: 1, locale: fr)
        XCTAssertEqual(HealthEvidence.toolErrors(count: 14, calls: 325, rate: 14.0 / 325).sentence(locale: fr),
                       "14 erreurs d'outil sur 325 appels, soit \(rate).")
        XCTAssertEqual(HealthEvidence.abortedTurns(count: 0, turns: 1).sentence(locale: fr),
                       "0 tour interrompu sur 1 tour assistant.")
        XCTAssertEqual(HealthEvidence.apiErrors(count: 2, turns: 1_234, rate: 2.0 / 1_234).sentence(locale: fr),
                       "2 erreurs d'API sur \(AppFormat.integer(1_234, locale: fr)) tours assistant, soit \(AppFormat.percent(2.0 / 1_234, digits: 1, locale: fr)).")
        XCTAssertEqual(HealthEvidence.endedOnError.sentence(locale: fr), "La session se termine sur une erreur.")
        XCTAssertEqual(HealthEvidence.noErrors.sentence(locale: fr), "Aucune erreur détectée.")
    }
}
