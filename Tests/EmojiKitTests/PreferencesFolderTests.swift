import AppKit
import Carbon.HIToolbox
import Testing
@testable import EmojiKit

/// The preferences folder of D16 (YAZ-2900): one history file for each Mac, added up on each Mac.
/// Each test has its own temp folder. No test reads the real Application Support or `yaseen-os`.
@MainActor
@Suite struct PreferencesFolderTests {
    private let commandE = HotKeyCombo(keyCode: UInt32(kVK_ANSI_E), modifiers: .command)
    private let controlOptionE = HotKeyCombo(keyCode: UInt32(kVK_ANSI_E), modifiers: [.control, .option])
    private let commandK = HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: .command)

    private func time(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    private func write(_ you: You, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try YouStore.encoder.encode(you).write(to: url, options: .atomic)
    }

    /// The other Mac's file with picks, words and a hide.
    private func otherMac() -> You {
        You(uses: ["🤣": You.Use(count: 10, last: time(500)), "🚀": You.Use(count: 3, last: time(1))],
            learned: ["lol": ["🤣": You.Use(count: 4, last: time(500))], "ship": ["🚢": You.Use(count: 2, last: time(2))]],
            added: ["🚀": ["blastoff"]],
            hidden: ["🍑": You.Hide(on: true, at: time(100)), "🤣": You.Hide(on: true, at: time(3))])
    }

    @Test func theNamesOfTheFiles() {
        #expect(PreferencesFolder.safeName("Yasin's BIG Macbook Pro") == "Yasin-s-BIG-Macbook-Pro")
        #expect(PreferencesFolder.safeName("Yasins-MacBook-Air") == "Yasins-MacBook-Air")
        #expect(PreferencesFolder.safeName("Café 💻 ") == "Caf")
        #expect(PreferencesFolder.safeName("💻") == "Mac")
        for name in ["you-A.json", "you-Yasin-s-BIG-Macbook-Pro.json"] { #expect(PreferencesFolder.isHistoryFile(name)) }
        for name in ["you.json", "you-.json", "you-A.bad.json", "you-A 2.json", "you-A.json.tmp", "me-A.json"] {
            #expect(!PreferencesFolder.isHistoryFile(name), "\(name)")
        }
        // The name is made one time and kept: a rename of the Mac does not make a second file.
        let prefs = Prefs(defaults: MemoryDefaults())
        #expect(prefs.macName(computerName: { "Yasin's Air" }) == "Yasin-s-Air")
        #expect(prefs.macName(computerName: { "A new name" }) == "Yasin-s-Air")
    }

    /// Two Macs: the uses, the learned words and the added words add up, the newest hide wins,
    /// and this Mac writes only its own file. The other file keeps the same bytes.
    @Test func twoMacsAddUpAndEachWritesOnlyItsOwnFile() throws {
        let folder = try TempFolder()
        let otherURL = folder.defaultFolder.appendingPathComponent("you-B.json")
        try write(otherMac(), to: otherURL)
        let otherBytes = try Data(contentsOf: otherURL)

        let clock = StepClock()   // its times are 1 to 20 seconds after `time(0)`
        let store = YouStore(url: folder.defaultFolder.appendingPathComponent("you-A.json"), now: clock.now)
        store.load()
        store.recordPick("🤣", query: "lol")        // time(1)
        store.recordPick("🚀", query: "ship")       // time(2)
        store.addWord("rocket man", to: "🚀")
        store.addWord("blastoff", to: "🚀")         // the same word on both Macs counts one time
        store.hide("🤣")                            // time(3): the same time as the hide of B
        store.showHidden()                          // time(4): shows 🤣 and 🍑 again
        let you = store.you
        #expect(you.uses["🤣"]?.count == 11 && you.uses["🤣"]?.last == time(500))
        #expect(you.uses["🚀"]?.count == 4 && you.uses["🚀"]?.last == time(2))
        #expect(you.learned["lol"]?["🤣"]?.count == 5)
        #expect(you.learned["ship"]?["🚢"]?.count == 2 && you.learned["ship"]?["🚀"]?.count == 1)
        #expect(you.added["🚀"] == ["rocket man", "blastoff"])
        // 🤣: the show at time(4) wins over B's hide at time(3). 🍑: B hid it at time(100), after the show.
        #expect(you.hidden["🤣"]?.on == false)
        #expect(you.hidden["🍑"]?.on == true && store.hiddenCount == 1)
        #expect(Search.results(for: "lol", in: Catalog.all, you: you).first?.text == "🤣")
        let most = Search.mostUsed(in: Catalog.all, you: you).map(\.text)
        #expect(most.prefix(2) == ["🤣", "🚀"])

        // This Mac's file has only its own data.
        let own = try YouStore.decoder.decode(You.self, from: Data(contentsOf: store.url))
        #expect(own.uses["🤣"]?.count == 1 && own.learned["ship"]?["🚢"] == nil && own.added["🚀"] == ["rocket man", "blastoff"])

        store.forgetWords()
        _ = store.setHotKey(You.Key(commandK))
        _ = store.setPickMode("copyOnly")
        _ = store.setDefaultTone("\u{1F3FD}")
        #expect(try Data(contentsOf: otherURL) == otherBytes)
        #expect(folder.names(in: folder.defaultFolder) == ["you-A.json", "you-B.json"])

        // The file is easy to read in git: sorted keys and one value on each line.
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains("\"forgotAt\" : ") && text.contains("\n    \"pickMode\" : {\n"))
    }

    /// "Forget learned words" on Mac A: A's merged view has no words at once, B clears its own words one time
    /// at its next reload, and a later word on B stays.
    @Test func forgetOnOneMacClearsTheWordsOfTheOtherMac() throws {
        let folder = try TempFolder()
        let clockA = StepClock()
        let a = YouStore(url: folder.defaultFolder.appendingPathComponent("you-A.json"), now: clockA.now)
        let b = YouStore(url: folder.defaultFolder.appendingPathComponent("you-B.json"), now: { Date(timeIntervalSince1970: 1_900_000_000) })
        a.load()
        b.load()
        a.recordPick("🤣", query: "lol")
        b.recordPick("🚀", query: "ship")
        b.addWord("blastoff", to: "🚀")
        #expect(a.reload() && b.reload())
        #expect(a.you.learnedPairs == 2 && b.you.learnedPairs == 2)

        a.forgetWords()
        #expect(a.you.learned.isEmpty && a.you.added.isEmpty)     // B's words do not show on A
        #expect(a.you.uses["🚀"]?.count == 1)                     // the uses stay

        #expect(b.reload())
        #expect(b.own.learned.isEmpty && b.own.added.isEmpty)
        #expect(b.own.forgetApplied == a.own.forgotAt)
        // A new word on B after the Forget stays, also after more reloads.
        b.recordPick("🚢", query: "boat")
        #expect(a.reload())
        #expect(!b.reload())
        #expect(b.own.learned["boat"]?["🚢"]?.count == 1)
        #expect(a.you.learned["boat"]?["🚢"]?.count == 1)
    }

    /// The settings of the other Mac: the newest change wins, and a newer hotkey works at once (fake registrar).
    /// The panel reads only a changed file. A refused hotkey keeps the old key, with the red line.
    @Test func aNewerHotKeyFromTheOtherMacWorksAtOnce() async throws {
        let rig = try PickRig()
        let otherURL = rig.folder.defaultFolder.appendingPathComponent("you-B.json")
        let later = Date().addingTimeInterval(3_600)
        var other = You()
        other.settings.hotKey = You.Dated(You.Key(controlOptionE), at: later)
        other.settings.pickMode = You.Dated("copyOnly", at: Date().addingTimeInterval(-60))
        try write(other, to: otherURL)

        let hotKeys = FakeHotKeyRegistrar()
        let app = AppController(hotKeys: hotKeys, loginItem: FakeLoginItem(), parts: rig.parts(catalog: smallCatalog(20)))
        app.start()
        #expect(hotKeys.registered == [.findEmoji: controlOptionE])
        #expect(app.settings.hotKey == controlOptionE && rig.prefs.hotKey == controlOptionE)
        let find = try #require(app.statusMenu.menu.item(withTitle: "Find an emoji"))
        #expect(find.keyEquivalent == "e" && find.keyEquivalentModifierMask == [.control, .option])
        #expect(app.settings.pickMode == .copyOnly)
        // A change on this Mac is newer than the pick mode of B. It goes into this Mac's file only.
        app.settings.setPickMode(.paste)
        #expect(app.store.own.settings.pickMode?.value == "paste")
        #expect(app.store.you.settings.pickMode?.value == "paste")

        // B gets ⌘K, but a different app has it: the old key stays, and Settings shows the red line.
        await app.ready?.value
        let session = try #require(app.session)
        hotKeys.refused = [commandK]
        other.settings.hotKey = You.Dated(You.Key(commandK), at: later.addingTimeInterval(1))
        try write(other, to: otherURL)
        session.open()      // the panel reads the changed file
        #expect(hotKeys.registered == [.findEmoji: controlOptionE])
        #expect(app.settings.hotKeyProblem == SettingsModel.refusedText)
        #expect(rig.prefs.hotKey == controlOptionE)
        session.close()

        // B gets ⌘K again, and now it is free: it works at once.
        hotKeys.refused = []
        other.settings.hotKey = You.Dated(You.Key(commandK), at: later.addingTimeInterval(2))
        try write(other, to: otherURL)
        session.open()
        #expect(hotKeys.registered == [.findEmoji: commandK] && app.settings.hotKeyProblem == nil)
        #expect(find.keyEquivalent == "k" && find.keyEquivalentModifierMask == .command)
        #expect(!app.store.reload())     // no file changed: nothing to read
    }

    /// The first start of D16 copies `you.json` into this Mac's file. The backup stays, and no pick counts two times.
    /// A missing folder gives the default folder. "Set preferences folder…" and "Reset to Mac Default Folder" keep the data.
    @Test func theMoveFromYouJsonAndTheFolders() async throws {
        let rig = try PickRig()
        let old = rig.folder.defaultFolder.appendingPathComponent("you.json")
        let oldText = """
        {"added": {"🚀": ["blastoff"]}, "imported": "2026-10-16T10:00:00.000Z", "learned": {},
         "tones": {}, "uses": {"🤣": {"count": 358, "last": "2026-10-16T11:00:00.000Z"}}}
        """
        try FileManager.default.createDirectory(at: rig.folder.defaultFolder, withIntermediateDirectories: true)
        try Data(oldText.utf8).write(to: old)
        // The chosen folder is not on this Mac (for example, not cloned).
        let sync = rig.folder.url.appendingPathComponent("yaseen-os/Sync/yaseen-emoji", isDirectory: true)
        rig.prefs.preferencesFolder = sync.path

        let app = AppController(hotKeys: FakeHotKeyRegistrar(), loginItem: FakeLoginItem(), parts: rig.parts(catalog: []))
        app.start()
        #expect(app.store.url == rig.folder.defaultFolder.appendingPathComponent("you-Test-Mac.json"))
        #expect(app.settings.folderProblem == PreferencesFolder.missingText)
        #expect(app.settings.folderPath == sync.path)
        #expect(app.store.you.uses["🤣"]?.count == 358 && app.store.you.added["🚀"] == ["blastoff"])
        #expect(try String(contentsOf: old, encoding: .utf8) == oldText)

        // A second start reads this Mac's file. `you.json` does not count again.
        let again = AppController(hotKeys: FakeHotKeyRegistrar(), loginItem: FakeLoginItem(), parts: rig.parts(catalog: []))
        again.start()
        #expect(again.store.you.uses["🤣"]?.count == 358)

        // The folder comes (a git clone with the file of a different Mac). "Set preferences folder…" picks it.
        try write(You(uses: ["🤣": You.Use(count: 2, last: time(0))]), to: sync.appendingPathComponent("you-B.json"))
        again.settings.pickFolder = { $0(sync) }
        again.settings.choosePreferencesFolder()
        #expect(again.store.url == sync.appendingPathComponent("you-Test-Mac.json"))
        #expect(rig.prefs.preferencesFolder == sync.path && again.settings.folderProblem == nil)
        #expect(again.store.you.uses["🤣"]?.count == 360)
        again.store.recordPick("🤣", query: "")

        // "Reset to Mac Default Folder": the default folder gets the data of now, also the pick in the other folder.
        again.settings.useThisMacOnly()
        #expect(rig.prefs.preferencesFolder.isEmpty && again.settings.folderIsDefault)
        #expect(again.store.url == rig.folder.defaultFolder.appendingPathComponent("you-Test-Mac.json"))
        #expect(again.store.you.uses["🤣"]?.count == 359)
        #expect(FileManager.default.fileExists(atPath: sync.appendingPathComponent("you-Test-Mac.json").path))
    }

    /// `install.sh` imports the EmojiFinder history only when the folder has no history at all (D6, D16).
    @Test func theImportRunsOnlyWithNoHistory() throws {
        let folder = try TempFolder()
        let rows = Data(#"[{"emoji": "🤣", "count": 358}]"#.utf8)
        let defaults = MemoryDefaults()
        defaults.set("Air", forKey: "yaseenEmoji.macName")

        // Only the file of a different Mac: that is history, so nothing changes.
        try write(You(uses: ["🙌": You.Use(count: 1, last: time(0))]), to: folder.defaultFolder.appendingPathComponent("you-B.json"))
        #expect(try YouImport.run(rows, intoFolder: folder.defaultFolder, defaults: defaults).changed == false)
        #expect(folder.names(in: folder.defaultFolder) == ["you-B.json"])

        // No history: the import writes this Mac's file.
        let empty = folder.url.appendingPathComponent("empty", isDirectory: true)
        let summary = try YouImport.run(rows, intoFolder: empty, defaults: defaults)
        #expect(summary.changed)
        let store = YouStore(url: empty.appendingPathComponent("you-Air.json"))
        store.load()
        #expect(store.you.uses["🤣"]?.count == 358)
        #expect(try YouImport.run(rows, intoFolder: empty, defaults: defaults).changed == false)
    }
}
