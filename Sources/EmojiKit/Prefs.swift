import AppKit

/// What Enter does (D2; D16 of YAZ-2919): paste into the app in front, or put the item on the clipboard only.
enum PickMode: String, CaseIterable {
    case paste
    case copyOnly

    /// The name in Settings → "When you press Enter".
    var title: String {
        switch self {
        case .paste: return "Paste"
        case .copyOnly: return "Copy only"
        }
    }
}

/// The three rows of Settings → "When you press Enter" (D16 of YAZ-2919). Each kind has its own mode and Keep value.
enum PickKind: String, CaseIterable {
    case emoji
    case gif
    case meme

    init(_ kind: ItemKind) {
        switch kind {
        case .gif: self = .gif
        case .meme: self = .meme
        }
    }

    /// The name of the row in Settings.
    var title: String {
        switch self {
        case .emoji: return "Emojis"
        case .gif: return "GIFs"
        case .meme: return "Memes"
        }
    }

    /// The name in a sentence: "emojis", "GIFs", "memes".
    var name: String { self == .gif ? title : title.lowercased() }
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

/// The settings of the app, in `UserDefaults` (D2, D8, D9, D16).
///
/// The hotkey, "When you press Enter", the default skin tone and the two KLIPY switches also sync through the history files (D16).
/// `UserDefaults` is the cache of this Mac: it keeps the value and the time of the change that this Mac applied.
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
        static let hotKeyChangedAt = "yaseenEmoji.hotKeyChangedAt"
        static let pickModeChangedAt = "yaseenEmoji.pickModeChangedAt"
        static let defaultToneChangedAt = "yaseenEmoji.defaultToneChangedAt"
        static let keepOnClipboard = "yaseenEmoji.keepOnClipboard"
        static let keepOnClipboardChangedAt = "yaseenEmoji.keepOnClipboardChangedAt"
        static let klipyGIFs = "yaseenEmoji.klipyGIFs"
        static let klipyMemes = "yaseenEmoji.klipyMemes"
        static let klipyGIFsChangedAt = "yaseenEmoji.klipyGIFsChangedAt"
        static let klipyMemesChangedAt = "yaseenEmoji.klipyMemesChangedAt"
        static let preferencesFolder = "yaseenEmoji.preferencesFolder"
        static let mediaFolder = "yaseenEmoji.mediaFolder"
        static let macName = "yaseenEmoji.macName"
        static let settingsPage = "yaseenEmoji.settingsPage"

        static func klipy(_ kind: ItemKind) -> String { kind == .gif ? klipyGIFs : klipyMemes }
        /// `yaseenEmoji.pickMode.emoji` and so on: the key of one kind (D16 of YAZ-2919).
        static func of(_ key: String, _ kind: PickKind) -> String { key + "." + kind.rawValue }
        static func klipyChangedAt(_ kind: ItemKind) -> String { kind == .gif ? klipyGIFsChangedAt : klipyMemesChangedAt }
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

    /// "When you press Enter" of one kind (D16 of YAZ-2919). A kind with no value of its own uses the one
    /// "When you pick" of v0.1 (D2), so an old Copy only stays Copy only. Then the start value is Paste.
    func pickMode(_ kind: PickKind) -> PickMode {
        mode(Key.of(Key.pickMode, kind)) ?? mode(Key.pickMode) ?? .paste
    }

    func setPickMode(_ mode: PickMode, for kind: PickKind) {
        defaults.set(mode.rawValue, forKey: Key.of(Key.pickMode, kind))
    }

    /// "Keep it on the clipboard after a paste" of one kind (D16 of YAZ-2919). The start value is on.
    func keepsOnClipboard(_ kind: PickKind) -> Bool {
        defaults.object(forKey: Key.of(Key.keepOnClipboard, kind)) as? Bool ?? true
    }

    func setKeepsOnClipboard(_ keep: Bool, for kind: PickKind) {
        defaults.set(keep, forKey: Key.of(Key.keepOnClipboard, kind))
    }

    private func mode(_ key: String) -> PickMode? {
        (defaults.object(forKey: key) as? String).flatMap(PickMode.init(rawValue:))
    }

    /// "Default skin tone": "" (yellow) or one tone mark of `SkinTone.all`. The start value is yellow (D9).
    var defaultTone: String {
        get {
            let tone = defaults.object(forKey: Key.defaultTone) as? String ?? ""
            return SkinTone.all.contains(tone) ? tone : ""
        }
        set { defaults.set(SkinTone.all.contains(newValue) ? newValue : "", forKey: Key.defaultTone) }
    }

    /// "Search KLIPY in GIFs" and "Search KLIPY in Memes" (D14 update of YAZ-2919).
    /// The start values: GIFs on, Memes off (Yaseen, 16 Oct 2026: "memes off by default").
    func searchesKlipy(_ kind: ItemKind) -> Bool {
        defaults.object(forKey: Key.klipy(kind)) as? Bool ?? (kind == .gif)
    }

    func setSearchesKlipy(_ on: Bool, for kind: ItemKind) {
        defaults.set(on, forKey: Key.klipy(kind))
    }

    /// True after the first launch asked for Accessibility. The app asks one time only (D2).
    var askedForAccessibility: Bool {
        get { defaults.object(forKey: Key.askedForAccessibility) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.askedForAccessibility) }
    }

    // MARK: D16

    /// The time of the hotkey and the default skin tone that this Mac uses now.
    /// The app applies a setting from a history file only when it is newer. Nil: no dated change yet.
    var hotKeyChangedAt: Date? {
        get { defaults.object(forKey: Key.hotKeyChangedAt) as? Date }
        set { defaults.set(newValue, forKey: Key.hotKeyChangedAt) }
    }

    var defaultToneChangedAt: Date? {
        get { defaults.object(forKey: Key.defaultToneChangedAt) as? Date }
        set { defaults.set(newValue, forKey: Key.defaultToneChangedAt) }
    }

    /// The time of the mode of `kind` that this Mac uses now. A kind with no time of its own uses the time of
    /// the v0.1 "When you pick", so the old synced value does not win again over the old local one.
    func pickModeChangedAt(_ kind: PickKind) -> Date? {
        defaults.object(forKey: Key.of(Key.pickModeChangedAt, kind)) as? Date ?? defaults.object(forKey: Key.pickModeChangedAt) as? Date
    }

    func setPickModeChangedAt(_ date: Date, for kind: PickKind) {
        defaults.set(date, forKey: Key.of(Key.pickModeChangedAt, kind))
    }

    /// The time of the Keep value of `kind` that this Mac uses now, or nil.
    func keepChangedAt(_ kind: PickKind) -> Date? {
        defaults.object(forKey: Key.of(Key.keepOnClipboardChangedAt, kind)) as? Date
    }

    func setKeepChangedAt(_ date: Date, for kind: PickKind) {
        defaults.set(date, forKey: Key.of(Key.keepOnClipboardChangedAt, kind))
    }

    /// The time of the KLIPY switch of `kind` that this Mac uses now, or nil.
    func klipyChangedAt(_ kind: ItemKind) -> Date? {
        defaults.object(forKey: Key.klipyChangedAt(kind)) as? Date
    }

    func setKlipyChangedAt(_ date: Date, for kind: ItemKind) {
        defaults.set(date, forKey: Key.klipyChangedAt(kind))
    }

    /// The path of the preferences folder. "" is the default folder. It stays on each Mac.
    var preferencesFolder: String {
        get { defaults.object(forKey: Key.preferencesFolder) as? String ?? "" }
        set { defaults.set(newValue, forKey: Key.preferencesFolder) }
    }

    /// The path of the GIFs and memes folder (D4 of YAZ-2919). "" is the preferences folder. It stays on each Mac.
    var mediaFolder: String {
        get { defaults.object(forKey: Key.mediaFolder) as? String ?? "" }
        set { defaults.set(newValue, forKey: Key.mediaFolder) }
    }

    /// The page of Settings that you used last (D19 of YAZ-2919). It stays on each Mac. The start value is General.
    var settingsPage: SettingsPage {
        get { (defaults.object(forKey: Key.settingsPage) as? String).flatMap(SettingsPage.init(rawValue:)) ?? .general }
        set { defaults.set(newValue.rawValue, forKey: Key.settingsPage) }
    }

    /// The safe name of this Mac for `you-<Mac name>.json`. The first call makes it from the computer
    /// name and keeps it, so a rename of the Mac does not make a second file.
    func macName(computerName: () -> String) -> String {
        if let name = defaults.object(forKey: Key.macName) as? String, PreferencesFolder.safeName(name) == name {
            return name
        }
        let name = PreferencesFolder.safeName(computerName())
        defaults.set(name, forKey: Key.macName)
        return name
    }
}
