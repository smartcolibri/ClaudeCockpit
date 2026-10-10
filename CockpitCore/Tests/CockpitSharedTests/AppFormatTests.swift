import XCTest
@testable import CockpitShared

/// Every assertion pins its locale: the default follows the app's language, which a test
/// must not depend on. Expected strings that carry a locale's spacing
/// are built from the formatter rather than typed out, so the test checks the shape, not
/// whether the separator is a no-break space this year.
final class AppFormatTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let fr = Locale(identifier: "fr_FR")
    private let now = ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z")!

    func testTokensInEnglish() {
        XCTAssertEqual(AppFormat.tokens(999, locale: en), "999")
        XCTAssertEqual(AppFormat.tokens(9_999, locale: en), "9,999")
        XCTAssertEqual(AppFormat.tokens(12_345, locale: en), "12.3K")
        XCTAssertEqual(AppFormat.tokens(250_000, locale: en), "250K")
        XCTAssertEqual(AppFormat.tokens(1_260_000, locale: en), "1.3M")
        XCTAssertEqual(AppFormat.tokens(2_500_000_000, locale: en), "2.5B")
    }

    func testTokensInFrench() {
        XCTAssertEqual(AppFormat.tokens(999, locale: fr), "999")
        XCTAssertEqual(AppFormat.tokens(12_345, locale: fr), "12,3 k")
        XCTAssertEqual(AppFormat.tokens(250_000, locale: fr), "250 k")
        XCTAssertEqual(AppFormat.tokens(1_260_000, locale: fr), "1,3 M")
        XCTAssertEqual(AppFormat.tokens(2_500_000_000, locale: fr), "2,5 G")
    }

    func testDurationInEnglish() {
        XCTAssertEqual(AppFormat.duration(30, locale: en), "30s")
        XCTAssertEqual(AppFormat.duration(125, locale: en), "2 min")
        XCTAssertEqual(AppFormat.duration(7_500, locale: en), "2h 05m")
        XCTAssertEqual(AppFormat.duration(3 * 86_400 + 3_600, locale: en), "3d 1h")
    }

    func testDurationInFrench() {
        XCTAssertEqual(AppFormat.duration(30, locale: fr), "30 s")
        XCTAssertEqual(AppFormat.duration(125, locale: fr), "2 min")
        XCTAssertEqual(AppFormat.duration(7_500, locale: fr), "2 h 05")
        XCTAssertEqual(AppFormat.duration(3 * 86_400 + 3_600, locale: fr), "3 j 1 h")
    }

    func testPercent() {
        XCTAssertEqual(AppFormat.percent(0.42, locale: en), "42%")
        XCTAssertEqual(AppFormat.percent(42.5, fraction: false, digits: 1, locale: en), "42.5%")
        // French puts a no-break space before the sign.
        XCTAssertEqual(AppFormat.percent(0.42, locale: fr), "42\u{A0}%")
        XCTAssertEqual(AppFormat.percent(42.5, fraction: false, digits: 1, locale: fr), "42,5\u{A0}%")
    }

    /// The user's decision: the currency follows the app language, "$0.36" against "0,36 $US".
    func testMoney() {
        XCTAssertEqual(AppFormat.money(0.36, locale: en), "$0.36")
        XCTAssertEqual(AppFormat.money(0.36, locale: fr), "0,36\u{A0}$US")
        XCTAssertEqual(AppFormat.money(12.5, currency: "EUR", locale: en), "€12.50")
        XCTAssertEqual(AppFormat.money(12.5, currency: "EUR", locale: fr), "12,50\u{A0}€")
    }

    func testIntegerGroupsByLocale() {
        XCTAssertEqual(AppFormat.integer(1_234_567, locale: en), "1,234,567")
        XCTAssertEqual(AppFormat.integer(1_234_567, locale: fr), "1\u{202F}234\u{202F}567")
    }

    func testDates() {
        XCTAssertEqual(AppFormat.shortDate(now, locale: en), "Oct 10")
        XCTAssertEqual(AppFormat.shortDate(now, locale: fr), "10 oct.")
        XCTAssertEqual(AppFormat.weekday(now, locale: en), "Sat 10")
        XCTAssertEqual(AppFormat.weekday(now, locale: fr), "sam. 10")
    }

    /// 14:05:09 on Oct 10, 2026 in the machine's time zone, which the formatters use.
    private var afternoon: Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 10, day: 10, hour: 14, minute: 5, second: 9))!
    }

    func testTimesInEnglish() {
        XCTAssertEqual(AppFormat.time(afternoon, locale: en), "2:05\u{202F}PM")
        XCTAssertEqual(AppFormat.timeWithSeconds(afternoon, locale: en), "2:05:09\u{202F}PM")
        XCTAssertEqual(AppFormat.dateTime(afternoon, locale: en), "10/10/2026, 2:05\u{202F}PM")
        XCTAssertEqual(AppFormat.hour(14, locale: en), "2\u{202F}PM")
        XCTAssertEqual(AppFormat.hour(0, locale: en), "12\u{202F}AM")
    }

    func testTimesInFrench() {
        XCTAssertEqual(AppFormat.time(afternoon, locale: fr), "14:05")
        XCTAssertEqual(AppFormat.timeWithSeconds(afternoon, locale: fr), "14:05:09")
        XCTAssertEqual(AppFormat.dateTime(afternoon, locale: fr), "10/10/2026 14:05")
        XCTAssertEqual(AppFormat.hour(14, locale: fr), "14 h")
        XCTAssertEqual(AppFormat.hour(0, locale: fr), "0 h")
    }

    func testBytes() {
        XCTAssertEqual(AppFormat.bytes(1_500_000, locale: en), "1.5 MB")
        XCTAssertEqual(AppFormat.bytes(1_500_000, locale: fr), "1,5\u{202F}Mo")
    }

    /// The app's locale reuses one formatter per style; the output is the same as a fresh one.
    func testDefaultLocaleFormattersMatchFreshOnes() {
        let other = AppFormat.locale.identifier == "en_US" ? fr : en
        for _ in 0..<2 {
            XCTAssertEqual(AppFormat.money(0.36), AppFormat.money(0.36, locale: Locale(identifier: AppFormat.locale.identifier)))
            XCTAssertEqual(AppFormat.integer(1_234), AppFormat.integer(1_234, locale: Locale(identifier: AppFormat.locale.identifier)))
            XCTAssertEqual(AppFormat.shortDate(now), AppFormat.shortDate(now, locale: Locale(identifier: AppFormat.locale.identifier)))
        }
        XCTAssertNotEqual(AppFormat.money(0.36, locale: other), AppFormat.money(0.36))
    }

    func testRelativeInEnglish() {
        XCTAssertEqual(AppFormat.relative(now.addingTimeInterval(-10), now: now, locale: en), "just now")
        XCTAssertEqual(AppFormat.relative(now.addingTimeInterval(-180), now: now, locale: en), "3 min ago")
        XCTAssertEqual(AppFormat.relative(now.addingTimeInterval(-7_300), now: now, locale: en), "2h ago")
        let old = now.addingTimeInterval(-3 * 86_400)
        XCTAssertEqual(AppFormat.relative(old, now: now, locale: en),
                       "on \(AppFormat.shortDate(old, locale: en))")
        XCTAssertEqual(AppFormat.relative(old, now: now, standalone: true, locale: en), "Oct 7")
        XCTAssertEqual(AppFormat.relative(now.addingTimeInterval(-180), now: now, standalone: true, locale: en),
                       "3 min ago")
    }

    func testRelativeInFrench() {
        XCTAssertEqual(AppFormat.relative(now.addingTimeInterval(-10), now: now, locale: fr), "à l'instant")
        XCTAssertEqual(AppFormat.relative(now.addingTimeInterval(-180), now: now, locale: fr), "il y a 3 min")
        XCTAssertEqual(AppFormat.relative(now.addingTimeInterval(-7_300), now: now, locale: fr), "il y a 2 h")
        let old = now.addingTimeInterval(-3 * 86_400)
        XCTAssertEqual(AppFormat.relative(old, now: now, locale: fr),
                       "le \(AppFormat.shortDate(old, locale: fr))")
        XCTAssertEqual(AppFormat.relative(old, now: now, standalone: true, locale: fr), "7 oct.")
    }

    /// A language without its own wording falls back to English words, in its own numbers.
    func testOtherLanguagesUseEnglishWords() {
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(AppFormat.relative(now.addingTimeInterval(-10), now: now, locale: de), "just now")
        XCTAssertEqual(AppFormat.tokens(12_345, locale: de), "12,3K")
    }

    /// The formats follow the app's language, not the Mac's region: English on a French Mac
    /// still reads "$0.36" and "Oct 10", French reads "0,36 $US" and "10 oct." everywhere.
    func testResolvedLocaleFollowsTheAppLanguageOnly() throws {
        XCTAssertEqual(AppFormat.formattingLocales["en"], "en_US")
        XCTAssertEqual(AppFormat.formattingLocales["fr"], "fr_FR")
        let resolved = AppFormat.resolvedLocale(bundle: .main)
        XCTAssertTrue(["en_US", "fr_FR"].contains(resolved.identifier), resolved.identifier)

        for (language, expected) in [("en", "en_US"), ("fr", "fr_FR"), ("de", "en_US")] {
            let bundle = try Self.bundle(localizedIn: language)
            XCTAssertEqual(AppFormat.resolvedLocale(bundle: bundle).identifier, expected, language)
        }

        let english = Locale(identifier: "en_US")
        XCTAssertEqual(AppFormat.money(0.36, locale: english), "$0.36")
        XCTAssertEqual(AppFormat.percent(1, locale: english), "100%")
        XCTAssertEqual(AppFormat.shortDate(now, locale: english), "Oct 10")
        XCTAssertEqual(AppFormat.integer(1_234, locale: english), "1,234")
    }

    /// A throwaway bundle whose only localisation is `language`, so `preferredLocalizations`
    /// resolves to it whatever the machine's own preferences.
    private static func bundle(localizedIn language: String) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppFormatTests-\(language)-\(UUID().uuidString).bundle")
        let lproj = root.appendingPathComponent("Contents/Resources/\(language).lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try Data("\"k\" = \"v\";".utf8).write(to: lproj.appendingPathComponent("Localizable.strings"))
        let info: [String: Any] = ["CFBundleIdentifier": "test.\(language)", "CFBundleDevelopmentRegion": language]
        try (info as NSDictionary).write(to: root.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(Bundle(url: root))
    }
}
