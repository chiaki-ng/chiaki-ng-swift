import Foundation
import SwiftUI

// MARK: - Runtime localization bridge
//
// SwiftUI only localizes string *literals* (they resolve to LocalizedStringKey).
// chiaki-ng passes most labels around as `String` values (constants, enum
// display names, custom component arguments). Those resolve to the
// StringProtocol initializers and are never looked up in the string table.
//
// The overloads below give String values a more specific initializer that
// routes the text through the selected table. Literals still work: the helper
// performs the same key lookup, so existing .strings entries keep applying.
//
// This file lives in ChiakiModels and is re-exported by the UI modules, so no
// call sites need to change.

private let chiakiDigits = try! NSRegularExpression(pattern: "[0-9]+(?:[.,][0-9]+)?", options: [])
private let chiakiSpecifiers = try! NSRegularExpression(pattern: "%(?:([0-9]+)\\$)?(?:@|lld|ld|d|f)", options: [])

/// Fills the captured numbers back into a translated format template.
private func chiakiFill(_ template: String, values: [String]) -> String {
    let ns = template as NSString
    var result = ""
    var cursor = 0
    var next = 0
    for match in chiakiSpecifiers.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
        result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        let index: Int
        if match.range(at: 1).location != NSNotFound {
            index = (Int(ns.substring(with: match.range(at: 1))) ?? next + 1) - 1
        } else {
            index = next
            next += 1
        }
        if index >= 0 && index < values.count {
            result += values[index]
        }
        cursor = match.range.location + match.range.length
    }
    result += ns.substring(from: cursor)
    return result.replacingOccurrences(of: "%%", with: "%")
}

/// Resolves a display string against the app's localization tables.
/// Falls back to a normalized key (numbers replaced by %@) so dynamically
/// formatted strings such as "Uses 15 Mbps for 1080p." are translated too.
public func chiakiLocalized(_ text: String) -> String {
    let language = AppLanguage.current.resolved
    guard language == .simplifiedChinese,
          let path = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"),
          let bundle = Bundle(path: path) else {
        return text
    }
    let direct = bundle.localizedString(forKey: text, value: text, table: nil)
    if direct != text {
        return direct
    }
    let ns = text as NSString
    let matches = chiakiDigits.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty, matches.count <= 8 else { return text }
    var pattern = ""
    var values: [String] = []
    var cursor = 0
    for match in matches {
        let range = match.range
        if range.location > cursor {
            pattern += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
        }
        pattern += "%@"
        values.append(ns.substring(with: range))
        cursor = range.location + range.length
    }
    if cursor < ns.length {
        pattern += ns.substring(from: cursor)
    }
    var template = bundle.localizedString(forKey: pattern, value: pattern, table: nil)
    if template == pattern {
        let integerPattern = pattern.replacingOccurrences(of: "%@", with: "%lld")
        template = bundle.localizedString(forKey: integerPattern, value: integerPattern, table: nil)
    }
    guard template != pattern else { return text }
    return chiakiFill(template, values: values)
}

/// Localizes a preset name and the duplicate suffix added by the Controls editor.
/// Stored preset names stay unchanged; only their displayed form is translated.
public func chiakiLocalizedPresetName(_ name: String) -> String {
    var base = name
    var copyCount = 0
    while base.hasSuffix(" copy") {
        base.removeLast(" copy".count)
        copyCount += 1
    }
    let localizedBase = chiakiLocalized(base)
    let suffix = AppLanguage.current.resolved == .simplifiedChinese ? " 副本" : " copy"
    return localizedBase + String(repeating: suffix, count: copyCount)
}

@inline(__always)
private func chiakiText(_ string: String) -> Text {
    Text(verbatim: chiakiLocalized(string))
}

public extension Text {
    init(_ string: String) {
        self = chiakiText(string)
    }
}

public extension Label where Title == Text, Icon == Image {
    init(_ title: String, systemImage name: String) {
        self.init(title: { chiakiText(title) }, icon: { Image(systemName: name) })
    }

    init(_ title: String, image name: String) {
        self.init(title: { chiakiText(title) }, icon: { Image(name) })
    }
}

public extension Button where Label == Text {
    init(_ title: String, action: @escaping () -> Void) {
        self.init(action: action, label: { chiakiText(title) })
    }

    init(_ title: String, role: ButtonRole?, action: @escaping () -> Void) {
        self.init(role: role, action: action, label: { chiakiText(title) })
    }
}

public extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ title: String, systemImage name: String, action: @escaping () -> Void) {
        self.init(action: action) {
            SwiftUI.Label(title: { chiakiText(title) }, icon: { Image(systemName: name) })
        }
    }
}

public extension Toggle where Label == Text {
    init(_ title: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn, label: { chiakiText(title) })
    }
}

public extension TextField where Label == Text {
    init(_ title: String, text: Binding<String>) {
        self.init(text: text, label: { chiakiText(title) })
    }

    init(_ title: String, text: Binding<String>, prompt: Text?) {
        self.init(text: text, prompt: prompt, label: { chiakiText(title) })
    }

    init(_ title: String, text: Binding<String>, prompt: Text?, axis: Axis) {
        self.init(text: text, prompt: prompt, axis: axis, label: { chiakiText(title) })
    }
}

public extension SecureField where Label == Text {
    init(_ title: String, text: Binding<String>) {
        self.init(text: text, label: { chiakiText(title) })
    }
}

public extension Picker where Label == Text {
    init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content, label: { chiakiText(title) })
    }
}

public extension Section where Parent == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { chiakiText(title) })
    }
}

public extension Menu where Label == Text {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, label: { chiakiText(title) })
    }
}

public extension View {
    func help(_ text: String) -> some View {
        help(Text(verbatim: chiakiLocalized(text)))
    }

    func accessibilityLabel(_ label: String) -> some View {
        accessibilityLabel(Text(verbatim: chiakiLocalized(label)))
    }

    func navigationTitle(_ title: String) -> some View {
        navigationTitle(Text(verbatim: chiakiLocalized(title)))
    }
}
