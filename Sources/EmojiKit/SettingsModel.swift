import AppKit
import Carbon.HIToolbox

/// The state and the rules of the settings window, with no window and no view (D2, D8, D9, D10, D15).
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
    static let forgetQuestion = "Forget all learned and added words? Your most used stays."
    static let forgottenText = "The learned words are gone."
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
    /// True while the row "Forget learned words" asks to confirm.
    @Published private(set) var isConfirmingForget = false
    /// The grey line after "Forget".
    @Published private(set) var forgetNote: String?
    /// The emojis hidden from "Your most used" (D15).
    @Published private(set) var hiddenCount = 0

    /// The menu shows the hotkey, so the app must know each change.
    var onHotKeyChanged: (HotKeyCombo) -> Void = { _ in }
    /// The default tone changes the grid, so the panel must know.
    var onTonesChanged: () -> Void = {}
    /// Opens a URL. The app opens System Settings. A test keeps the URL.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private let prefs: Prefs
    private let hotKeys: HotKeyRegistering
    private let loginItem: LoginItem
    private let access: PasteAccess
    private let store: YouStore

    init(prefs: Prefs, hotKeys: HotKeyRegistering, loginItem: LoginItem, access: PasteAccess, store: YouStore) {
        self.prefs = prefs
        self.hotKeys = hotKeys
        self.loginItem = loginItem
        self.access = access
        self.store = store
        hotKey = prefs.hotKey
        pickMode = prefs.pickMode
        defaultTone = prefs.defaultTone
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
        pickMode = mode
    }

    func setDefaultTone(_ tone: String) {
        guard SkinTone.all.contains(tone) else { return }
        prefs.defaultTone = tone
        defaultTone = tone
        onTonesChanged()
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
    }

    // MARK: Hidden from Your most used (D15)

    /// "Show them again": each hidden emoji comes back to "Your most used".
    func showHidden() {
        store.showHidden()
        hiddenCount = store.hiddenCount
    }

    // MARK: Forget learned words (D4)

    /// The first click on "Forget learned words": the row asks to confirm.
    func askToForget() {
        forgetNote = nil
        isConfirmingForget = true
    }

    func cancelForget() {
        isConfirmingForget = false
    }

    /// "Forget": clears `learned` and `added`. Your uses and the hidden emojis stay.
    func forgetWords() {
        store.forgetWords()
        isConfirmingForget = false
        forgetNote = SettingsModel.forgottenText
    }
}
