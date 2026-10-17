import Foundation
import Testing
@testable import EmojiKit

/// The list of GIFs and memes (YAZ-2921, D3 and D4 of YAZ-2919): one `library-<Mac>.json` for each Mac,
/// combined on each Mac, and the files in `gifs/` and `memes/`. Each test has its own temp folder and a fake Trash.
/// No test reads the real preferences folder or the real Trash.
@Suite struct LibraryTests {
    /// A small file that the store keeps as it is. The store does not read the bytes.
    private func gif(_ text: String) -> PreparedFile {
        PreparedFile(bytes: Data("GIF89a \(text)".utf8), ext: "gif", kind: .gif)
    }

    private func store(_ mac: String, in folder: TempFolder, clock: StepClock, trash: FakeTrash? = nil,
                       media: URL? = nil) -> LibraryStore {
        let preferences = folder.defaultFolder
        return LibraryStore(url: preferences.appendingPathComponent("library-\(mac).json"),
                            mediaFolder: media ?? preferences,
                            trash: trash ?? FakeTrash(folder: folder.url.appendingPathComponent("Trash")), now: clock.now)
    }

    @Test func theNamesOfTheListFiles() {
        let folders = PreferencesFolder(defaultFolder: URL(fileURLWithPath: "/tmp"), macName: "Yasin-s-Air")
        #expect(folders.libraryFileName == "library-Yasin-s-Air.json")
        for name in ["library-A.json", "library-Yasin-s-BIG-Macbook-Pro.json"] {
            #expect(PreferencesFolder.isLibraryFile(name), "\(name)")
            #expect(!PreferencesFolder.isHistoryFile(name), "\(name)")
        }
        for name in ["you-A.json", "you-Yasin-s-Air.json"] { #expect(!PreferencesFolder.isLibraryFile(name), "\(name)") }
        for name in ["library.json", "library-.json", "library-A.bad.json", "library-A 2.json", "library-A.json.tmp"] {
            #expect(!PreferencesFolder.isLibraryFile(name), "\(name)")
        }
    }

    /// D3: Mac A adds, Mac B removes later, and both see it removed. Mac A adds it again, and it comes back on both.
    /// The same GIF on two Macs is one item, with the same file name. Each Mac writes only its own list.
    @Test func twoMacsAddRemoveAndAddAgain() throws {
        let folder = try TempFolder()
        let clock = StepClock()
        let trash = FakeTrash(folder: folder.url.appendingPathComponent("Trash"))
        let macA = store("A", in: folder, clock: clock)
        let macB = store("B", in: folder, clock: clock, trash: trash)
        macA.load()
        macB.load()

        let dance = gif("dance")
        let added = try macA.add(dance, words: ["Dance", "party", "dance"])
        guard case .added(let item) = added else { Issue.record("not added"); return }
        #expect(item.id.count == 16 && item.file == "gifs/\(dance.id).gif" && item.key == "gif:\(dance.id)")
        #expect(item.words == ["dance", "party"])
        let file = folder.defaultFolder.appendingPathComponent("gifs/\(dance.id).gif")
        #expect(try Data(contentsOf: file) == dance.bytes)

        // B reads the list of A at its next open. The same GIF added on B is the same item.
        #expect(macB.reload())
        #expect(macB.items.map(\.id) == [dance.id])
        let again = try macB.add(dance, words: ["moves"])
        #expect(again == .alreadyThere(macB.item(dance.id)!))
        #expect(macB.items.count == 1 && macB.items[0].words == ["dance", "party", "moves"])

        // B removes it later: the file goes to the Trash, and B writes the remove into its own list.
        try macB.remove(dance.id)
        #expect(trash.trashed == ["\(dance.id).gif"])
        #expect(macB.items.isEmpty && macB.item(dance.id)?.isRemoved == true)
        #expect(macA.reload())
        #expect(macA.items.isEmpty && macA.item(dance.id)?.isRemoved == true)
        #expect(macA.own.items[dance.id]?.isRemoved == false)        // A never writes the change of B

        // A adds it again after the remove: it comes back on both Macs, with the old and the new words.
        let back = try macA.add(dance, words: ["groove"])
        guard case .added(let item2) = back else { Issue.record("not added again"); return }
        #expect(item2.words == ["dance", "party", "moves", "groove"])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(macB.reload())
        #expect(macB.items.map(\.id) == [dance.id] && macB.missing.isEmpty)

        // A new start of each Mac reads the same list.
        let newA = store("A", in: folder, clock: clock)
        newA.load()
        #expect(newA.all == macA.all && newA.items == macA.items)
    }

    /// D3: the newest `changed` wins. The same time: the delete wins. Then each Mac selects the same item.
    @Test func theCombineRule() {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let live = Item(id: "a", kind: .gif, file: "gifs/a.gif", klipyID: nil, words: ["x"], added: time, changed: time)
        var removed = live
        removed.removed = time
        var newer = live
        newer.changed = time.addingTimeInterval(1)
        #expect(Item.winner(live, removed) == removed && Item.winner(removed, live) == removed)
        #expect(Item.winner(removed, newer) == newer && Item.winner(newer, removed) == newer)
        var moreWords = live
        moreWords.words = ["x", "y"]
        #expect(Item.winner(live, moreWords) == moreWords && Item.winner(moreWords, live) == moreWords)

        let own = LibraryFile(items: ["a": newer])
        let other = LibraryFile(items: ["a": removed, "b": Item(id: "b", kind: .meme, file: nil, klipyID: "9",
                                                               words: [], added: time, changed: time)])
        let combined = LibraryFile.combine(own: own, others: [other])
        #expect(combined["a"] == newer && combined["b"]?.key == "klipy:9")
    }

    /// D3: a bad list of this Mac moves to `library-<Mac>.bad.json`, and the store starts empty.
    /// A bad list of a different Mac keeps its last good data.
    @Test func aBadListMovesAwayAndABadOtherListKeepsItsData() throws {
        let folder = try TempFolder()
        let clock = StepClock()
        let macB = store("B", in: folder, clock: clock)
        macB.load()
        try macB.add(gif("b"), words: ["bee"])

        let ownURL = folder.defaultFolder.appendingPathComponent("library-A.json")
        try Data("{ not json".utf8).write(to: ownURL)
        let macA = store("A", in: folder, clock: clock)
        macA.load()
        #expect(macA.movedBadFile?.lastPathComponent == "library-A.bad.json")
        #expect(macA.own == LibraryFile() && macA.items.count == 1)       // only the item of B
        #expect(try String(contentsOf: folder.defaultFolder.appendingPathComponent("library-A.bad.json"), encoding: .utf8) == "{ not json")
        // A new change of A saves a new, good file.
        try macA.add(gif("a"), words: ["ant"])
        #expect(macA.saveError == nil)
        #expect(try MacFiles.decoder.decode(LibraryFile.self, from: Data(contentsOf: ownURL)).items.count == 1)

        // Half a file of B (git writes it): A keeps the last good data of B.
        try Data("{ \"items\": ".utf8).write(to: folder.defaultFolder.appendingPathComponent("library-B.json"))
        _ = macA.reload()
        #expect(macA.items.count == 2)
        #expect(folder.names(in: folder.defaultFolder) == ["gifs", "library-A.bad.json", "library-A.json", "library-B.json"])
    }

    /// D4: a file in the list that is not on disk is missing (a grey tile). The next open checks again.
    /// A chosen folder that is gone: the list still loads, each own file is missing, and an add makes no folder.
    @Test func missingFilesAndAMissingFolder() throws {
        let folder = try TempFolder()
        let clock = StepClock()
        let macA = store("A", in: folder, clock: clock)
        macA.load()
        let item = try macA.add(gif("one"), words: ["one"]).item
        let saved = macA.saveKlipy("k1", kind: .gif, words: ["klipy"])
        #expect(saved.file == nil && saved.key == "klipy:k1" && saved.id == "klipy-k1")
        #expect(macA.missing.isEmpty && !macA.mediaFolderIsMissing)

        let file = try #require(macA.fileURL(of: item))
        let bytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        #expect(macA.reload())
        #expect(macA.missing == [item.id])
        try bytes.write(to: file)        // git pulls it
        #expect(macA.reload())
        #expect(macA.missing.isEmpty)
        #expect(!macA.reload())          // nothing changed

        // A KLIPY item has no file: its remove calls no Trash.
        let trash = FakeTrash(folder: folder.url.appendingPathComponent("Trash"))
        let macB = store("B", in: folder, clock: clock, trash: trash)
        macB.load()
        try macB.remove(saved.id)
        #expect(trash.trashed.isEmpty && macB.item(saved.id)?.isRemoved == true)
        // The Trash refuses a file: the item stays.
        trash.refuses = true
        #expect(throws: FakeTrash.Refused.self) { try macB.remove(item.id) }
        #expect(macB.item(item.id)?.isRemoved == false)

        // The chosen GIFs and memes folder is gone (an unmounted drive).
        let gone = folder.url.appendingPathComponent("Drive/GIFs", isDirectory: true)
        let place = MediaFolder.resolve(chosen: gone.path, preferencesFolder: folder.defaultFolder)
        #expect(place.folder == gone && place.isMissing)
        #expect(MediaFolder.resolve(chosen: "", preferencesFolder: folder.defaultFolder) == (folder.defaultFolder, false))
        let macC = store("C", in: folder, clock: clock, media: place.folder)
        macC.load()
        #expect(macC.mediaFolderIsMissing && macC.missing == [item.id] && macC.items.map(\.id) == [item.id])
        #expect(throws: MediaFolder.Missing.self) { try macC.add(gif("two"), words: ["two"]) }
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    /// D4: the move copies `gifs/` and `memes/`, checks each copy, then removes the old files.
    /// A failed copy keeps all the old files and the old folder, and removes the copies that it made.
    @Test func theFolderMoveCopiesChecksAndRemoves() throws {
        let folder = try TempFolder()
        let clock = StepClock()
        let macA = store("A", in: folder, clock: clock)
        macA.load()
        let one = try macA.add(gif("one"), words: ["one"]).item
        let two = try macA.add(gif("two"), words: ["two"]).item
        let meme = try macA.add(PreparedFile(bytes: Data("PNG meme".utf8), ext: "png", kind: .meme), words: ["meme"]).item
        let still = try macA.add(gif("still"), as: .meme, words: ["still"]).item    // a GIF marked as a meme
        #expect(still.file == "memes/\(still.id).gif" && still.kind == .meme)
        let old = folder.defaultFolder
        let oldNames = folder.names(in: old.appendingPathComponent("gifs")) + folder.names(in: old.appendingPathComponent("memes"))
        #expect(oldNames.count == 4)
        var bytes: [String: Data] = [:]
        for item in [one, two, meme, still] { bytes[item.id] = try Data(contentsOf: old.appendingPathComponent(item.file!)) }

        // The copy into `memes/` fails: the new `memes/` folder cannot be written.
        let new = folder.url.appendingPathComponent("Media", isDirectory: true)
        let lockedMemes = new.appendingPathComponent("memes", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedMemes, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedMemes.path)
        #expect(throws: (any Error).self) { try macA.useMediaFolder(new) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedMemes.path)
        #expect(macA.mediaFolder == old)
        #expect(folder.names(in: old.appendingPathComponent("gifs")) + folder.names(in: old.appendingPathComponent("memes")) == oldNames)
        #expect(folder.names(in: new.appendingPathComponent("gifs")).isEmpty)     // the copies of `gifs/` are gone again
        #expect(macA.missing.isEmpty)

        // A different file with the same name in the new folder also stops the move.
        try Data("other bytes".utf8).write(to: lockedMemes.appendingPathComponent("\(meme.id).png"))
        #expect(throws: MediaFolder.DifferentFile.self) { try macA.useMediaFolder(new) }
        #expect(macA.mediaFolder == old && folder.names(in: old.appendingPathComponent("memes")).count == 2)
        try FileManager.default.removeItem(at: lockedMemes.appendingPathComponent("\(meme.id).png"))

        // The same file is already there (git has it): it stays, and the move works.
        try FileManager.default.createDirectory(at: new.appendingPathComponent("gifs"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: old.appendingPathComponent(one.file!), to: new.appendingPathComponent(one.file!))
        try macA.useMediaFolder(new)
        #expect(macA.mediaFolder == new && macA.missing.isEmpty)
        for item in [one, two, meme, still] {
            #expect(macA.fileURL(of: item) == new.appendingPathComponent(item.file!))
            #expect(try Data(contentsOf: new.appendingPathComponent(item.file!)) == bytes[item.id])
        }
        #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("gifs").path))
        #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("memes").path))
        // The list stays in the preferences folder.
        #expect(folder.names(in: old) == ["library-A.json"])
    }

    /// The app loads the list at the start, next to the history, and reads the list of a different Mac at each open.
    @MainActor @Test func theAppLoadsTheListAndReadsItAgainAtEachOpen() async throws {
        let rig = try PickRig()
        let app = AppController(hotKeys: FakeHotKeyRegistrar(), loginItem: FakeLoginItem(), parts: rig.parts(catalog: smallCatalog(5)))
        app.start()
        #expect(app.library.url == rig.folder.defaultFolder.appendingPathComponent("library-Test-Mac.json"))
        #expect(app.library.mediaFolder == rig.folder.defaultFolder && app.library.items.isEmpty)

        let macB = store("B", in: rig.folder, clock: StepClock())
        macB.load()
        let item = try macB.add(gif("b"), words: ["bee"]).item
        await app.ready?.value
        try #require(app.session).open()      // the panel reads the changed list
        #expect(app.library.items.map(\.id) == [item.id])
        app.session?.close()
    }
}
