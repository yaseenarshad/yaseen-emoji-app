import AppKit
import Testing
import UniformTypeIdentifiers
@testable import EmojiKit

/// The title of each GIF and meme (D15 of YAZ-2919): the list file, the sync, the Title box of the add window,
/// "Rename…", the text below a tile, and the search. No test makes a window. The files are made in the test.
@MainActor
@Suite struct TitleTests {
    /// Adds your own meme (a PNG made in the test) with a title. `seed` makes the bytes different.
    @discardableResult
    private func addMeme(_ rig: PickRig, words: [String], title: String = "", seed: Int = 0) throws -> Item {
        let bytes = makeTestImage(width: 40 + seed, height: 30, type: .png)
        return try rig.library.add(PreparedFile(bytes: bytes, ext: "png", kind: .meme), words: words, title: title).item
    }

    /// A list file of an earlier build has no `title`. It loads, and each item gets "". The next save writes the field.
    @Test func anOldListFileWithNoTitleLoads() throws {
        let folder = try TempFolder()
        try FileManager.default.createDirectory(at: folder.defaultFolder, withIntermediateDirectories: true)
        let url = folder.defaultFolder.appendingPathComponent("library-A.json")
        try Data("""
        {
          "items" : {
            "3fa9c1d2e8b04a77" : {
              "added" : "2026-10-16T20:00:00.000Z",
              "changed" : "2026-10-16T20:00:00.000Z",
              "file" : "memes/3fa9c1d2e8b04a77.png",
              "id" : "3fa9c1d2e8b04a77",
              "kind" : "meme",
              "words" : ["midwit", "mba"]
            }
          }
        }
        """.utf8).write(to: url)
        let store = LibraryStore(url: url, mediaFolder: folder.defaultFolder, now: StepClock().now)
        store.load()
        #expect(store.movedBadFile == nil)
        let item = try #require(store.item("3fa9c1d2e8b04a77"))
        #expect(item.title == "" && item.words == ["midwit", "mba"] && item.kind == .meme)

        store.setTitle("  Midwit   MBA ", of: item.id)
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved.contains("\"title\" : \"Midwit MBA\""))
        #expect(store.item(item.id)?.file == "memes/3fa9c1d2e8b04a77.png")
    }

    /// D3: the title syncs with the item, and the newest `changed` wins. Each Mac writes only its own list.
    @Test func theTitleSyncsAndTheNewestChangeWins() throws {
        let folder = try TempFolder()
        let clock = StepClock()
        func store(_ mac: String) -> LibraryStore {
            LibraryStore(url: folder.defaultFolder.appendingPathComponent("library-\(mac).json"),
                         mediaFolder: folder.defaultFolder, now: clock.now)
        }
        let macA = store("A"), macB = store("B")
        macA.load()
        macB.load()
        let meme = PreparedFile(bytes: makeTestImage(width: 40, height: 30, type: .png), ext: "png", kind: .meme)
        let item = try macA.add(meme, words: ["fine"], title: "This is fine").item
        #expect(item.title == "This is fine")

        #expect(macB.reload())
        #expect(macB.item(item.id)?.title == "This is fine")
        // B renames later: A sees the title of B at its next open.
        macB.setTitle("Fine dog", of: item.id)
        #expect(macA.reload())
        #expect(macA.item(item.id)?.title == "Fine dog")
        #expect(macA.own.items[item.id]?.title == "This is fine")      // A never writes the change of B
        // A clears it even later: the empty title wins on both Macs.
        macA.setTitle("", of: item.id)
        #expect(macB.reload())
        #expect(macB.item(item.id)?.title == "" && macA.item(item.id)?.title == "")
        // The same time on two Macs: each Mac selects the same item.
        var one = item, two = item
        one.title = "a"
        two.title = "b"
        #expect(Item.winner(one, two).title == "b" && Item.winner(two, one).title == "b")
    }

    /// The first text of the Title box: the file name, with `-` and `_` as spaces. A camera or system name,
    /// a UUID, only digits, or a paste with no file name gives an empty box.
    @Test func theAddWindowGuessesTheTitleFromTheFileName() {
        func title(_ name: String) -> String { AddSource.file(URL(fileURLWithPath: "/tmp/\(name)")).suggestedTitle }
        #expect(title("midwit-mba.png") == "midwit mba")
        #expect(title("Happy_Dance--2.gif") == "Happy Dance 2")
        #expect(title("this is fine (1).png") == "this is fine")
        #expect(title("photo booth fail.jpg") == "photo booth fail")
        #expect(title("imgur classic.gif") == "imgur classic")
        for name in ["IMG_2231.JPG", "IMG20240101.png", "DSC_0042.jpg", "PXL_20260101_101010.jpg", "Screenshot 2026-10-16 at 10.22.31.png",
                     "Screen Recording 2026-10-16 at 10.22.31.mov", "CleanShot 2026-10-16 at 10.22.31@2x.png",
                     "WhatsApp Image 2026-10-16 at 10.22.31.jpeg", "image (1).png", "giphy.gif", "tenor.gif", "Untitled.png",
                     "3F2504E0-4F89-11D3-9A0C-0305E82C3301.gif", "3fa9c1d2e8b04a77.gif", "20240101 1234.png", "1.gif"] {
            #expect(title(name) == "", "\(name)")
        }
        #expect(AddSource.bytes(Data(), type: .png).suggestedTitle == "")
        #expect(AddSource.bytes(Data(), type: .gif).suggestedTitle == "")
    }

    /// The Title box in the rows: the file name fills it, the add keeps the text, a paste has an empty box,
    /// and a duplicate keeps the title of its item unless you type a new one.
    @Test func theTitleBoxOfTheAddWindow() async throws {
        let rig = try PickRig()
        let model = AddModel(library: rig.library, readText: { _ in [] })
        let url = rig.folder.url.appendingPathComponent("midwit-mba.png")
        let bytes = makeTestImage(width: 60, height: 40, type: .png)
        try bytes.write(to: url)
        model.add([.file(url), .bytes(makeTestImage(width: 61, height: 40, type: .png), type: .png)])
        #expect(model.rows.map(\.title) == ["midwit mba", ""])
        await model.settle()
        model.setWords("midwit", of: model.rows[0].id)
        model.setTitle("  Midwit  MBA ", of: model.rows[0].id)
        model.add(row: model.rows[0].id)
        await model.settle()
        let item = try #require(rig.library.items(.meme).first)
        #expect(item.title == "Midwit MBA" && item.words == ["midwit"])

        // The same file again: the box shows the title of the item, and an empty box keeps it.
        let again = rig.folder.url.appendingPathComponent("IMG_2231.png")
        try bytes.write(to: again)
        model.add([.file(again)])
        await model.settle()
        let duplicate = try #require(model.rows.last)
        #expect(duplicate.existing?.id == item.id && duplicate.title == "Midwit MBA")
        model.setTitle("", of: duplicate.id)
        model.setWords("mba", of: duplicate.id)
        model.add(row: duplicate.id)
        await model.settle()
        #expect(rig.library.item(item.id)?.title == "Midwit MBA" && rig.library.item(item.id)?.words == ["midwit", "mba"])

        // A typed new title replaces it.
        model.add([.file(again)])
        await model.settle()
        let third = try #require(model.rows.last)
        model.setTitle("Smart guy", of: third.id)
        model.setWords("smart", of: third.id)
        model.add(row: third.id)
        await model.settle()
        #expect(rig.library.item(item.id)?.title == "Smart guy")
        #expect(rig.library.items(.meme).count == 1)
    }

    /// "Rename…" is only on your own GIFs and memes. The search box asks for the title, Enter saves it, and an empty
    /// text clears it. Esc stops with no change. The file keeps its name and its bytes.
    @Test func renameSetsAndClearsTheTitle() throws {
        let online = FakeOnline()
        let found = FakeOnline.gif("fine-dog", kind: .meme)
        online.known = ["fine-dog": found]
        let rig = try PickRig(online: online)
        rig.prefs.setSearchesKlipy(true, for: .meme)
        rig.library.saveKlipy("fine-dog", kind: .meme)
        let meme = try addMeme(rig, words: ["fine", "coffee", "dog", "fire"])
        let file = try #require(rig.library.fileURL(of: meme))
        let bytes = try Data(contentsOf: file)
        let session = rig.session
        session.open()
        session.select(tab: .memes)
        let own = try rig.place(of: meme.key)
        #expect(session.menuActions(at: own).map(\.title)
            == ["Add a word…", "Rename…", "Copy only", "Show in Finder", "Add a GIF or meme…"])
        let saved = try rig.place(of: found.youKey)
        #expect(!session.menuActions(at: saved).contains(.rename))

        session.select(own)
        session.perform(.rename)
        #expect(session.lines == [.title("Type a title for \"fine coffee dog\". Enter saves. Esc stops.")])
        #expect(session.placeholder == "A title for \"fine coffee dog\"" && session.query == "")
        session.nextTab(back: false)
        #expect(session.tab == .memes)
        session.setQuery("  This is   fine ")
        session.enter(shift: false)
        #expect(rig.library.item(meme.id)?.title == "This is fine")
        #expect(session.query == "This is fine" && session.selectedItem?.key == meme.key && session.selection == 0)

        // Rename again: the box starts with the title. Esc changes nothing.
        session.perform(.rename)
        #expect(session.query == "This is fine")
        #expect(session.lines == [.title("Type a title for \"This is fine\". Enter saves. Esc stops.")])
        session.setQuery("Something else")
        session.escape()
        #expect(rig.library.item(meme.id)?.title == "This is fine" && session.query == "" && session.isOpen)

        // An empty text clears the title. The tile shows its first 3 words again.
        session.select(try rig.place(of: meme.key))
        session.perform(.rename)
        session.setQuery("")
        session.enter(shift: false)
        let cleared = try #require(rig.library.item(meme.id))
        #expect(cleared.title == "" && PickSession.label(of: .own(cleared)) == "fine coffee dog")
        #expect(session.query == "" && session.selectedItem?.key == meme.key)

        // The file never changed: the same name, the same bytes, and no other file.
        #expect(cleared.file == meme.file && rig.library.fileURL(of: cleared) == file)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(rig.folder.names(in: file.deletingLastPathComponent()) == [file.lastPathComponent])
    }

    /// The text below a tile: the title, else the first 3 words of the item. A KLIPY tile shows KLIPY's title,
    /// also when it is saved. An emoji has none.
    @Test func theTextBelowATile() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var item = Item(id: "a", kind: .meme, file: "memes/a.png", klipyID: nil, words: ["fine", "coffee", "dog", "fire"],
                        added: date, changed: date)
        #expect(PickSession.label(of: .own(item)) == "fine coffee dog")
        item.title = "This is fine"
        #expect(PickSession.label(of: .own(item)) == "This is fine")
        item.title = ""
        item.words = ["wave"]
        #expect(PickSession.label(of: .own(item)) == "wave")
        let klipy = FakeOnline.gif("hello-hi-662")
        #expect(PickSession.label(of: .online(klipy)) == "hello-hi-662")
        #expect(PickSession.label(of: .emoji(smallCatalog(1)[0])) == "")
        #expect(PickSession.shortName(of: .online(FakeOnline.gif(""))) == "this GIF")
    }

    /// The search (D15): a title that is the search text comes first (`isName`), before newer items with more uses
    /// whose words match. A title word matches like a word, also as a prefix. The emoji search does not change.
    @Test func aTitleThatIsTheSearchTextComesFirst() throws {
        let rig = try PickRig()
        let titled = try addMeme(rig, words: ["dog"], title: "Fine", seed: 1)
        let words = try addMeme(rig, words: ["fine", "this", "is"], seed: 2)
        let long = try addMeme(rig, words: ["cat"], title: "This is fine", seed: 3)
        let other = try addMeme(rig, words: ["this", "is", "fine"], seed: 4)
        for _ in 0..<5 {
            rig.store.recordPick(words.key, query: "")
            rig.store.recordPick(other.key, query: "")
        }
        let session = rig.session
        session.open()
        session.select(tab: .memes)
        session.setQuery("fine")
        #expect(session.items.first?.key == titled.key)
        #expect(Set(session.items.map(\.key)) == Set([titled.key, words.key, long.key, other.key]))
        session.setQuery("This is fine")
        #expect(session.items.first?.key == long.key)
        // A title word, and a prefix of it.
        session.setQuery("cat")
        #expect(session.items.first?.key == long.key)
        // D17: the other memes follow under "All your memes".
        #expect(session.lines.first == .title(PickSession.yoursTitle) && session.lines.dropFirst().first == .cells(0..<1))
        #expect(session.lines.contains(.title(PickSession.allYourTitle(.meme))) && session.items.count == 4)
        session.setQuery("fin")
        #expect(session.items.count == 4)

        let entry = TileEntry(item: .own(long), words: long.words, title: long.title, order: 0)
        #expect(entry.name == "this is fine" && entry.nameBytes == Array("this is fine".utf8))
        #expect(entry.wordBytes.map { String(decoding: $0, as: UTF8.self) } == ["cat", "this is fine", "this", "is", "fine"])
        // The Emoji tab: "rocket" still gives 🚀 first.
        session.select(tab: .emoji)
        session.setQuery("rocket")
        #expect(session.items.first?.emoji?.text == "🚀")
    }

    /// The big preview (D15): the Memes tab and a meme with the blue box show that meme. The GIFs tab, no blue box,
    /// a hidden panel, a step aside and "Rename…" hide it.
    @Test func thePreviewShowsTheMemeWithTheBlueBox() throws {
        let rig = try PickRig()
        let first = try addMeme(rig, words: ["fine"], seed: 1)
        let second = try addMeme(rig, words: ["dog"], seed: 2)
        try rig.addOwn(.gif, words: ["dance"])
        let session = rig.session
        func preview(steppingAside: Bool = false) -> PickItem? {
            MemePreview.item(isOpen: session.isOpen, isSteppingAside: steppingAside, tab: session.tab, selected: session.selectedItem)
        }
        session.open()
        #expect(preview() == nil)                                    // the Emoji tab
        session.select(tab: .gifs)
        #expect(session.selectedItem?.kind == .gif && preview() == nil)
        session.select(tab: .memes)
        #expect(preview() == .own(second))
        session.move(.right)
        #expect(preview() == .own(first))
        session.select(0)
        #expect(preview() == .own(second))
        #expect(preview(steppingAside: true) == nil)
        // No match: no item has the blue box.
        session.setQuery("zzqqxx")
        #expect(session.selection == nil && preview() == nil)
        session.setQuery("")
        session.perform(.rename)
        #expect(preview() == nil)
        session.escape()
        #expect(preview() == .own(second))
        session.close()
        #expect(preview() == nil)
        // A KLIPY meme counts too. A GIF never shows.
        let meme = FakeOnline.gif("fine-dog", kind: .meme)
        #expect(MemePreview.item(isOpen: true, isSteppingAside: false, tab: .memes, selected: .online(meme)) == .online(meme))
        #expect(MemePreview.item(isOpen: true, isSteppingAside: false, tab: .memes, selected: .online(FakeOnline.gif("g"))) == nil)
    }

    /// The side of the preview: right of the panel when 8 + 360 points fit on the visible screen, else left,
    /// else the side with more room. The same top and height as the panel.
    @Test func thePreviewGoesRightOrLeftByTheRoomOnTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let middle = CGRect(x: 490, y: 337, width: 460, height: 392)
        #expect(MemePreview.side(panel: middle, visibleFrame: screen) == .right)
        #expect(MemePreview.frame(panel: middle, visibleFrame: screen) == CGRect(x: 958, y: 337, width: 360, height: 392))
        // Dragged to the right edge: the preview goes left.
        let right = CGRect(x: 900, y: 337, width: 460, height: 392)
        #expect(MemePreview.side(panel: right, visibleFrame: screen) == .left)
        #expect(MemePreview.frame(panel: right, visibleFrame: screen) == CGRect(x: 532, y: 337, width: 360, height: 392))
        // Exactly enough room on the right.
        let edge = CGRect(x: 1440 - 368 - 460, y: 0, width: 460, height: 392)
        #expect(MemePreview.side(panel: edge, visibleFrame: screen) == .right)
        // A second screen on the left of the main screen.
        let left = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        #expect(MemePreview.side(panel: CGRect(x: -500, y: 200, width: 460, height: 392), visibleFrame: left) == .left)
        // No room on either side: the side with more room.
        let small = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(MemePreview.side(panel: CGRect(x: 100, y: 0, width: 460, height: 392), visibleFrame: small) == .right)
        #expect(MemePreview.side(panel: CGRect(x: 300, y: 0, width: 460, height: 392), visibleFrame: small) == .left)
    }
}
