import AppKit
import Testing
import UniformTypeIdentifiers
@testable import EmojiKit

/// D16 of YAZ-2919: "When you press Enter" for each kind (Paste | Copy only), and "Keep it on the clipboard after
/// a paste". The fakes keep the clipboard, the keys and the clock. No test touches the real clipboard.
@MainActor
@Suite struct EnterTests {
    /// The one clipboard item of a GIF (D6 of YAZ-2919), with or without the transient mark.
    private func gifItem(_ url: URL, transient: Bool) throws -> ClipboardContents {
        ClipboardContents(items: [.init(values: [
            ("public.file-url", Data(url.absoluteString.utf8)),
            (UTType.gif.identifier, try Data(contentsOf: url)),
        ] + (transient ? [("org.nspasteboard.TransientType", Data())] : []))])
    }

    /// The start values: Paste and Keep for all three kinds. An emoji pick pastes, and the emoji stays on the
    /// clipboard with no transient mark. No restore waits.
    @Test func theStartValuesPasteAndKeep() throws {
        let rig = try PickRig()
        let model = rig.settingsModel()
        for kind in PickKind.allCases {
            #expect(model.choice(kind) == SettingsModel.EnterChoice(mode: .paste, keep: true))
        }
        #expect(model.enterText == "Emojis, GIFs and memes paste and stay on the clipboard.")

        rig.session.open()
        rig.session.setQuery("rocket")
        try rig.select("🚀")
        rig.session.enter(shift: false)
        #expect(!rig.session.isOpen)
        #expect(rig.clipboard.contents == .text("🚀") && !rig.clipboard.lastWriteIsTransient)
        rig.later.advance(by: Paster.postDelay)
        #expect(rig.keys.sent == [Paster.pasteKey])
        // The ⌘V and the come-back step are the last work. Nothing waits for a restore.
        rig.later.advance(by: Paster.comeBackDelay)
        #expect(rig.later.isEmpty)
        rig.later.advance(by: Paster.fileRestoreDelay)
        #expect(rig.clipboard.contents == .text("🚀") && rig.clipboard.restores == 0)
        #expect(rig.store.you.uses[You.key("🚀")]?.count == 1)
    }

    /// Keep on for a GIF: the file stays on the clipboard after the 1.0 s of a restore, with no transient mark.
    /// Shift+Enter (paste, stay open) keeps it too, and the panel comes back.
    @Test func keepOnLeavesTheGIFOnTheClipboard() throws {
        let rig = try PickRig()
        let gif = try rig.addOwn(words: ["dance"])
        let url = try #require(rig.library.fileURL(of: gif))
        let kept = try gifItem(url, transient: false)
        rig.session.open()
        rig.session.select(tab: .gifs)
        rig.session.enter(shift: false)
        #expect(rig.clipboard.contents == kept)
        rig.later.advance(by: Paster.postDelay + Paster.fileRestoreDelay + 0.1)
        #expect(rig.keys.sent == [Paster.pasteKey])
        #expect(rig.clipboard.contents == kept && rig.clipboard.restores == 0 && rig.later.isEmpty)

        rig.clipboard.userCopies("my text")
        rig.session.open()
        rig.session.select(tab: .gifs)
        rig.session.enter(shift: true)
        #expect(rig.session.isOpen && rig.panel.calls.last == "makeWay")
        rig.later.runAll()
        #expect(rig.panel.calls.last == "comeBack" && rig.keys.sent.count == 2)
        #expect(rig.clipboard.contents == kept && rig.clipboard.restores == 0)
    }

    /// Copy only: the Keep value has no effect. With Keep on or off, Enter posts no ⌘V, writes no transient mark,
    /// and brings back no old clipboard. The switch shows off.
    @Test func copyOnlyIgnoresKeep() throws {
        for keep in [true, false] {
            let rig = try PickRig()
            rig.setEnter(.copyOnly, keep: keep)
            rig.session.open()
            rig.session.setQuery("fire")
            try rig.select("🔥")
            rig.session.enter(shift: false)
            rig.later.runAll()
            #expect(rig.keys.sent.isEmpty && !rig.clipboard.lastWriteIsTransient)
            #expect(rig.clipboard.contents == .text("🔥") && rig.clipboard.restores == 0)
            #expect(rig.settingsModel().enterText == "Emojis, GIFs and memes copy only. You paste with ⌘V.")
        }
    }

    /// Each kind has its own row: emojis with Keep off get the restore of D2 after 0.3 s, GIFs with Keep on stay,
    /// and memes with Copy only post no ⌘V. A Keep pick in the wait of an emoji restore stops that restore.
    @Test func eachKindUsesItsOwnRow() throws {
        let rig = try PickRig()
        let model = rig.settingsModel()
        model.setKeepsOnClipboard(false, for: .emoji)
        model.setPickMode(.copyOnly, for: .meme)
        #expect(model.choice(.emoji) == SettingsModel.EnterChoice(mode: .paste, keep: false))
        #expect(model.choice(.gif) == SettingsModel.EnterChoice(mode: .paste, keep: true))
        #expect(model.choice(.meme).mode == .copyOnly)
        #expect(model.enterText == "GIFs paste and stay on the clipboard. Emojis paste, then your old clipboard comes back. "
            + "Memes copy only. You paste with ⌘V.")
        let gif = try rig.addOwn(words: ["dance"])
        let meme = try rig.addOwn(.meme, words: ["fine"])
        let gifURL = try #require(rig.library.fileURL(of: gif))

        // An emoji: transient, then the old clipboard comes back after 0.3 s.
        rig.session.open()
        rig.session.setQuery("rocket")
        try rig.select("🚀")
        rig.session.enter(shift: false)
        #expect(rig.clipboard.lastWriteIsTransient)
        rig.later.advance(by: Paster.postDelay + Paster.restoreDelay)
        #expect(rig.clipboard.contents == FakeClipboard.rich && rig.clipboard.restores == 1)

        // A GIF: no transient mark, and it stays.
        rig.session.open()
        rig.session.select(tab: .gifs)
        rig.session.setQuery("dance")
        rig.session.enter(shift: false)
        rig.later.runAll()
        #expect(rig.clipboard.contents == (try gifItem(gifURL, transient: false)) && rig.clipboard.restores == 1)
        #expect(rig.keys.sent.count == 2)

        // A meme: copy only.
        rig.session.open()
        rig.session.select(tab: .memes)
        rig.session.setQuery("fine")
        rig.session.enter(shift: false)
        rig.later.runAll()
        #expect(rig.keys.sent.count == 2 && !rig.clipboard.lastWriteIsTransient)
        #expect(rig.clipboard.contents.items.first?.values.contains { $0.type == UTType.png.identifier } == true)
        #expect(rig.store.you.uses[meme.key]?.count == 1)

        // An emoji pick, then a GIF pick in its 0.3 s wait: the GIF stays, and the emoji restore does nothing.
        rig.session.open()
        rig.session.select(tab: .emoji)
        rig.session.setQuery("rocket")
        try rig.select("🚀")
        rig.session.enter(shift: false)
        rig.later.advance(by: Paster.postDelay)
        rig.session.open()
        rig.session.select(tab: .gifs)
        rig.session.setQuery("dance")
        rig.session.enter(shift: false)
        rig.later.runAll()
        #expect(rig.clipboard.contents == (try gifItem(gifURL, transient: false)) && rig.clipboard.restores == 1)
    }

    /// No Accessibility, or a password field: copy only, with Keep on or off (D2).
    @Test func noAccessibilityCopiesOnly() throws {
        let rig = try PickRig(trusted: false)
        rig.setEnter(.paste, keep: false)
        rig.session.open()
        rig.session.setQuery("rocket")
        try rig.select("🚀")
        rig.session.enter(shift: false)
        rig.later.runAll()
        #expect(rig.keys.sent.isEmpty && !rig.clipboard.lastWriteIsTransient && rig.clipboard.restores == 0)
        #expect(rig.clipboard.contents == .text("🚀"))
    }

    /// The six values sync through the history files (D16), and the newest change wins for each kind and value.
    /// Mac B's newer GIF change works on Mac A at the next open, and a GIF pick on A then uses it.
    /// Mac A's newer meme change beats Mac B's older one. Each Mac writes only its own file.
    @Test func theEnterChoicesSyncAndTheNewestChangeWins() async throws {
        let rig = try PickRig()
        let gif = try rig.addOwn(words: ["dance"])
        let app = AppController(hotKeys: FakeHotKeyRegistrar(), loginItem: FakeLoginItem(), parts: rig.parts(catalog: smallCatalog(5)))
        app.start()
        await app.ready?.value
        let session = try #require(app.session)

        // Mac A: Keep off for memes, now.
        app.settings.setKeepsOnClipboard(false, for: .meme)
        #expect(app.store.own.settings.keepOnClipboard?["meme"]?.value == false && rig.prefs.keepChangedAt(.meme) != nil)

        // Mac B: Keep on for memes 2 hours ago, and Keep off for GIFs 1 hour ago. Whole seconds: the file keeps milliseconds.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var timeB = now.addingTimeInterval(-7_200)
        let macB = YouStore(url: rig.folder.defaultFolder.appendingPathComponent("you-B.json"), now: { timeB })
        macB.load()
        macB.setKeepsOnClipboard(true, for: .meme)
        timeB = now.addingTimeInterval(-3_600)
        macB.setKeepsOnClipboard(false, for: .gif)

        // The next open reads B's file. B's GIF change wins. A's meme change is newer: it stays.
        session.open()
        #expect(app.settings.choice(.gif).keep == false && rig.prefs.keepChangedAt(.gif) == timeB)
        #expect(app.settings.choice(.meme).keep == false && app.settings.choice(.emoji).keep)
        // A GIF pick on A now gets the restore of D2.
        session.select(tab: .gifs)
        session.setQuery("dance")
        #expect(session.selectedItem == .own(gif))
        session.enter(shift: false)
        #expect(rig.clipboard.lastWriteIsTransient)
        rig.later.runAll()
        #expect(rig.clipboard.restores == 1 && rig.clipboard.contents == FakeClipboard.rich)

        // B sets Copy only for emojis a minute later. A's next open applies it. With no new change, nothing applies again.
        timeB = timeB.addingTimeInterval(60)
        macB.setPickMode(PickMode.copyOnly.rawValue, for: .emoji)
        session.open()
        #expect(app.settings.choice(.emoji).mode == .copyOnly && rig.prefs.pickMode(.emoji) == .copyOnly)
        #expect(rig.prefs.pickMode(.gif) == .paste && rig.prefs.pickMode(.meme) == .paste)
        session.close()
        #expect(!app.store.reload())

        // Each Mac's file has only its own changes.
        #expect(app.store.own.settings.keepOnClipboard?.keys.sorted() == ["meme"] && app.store.own.settings.pickModes == nil)
        let fileB = try YouStore.decoder.decode(You.self, from: Data(contentsOf: macB.url))
        #expect(fileB.settings.keepOnClipboard?["meme"]?.value == true && fileB.settings.pickModes?["emoji"]?.value == "copyOnly")
    }

    /// `You.merge` keeps the newest change of each kind, from any file.
    @Test func theMergeKeepsTheNewestChangeOfEachKind() {
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        var own = You(), other = You()
        own.settings.pickModes = ["gif": You.Dated("copyOnly", at: late), "emoji": You.Dated("paste", at: early)]
        other.settings.pickModes = ["gif": You.Dated("paste", at: early), "emoji": You.Dated("copyOnly", at: late)]
        other.settings.keepOnClipboard = ["meme": You.Dated(false, at: early)]
        let merged = You.merge(own: own, others: [other]).settings
        #expect(merged.pickModes?["gif"]?.value == "copyOnly" && merged.pickModes?["emoji"]?.value == "copyOnly")
        #expect(merged.keepOnClipboard == ["meme": You.Dated(false, at: early)])
        #expect(merged.pickMode(.meme) == nil)
    }

    /// An old history file with only the v0.1 `pickMode: copyOnly` loads, and gives Copy only for all three kinds.
    /// Keep stays on. The old local pref does the same with no file. A change of one kind changes only that kind.
    @Test func anOldPickModeGivesTheModeOfAllThreeKinds() throws {
        let rig = try PickRig()
        let old = #"{"settings": {"pickMode": {"value": "copyOnly", "at": "2026-10-16T10:00:00.000Z"}}, "uses": {}}"#
        try FileManager.default.createDirectory(at: rig.folder.youFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(old.utf8).write(to: rig.folder.youFile)
        rig.store.load()
        #expect(rig.store.movedBadFile == nil && rig.store.you.settings.pickModes == nil)
        let model = rig.settingsModel()
        model.applySynced()
        for kind in PickKind.allCases {
            #expect(model.choice(kind) == SettingsModel.EnterChoice(mode: .copyOnly, keep: true))
            #expect(rig.prefs.pickModeChangedAt(kind) == rig.store.you.settings.pickMode?.at)
        }
        rig.session.open()
        rig.session.setQuery("rocket")
        rig.session.enter(shift: false)
        rig.later.runAll()
        #expect(rig.keys.sent.isEmpty)

        // The old local pref, with no history file: the same.
        let defaults = MemoryDefaults()
        defaults.set("copyOnly", forKey: "yaseenEmoji.pickMode")
        let prefs = Prefs(defaults: defaults)
        #expect(PickKind.allCases.allSatisfy { prefs.pickMode($0) == .copyOnly && prefs.keepsOnClipboard($0) })
        prefs.setPickMode(.paste, for: .gif)
        #expect(prefs.pickMode(.gif) == .paste && prefs.pickMode(.emoji) == .copyOnly && prefs.pickMode(.meme) == .copyOnly)
    }

    /// A KLIPY GIF uses the GIFs row, a KLIPY meme the Memes row.
    @Test func eachItemHasItsRow() throws {
        let rig = try PickRig()
        let gif = try rig.addOwn(words: ["dance"])
        #expect(PickItem.emoji(Catalog.all[0]).pickKind == .emoji)
        #expect(PickItem.own(gif).pickKind == .gif && PickItem.online(FakeOnline.gif("b")).pickKind == .gif)
        #expect(PickItem.online(FakeOnline.gif("a", kind: .meme)).pickKind == .meme)
    }
}
