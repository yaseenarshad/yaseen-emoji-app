import AppKit
import Carbon.HIToolbox
import Testing
@testable import EmojiKit

/// Prefs, Settings, the menu and the hotkey (YAZ-2900). No test here makes a window or takes a real hotkey.
@MainActor
@Suite struct SettingsTests {
    private let commandE = HotKeyCombo(keyCode: UInt32(kVK_ANSI_E), modifiers: .command)
    private let controlOptionE = HotKeyCombo(keyCode: UInt32(kVK_ANSI_E), modifiers: [.control, .option])
    private let commandK = HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: .command)

    private func makeModel(_ rig: PickRig, hotKeys: FakeHotKeyRegistrar, loginItem: FakeLoginItem = FakeLoginItem()) -> SettingsModel {
        let model = SettingsModel(prefs: rig.prefs, hotKeys: hotKeys, loginItem: loginItem, access: rig.access, store: rig.store,
                                  folders: rig.folders)
        model.registerHotKey()
        return model
    }

    /// The start values, a save and a load, and broken values that give the start values.
    @Test func prefsSaveAndLoad() {
        let defaults = MemoryDefaults()
        let prefs = Prefs(defaults: defaults)
        #expect(prefs.hotKey == commandE)
        #expect(prefs.hotKey.keyCode == 14 && prefs.hotKey.modifiers == .command)
        #expect(prefs.pickMode == .paste)
        #expect(prefs.defaultTone == "")
        #expect(!prefs.askedForAccessibility)

        prefs.hotKey = controlOptionE
        prefs.pickMode = .copyOnly
        prefs.defaultTone = "\u{1F3FE}"
        prefs.askedForAccessibility = true
        let again = Prefs(defaults: defaults)
        #expect(again.hotKey == controlOptionE)
        #expect(again.pickMode == .copyOnly)
        #expect(again.defaultTone == "\u{1F3FE}")
        #expect(again.askedForAccessibility)

        // Broken values: a key with no modifier, a code past one byte, an unknown mode, a tone that is not a tone.
        defaults.set(Int(kVK_ANSI_E), forKey: "yaseenEmoji.hotKeyCode")
        defaults.set(0, forKey: "yaseenEmoji.hotKeyModifiers")
        defaults.set("type it", forKey: "yaseenEmoji.pickMode")
        defaults.set("x", forKey: "yaseenEmoji.defaultTone")
        #expect(again.hotKey == commandE)
        #expect(again.pickMode == .paste)
        #expect(again.defaultTone == "")
        defaults.set(300, forKey: "yaseenEmoji.hotKeyCode")
        defaults.set(Int(NSEvent.ModifierFlags.command.rawValue), forKey: "yaseenEmoji.hotKeyModifiers")
        #expect(again.hotKey == commandE)
    }

    /// A new key works at once. A key that macOS refuses keeps the old key, with the red line (D8).
    @Test func aRefusedHotKeyKeepsTheOldKey() throws {
        let rig = try PickRig()
        let hotKeys = FakeHotKeyRegistrar()
        let model = makeModel(rig, hotKeys: hotKeys)
        var told: [String] = []
        model.onHotKeyChanged = { told.append($0.text) }
        #expect(hotKeys.registered == [.findEmoji: commandE])

        // Another app has ⌃⌥E.
        hotKeys.refused = [controlOptionE]
        model.startRecording()
        // The recorder stops the hotkey, so it also gets ⌘E.
        #expect(hotKeys.registered.isEmpty)
        #expect(model.keyDown(controlOptionE))
        #expect(model.hotKeyProblem == "This key is in use. Pick a different key.")
        #expect(model.hotKey == commandE)
        #expect(hotKeys.registered == [.findEmoji: commandE])
        #expect(rig.prefs.hotKey == commandE)
        #expect(told.isEmpty)

        // A key with no ⌘, ⌃ or ⌥ is refused by the app, and the old key stays.
        model.startRecording()
        #expect(model.keyDown(HotKeyCombo(keyCode: UInt32(kVK_ANSI_E), modifiers: [])))
        #expect(model.hotKeyProblem == SettingsModel.needsModifierText)
        #expect(hotKeys.registered == [.findEmoji: commandE])

        // Esc stops the recorder with no change.
        model.startRecording()
        #expect(model.keyDown(HotKeyCombo(keyCode: UInt32(kVK_Escape), modifiers: [])))
        #expect(!model.isRecording && hotKeys.registered == [.findEmoji: commandE])

        // A free key works at once, with no restart, and is stored.
        model.startRecording()
        #expect(model.keyDown(commandK))
        #expect(model.hotKeyProblem == nil)
        #expect(hotKeys.registered == [.findEmoji: commandK])
        #expect(Prefs(defaults: rig.defaults).hotKey == commandK)
        #expect(told == ["⌘K"])
        // Not recording: the model does not take the key.
        #expect(!model.keyDown(commandE))
    }

    /// "Forget learned words" asks one time, then calls `forgetWords`: the uses and the hidden emojis stay (D4).
    /// "Show them again" brings the hidden emojis back (D15).
    @Test func forgetLearnedWordsCallsForgetWords() throws {
        let rig = try PickRig()
        rig.store.recordPick("🚀", query: "ship")
        rig.store.addWord("blastoff", to: "🚀")
        rig.store.recordPick("👍", query: "")
        rig.store.hide("👍")
        let model = makeModel(rig, hotKeys: FakeHotKeyRegistrar())

        model.askToForget()
        #expect(model.isConfirmingForget)
        model.cancelForget()
        #expect(rig.store.you.learnedPairs == 1)

        // D19: the red button does nothing until you type "forget".
        model.askToForget()
        model.typedConfirmation = "forgot"
        model.confirm()
        #expect(model.isConfirmingForget && rig.store.you.learnedPairs == 1)
        model.typedConfirmation = " Forget "
        model.confirm()
        #expect(!model.isConfirmingForget)
        #expect(model.forgetNote == SettingsModel.forgottenText)
        let saved = YouStore(url: rig.folder.youFile)
        saved.load()
        #expect(saved.you.learned.isEmpty && saved.you.added.isEmpty)
        #expect(saved.you.uses[You.key("🚀")]?.count == 1)
        #expect(saved.hiddenCount == 1)

        // The panel hid one more emoji while Settings was closed: the row reads it again.
        rig.store.hide("🚀")
        model.refresh()
        #expect(model.hiddenCount == 2)
        model.showHidden()
        #expect(model.hiddenCount == 0 && rig.store.hiddenCount == 0)
    }

    /// The menu (D10), the hotkey that opens and closes the panel (D8), and the first launch.
    @Test func theHotKeyOpensAndClosesThePanel() async throws {
        let rig = try PickRig(trusted: false)
        let hotKeys = FakeHotKeyRegistrar()
        let loginItem = FakeLoginItem()
        let app = AppController(hotKeys: hotKeys, loginItem: loginItem, parts: rig.parts(catalog: smallCatalog(20)))
        var settingsOpened = 0
        app.openSettings = { settingsOpened += 1 }
        app.start()
        #expect(hotKeys.registered == [.findEmoji: commandE])
        #expect(app.statusMenu.statusItem == nil)

        // The rows, and the hotkey on "Find an emoji".
        let menu = app.statusMenu.menu
        #expect(menu.items.map(\.title) == ["Find an emoji", "", "Settings…", "Start at login", "", "Quit Yaseen Emoji"])
        let find = try #require(menu.item(withTitle: "Find an emoji"))
        #expect(find.keyEquivalent == "e" && find.keyEquivalentModifierMask == .command)

        // The hotkey before the catalog is ready: the panel opens when it is ready, one time.
        hotKeys.press(commandE)
        #expect(app.session == nil && app.opensWhenReady)
        await app.ready?.value
        let session = try #require(app.session)
        #expect(session.isOpen)
        #expect(rig.panel.calls == ["show"])

        // The hotkey again closes the panel, and opens it again.
        hotKeys.press(commandE)
        #expect(!session.isOpen)
        hotKeys.press(commandE)
        #expect(session.isOpen)
        #expect(rig.panel.calls == ["show", "hide", "show"])
        // The menu row always opens: the panel can still be open behind the menu.
        click(find)
        #expect(session.isOpen)
        click(find)
        #expect(session.isOpen)
        hotKeys.press(commandE)
        #expect(!session.isOpen)

        // The first launch asks for Accessibility one time. A second launch does not ask again.
        #expect(rig.access.asks == 1)
        let second = AppController(hotKeys: FakeHotKeyRegistrar(), loginItem: loginItem, parts: rig.parts(catalog: []))
        second.start()
        #expect(rig.access.asks == 1)

        // "Settings…" and "Start at login".
        click(try #require(menu.item(withTitle: "Settings…")))
        #expect(settingsOpened == 1)
        let login = try #require(menu.item(withTitle: "Start at login"))
        #expect(login.state == .off)
        click(login)
        #expect(loginItem.calls == [true])
        #expect(login.state == .on)

        // A new hotkey in Settings shows on the menu row, and the old key does nothing.
        app.settings.startRecording()
        _ = app.settings.keyDown(commandK)
        #expect(find.keyEquivalent == "k")
        hotKeys.press(commandE)
        #expect(!session.isOpen)
        hotKeys.press(commandK)
        #expect(session.isOpen)
        hotKeys.press(commandK)
        #expect(!session.isOpen)
    }
}
