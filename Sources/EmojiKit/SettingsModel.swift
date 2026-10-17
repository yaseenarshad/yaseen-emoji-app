import AppKit
import Carbon.HIToolbox

/// The state and the rules of the settings window, with no window and no view (D2, D8, D9, D10, D15, D16;
/// D4 and D14 of YAZ-2919).
///
/// The model owns the changes of the settings: it registers the hotkey, stores the prefs, asks
/// macOS for "Start at login", and clears the learned words. The app, the menu and the window
/// only call it. Thus a test proves the rules. The same idea as `SettingsModel` in Screendraw.
@MainActor
final class SettingsModel: ObservableObject {
    static let refusedText = "This key is in use. Pick a different key."
    static let needsModifierText = "A hotkey needs ⌘, ⌃ or ⌥ with the key, or a function key."
    static let loginItemNotAvailableText = "Start at login works only in the installed app."
    static let loginItemNotChangedText = "macOS did not change this setting. Look at Login Items in System Settings."
    static let accessibilityOnText = "Accessibility is on. A pick pastes into your app."
    static let accessibilityOffText = "Accessibility is off. A pick copies only."
    static let forgetQuestion = "This deletes every word the app learned and every word you added, on all your Macs. You can't undo it. Your most used stays."
    static let resetQuestion = "This Mac stops sharing its history with your other Macs. Your files stay in the folder."
    static let forgottenText = "The learned words are gone."
    static let folderNotWrittenText = "Yaseen Emoji can't write into this folder. Pick a different folder."
    static let mediaSameText = "Same as the preferences folder."
    static let mediaDifferentText = "Your GIFs and memes are in a different folder."
    static let mediaResetQuestion = "Your GIFs and memes move back into the preferences folder. The app copies each file, checks it, then removes the old copy."
    static let mediaNotMovedText = "Yaseen Emoji can't move your GIFs and memes into this folder. They stay in the old folder."
    static let klipyKeyNote = "Without a key, you see only your own GIFs and memes."
    static let klipyKeyNotSavedText = "Yaseen Emoji can't keep the key in the Keychain."
    /// The Partner Panel of KLIPY, where you make a free key ("API Keys").
    static let klipyKeyURL = URL(string: "https://partner.klipy.com/")!
    /// The Accessibility pane of System Settings.
    static let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    @Published private(set) var hotKey: HotKeyCombo
    /// True while the hotkey row waits for a key. The hotkey is off during that time.
    @Published private(set) var isRecording = false
    /// The red line below the hotkey row.
    @Published private(set) var hotKeyProblem: String?
    @Published private(set) var pickMode: PickMode
    @Published private(set) var defaultTone: String
    /// The real state from macOS, not a stored value.
    @Published private(set) var startAtLogin = false
    /// The red line below the switch.
    @Published private(set) var loginItemProblem: String?
    @Published private(set) var accessibilityIsOn = false
    /// The row that asks you to type a word before its button works (D19), or nil.
    @Published private(set) var confirming: Danger?
    /// What you typed in the box of that row.
    @Published var typedConfirmation = ""
    /// The grey line after "Forget".
    @Published private(set) var forgetNote: String?
    /// The emojis hidden from "Your most used" (D15).
    @Published private(set) var hiddenCount = 0
    /// The preferences folder that you chose, or the default folder (D16).
    @Published private(set) var folderPath = ""
    /// True when this Mac uses the default folder.
    @Published private(set) var folderIsDefault = true
    /// The red line below the preferences folder: the folder is missing, or the app can't write into it.
    @Published private(set) var folderProblem: String?
    /// The GIFs and memes folder in use (D4 of YAZ-2919).
    @Published private(set) var mediaFolderPath = ""
    /// True when the GIFs and memes are in the preferences folder (the pref is "").
    @Published private(set) var mediaFolderIsSame = true
    /// The red line below the GIFs and memes folder: the folder is missing, or a move failed.
    @Published private(set) var mediaFolderProblem: String?
    /// The text of the KLIPY key box (D14 of YAZ-2919). It holds the saved key, or what you typed.
    @Published var klipyKeyText = ""
    /// True when this Mac's Keychain has a KLIPY key.
    @Published private(set) var hasKlipyKey = false
    /// The red line below the key box.
    @Published private(set) var klipyKeyProblem: String?

    /// The menu shows the hotkey, so the app must know each change.
    var onHotKeyChanged: (HotKeyCombo) -> Void = { _ in }
    /// The default tone changes the grid, so the panel must know.
    var onTonesChanged: () -> Void = {}
    /// Opens a URL. The app opens System Settings. A test keeps the URL.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Asks for a folder and gives it, or nil on Cancel. The window shows the folder picker. A test gives a folder.
    var pickFolder: (@escaping (URL?) -> Void) -> Void = { $0(nil) }
    /// The same for "Set GIFs and memes folder…".
    var pickMediaFolder: (@escaping (URL?) -> Void) -> Void = { $0(nil) }
    /// The KLIPY key changed: the panel searches KLIPY with the new key, or stops.
    var onKlipyKeyChanged: () -> Void = {}

    private let prefs: Prefs
    private let hotKeys: HotKeyRegistering
    private let loginItem: LoginItem
    private let access: PasteAccess
    private let store: YouStore
    private let folders: PreferencesFolder
    /// The list of GIFs and memes. It moves with the preferences folder (D3, D4 of YAZ-2919).
    private let library: LibraryStore
    private let keyStore: KeyStore
    /// The red line of a folder that the app could not write. The next refresh keeps it.
    private var folderWriteProblem: String?
    /// The red line of a move of the GIFs and memes that failed. The next refresh keeps it.
    private var mediaMoveProblem: String?

    init(prefs: Prefs, hotKeys: HotKeyRegistering, loginItem: LoginItem, access: PasteAccess, store: YouStore,
         folders: PreferencesFolder, library: LibraryStore, keyStore: KeyStore) {
        self.prefs = prefs
        self.hotKeys = hotKeys
        self.loginItem = loginItem
        self.access = access
        self.store = store
        self.folders = folders
        self.library = library
        self.keyStore = keyStore
        hotKey = prefs.hotKey
        pickMode = prefs.pickMode
        defaultTone = prefs.defaultTone
        let key = keyStore.read() ?? ""
        klipyKeyText = key
        hasKlipyKey = !key.isEmpty
        refresh()
    }

    // MARK: The hotkey (D8)

    /// Registers the stored hotkey. The app calls this at the start.
    /// When macOS refuses it, the app continues to run, and the window shows the red line.
    func registerHotKey() {
        hotKeyProblem = hotKeys.register(hotKey, for: .findEmoji) ? nil : SettingsModel.refusedText
    }

    /// "Change…". The hotkey is off while the row records, so the row also gets the key that is the hotkey now.
    func startRecording() {
        guard !isRecording else { return }
        hotKeys.unregister(.findEmoji)
        hotKeyProblem = nil
        isRecording = true
    }

    /// Stops the recorder with no change. The hotkey works again.
    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        registerHotKey()
    }

    /// A key-down in the settings window. Returns `true` when the model used the key.
    func keyDown(_ combo: HotKeyCombo) -> Bool {
        guard isRecording else { return false }
        if combo.keyCode == UInt32(kVK_Escape) {
            cancelRecording()
            return true
        }
        isRecording = false
        if !combo.isValid {
            registerHotKey()
            hotKeyProblem = SettingsModel.needsModifierText
        } else if hotKeys.register(combo, for: .findEmoji) {
            // Store only a key that macOS accepted. It works at once, with no restart.
            hotKey = combo
            prefs.hotKey = combo
            // The other Macs get it through this Mac's history file (D16).
            prefs.hotKeyChangedAt = store.setHotKey(You.Key(combo))
            hotKeyProblem = nil
            onHotKeyChanged(combo)
        } else {
            // The old key comes back, and the red line tells why.
            registerHotKey()
            hotKeyProblem = SettingsModel.refusedText
        }
        return true
    }

    // MARK: When you pick (D2) and the default skin tone (D9)

    func setPickMode(_ mode: PickMode) {
        prefs.pickMode = mode
        prefs.pickModeChangedAt = store.setPickMode(mode.rawValue)
        pickMode = mode
    }

    func setDefaultTone(_ tone: String) {
        guard SkinTone.all.contains(tone) else { return }
        prefs.defaultTone = tone
        prefs.defaultToneChangedAt = store.setDefaultTone(tone)
        defaultTone = tone
        onTonesChanged()
    }

    // MARK: The settings of the other Macs (D16)

    /// Uses each setting of the history files that is newer than the value of this Mac: the newest change wins.
    /// A new hotkey works at once. When macOS refuses it, the old key stays, the red line shows,
    /// and the next change of the files tries again. The app calls this after a load or a reload.
    func applySynced() {
        let synced = store.you.settings
        if let mode = synced.pickMode, isNewer(mode.at, than: prefs.pickModeChangedAt),
           let value = PickMode(rawValue: mode.value) {
            prefs.pickMode = value
            prefs.pickModeChangedAt = mode.at
            pickMode = value
        }
        if let tone = synced.defaultTone, isNewer(tone.at, than: prefs.defaultToneChangedAt),
           SkinTone.all.contains(tone.value) {
            prefs.defaultTone = tone.value
            prefs.defaultToneChangedAt = tone.at
            if defaultTone != tone.value {
                defaultTone = tone.value
                onTonesChanged()
            }
        }
        // The recorder has the hotkey off. The next reload applies the key.
        if let key = synced.hotKey, isNewer(key.at, than: prefs.hotKeyChangedAt), !isRecording,
           let combo = HotKeyCombo(key.value), combo.isValid {
            if combo == hotKey {
                prefs.hotKeyChangedAt = key.at
            } else if hotKeys.register(combo, for: .findEmoji) {
                hotKey = combo
                prefs.hotKey = combo
                prefs.hotKeyChangedAt = key.at
                hotKeyProblem = nil
                onHotKeyChanged(combo)
            } else {
                registerHotKey()
                hotKeyProblem = SettingsModel.refusedText
            }
        }
    }

    private func isNewer(_ date: Date, than applied: Date?) -> Bool {
        applied.map { date > $0 } ?? true
    }

    // MARK: The preferences folder (D16)

    /// "Set preferences folder…": the folder picker, then `usePreferencesFolder`.
    func choosePreferencesFolder() {
        pickFolder { [weak self] folder in
            guard let folder else { return }
            self?.usePreferencesFolder(folder)
        }
    }

    /// Writes this Mac's history file and list into `folder`, then uses the folder. The files of the other Macs
    /// that are already there count at once, and their newer settings apply. The old files stay.
    /// When the GIFs and memes are in the preferences folder, they move too (D4 of YAZ-2919). If that move fails,
    /// they stay in the old folder, and the GIFs and memes folder becomes the old folder, so no file is lost.
    func usePreferencesFolder(_ folder: URL) {
        let isDefault = folder.standardizedFileURL.path == folders.defaultFolder.standardizedFileURL.path
        let oldHistory = store.url
        do {
            try store.move(to: folders.ownFile(in: folder))
        } catch {
            folderWriteProblem = SettingsModel.folderNotWrittenText
            refresh()
            return
        }
        do {
            try library.move(to: folder.appendingPathComponent(folders.libraryFileName))
        } catch {
            // The history goes back, so the two files stay in one folder.
            try? store.move(to: oldHistory)
            folderWriteProblem = SettingsModel.folderNotWrittenText
            refresh()
            return
        }
        prefs.preferencesFolder = isDefault ? "" : folder.path
        folderWriteProblem = nil
        if prefs.mediaFolder.isEmpty {
            let oldMedia = library.mediaFolder
            do {
                try library.useMediaFolder(folder)
                mediaMoveProblem = nil
            } catch {
                prefs.mediaFolder = oldMedia.path
                mediaMoveProblem = SettingsModel.mediaMoveText(error)
            }
        }
        applySynced()
        refresh()
    }

    /// "Reset to Mac Default Folder": back to the default folder, with this Mac's data of now.
    /// Settings asks you to type "reset" first (D19).
    func useThisMacOnly() {
        usePreferencesFolder(folders.defaultFolder)
    }

    // MARK: The GIFs and memes folder (D4 and D14 of YAZ-2919)

    /// "Set GIFs and memes folder…": the folder picker, then `useMediaFolder`.
    func chooseMediaFolder() {
        pickMediaFolder { [weak self] folder in
            guard let folder else { return }
            self?.useMediaFolder(folder)
        }
    }

    /// Moves `gifs/` and `memes/` into `folder` (copy, check, then remove the old copies), then uses it.
    /// The pref changes only after a move with no error. The preferences folder itself is the pref "".
    func useMediaFolder(_ folder: URL) {
        let isSame = folder.standardizedFileURL.path == store.folder.standardizedFileURL.path
        do {
            try library.useMediaFolder(folder)
        } catch {
            mediaMoveProblem = SettingsModel.mediaMoveText(error)
            refresh()
            return
        }
        prefs.mediaFolder = isSame ? "" : folder.path
        mediaMoveProblem = nil
        refresh()
    }

    /// "Reset to Same Folder…": the GIFs and memes go back into the preferences folder.
    /// Settings asks you to type "reset" first (D19).
    func useSameMediaFolder() {
        useMediaFolder(store.folder)
    }

    /// The red line of a failed move: the reason of the folder move, or the general text.
    static func mediaMoveText(_ error: Error) -> String {
        switch error {
        case is MediaFolder.DifferentFile, is MediaFolder.BadCopy, is MediaFolder.Missing:
            return "\(mediaNotMovedText) \(error.localizedDescription)"
        default:
            return mediaNotMovedText
        }
    }

    // MARK: The KLIPY key (D2 and D14 of YAZ-2919)

    /// Enter, a click outside the box, or a close of the window: the box goes into this Mac's Keychain.
    /// An empty box removes the key. The same key again changes nothing.
    func saveKlipyKey() {
        let key = KlipyKey.clean(klipyKeyText)
        if klipyKeyText != key { klipyKeyText = key }
        guard key != (keyStore.read() ?? "") else {
            klipyKeyProblem = nil
            return
        }
        do {
            try keyStore.write(key)
        } catch {
            klipyKeyProblem = SettingsModel.klipyKeyNotSavedText
            return
        }
        klipyKeyProblem = nil
        hasKlipyKey = !key.isEmpty
        onKlipyKeyChanged()
    }

    /// "Get a free key": the Partner Panel of KLIPY.
    func openKlipyKeyPage() {
        openURL(SettingsModel.klipyKeyURL)
    }

    // MARK: Start at login

    var loginItemIsAvailable: Bool { loginItem.isAvailable }

    /// The grey line below the switch.
    var loginItemNote: String? {
        loginItem.isAvailable ? nil : SettingsModel.loginItemNotAvailableText
    }

    /// The switch and the menu row. When macOS refuses the change, the switch goes back and the red line shows why.
    func setStartAtLogin(_ enabled: Bool) {
        guard loginItem.isAvailable else { return }
        do {
            try loginItem.setEnabled(enabled)
            loginItemProblem = nil
        } catch {
            loginItemProblem = error.localizedDescription
        }
        refresh()
        if startAtLogin != enabled, loginItemProblem == nil {
            // macOS gave no error, but the state is not the new one (for example, the user must approve the app).
            loginItemProblem = SettingsModel.loginItemNotChangedText
        }
    }

    // MARK: Accessibility

    var accessibilityText: String {
        accessibilityIsOn ? SettingsModel.accessibilityOnText : SettingsModel.accessibilityOffText
    }

    func openAccessibilitySettings() {
        openURL(SettingsModel.accessibilityURL)
    }

    /// Reads the real states again. The user can change them in System Settings while the app runs.
    func refresh() {
        startAtLogin = loginItem.isAvailable && loginItem.isEnabled
        accessibilityIsOn = access.isTrusted
        // The panel can hide an emoji while this window is closed.
        hiddenCount = store.hiddenCount
        let chosen = prefs.preferencesFolder
        folderIsDefault = chosen.isEmpty
        folderPath = chosen.isEmpty ? folders.defaultFolder.path : chosen
        // The store uses the default folder when the chosen folder was missing at the start.
        let isMissing = !chosen.isEmpty
            && store.folder.standardizedFileURL.path != URL(fileURLWithPath: chosen).standardizedFileURL.path
        folderProblem = folderWriteProblem ?? (isMissing ? PreferencesFolder.missingText : nil)
        mediaFolderIsSame = prefs.mediaFolder.isEmpty
        mediaFolderPath = library.mediaFolder.path
        mediaFolderProblem = mediaMoveProblem ?? (library.mediaFolderIsMissing ? MediaFolder.missingText : nil)
    }

    // MARK: Hidden from Your most used (D15)

    /// "Show them again": each hidden emoji comes back to "Your most used".
    func showHidden() {
        store.showHidden()
        hiddenCount = store.hiddenCount
    }

    // MARK: Forget learned words (D4)

    /// "Forget": clears `learned` and `added`. Your uses and the hidden emojis stay.
    /// Settings asks you to type "forget" first (D19).
    func forgetWords() {
        store.forgetWords()
        forgetNote = SettingsModel.forgottenText
    }

    // MARK: Type to confirm (D19)

    /// The buttons that you must confirm by typing a word.
    enum Danger: Equatable {
        /// "Reset to Mac Default Folder…", "Forget learned words…", "Reset to Same Folder…" (D14 of YAZ-2919).
        case reset, forget, resetMedia
        /// The word to type.
        var word: String { self == .forget ? "forget" : "reset" }
    }

    var isConfirmingForget: Bool { confirming == .forget }

    /// The first click: the row asks you to type the word.
    func ask(_ danger: Danger) {
        forgetNote = nil
        typedConfirmation = ""
        confirming = danger
    }

    func askToForget() { ask(.forget) }

    /// True when the box has the word, in any case, with no extra spaces.
    var canConfirm: Bool {
        guard let confirming else { return false }
        return typedConfirmation.trimmingCharacters(in: .whitespaces).lowercased() == confirming.word
    }

    /// The red button. It does nothing until the box has the word.
    func confirm() {
        guard canConfirm, let danger = confirming else { return }
        cancelConfirm()
        switch danger {
        case .reset: useThisMacOnly()
        case .forget: forgetWords()
        case .resetMedia: useSameMediaFolder()
        }
    }

    func cancelConfirm() {
        confirming = nil
        typedConfirmation = ""
    }

    func cancelForget() { cancelConfirm() }
}
