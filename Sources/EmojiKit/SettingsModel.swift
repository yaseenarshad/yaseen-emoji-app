import AppKit
import Carbon.HIToolbox

/// Runs the slow file work of Settings, the copy and check of a folder move, and gives the result on the main
/// thread (item 16 of the v0.2 polish, YAZ-2929). The app runs the work off the main thread. A test runs it at once,
/// or when the test wants, so no test waits.
@MainActor
protocol FileWork: AnyObject {
    /// `done` gets nil after the work, or the error that it threw.
    func run(_ work: @escaping @Sendable () throws -> Void, done: @escaping @MainActor (Error?) -> Void)
}

/// The app's `FileWork`: a detached task, then `done` on the main actor.
@MainActor
final class BackgroundFileWork: FileWork {
    func run(_ work: @escaping @Sendable () throws -> Void, done: @escaping @MainActor (Error?) -> Void) {
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            switch result {
            case .success: done(nil)
            case .failure(let error): done(error)
            }
        }
    }
}

/// The state and the rules of the settings window, with no window and no view (D2, D8, D9, D10, D15, D16;
/// D4, D14, D16, D19 and D20 of YAZ-2919).
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
    static let folderNotMadeText = "Yaseen Emoji can't make this folder."
    /// The line of the folder row while its files move (item 16 of YAZ-2929).
    static let movingText = "Moving your files…"
    static let klipyKeyNote = "Without a key, you see only your own GIFs and memes."
    static let klipyKeyNotSavedText = "Yaseen Emoji can't keep the key in the Keychain."
    static let klipyKeySavedNote = "Saved in this Mac's Keychain. Use Change… or Remove… to edit it."
    static let klipyKeyEmptyText = "Paste a key first."
    static let klipyKeyRemoveQuestion = "This Mac stops searching KLIPY. Your own GIFs and memes stay. You can paste the key again later."
    /// The Partner Panel of KLIPY, where you make a free key ("API Keys").
    static let klipyKeyURL = URL(string: "https://partner.klipy.com/")!
    /// The Accessibility pane of System Settings.
    static let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// The page on the right (D19 of YAZ-2919). It starts on the page that you used last on this Mac.
    @Published private(set) var page: SettingsPage
    @Published private(set) var hotKey: HotKeyCombo
    /// True while the hotkey row waits for a key. The hotkey is off during that time.
    @Published private(set) var isRecording = false
    /// The red line below the hotkey row.
    @Published private(set) var hotKeyProblem: String?
    /// "After Enter" (D20 of YAZ-2919): the panel stays open after a paste, or closes.
    @Published private(set) var afterEnter: AfterEnter
    /// "When you press Enter" (D16 of YAZ-2919): the mode and "Keep it on the clipboard after a paste" of each kind.
    @Published private(set) var enter: [PickKind: EnterChoice] = [:]
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
    /// True when the chosen preferences folder is missing, and this Mac uses the default folder (D16).
    @Published private(set) var folderIsMissing = false
    /// The red line below the preferences folder: the folder is missing, or the app can't write into it.
    @Published private(set) var folderProblem: String?
    /// The GIFs and memes folder in use (D4 of YAZ-2919).
    @Published private(set) var mediaFolderPath = ""
    /// True when the GIFs and memes are in the preferences folder (the pref is "").
    @Published private(set) var mediaFolderIsSame = true
    /// True when the GIFs and memes folder that you chose is missing (D4 of YAZ-2919).
    @Published private(set) var mediaFolderIsMissing = false
    /// The red line below the GIFs and memes folder: the folder is missing, or a move failed.
    @Published private(set) var mediaFolderProblem: String?
    /// The folder row whose files move now, or nil (item 16 of YAZ-2929). The row shows `movingText`, and the buttons
    /// of both folder rows are off, so a second move can't start in the middle of the first.
    @Published private(set) var moving: FolderRow?
    /// The text of the KLIPY key box (D14 of YAZ-2919): what you typed. It never holds the saved key.
    @Published var klipyKeyText = ""
    /// True while the box is open after "Change…". A saved key is locked until then (Yaseen, 16 Oct 2026).
    @Published private(set) var isChangingKlipyKey = false
    /// True when this Mac's Keychain has a KLIPY key.
    @Published private(set) var hasKlipyKey = false
    /// The red line below the key box.
    @Published private(set) var klipyKeyProblem: String?
    /// "Search KLIPY in GIFs" and "Search KLIPY in Memes" (D14 update of YAZ-2919). They sync (D16).
    @Published private(set) var klipyGIFs: Bool
    @Published private(set) var klipyMemes: Bool

    /// The menu shows the hotkey, so the app must know each change.
    var onHotKeyChanged: (HotKeyCombo) -> Void = { _ in }
    /// The default tone changes the grid, so the panel must know.
    var onTonesChanged: () -> Void = {}
    /// Opens a URL. The app opens System Settings. A test keeps the URL.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// "Show in Finder" of the two folder rows (D19 of YAZ-2919): a Finder window with the contents of the folder.
    /// A test keeps the folder, so no test opens Finder.
    var openInFinder: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Asks for a folder and gives it, or nil on Cancel. The window shows the folder picker. A test gives a folder.
    var pickFolder: (@escaping (URL?) -> Void) -> Void = { $0(nil) }
    /// The same for "Set GIFs and memes folder…".
    var pickMediaFolder: (@escaping (URL?) -> Void) -> Void = { $0(nil) }
    /// The KLIPY key changed: the panel searches KLIPY with the new key, or stops.
    var onKlipyKeyChanged: () -> Void = {}
    /// A KLIPY switch changed, here or on a different Mac: the panel builds its GIFs and Memes tabs again.
    var onKlipySwitchChanged: () -> Void = {}

    private let prefs: Prefs
    private let hotKeys: HotKeyRegistering
    private let loginItem: LoginItem
    private let access: PasteAccess
    private let store: YouStore
    private let folders: PreferencesFolder
    /// The list of GIFs and memes. It moves with the preferences folder (D3, D4 of YAZ-2919).
    private let library: LibraryStore
    private let keyStore: KeyStore
    /// The copy and check of a folder move, off the main thread in the app.
    private let fileWork: FileWork
    /// The red line of a folder that the app could not write. The next refresh keeps it.
    private var folderWriteProblem: String?
    /// The red line of a move of the GIFs and memes that failed. The next refresh keeps it.
    private var mediaMoveProblem: String?

    init(prefs: Prefs, hotKeys: HotKeyRegistering, loginItem: LoginItem, access: PasteAccess, store: YouStore,
         folders: PreferencesFolder, library: LibraryStore, keyStore: KeyStore, fileWork: FileWork) {
        self.prefs = prefs
        self.hotKeys = hotKeys
        self.loginItem = loginItem
        self.access = access
        self.store = store
        self.folders = folders
        self.library = library
        self.keyStore = keyStore
        self.fileWork = fileWork
        page = prefs.settingsPage
        afterEnter = prefs.afterEnter
        hotKey = prefs.hotKey
        defaultTone = prefs.defaultTone
        klipyGIFs = prefs.searchesKlipy(.gif)
        klipyMemes = prefs.searchesKlipy(.meme)
        hasKlipyKey = !(keyStore.read() ?? "").isEmpty
        showEnter()
        refresh()
    }

    // MARK: The pages (D19 of YAZ-2919)

    /// A click in the list. The page is kept on this Mac only. A page change stops the hotkey recorder,
    /// the type-to-confirm box and "Change…" of the KLIPY key, the same as a close of the window:
    /// a recorder on a hidden page would keep the hotkey off and take the next key.
    func select(_ page: SettingsPage) {
        guard page != self.page else { return }
        cancelRecording()
        cancelConfirm()
        if isChangingKlipyKey { cancelChangingKlipyKey() }
        self.page = page
        prefs.settingsPage = page
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

    // MARK: When you press Enter (D2; D16, D20 of YAZ-2919) and the default skin tone (D9)

    /// "After Enter: Stay open | Close". The other Macs get it through this Mac's history file (D16).
    func setAfterEnter(_ value: AfterEnter) {
        guard value != prefs.afterEnter else { return }
        prefs.afterEnter = value
        prefs.afterEnterChangedAt = store.setAfterEnter(value.rawValue)
        afterEnter = value
    }

    /// The grey line below "After Enter".
    var afterEnterText: String { SettingsModel.afterEnterText(afterEnter) }

    static func afterEnterText(_ value: AfterEnter) -> String {
        switch value {
        case .stayOpen:
            return "Enter pastes, and the panel stays open for the next one. Shift+Enter pastes and closes. Esc closes."
        case .close:
            return "Enter pastes and closes. Shift+Enter pastes, and the panel stays open."
        }
    }

    /// What Enter does for one kind.
    struct EnterChoice: Equatable {
        var mode: PickMode
        /// "Keep it on the clipboard after a paste". It has no effect with Copy only.
        var keep: Bool
    }

    func choice(_ kind: PickKind) -> EnterChoice {
        enter[kind] ?? stored(kind)
    }

    /// "Paste | Copy only" of one kind. The other Macs get it through this Mac's history file (D16).
    func setPickMode(_ mode: PickMode, for kind: PickKind) {
        guard mode != prefs.pickMode(kind) else { return }
        prefs.setPickMode(mode, for: kind)
        prefs.setPickModeChangedAt(store.setPickMode(mode.rawValue, for: kind), for: kind)
        showEnter()
    }

    /// "Keep it on the clipboard after a paste" of one kind. Copy only always keeps, so the switch is off there.
    func setKeepsOnClipboard(_ keep: Bool, for kind: PickKind) {
        guard keep != prefs.keepsOnClipboard(kind) else { return }
        prefs.setKeepsOnClipboard(keep, for: kind)
        prefs.setKeepChangedAt(store.setKeepsOnClipboard(keep, for: kind), for: kind)
        showEnter()
    }

    /// The grey line below "When you press Enter": what Enter does now, with the kinds that do the same thing.
    var enterText: String {
        SettingsModel.enterText(PickKind.allCases.map { (kind: $0, choice: choice($0)) })
    }

    static func enterText(_ choices: [(kind: PickKind, choice: EnterChoice)]) -> String {
        let ways: [(text: String, test: (EnterChoice) -> Bool)] = [
            ("paste and stay on the clipboard.", { $0.mode == .paste && $0.keep }),
            ("paste, then your old clipboard comes back.", { $0.mode == .paste && !$0.keep }),
            ("copy only. You paste with ⌘V.", { $0.mode == .copyOnly }),
        ]
        return ways.compactMap { way -> String? in
            let names = choices.filter { way.test($0.choice) }.map(\.kind.name)
            guard let last = names.last else { return nil }
            let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
            return list.prefix(1).uppercased() + list.dropFirst() + " " + way.text
        }.joined(separator: " ")
    }

    private func stored(_ kind: PickKind) -> EnterChoice {
        EnterChoice(mode: prefs.pickMode(kind), keep: prefs.keepsOnClipboard(kind))
    }

    private func showEnter() {
        enter = Dictionary(uniqueKeysWithValues: PickKind.allCases.map { ($0, stored($0)) })
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
        // An old file has no `afterEnter`: this Mac keeps its value, or the start value Stay open.
        if let after = synced.afterEnter, isNewer(after.at, than: prefs.afterEnterChangedAt),
           let value = AfterEnter(rawValue: after.value) {
            prefs.afterEnter = value
            prefs.afterEnterChangedAt = after.at
            afterEnter = value
        }
        for kind in PickKind.allCases {
            // A kind with no value of its own uses the v0.1 `pickMode`, so an old file still gives its mode.
            if let mode = synced.pickMode(kind), isNewer(mode.at, than: prefs.pickModeChangedAt(kind)),
               let value = PickMode(rawValue: mode.value) {
                prefs.setPickMode(value, for: kind)
                prefs.setPickModeChangedAt(mode.at, for: kind)
            }
            if let keep = synced.keepOnClipboard?[kind.rawValue], isNewer(keep.at, than: prefs.keepChangedAt(kind)) {
                prefs.setKeepsOnClipboard(keep.value, for: kind)
                prefs.setKeepChangedAt(keep.at, for: kind)
            }
        }
        showEnter()
        if let tone = synced.defaultTone, isNewer(tone.at, than: prefs.defaultToneChangedAt),
           SkinTone.all.contains(tone.value) {
            prefs.defaultTone = tone.value
            prefs.defaultToneChangedAt = tone.at
            if defaultTone != tone.value {
                defaultTone = tone.value
                onTonesChanged()
            }
        }
        for kind in ItemKind.allCases {
            if let synced = synced[keyPath: You.Settings.klipy(kind)], isNewer(synced.at, than: prefs.klipyChangedAt(kind)) {
                let changed = synced.value != prefs.searchesKlipy(kind)
                prefs.setSearchesKlipy(synced.value, for: kind)
                prefs.setKlipyChangedAt(synced.at, for: kind)
                showKlipySwitch(kind)
                if changed { onKlipySwitchChanged() }
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
    /// When the GIFs and memes are in the preferences folder, they move too (D4 of YAZ-2919), off the main thread.
    /// During that move, the GIFs and memes folder is the old folder, where all the files still are. If the move fails,
    /// they stay there, and the GIFs and memes folder stays the old folder, so no file is lost.
    func usePreferencesFolder(_ folder: URL) {
        guard moving == nil else { return }
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
            prefs.mediaFolder = library.mediaFolder.path
            moveMedia(to: folder, row: .preferences) { [weak self] error in
                guard let self else { return }
                if let error {
                    mediaMoveProblem = SettingsModel.mediaMoveText(error)
                } else {
                    prefs.mediaFolder = ""
                    mediaMoveProblem = nil
                }
                refresh()
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

    /// "Show in Finder" of the preferences folder (D19 of YAZ-2919): the folder of this Mac's history file.
    /// A missing folder is made first. A chosen folder that is missing is not made: the row shows the red line.
    func showPreferencesFolder() {
        guard !folderIsMissing else { return }
        if makeAndOpen(store.folder) {
            if folderWriteProblem == SettingsModel.folderNotMadeText { folderWriteProblem = nil }
        } else {
            folderWriteProblem = SettingsModel.folderNotMadeText
        }
        refresh()
    }

    /// Makes `folder` when it is missing, with its parent folders, then opens it in Finder.
    /// Returns false when the app can't make it.
    private func makeAndOpen(_ folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return false
        }
        openInFinder(folder)
        return true
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
        guard moving == nil else { return }
        let isSame = folder.standardizedFileURL.path == store.folder.standardizedFileURL.path
        moveMedia(to: folder, row: .media) { [weak self] error in
            guard let self else { return }
            if let error {
                mediaMoveProblem = SettingsModel.mediaMoveText(error)
            } else {
                prefs.mediaFolder = isSame ? "" : folder.path
                mediaMoveProblem = nil
            }
            refresh()
        }
    }

    /// The two folder rows (item 16 of YAZ-2929).
    enum FolderRow: Equatable {
        case preferences, media
    }

    /// Copies and checks the files of `gifs/` and `memes/` off the main thread (`MediaFolder.move`). Then, on the main
    /// actor, the list uses the new folder after a move with no error, and `done` gets the result.
    private func moveMedia(to folder: URL, row: FolderRow, done: @escaping @MainActor (Error?) -> Void) {
        let old = library.mediaFolder
        moving = row
        fileWork.run({ try MediaFolder.move(from: old, to: folder) }, done: { [weak self] error in
            guard let self else { return }
            if error == nil { library.mediaFolderMoved(to: folder) }
            moving = nil
            done(error)
        })
    }

    /// "Reset to Same Folder…": the GIFs and memes go back into the preferences folder.
    /// Settings asks you to type "reset" first (D19).
    func useSameMediaFolder() {
        useMediaFolder(store.folder)
    }

    /// "Show in Finder" of the GIFs and memes folder (D19 of YAZ-2919): the folder of `gifs/` and `memes/`.
    /// The same rules as `showPreferencesFolder`. A chosen folder that is missing is not made (D4): an empty folder
    /// in its place would split the files.
    func showMediaFolder() {
        guard !library.mediaFolderIsMissing else { return }
        if makeAndOpen(library.mediaFolder) {
            if mediaMoveProblem == SettingsModel.folderNotMadeText { mediaMoveProblem = nil }
        } else {
            mediaMoveProblem = SettingsModel.folderNotMadeText
        }
        refresh()
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

    // The key row is locked when a key is saved (D14 update of YAZ-2919). Only "Save" (or Enter in the box) writes
    // the key. A click outside the box or a close of the window changes nothing.

    /// "Change…": opens an empty box. The saved key stays until "Save".
    func startChangingKlipyKey() {
        cancelConfirm()
        klipyKeyText = ""
        klipyKeyProblem = nil
        isChangingKlipyKey = true
    }

    /// "Cancel": closes the box with no change.
    func cancelChangingKlipyKey() {
        klipyKeyText = ""
        klipyKeyProblem = nil
        isChangingKlipyKey = false
    }

    /// "Save" or Enter: the box goes into this Mac's Keychain. An empty box saves nothing: "Remove…" removes a key.
    func saveKlipyKey() {
        let key = KlipyKey.clean(klipyKeyText)
        guard !key.isEmpty else {
            klipyKeyProblem = SettingsModel.klipyKeyEmptyText
            return
        }
        do {
            try keyStore.write(key)
        } catch {
            klipyKeyProblem = SettingsModel.klipyKeyNotSavedText
            return
        }
        klipyKeyText = ""
        klipyKeyProblem = nil
        isChangingKlipyKey = false
        hasKlipyKey = true
        onKlipyKeyChanged()
    }

    /// "Remove…", after you type "remove" (D19 of YAZ-2894).
    func removeKlipyKey() {
        do {
            try keyStore.write("")
        } catch {
            klipyKeyProblem = SettingsModel.klipyKeyNotSavedText
            return
        }
        klipyKeyProblem = nil
        isChangingKlipyKey = false
        hasKlipyKey = false
        onKlipyKeyChanged()
    }

    // MARK: The KLIPY switches (D14 update of YAZ-2919)

    /// The switch of the tab of `kind`.
    func searchesKlipy(_ kind: ItemKind) -> Bool {
        kind == .gif ? klipyGIFs : klipyMemes
    }

    /// "Search KLIPY in GIFs" or "Search KLIPY in Memes". A tab with its switch off sends no request and shows
    /// only your own files. The other Macs get the change through this Mac's history file (D16).
    func setSearchesKlipy(_ on: Bool, for kind: ItemKind) {
        guard on != searchesKlipy(kind) else { return }
        prefs.setSearchesKlipy(on, for: kind)
        prefs.setKlipyChangedAt(store.setSearchesKlipy(on, for: kind), for: kind)
        showKlipySwitch(kind)
        onKlipySwitchChanged()
    }

    private func showKlipySwitch(_ kind: ItemKind) {
        switch kind {
        case .gif: klipyGIFs = prefs.searchesKlipy(.gif)
        case .meme: klipyMemes = prefs.searchesKlipy(.meme)
        }
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
        folderIsMissing = isMissing
        folderProblem = folderWriteProblem ?? (isMissing ? PreferencesFolder.missingText : nil)
        mediaFolderIsSame = prefs.mediaFolder.isEmpty
        mediaFolderPath = library.mediaFolder.path
        mediaFolderIsMissing = library.mediaFolderIsMissing
        mediaFolderProblem = mediaMoveProblem ?? (mediaFolderIsMissing ? MediaFolder.missingText : nil)
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
        /// "Remove…" of the KLIPY key.
        case removeKey
        /// The word to type.
        var word: String {
            switch self {
            case .forget: return "forget"
            case .removeKey: return "remove"
            case .reset, .resetMedia: return "reset"
            }
        }
    }

    var isConfirmingForget: Bool { confirming == .forget }

    /// The first click: the row asks you to type the word.
    func ask(_ danger: Danger) {
        forgetNote = nil
        typedConfirmation = ""
        confirming = danger
    }

    func askToForget() { ask(.forget) }

    /// True when the box has the word, in any case, with no extra spaces. A folder reset also waits for a move that runs.
    var canConfirm: Bool {
        guard let confirming else { return false }
        if moving != nil, confirming == .reset || confirming == .resetMedia { return false }
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
        case .removeKey: removeKlipyKey()
        }
    }

    func cancelConfirm() {
        confirming = nil
        typedConfirmation = ""
    }

    func cancelForget() { cancelConfirm() }
}
