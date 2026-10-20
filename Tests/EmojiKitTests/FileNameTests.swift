import Foundation
import Testing
@testable import EmojiKit

/// Real file names (YAZ-3021; D24 and D25 of YAZ-3018): the name rule, "Rename…" of the real file, and the add that
/// names the file with its title. No test makes a window. Each test has its own temp folder.
@MainActor
@Suite struct FileNameTests {
    @discardableResult
    private func put(_ bytes: Data, at path: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    /// The end-to-end test of YAZ-3021: a file in `memes/Infinite game/` → "Add a word…" → the search "infinite game"
    /// finds it → "Rename…" to "loop of life" → the file is `memes/Infinite game/loop of life.png`, with its words.
    @Test func aFileInAFolderIsFoundAndRenamedWithItsWords() throws {
        let rig = try PickRig()
        let media = rig.folder.defaultFolder
        let bytes = makeTestImage(width: 50, height: 40, type: .png)
        let circle = try put(bytes, at: "memes/Infinite game/circle.png", in: media)
        try put(makeTestImage(width: 51, height: 40, type: .png), at: "memes/other.png", in: media)
        rig.session.willOpen = { rig.library.reload() }
        let session = rig.session
        session.open()
        session.select(tab: .memes)
        let item = try #require(rig.library.items.first { $0.title == "circle" })

        // "Add a word…" with an empty search: the file gets its record, with the word.
        session.select(try rig.place(of: item.key))
        session.perform(.addWord)
        session.setQuery("loop")
        session.enter(shift: false)
        #expect(rig.library.own.items[item.id]?.words == ["loop"])

        // The folder name finds it.
        session.setQuery("infinite game")
        #expect(session.lines.prefix(2) == [.title(PickSession.yoursTitle), .cells(0..<1)])
        #expect(session.items.first?.key == item.key)

        // "Rename…" to "loop of life".
        session.select(0)
        session.perform(.rename)
        #expect(session.query == "circle")
        session.setQuery("loop of life")
        session.enter(shift: false)
        let renamed = media.appendingPathComponent("memes/Infinite game/loop of life.png")
        #expect(FileManager.default.fileExists(atPath: renamed.path) && !FileManager.default.fileExists(atPath: circle.path))
        #expect(try Data(contentsOf: renamed) == bytes)
        #expect(session.query == "loop of life" && session.selectedItem?.key == item.key)

        // The next open reads the folder again: the same item, with its word, its new title and its folder words.
        session.close()
        session.open()
        session.select(tab: .memes)
        session.setQuery("infinite game")
        #expect(session.items.first?.key == item.key)
        let shown = try #require(rig.library.item(item.id))
        #expect(shown.title == "loop of life" && shown.words == ["loop"] && rig.library.fileURL(of: shown) == renamed)
        #expect(PickSession.label(of: .own(shown)) == "loop of life")
        session.close()
    }

    /// The name rule of D24 and D25: trimmed, one space, `/` and `:` as `-`, no dot at the start, 120 characters.
    @Test func theNameRule() {
        #expect(MediaName.fileName("  loop   of life ") == "loop of life")
        #expect(MediaName.fileName("a/b: c") == "a-b- c")
        #expect(MediaName.fileName(". .hidden") == "hidden")
        #expect(MediaName.fileName("...") == "" && MediaName.fileName("   ") == "")
        #expect(MediaName.fileName(String(repeating: "a", count: 130)).count == 120)
        #expect(MediaName.fileName(String(repeating: "a", count: 119) + " b").count == 119)
    }

    /// "Rename…" in the store: the name of a different file gives " 2". `/`, `:` and a dot at the start are cleaned.
    /// A change of the case only works. A move that fails keeps the old name and gives the reason.
    @Test func renameCleansTheNameAndAvoidsAClash() throws {
        let folder = try TempFolder()
        let media = folder.defaultFolder
        try put(Data("one".utf8), at: "memes/Fun/one.png", in: media)
        try put(Data("two".utf8), at: "memes/Fun/Taken.png", in: media)
        let library = LibraryStore(url: media.appendingPathComponent("library-A.json"), mediaFolder: media)
        library.load()
        let id = MediaHash.id(Data("one".utf8))
        func name() -> String? { library.fileURL(of: library.item(id)!)?.lastPathComponent }

        #expect(try library.rename(id, to: "Taken"))
        #expect(name() == "Taken 2.png" && library.item(id)?.title == "Taken 2")
        #expect(try library.rename(id, to: ".a/b:c"))
        #expect(name() == "a-b-c.png")
        #expect(try library.rename(id, to: "A-B-C"))           // the case only
        #expect(name() == "A-B-C.png")
        #expect(try library.rename(id, to: "  A-B-C ") == false)     // the same name
        #expect(try library.rename(id, to: "") == false)
        #expect(folder.names(in: media.appendingPathComponent("memes/Fun")) == ["A-B-C.png", "Taken.png"])
        #expect(!library.reload())                              // the cache knows the new path: no change, no hash

        // The folder cannot be written: the move fails, and the file keeps its name.
        let fun = media.appendingPathComponent("memes/Fun")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fun.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fun.path) }
        let failure = #expect(throws: LibraryStore.RenameFailure.self) { try library.rename(id, to: "New name") }
        #expect(failure?.localizedDescription.hasPrefix(LibraryStore.cantRenameText + " ") == true)
        #expect(name() == "A-B-C.png")
    }

    /// D25: an add writes `<title>.<ext>` at the top of the folder. A different picture with the same name gets " 2".
    /// The same picture under any name and in any subfolder is "You have this one already": no new file, only the words.
    @Test func anAddNamesTheFileWithItsTitle() throws {
        let folder = try TempFolder()
        let media = folder.defaultFolder
        let library = LibraryStore(url: media.appendingPathComponent("library-A.json"), mediaFolder: media)
        library.load()
        let first = PreparedFile(bytes: Data("first".utf8), ext: "png", kind: .meme)
        let second = PreparedFile(bytes: Data("second".utf8), ext: "png", kind: .meme)
        #expect(try library.add(first, words: ["a"], title: "infinite game").item.file == "memes/infinite game.png")
        #expect(try library.add(second, words: ["b"], title: " infinite  game").item.file == "memes/infinite game 2.png")
        // The same bytes at the wanted name: the write uses that file (two rows of the add window at the same time).
        let target = media.appendingPathComponent("memes/infinite game.png")
        #expect(try LibraryStore.writeMediaFile(first.bytes, to: target) == target)

        // The same picture, moved into a subfolder in Finder: only the new words, and no new file.
        try FileManager.default.createDirectory(at: media.appendingPathComponent("memes/Games"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: target, to: media.appendingPathComponent("memes/Games/circle.png"))
        library.reload()
        let again = try library.add(first, words: ["a", "loop"], title: "Something else")
        #expect(again == .alreadyThere(library.item(first.id)!) && again.item.words == ["a", "loop"])
        #expect(again.item.file == "memes/Games/circle.png" && again.item.title == "circle")
        #expect(folder.names(in: media.appendingPathComponent("memes")) == ["Games", "infinite game 2.png"])
        // The record keeps the path of its add, for old builds.
        #expect(library.own.items[first.id]?.file == "memes/infinite game.png")
    }

    /// D25: the add window with a file that is already in the folder, but not in the last scan (put in Finder after the
    /// last open): no copy, only its words. A file from outside gets the name of its Title box.
    @Test func theAddWindowDoesNotCopyAFileOfTheFolder() async throws {
        let rig = try PickRig()
        let media = rig.folder.defaultFolder
        let inside = try put(makeTestImage(width: 50, height: 40, type: .png), at: "memes/Infinite game/circle.png", in: media)
        let outside = try put(makeTestImage(width: 52, height: 40, type: .png), at: "Downloads/infinite-game.png", in: rig.folder.url)
        #expect(rig.library.items.isEmpty)
        let model = AddModel(library: rig.library, readText: { _ in [] })
        model.add([.file(inside), .file(outside)])
        await model.settle()
        #expect(model.rows.map(\.title) == ["circle", "infinite game"])
        for row in model.rows {
            model.setWords("loop", of: row.id)
            model.add(row: row.id)
        }
        await model.settle()
        #expect(model.rows.isEmpty)
        let files = rig.library.items(.meme).compactMap(\.file).sorted()
        #expect(files == ["memes/Infinite game/circle.png", "memes/infinite game.png"])
        #expect(rig.folder.names(in: media.appendingPathComponent("memes/Infinite game")) == ["circle.png"])
        #expect(rig.library.items(.meme).allSatisfy { $0.words == ["loop"] })
    }
}

/// `--name-files` (YAZ-3022, D26 of YAZ-3018): the one-time names of the code-named files. Fake prefs, a temp folder.
@Suite struct NameFilesTests {
    @Test func theCodeNamedFilesGetTheirTitleOrTheirWords() throws {
        let folder = try TempFolder()
        let media = folder.defaultFolder
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        var list = LibraryFile()
        // A file with the code name of its hash, at `path`, and its record.
        func coded(_ text: String, in kind: ItemKind, title: String = "", words: [String] = [], record: Bool = true) throws -> String {
            let bytes = Data(text.utf8)
            let id = MediaHash.id(bytes)
            let ext = kind == .gif ? "gif" : "png"
            let url = media.appendingPathComponent("\(kind.folderName)/\(id).\(ext)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            if record {
                list.items[id] = Item(id: id, kind: kind, file: "\(kind.folderName)/\(id).\(ext)", klipyID: nil, words: words,
                                      title: title, added: time, changed: time)
            }
            return id
        }
        let titled = try coded("fine", in: .meme, title: "This is fine", words: ["fine"])
        let worded = try coded("dog", in: .meme, words: ["fine", "dog", "coffee", "fire", "extra"])
        let bare = try coded("bare", in: .meme, record: false)
        let clash = try coded("clash", in: .meme, title: "Taken", words: ["x"])
        let gif = try coded("party", in: .gif, title: "party: time/now", words: ["party"])
        try Data("taken".utf8).write(to: media.appendingPathComponent("memes/Taken.png"))
        let deep = media.appendingPathComponent("memes/Old/0123456789abcdef.png")
        try FileManager.default.createDirectory(at: deep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: deep)
        let listURL = media.appendingPathComponent("library-Test-Mac.json")
        try MacFiles.save(list, to: listURL)
        let before = try Data(contentsOf: listURL)

        let defaults = MemoryDefaults()
        var lines: [String] = []
        func run() -> Int32 {
            NameCommand.run(defaults: defaults, defaultFolder: media, computerName: { "Test Mac" }) { lines.append($0) }
        }
        #expect(run() == 0)
        #expect(Set(lines) == [
            "memes/\(titled).png → memes/This is fine.png",
            "memes/\(worded).png → memes/fine dog coffee fire.png",
            "memes/\(bare).png: no change, no title and no words",
            "memes/\(clash).png → memes/Taken 2.png",
            "gifs/\(gif).gif → gifs/party- time-now.gif",
        ])
        #expect(folder.names(in: media.appendingPathComponent("memes"))
            == ["Old", "Taken 2.png", "Taken.png", "This is fine.png", "\(bare).png", "fine dog coffee fire.png"].sorted())
        #expect(FileManager.default.fileExists(atPath: deep.path))
        // The words stay, and the list file does not change.
        #expect(try Data(contentsOf: listURL) == before)
        let library = LibraryStore(url: listURL, mediaFolder: media)
        library.load()
        #expect(library.item(titled)?.title == "This is fine" && library.item(titled)?.words == ["fine"])
        #expect(library.item(worded)?.title == "fine dog coffee fire" && library.missing.isEmpty)

        // A second run changes nothing.
        lines = []
        #expect(run() == 0)
        #expect(lines == ["memes/\(bare).png: no change, no title and no words"])
        try FileManager.default.removeItem(at: media.appendingPathComponent("memes/\(bare).png"))
        lines = []
        #expect(run() == 0 && lines == [NameCommand.noCodeNamesText])
    }
}
