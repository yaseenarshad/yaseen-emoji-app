import AppKit
import Testing
import UniformTypeIdentifiers
@testable import EmojiKit

/// A text reader with no Vision: it gives the same words each time and counts the reads (D8 of YAZ-2919).
@MainActor
final class FakeTextReader {
    let words: [String]
    private(set) var reads = 0

    init(_ words: [String]) {
        self.words = words
    }

    func read(_ bytes: Data) -> [String] {
        reads += 1
        return words
    }
}

/// The rules of the add window (YAZ-2927, D5, D8 and D12 of YAZ-2919) on `AddModel`, with no window.
/// The files are made in the test, in a temp folder. The clipboard is a fake (`ClipboardContents`).
@MainActor
@Suite struct AddWindowTests {
    private func model(_ rig: PickRig, reader: FakeTextReader? = nil) -> AddModel {
        let reader = reader ?? FakeTextReader([])
        return AddModel(library: rig.library, readText: { bytes in reader.read(bytes) })
    }

    /// Writes a test file into the temp folder of the rig.
    private func file(_ name: String, _ bytes: Data, in rig: PickRig) throws -> URL {
        let url = rig.folder.url.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// One clipboard item with these types and their data.
    private func item(_ values: (UTType, Data)...) -> ClipboardContents.Item {
        ClipboardContents.Item(values: values.map { ($0.0.identifier, $0.1) })
    }

    /// D12: "Getting it ready…" while the file is prepared. "Add" with no word is refused with "Type one word first.".
    /// "Add" with a word: the row goes away, and the item is first in "Your GIFs". The search finds it by its words.
    @Test func addNeedsAWordAndPutsTheItemFirst() async throws {
        let rig = try PickRig()
        let older = try rig.addOwn(.gif, words: ["old"], seed: 1)
        let model = model(rig)
        model.add([.file(try file("dance.gif", makeTestImage(width: 50, height: 30, type: .gif, frames: 3), in: rig))])
        #expect(model.rows.map(\.state) == [.preparing])
        #expect(model.rows[0].name == "dance.gif")
        await model.settle()

        let row = try #require(model.rows.first)
        #expect(row.state == .ready && row.kind == .gif && row.words.isEmpty && row.existing == nil)
        #expect(row.preview != nil && row.note == nil)
        model.add(row: row.id)
        #expect(model.rows[0].problem == AddModel.needsWordText)
        model.setWords(" , ", of: row.id)
        model.add(row: row.id)
        await model.settle()
        #expect(model.rows[0].problem == AddModel.needsWordText && rig.library.items.map(\.id) == [older.id])

        var results: [AddResult] = []
        model.onAdded = { results.append($0) }
        model.setWords("Dance, party", of: row.id)
        #expect(model.rows[0].problem == nil)
        model.add(row: row.id)
        await model.settle()
        #expect(model.rows.isEmpty)
        guard case .added(let added) = try #require(results.first) else { Issue.record("not a new item"); return }
        #expect(added.words == ["dance", "party"] && added.file == "gifs/\(added.id).gif")
        #expect(FileManager.default.fileExists(atPath: try #require(rig.library.fileURL(of: added)).path))
        #expect(rig.library.items(.gif).map(\.id) == [added.id, older.id])

        rig.session.open()
        rig.session.select(tab: .gifs)
        #expect(rig.session.lines.first == .title("Your GIFs"))
        #expect(rig.session.items.first == .own(added))
        rig.session.setQuery("party")
        #expect(rig.session.items.first == .own(added))
    }

    /// D8: a meme row has its read words at once. A GIF gets no read words. A GIF marked as a meme reads its words
    /// one time, and goes into `memes/`.
    @Test func aMemeRowGetsItsReadWords() async throws {
        let rig = try PickRig()
        let reader = FakeTextReader(["fine", "coffee"])
        let model = model(rig, reader: reader)
        model.add([.file(try file("fine.png", makeTestImage(width: 60, height: 40, type: .png), in: rig)),
                   .file(try file("wave.gif", makeTestImage(width: 50, height: 30, type: .gif, frames: 2), in: rig))])
        await model.settle()
        let meme = model.rows[0], gif = model.rows[1]
        #expect(meme.kind == .meme && meme.words == "fine coffee")
        #expect(gif.kind == .gif && gif.words.isEmpty)
        #expect(reader.reads == 1)

        model.setKind(.meme, of: gif.id)
        await model.settle()
        #expect(model.row(gif.id)?.words == "fine coffee" && reader.reads == 2)
        model.setKind(.gif, of: gif.id)
        model.setKind(.meme, of: gif.id)
        await model.settle()
        #expect(reader.reads == 2)

        model.add(row: meme.id)
        await model.settle()
        model.setWords("wave hello", of: gif.id)
        model.add(row: gif.id)
        await model.settle()
        #expect(model.rows.isEmpty)
        #expect(rig.library.items(.meme).map(\.words) == [["wave", "hello"], ["fine", "coffee"]])
        #expect(rig.library.items(.meme).allSatisfy { $0.file?.hasPrefix("memes/") == true })
        #expect(rig.library.items(.gif).isEmpty)
    }

    /// D12: a file of the list says "You have this one already.", keeps the kind of its item, and "Add" adds
    /// only the new words. Two pastes of the same new file: after the first add, the second row is a duplicate.
    @Test func aDuplicateRowAddsOnlyTheNewWords() async throws {
        let rig = try PickRig()
        let reader = FakeTextReader(["never"])
        let model = model(rig, reader: reader)
        let existing = try rig.addOwn(.gif, words: ["dance"])
        let bytes = try Data(contentsOf: try #require(rig.library.fileURL(of: existing)))
        model.add([.file(try file("again.gif", bytes, in: rig))])
        await model.settle()

        let row = try #require(model.rows.first)
        #expect(row.existing == existing && row.kind == .gif)
        model.setKind(.meme, of: row.id)
        #expect(model.rows[0].kind == .gif)
        model.add(row: row.id)
        #expect(model.rows[0].problem == AddModel.needsWordText)
        var results: [AddResult] = []
        model.onAdded = { results.append($0) }
        model.setWords("dance party", of: row.id)
        model.add(row: row.id)
        await model.settle()
        #expect(model.rows.isEmpty)
        #expect(results.map(\.item.words) == [["dance", "party"]])
        if case .alreadyThere = results.first {} else { Issue.record("not a duplicate") }
        #expect(rig.library.items.map(\.id) == [existing.id] && rig.library.items[0].words == ["dance", "party"])

        // The same new meme pasted two times. A duplicate does not read its words.
        let meme = makeTestImage(width: 70, height: 40, type: .png)
        let board = ClipboardContents(items: [item((.png, meme))])
        model.paste(from: board)
        model.paste(from: board)
        await model.settle()
        #expect(model.rows.map(\.existing) == [nil, nil] && reader.reads == 2)
        model.add(row: model.rows[0].id)
        await model.settle()
        let second = try #require(model.rows.first)
        #expect(model.rows.count == 1 && second.existing?.words == ["never"] && second.kind == .meme)
    }

    /// D5 and D12: a refused file shows its error on its row as the red line, and the other rows still work.
    @Test func aRefusedFileShowsItsErrorAndTheOtherRowsWork() async throws {
        let rig = try PickRig()
        let model = model(rig)
        let folder = rig.folder.url.appendingPathComponent("a folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.add([.file(try file("notes.txt", Data("hello".utf8), in: rig)),
                   .file(try file("big.png", makeTestImage(width: 2_200, height: 1_600, type: .png, noise: true), in: rig)),
                   .file(folder),
                   .file(try file("ok.gif", makeTestImage(width: 50, height: 30, type: .gif, frames: 2), in: rig))])
        await model.settle()
        #expect(model.rows.map(\.state) == [.failed, .failed, .failed, .ready])
        #expect(model.rows.map(\.problem) == [MediaImport.wrongTypeText, MediaImport.tooLargeText, MediaImport.wrongTypeText, nil])

        let good = model.rows[3]
        model.setWords("ok", of: good.id)
        model.add(row: good.id)
        await model.settle()
        #expect(model.rows.count == 3 && model.rows.allSatisfy { $0.state == .failed })
        #expect(rig.library.items.map(\.words) == [["ok"]])

        // A GIFs and memes folder that is gone: the row shows the red line, and it stays.
        let gone = rig.folder.url.appendingPathComponent("gone", isDirectory: true)
        let away = LibraryStore(url: rig.library.url, mediaFolder: gone, trash: rig.trash)
        away.load()
        let awayModel = AddModel(library: away, readText: { _ in [] })
        awayModel.add([.file(try file("wave.gif", makeTestImage(width: 52, height: 30, type: .gif, frames: 2), in: rig))])
        await awayModel.settle()
        awayModel.setWords("wave", of: awayModel.rows[0].id)
        awayModel.add(row: awayModel.rows[0].id)
        await awayModel.settle()
        #expect(awayModel.rows.map(\.problem) == [MediaFolder.missingText])
        #expect(awayModel.rows[0].isAdding == false && !FileManager.default.fileExists(atPath: gone.path))
    }

    /// The "D12 update": a file URL wins over GIF bytes, GIF bytes win over a PNG, a video wins over a PNG,
    /// and a PNG alone gives a meme row with the still picture line. More than one file gives one row each.
    @Test func pasteTakesTheBestFormOfTheClipboard() async throws {
        let rig = try PickRig()
        let model = model(rig)
        let gif = makeTestImage(width: 50, height: 30, type: .gif, frames: 2)
        let png = makeTestImage(width: 60, height: 40, type: .png)
        let video = Data([0, 0, 0, 24]) + Data("ftypmp42".utf8)
        let first = try file("first.gif", gif, in: rig)
        let second = try file("second.png", png, in: rig)
        let fileURL = UTType.fileURL

        func sources(_ items: ClipboardContents.Item...) -> [AddSource] {
            PasteReader.sources(in: ClipboardContents(items: items))
        }
        #expect(sources(item((fileURL, Data(first.absoluteString.utf8)), (.gif, gif))).map(\.name) == ["first.gif"])
        #expect(sources(item((.png, png), (.gif, gif))) == [.bytes(gif, type: .gif)])
        #expect(sources(item((.png, png)), item((.gif, gif))) == [.bytes(gif, type: .gif)])
        #expect(sources(item((.png, png), (.mpeg4Movie, video))) == [.bytes(video, type: .mpeg4Movie)])
        #expect(sources(item((.tiff, png), (.jpeg, png))) == [.bytes(png, type: .jpeg)])
        #expect(sources(item((.utf8PlainText, Data("hello".utf8)))).isEmpty)
        let twoFiles = sources(item((fileURL, Data(first.absoluteString.utf8)), (.utf8PlainText, Data("first.gif".utf8))),
                               item((fileURL, Data(second.absoluteString.utf8))))
        guard case .file(let one) = twoFiles.first, case .file(let two) = twoFiles.last else {
            Issue.record("no files: \(twoFiles)")
            return
        }
        #expect(twoFiles.count == 2 && one.path == first.path && two.path == second.path)
        #expect(!PasteReader.canRead(ClipboardContents.text("hello")) && PasteReader.canRead(FakeClipboard.rich))

        // A PNG alone: one meme row with the still picture line. A TIFF becomes a PNG.
        model.paste(from: ClipboardContents(items: [item((.png, png))]))
        model.paste(from: ClipboardContents(items: [item((.tiff, makeTestImage(width: 30, height: 30, type: .tiff)))]))
        await model.settle()
        #expect(model.rows.map(\.kind) == [.meme, .meme] && model.rows.map(\.name) == ["Pasted picture", "Pasted picture"])
        #expect(model.rows.allSatisfy { $0.note == AddModel.stillPictureText })
        #expect(model.rows[1].file?.ext == "png")
        // GIF bytes and two files: no still picture line, one row for each file.
        model.paste(from: ClipboardContents(items: [item((.gif, gif))]))
        model.paste(from: ClipboardContents(items: [item((fileURL, Data(first.absoluteString.utf8))),
                                                    item((fileURL, Data(second.absoluteString.utf8)))]))
        await model.settle()
        #expect(model.rows.count == 5 && model.rows[2...].allSatisfy { $0.note == nil })
        #expect(model.rows.map(\.kind) == [.meme, .meme, .gif, .gif, .meme] && model.rows[2].name == "Pasted GIF")
        #expect(model.notice == nil)

        // A clipboard with only a text: no row, and the grey line.
        model.paste(from: ClipboardContents.text("hello"))
        #expect(model.rows.count == 5 && model.notice == AddModel.emptyClipboardText)
        model.add([.file(first)])
        #expect(model.notice == nil)
    }

    /// D12: a close with rows that wait asks "Close and drop N files?" in the window. Refused rows do not count.
    @Test func aCloseWithRowsThatWaitAsks() async throws {
        let rig = try PickRig()
        let model = model(rig)
        #expect(model.requestClose())
        model.add([.file(try file("a.png", makeTestImage(width: 30, height: 30, type: .png), in: rig)),
                   .file(try file("b.gif", makeTestImage(width: 40, height: 30, type: .gif, frames: 2), in: rig)),
                   .file(try file("c.txt", Data("c".utf8), in: rig))])
        #expect(!model.requestClose() && model.closeQuestion == "Close and drop 3 files?")   // also while they get ready
        await model.settle()
        #expect(!model.requestClose() && model.isAskingToClose && model.closeQuestion == "Close and drop 2 files?")
        model.cancelClose()
        #expect(!model.isAskingToClose && model.rows.count == 3)

        model.remove(model.rows[0].id)
        #expect(!model.requestClose() && model.closeQuestion == "Close and drop 1 file?")
        model.dropAll()
        #expect(model.rows.isEmpty && !model.isAskingToClose)

        // Only refused rows: the window closes at once, and the rows go.
        model.add([.file(try file("d.txt", Data("d".utf8), in: rig))])
        await model.settle()
        #expect(model.requestClose() && model.rows.isEmpty && !model.isAskingToClose)
    }

    /// D12: the ways in. The menu bar row and the right-click item open the add window with no row, and close the panel.
    /// A drop of files on the panel closes it and opens the add window with the files.
    @Test func theWaysIntoTheAddWindow() async throws {
        let rig = try PickRig()
        let app = AppController(hotKeys: FakeHotKeyRegistrar(), loginItem: FakeLoginItem(), parts: rig.parts(catalog: smallCatalog(5)))
        var opened: [[AddSource]] = []
        app.openAddWindow = { opened.append($0) }
        app.start()
        #expect(app.addModel.library === app.library)

        let row = try #require(app.statusMenu.menu.item(withTitle: "Add a GIF or meme…"))
        click(row)
        #expect(opened == [[]])

        await app.ready?.value
        let session = try #require(app.session)
        session.open()
        click(row)
        #expect(opened.count == 2 && !session.isOpen)

        session.open()
        session.select(tab: .gifs)
        #expect(session.menuActionsOutsideItems == [.addNew])
        session.perform(.addNew)
        #expect(opened.count == 3 && !session.isOpen)

        let dropped = AddSource.file(rig.folder.url.appendingPathComponent("dance.gif"))
        session.open()
        session.addFiles([])
        #expect(session.isOpen && opened.count == 3)
        session.addFiles([dropped])
        #expect(!session.isOpen && opened.last == [dropped])
    }
}
