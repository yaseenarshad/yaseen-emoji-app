/// The pages of Settings, in the order of the list on the left (D19 of YAZ-2919).
/// The window opens on the page that you used last on this Mac (`Prefs.settingsPage`, not synced).
enum SettingsPage: String, CaseIterable {
    case general
    case enterAndPaste
    case gifsAndMemes
    case history
    case syncFolder

    /// The name in the list and above the page.
    var title: String {
        switch self {
        case .general: return "General"
        case .enterAndPaste: return "Enter and paste"
        case .gifsAndMemes: return "GIFs and memes"
        case .history: return "Your history"
        case .syncFolder: return "Sync folder"
        }
    }

    /// The SF Symbol in the list.
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .enterAndPaste: return "return"
        case .gifsAndMemes: return "photo.on.rectangle"
        case .history: return "clock.arrow.circlepath"
        case .syncFolder: return "arrow.triangle.2.circlepath"
        }
    }

    /// The sections of the page, top to bottom. The view draws each page only from this map,
    /// and a test checks that each row is on exactly one page, so a new row can't get lost.
    var sections: [SettingsSection] {
        switch self {
        case .general:
            return [SettingsSection(rows: [.hotKey, .defaultTone, .startAtLogin]),
                    SettingsSection(title: "Accessibility", rows: [.accessibility])]
        case .enterAndPaste:
            return [SettingsSection(rows: [.afterEnter]),
                    SettingsSection(title: "When you press Enter", rows: [.enterEmojis, .enterGIFs, .enterMemes],
                                    showsEnterText: true)]
        case .gifsAndMemes:
            return [SettingsSection(rows: [.klipyKey, .klipyGIFs, .klipyMemes]),
                    SettingsSection(rows: [.mediaFolder])]
        case .history:
            return [SettingsSection(title: "Your most used", rows: [.hiddenFromMostUsed]),
                    SettingsSection(title: "Learned words", rows: [.forgetLearnedWords])]
        case .syncFolder:
            return [SettingsSection(rows: [.preferencesFolder])]
        }
    }

    /// The rows of the page, top to bottom.
    var rows: [SettingsRow] { sections.flatMap(\.rows) }
}

/// One grouped section of a page: an optional title, its rows, and the grey line of "When you press Enter".
struct SettingsSection: Hashable {
    var title: String?
    var rows: [SettingsRow]
    /// True for the section of D16 of YAZ-2919: the grey line below tells what Enter does now.
    var showsEnterText = false
}

/// Each row of Settings. The view has one `case` for each row, with no `default`.
enum SettingsRow: CaseIterable {
    /// "Find an emoji" (D8).
    case hotKey
    /// "Default skin tone" (D9).
    case defaultTone
    case startAtLogin
    case accessibility
    /// "After Enter: Stay open | Close" (D20 of YAZ-2919).
    case afterEnter
    /// "When you press Enter" of emojis, GIFs and memes (D16 of YAZ-2919).
    case enterEmojis, enterGIFs, enterMemes
    /// The KLIPY key (D2, D14 of YAZ-2919), and the two KLIPY switches (D14 update).
    case klipyKey, klipyGIFs, klipyMemes
    /// The GIFs and memes folder (D4 of YAZ-2919).
    case mediaFolder
    /// "Hidden from Your most used" (D15).
    case hiddenFromMostUsed
    /// "Forget learned words…" (D4).
    case forgetLearnedWords
    /// The preferences folder (D16).
    case preferencesFolder
}
