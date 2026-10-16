import AppKit

/// What a pick does (D2): paste into the app in front, or put the emoji on the clipboard only.
enum PickMode: String, CaseIterable {
    case paste
    case copyOnly

    /// The name in Settings → "When you pick".
    var title: String {
        switch self {
        case .paste: return "Paste"
        case .copyOnly: return "Copy only"
        }
    }
}

/// The skin tones of Settings → "Default skin tone" (D9).
enum SkinTone {
    /// "" is yellow (no tone). Then the five tone marks U+1F3FB to U+1F3FF, light to dark.
    /// `Emoji.toneForms` has the same order.
    static let all = ["", "\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}", "\u{1F3FE}", "\u{1F3FF}"]

    /// The place of a tone mark in `Emoji.toneForms`, or nil for yellow.
    static func formIndex(_ tone: String) -> Int? {
        guard let place = all.firstIndex(of: tone), place > 0 else { return nil }
        return place - 1
    }

    /// The thumbs up of one tone, so Settings shows the tone and not a code.
    static func sample(_ tone: String) -> String { "👍" + tone }
}

/// The settings of the app, in `UserDefaults` (D2, D8, D9).
///
/// The `UserDefaults` is a parameter, so a test gives one that keeps its values in memory.
/// A value that is missing or broken gives the start value. Prefs never fail.
/// "Start at login" is not here: macOS keeps it (`LoginItem.isEnabled`).
final class Prefs {
    private enum Key {
        static let hotKeyCode = "yaseenEmoji.hotKeyCode"
        static let hotKeyModifiers = "yaseenEmoji.hotKeyModifiers"
        static let pickMode = "yaseenEmoji.pickMode"
        static let defaultTone = "yaseenEmoji.defaultTone"
        static let askedForAccessibility = "yaseenEmoji.askedForAccessibility"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The hotkey of the panel. The start value is ⌘E (D8).
    var hotKey: HotKeyCombo {
        get {
            guard
                let code = defaults.object(forKey: Key.hotKeyCode) as? Int,
                let modifiers = defaults.object(forKey: Key.hotKeyModifiers) as? Int,
                // A virtual key code is one byte.
                (0...0xFF).contains(code), modifiers >= 0
            else { return HotKeyKind.findEmoji.startValue }
            let combo = HotKeyCombo(keyCode: UInt32(code), modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)))
            return combo.isValid ? combo : HotKeyKind.findEmoji.startValue
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.hotKeyCode)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: Key.hotKeyModifiers)
        }
    }

    /// "When you pick". The start value is Paste (D2).
    var pickMode: PickMode {
        get { (defaults.object(forKey: Key.pickMode) as? String).flatMap(PickMode.init(rawValue:)) ?? .paste }
        set { defaults.set(newValue.rawValue, forKey: Key.pickMode) }
    }

    /// "Default skin tone": "" (yellow) or one tone mark of `SkinTone.all`. The start value is yellow (D9).
    var defaultTone: String {
        get {
            let tone = defaults.object(forKey: Key.defaultTone) as? String ?? ""
            return SkinTone.all.contains(tone) ? tone : ""
        }
        set { defaults.set(SkinTone.all.contains(newValue) ? newValue : "", forKey: Key.defaultTone) }
    }

    /// True after the first launch asked for Accessibility. The app asks one time only (D2).
    var askedForAccessibility: Bool {
        get { defaults.object(forKey: Key.askedForAccessibility) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.askedForAccessibility) }
    }
}
