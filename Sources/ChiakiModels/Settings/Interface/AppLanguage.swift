import Foundation

/// The language used by the app's interface.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public static let defaultsKey = "app.interfaceLanguage"
    public var id: String { rawValue }

    public var localeIdentifier: String {
        switch self {
        case .system:
            Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        }
    }

    public var resolved: AppLanguage {
        guard self == .system else { return self }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
            ? .simplifiedChinese
            : .english
    }

    public static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "system") ?? .system
    }

    public static func title(_ language: AppLanguage) -> String {
        switch language {
        case .system: chiakiLocalized("Follow System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}
