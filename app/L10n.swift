// Localization. The Spanish text is the key; translations live in <lang>.lproj/Localizable.strings
// (Resources/en.lproj). SwiftUI literals (Button("…"), Toggle("…")…) are looked up automatically;
// strings built in code go through L().
import Foundation

func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}
