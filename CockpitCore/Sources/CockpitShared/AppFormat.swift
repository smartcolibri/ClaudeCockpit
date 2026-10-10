import Foundation

/// Number, date and duration formatting shared by every screen. Pure functions.
///
/// Every function takes the locale to write in, defaulting to ``locale``: the formatting
/// locale of the language the app resolved (English unless the user prefers a translation
/// it ships). Tests pass an explicit locale so their output does not depend on the machine.
///
/// The few words written here ("just now", "2 h 05") follow the locale's language, not the
/// process's: the String Catalogs pick the language from the process, so a formatter that
/// looked words up there could not be pinned by a test.
public enum AppFormat {
    /// The formatting locale of the language the app resolved: English formats as `en_US`
    /// ("$0.36", "Oct 10", "1,234") and French as `fr_FR` ("0,36 $US", "10 oct.", "1 234"),
    /// whatever the Mac's region. Numbers then read the way the surrounding words do.
    public static let locale: Locale = resolvedLocale()

    /// One formatting locale per language the app ships; anything else formats as English,
    /// which is also the language the interface falls back to.
    static let formattingLocales: [String: String] = ["en": "en_US", "fr": "fr_FR"]

    static func resolvedLocale(bundle: Bundle = .main) -> Locale {
        let preferred = bundle.preferredLocalizations.first.flatMap { $0 == "Base" ? nil : $0 }
        let language = Locale(identifier: preferred ?? "en").language.languageCode?.identifier ?? "en"
        return Locale(identifier: formattingLocales[language] ?? "en_US")
    }

    private static func isFrench(_ locale: Locale) -> Bool {
        locale.language.languageCode == .french
    }

    /// `1,234` · `12.3K` · `1.3M` · `2.5B` in English; `1 234` · `12,3 k` · `1,3 M` · `2,5 G` in French.
    public static func tokens(_ value: Int, locale: Locale = locale) -> String {
        let v = Double(value)
        let french = isFrench(locale)
        func scaled(_ divisor: Double, _ wide: Double, _ en: String, _ fr: String) -> String {
            let number = decimal(v / divisor, digits: abs(v) < wide ? 1 : 0, locale: locale)
            return french ? "\(number) \(fr)" : number + en
        }
        switch abs(v) {
        case ..<10_000: return integer(value, locale: locale)
        case ..<1_000_000: return scaled(1_000, 100_000, "K", "k")
        case ..<1_000_000_000: return scaled(1_000_000, 100_000_000, "M", "M")
        default:
            let number = decimal(v / 1_000_000_000, digits: 1, locale: locale)
            return french ? "\(number) G" : number + "B"
        }
    }

    public static func integer(_ value: Int, locale: Locale = locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func decimal(_ value: Double, digits: Int = 1, locale: Locale = locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    /// `$12.34` / `12,34 $US` — currency code `USD` or `EUR`.
    public static func money(
        _ value: Double, currency: String = "USD", digits: Int = 2, locale: Locale = locale
    ) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .currency
        f.currencyCode = currency
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// `42%` / `42 %` — `fraction: true` expects 0…1, otherwise 0…100.
    public static func percent(
        _ value: Double, fraction: Bool = true, digits: Int = 0, locale: Locale = locale
    ) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .percent
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        let ratio = fraction ? value : value / 100
        return f.string(from: NSNumber(value: ratio)) ?? String(format: "%.\(digits)f%%", ratio * 100)
    }

    /// `12s` · `45 min` · `2h 05m` · `3d 1h` in English; `12 s` · `45 min` · `2 h 05` · `3 j 1 h` in French.
    public static func duration(_ seconds: TimeInterval, locale: Locale = locale) -> String {
        let french = isFrench(locale)
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return french ? "\(s) s" : "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, rm = m % 60
        if h < 48 { return String(format: french ? "%d h %02d" : "%dh %02dm", h, rm) }
        let d = h / 24, rh = h % 24
        return french ? "\(d) j \(rh) h" : "\(d)d \(rh)h"
    }

    /// `just now` · `3 min ago` · `2h ago` · `on Oct 10`; `à l'instant` · `il y a 3 min` · `le 10 oct.`
    public static func relative(_ date: Date, now: Date = Date(), locale: Locale = locale) -> String {
        let french = isFrench(locale)
        let delta = now.timeIntervalSince(date)
        if delta < 45 { return french ? "à l'instant" : "just now" }
        if delta < 3600 {
            let minutes = Int(delta / 60)
            return french ? "il y a \(minutes) min" : "\(minutes) min ago"
        }
        if delta < 86_400 {
            let hours = Int(delta / 3600)
            return french ? "il y a \(hours) h" : "\(hours)h ago"
        }
        let day = shortDate(date, locale: locale)
        return french ? "le \(day)" : "on \(day)"
    }

    /// `Oct 10` / `10 oct.`
    public static func shortDate(_ date: Date, locale: Locale = locale) -> String {
        formatted(date, template: "dMMM", locale: locale)
    }

    /// `Sat 10` / `sam. 10`
    public static func weekday(_ date: Date, locale: Locale = locale) -> String {
        formatted(date, template: "EEEd", locale: locale)
    }

    /// `2:05 PM` / `14:05` — the region decides between 12 and 24 hours.
    public static func time(_ date: Date, locale: Locale = locale) -> String {
        formatted(date, template: "jmm", locale: locale)
    }

    /// `10/10/2026, 2:05 PM` / `10/10/2026 14:05`
    public static func dateTime(_ date: Date, locale: Locale = locale) -> String {
        formatted(date, template: "ddMMyyyyjmm", locale: locale)
    }

    private static func formatted(_ date: Date, template: String, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }
}
