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
                                  folders: rig.folders, library: rig.library, keyStore: rig.klipyKey)
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
        // D14 update of YAZ-2919: GIFs on, Memes off.
        #expect(prefs.searchesKlipy(.gif) && !prefs.searchesKlipy(.meme))
        #expect(prefs.klipyChangedAt(.gif) == nil && prefs.klipyChangedAt(.meme) == nil)

        prefs.hotKey = controlOptionE
        prefs.pickMode = .copyOnly
        prefs.defaultTone = "\u{1F3FE}"
        prefs.askedForAccessibility = true
        prefs.setSearchesKlipy(false, for: .gif)
        prefs.setSearchesKlipy(true, for: .meme)
        let again = Prefs(defaults: defaults)
        #expect(!again.searchesKlipy(.gif) && again.searchesKlipy(.meme))
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

    /// D14 update of YAZ-2919 and D16: the KLIPY switches sync through two history files, and the newest change wins.
    /// Mac B's newer Memes change works on Mac A at the next open. Mac A's newer GIFs change beats Mac B's older one.
    /// Each Mac writes only its own file.
    @Test func theKLIPYSwitchesSyncAndTheNewestChangeWins() async throws {
        let rig = try PickRig()
        try rig.klipyKey.write("test-key")
        let app = AppController(hotKeys: FakeHotKeyRegistrar(), loginItem: FakeLoginItem(), parts: rig.parts(catalog: smallCatalog(5)))
        app.start()
        await app.ready?.value
        let session = try #require(app.session)
        #expect(app.settings.klipyGIFs && !app.settings.klipyMemes)
        session.open()
        session.select(tab: .memes)
        #expect(session.placeholder == "Search your memes")
        session.close()

        // Mac A: GIFs off, now.
        app.settings.setSearchesKlipy(false, for: .gif)
        #expect(!app.settings.klipyGIFs && !rig.prefs.searchesKlipy(.gif))
        #expect(app.store.own.settings.klipyGIFs?.value == false && rig.prefs.klipyChangedAt(.gif) != nil)

        // Mac B: GIFs on 2 hours ago, and Memes on 1 hour ago. A has no Memes change, so B's is the newest.
        // Whole seconds: the file keeps milliseconds.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var timeB = now.addingTimeInterval(-7_200)
        let macB = YouStore(url: rig.folder.defaultFolder.appendingPathComponent("you-B.json"), now: { timeB })
        macB.load()
        macB.setSearchesKlipy(true, for: .gif)
        timeB = now.addingTimeInterval(-3_600)
        macB.setSearchesKlipy(true, for: .meme)

        // The next open reads B's file. B's Memes change wins. A's GIFs change is newer than B's: it stays.
        session.open()
        #expect(app.settings.klipyMemes && rig.prefs.searchesKlipy(.meme) && rig.prefs.klipyChangedAt(.meme) == timeB)
        #expect(!app.settings.klipyGIFs && !rig.prefs.searchesKlipy(.gif))
        session.select(tab: .memes)
        #expect(session.placeholder == "Search KLIPY")
        session.select(tab: .gifs)
        #expect(session.placeholder == "Search your GIFs")
        session.close()
        #expect(app.store.own.settings.klipyMemes == nil)
        #expect(macB.own.settings.klipyGIFs?.value == true)

        // B turns Memes off a minute later. A's next open applies it. With no new change, nothing applies again.
        timeB = timeB.addingTimeInterval(60)
        macB.setSearchesKlipy(false, for: .meme)
        session.open()
        #expect(!app.settings.klipyMemes && !rig.prefs.searchesKlipy(.meme))
        session.select(tab: .memes)
        #expect(session.placeholder == "Search your memes")
        session.close()
        #expect(!app.store.reload())

        // A change on A after it wins over B, and goes into A's file only.
        app.settings.setSearchesKlipy(true, for: .meme)
        #expect(app.store.you.settings.klipyMemes?.value == true)
        let fileB = try YouStore.decoder.decode(You.self, from: Data(contentsOf: macB.url))
        #expect(fileB.settings.klipyMemes?.value == false)
    }

    /// D14 update of YAZ-2919: a history file of an older build has no KLIPY switches. It loads, and the switches
    /// keep the start values: GIFs on, Memes off.
    @Test func anOldHistoryFileWithNoKLIPYSwitchesGivesTheStartValues() throws {
        let rig = try PickRig()
        let old = #"{"settings": {"pickMode": {"value": "copyOnly", "at": "2026-10-16T10:00:00.000Z"}}, "uses": {}}"#
        try FileManager.default.createDirectory(at: rig.folder.youFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(old.utf8).write(to: rig.folder.youFile)
        rig.store.load()
        #expect(rig.store.movedBadFile == nil)
        #expect(rig.store.you.settings.pickMode?.value == "copyOnly")
        #expect(rig.store.you.settings.klipyGIFs == nil && rig.store.you.settings.klipyMemes == nil)
        let model = makeModel(rig, hotKeys: FakeHotKeyRegistrar())
        model.applySynced()
        #expect(model.pickMode == .copyOnly)
        #expect(model.klipyGIFs && !model.klipyMemes)
        #expect(rig.prefs.klipyChangedAt(.gif) == nil && rig.prefs.klipyChangedAt(.meme) == nil)
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
        #expect(menu.items.map(\.title) == ["Find an emoji", "Add a GIF or meme…", "", "Settings…", "Start at login", "", "Quit Yaseen Emoji"])
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
