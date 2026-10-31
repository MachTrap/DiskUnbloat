import Foundation

/// Resolve display strings only. Never pass paths or stable model IDs through localization.
enum L10n {
    static func text(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: "Localizable") }
    static func format(_ key: String, _ arguments: CVarArg...) -> String { String(format: text(key), locale: Locale.current, arguments: arguments) }
    static func count(_ key: String, _ count: Int) -> String { String.localizedStringWithFormat(text(key), count) }
}
