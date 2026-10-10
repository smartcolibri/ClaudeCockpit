import Foundation

extension Bundle {
    /// This bundle's `<language>.lproj` for `locale`, else its English one, else itself.
    ///
    /// `String(localized:bundle:)` picks the language from the process's preferences and
    /// ignores any locale passed to it. Text that must be written in a chosen language — an
    /// export that follows the app's language, a test that pins one — looks its strings up in
    /// the sub-bundle this returns instead.
    public func localization(for locale: Locale) -> Bundle {
        for code in [locale.language.languageCode?.identifier, "en"].compactMap({ $0 }) {
            if let path = path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return self
    }
}
