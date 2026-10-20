import AppKit
import Testing
@testable import EmojiKit

/// The findings of the audit on YAZ-3026, fixed in YAZ-3027 (D22 to D27 of YAZ-3018). Temp folders, fake prefs,
/// no window. Each test names the item of the audit.
@MainActor
@Suite struct AuditFixTests {
    @discardableResult
    private func put(_ bytes: Data, at path: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    /// Item 1: the still picture is `<id>.png`. Two pictures with one name in two folders get two stills. An edit in
    /// place gets a new still. The clean-up keeps the stills of the items that show.
    @Test func theStillsAreNamedByTheID() async throws {
        let rig = try PickRig()
        let media = rig.folder.defaultFolder
        let work = try put(makeTestImage(width: 300, height: 300, type: .png, text: "ONE"), at: "memes/work/funny.png", in: media)
        try put(makeTestImage(width: 300, height: 300, type: .png, text: "TWO"), at: "memes/home/funny.png", in: media)
        rig.library.reload()
        var loaded: [String] = []
        rig.thumbnails.onLoad = { loaded.append($0) }
        func load() async throws {
            let wants = try rig.library.items.map { Thumbnails.Want(id: $0.id, file: try #require(rig.library.fileURL(of: $0))) }
            rig.thumbnails.want(wants)
            await waitUntil { Set(wants.map(\.id)).isSubset(of: Set(loaded)) }
        }
        try await load()
        let ids = rig.library.items.map(\.id).sorted()
        #expect(ids.count == 2 && rig.folder.names(in: rig.thumbnails.folder) == ids.map { "\($0).png" })
        let first = try Data(contentsOf: rig.thumbnails.folder.appendingPathComponent("\(ids[0]).png"))
        let second = try Data(contentsOf: rig.thumbnails.folder.appendingPathComponent("\(ids[1]).png"))
        #expect(first != second)

        // An edit in place: a new hash, a new still. The clean-up deletes only the still of the old item.
        try makeTestImage(width: 300, height: 300, type: .png, text: "NEW").write(to: work)
        rig.library.reload()
        try await load()
        let now = Set(rig.library.items.map(\.id))
        rig.thumbnails.removeStills(keeping: now)
        await waitUntil { Set(rig.folder.names(in: rig.thumbnails.folder)) == Set(now.map { "\($0).png" }) }
        #expect(Set(rig.folder.names(in: rig.thumbnails.folder)) == Set(now.map { "\($0).png" }))
        #expect(now.count == 2 && now != Set(ids))
    }

    /// Item 2: "Rename…" starts with the title of the file name. Enter with that text changes nothing.
    @Test func renameWithTheStartingTextChangesNothing() throws {
        let folder = try TempFolder()
        let media = folder.defaultFolder
        try put(Data("abc".utf8), at: "memes/A-B-C.png", in: media)
        try put(Data("circle".utf8), at: "memes/circle (1).png", in: media)
        let library = LibraryStore(url: media.appendingPathComponent("library-A.json"), mediaFolder: media)
        library.load()
        let abc = MediaHash.id(Data("abc".utf8)), circle = MediaHash.id(Data("circle".utf8))
        #expect(library.item(abc)?.title == "A B C" && library.item(circle)?.title == "circle")
        #expect(try library.rename(abc, to: "A B C") == false)
        #expect(try library.rename(circle, to: " circle ") == false)
        #expect(folder.names(in: media.appendingPathComponent("memes")) == ["A-B-C.png", "circle (1).png"])
        // A real change still renames.
        #expect(try library.rename(circle, to: "circle of life"))
        #expect(folder.names(in: media.appendingPathComponent("memes")) == ["A-B-C.png", "circle of life.png"])
    }

    /// Item 3: `--add-media` on a GIF, PNG or JPEG in the folder skips `prepare`: a file of 11 MB gets its words.
    /// With no `--words`, a meme in the folder still gets the words that Vision reads.
    @Test func addMediaGivesWordsToALargeFileInTheFolder() async throws {
        let folder = try TempFolder()
        let media = folder.defaultFolder
        let big = try put(Data(repeating: 7, count: 11_000_000), at: "memes/Big/huge.png", in: media)
        let hello = try put(makeTestImage(width: 800, height: 240, type: .png, text: "HELLO"), at: "memes/hello sign.png", in: media)
        var lines: [String] = []
        let defaults = MemoryDefaults()
        func run(_ arguments: [String]) async -> Int32 {
            await AddCommand.run(arguments, defaults: defaults, defaultFolder: media, computerName: { "Test Mac" }) { lines.append($0) }
        }
        #expect(await run([big.path, "--words", "big"]) == 0)
        #expect(lines.last?.hasPrefix("Already there: meme") == true)
        #expect(await run([hello.path]) == 0)
        let library = LibraryStore(url: media.appendingPathComponent("library-Test-Mac.json"), mediaFolder: media)
        library.load()
        #expect(library.item(MediaHash.id(try Data(contentsOf: big)))?.words == ["big"])
        #expect(library.item(MediaHash.id(try Data(contentsOf: hello)))?.words.contains("hello") == true)
        #expect(folder.names(in: media.appendingPathComponent("memes")) == ["Big", "hello sign.png"])
    }

    /// Item 4: ten adds of different pictures with one name at the same time: ten files, none written over.
    @Test func writesAtTheSameTimeNeverWriteOverAFile() async throws {
        let folder = try TempFolder()
        let target = folder.url.appendingPathComponent("memes/funny.png")
        let written = try await withThrowingTaskGroup(of: URL.self) { group in
            for place in 0..<10 {
                group.addTask { try LibraryStore.writeMediaFile(Data("picture \(place)".utf8), to: target) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(written).count == 10)
        let names = folder.names(in: target.deletingLastPathComponent())
        #expect(names.count == 10 && names.contains("funny.png") && names.contains("funny 10.png"))
        let contents = Set(try names.map { try Data(contentsOf: target.deletingLastPathComponent().appendingPathComponent($0)) })
        #expect(contents == Set((0..<10).map { Data("picture \($0)".utf8) }))
        // The same bytes again: that file, with no new file.
        #expect(try LibraryStore.writeMediaFile(Data("picture 3".utf8), to: target).lastPathComponent.hasPrefix("funny"))
        #expect(folder.names(in: target.deletingLastPathComponent()).count == 10)
    }

    /// Item 5: the moving picture of your own GIF has the path and the `id` in its key. An edit in place loads again.
    @Test func theMovingPictureKeyHasTheID() async throws {
        let folder = try TempFolder()
        let file = folder.url.appendingPathComponent("dance.gif")
        try makeTestImage(width: 40, height: 20, type: .gif, frames: 2).write(to: file)
        let pictures = MovingPictures(kept: 30, atOnce: 4, load: { try Data(contentsOf: $0) })
        let old = MovingPictures.ownURL(file, id: "aaaaaaaaaaaaaaaa")
        pictures.want([old])
        await waitUntil { pictures.image(for: old) != nil }
        #expect(pictures.image(for: old)?.size == NSSize(width: 40, height: 20))
        try makeTestImage(width: 30, height: 20, type: .gif, frames: 2).write(to: file)
        let new = MovingPictures.ownURL(file, id: "bbbbbbbbbbbbbbbb")
        #expect(new != old && pictures.image(for: new) == nil)
        pictures.want([new])
        await waitUntil { pictures.image(for: new) != nil }
        #expect(pictures.image(for: new)?.size == NSSize(width: 30, height: 20))
    }

    /// Item 6: the add window reads the folder before its rows. A picture that you put in Finder after the last open
    /// of the panel is "You have this one already", and its add writes no second file.
    @Test func theAddWindowReadsTheFolder() async throws {
        let rig = try PickRig()
        let media = rig.folder.defaultFolder
        let bytes = makeTestImage(width: 50, height: 40, type: .png)
        try put(bytes, at: "memes/Finder/circle.png", in: media)
        let outside = try put(bytes, at: "Downloads/circle copy.png", in: rig.folder.url)
        #expect(rig.library.items.isEmpty)
        let model = AddModel(library: rig.library, readText: { _ in [] })
        model.add([.file(outside)])
        await model.settle()
        #expect(model.rows.first?.existing?.file == "memes/Finder/circle.png")
        model.setWords("loop", of: model.rows[0].id)
        model.add(row: model.rows[0].id)
        await model.settle()
        #expect(rig.folder.names(in: media.appendingPathComponent("memes")) == ["Finder"])
        #expect(rig.library.items.map(\.words) == [["loop"]])
    }

    /// Item 7: a file that moved from `gifs/` to `memes/` keeps its uses and its learned words: the search reads
    /// `gif:<id>` and `meme:<id>`, and the counts add up. The keys of `you-<Mac>.json` do not change.
    @Test func aMoveBetweenGIFsAndMemesKeepsTheUses() throws {
        let rig = try PickRig()
        let media = rig.folder.defaultFolder
        let moved = try put(makeTestImage(width: 40, height: 30, type: .gif), at: "memes/moved.gif", in: media)
        try put(makeTestImage(width: 41, height: 30, type: .png), at: "memes/other.png", in: media)
        rig.library.reload()
        let id = MediaHash.id(try Data(contentsOf: moved))
        let other = try #require(rig.library.items.first { $0.id != id })
        for _ in 0..<3 { rig.store.recordPick("gif:\(id)", query: "") }     // used on the GIFs tab before the move
        rig.store.recordPick("gif:\(id)", query: "loopy")
        for _ in 0..<2 { rig.store.recordPick("meme:\(id)", query: "") }
        for _ in 0..<5 { rig.store.recordPick(other.key, query: "") }
        let item = try #require(rig.library.item(id))
        #expect(item.key == "meme:\(id)" && item.otherKey == "gif:\(id)")

        let session = rig.session
        session.open()
        session.select(tab: .memes)
        // 4 + 2 = 6 uses beat the 5 uses of the other meme.
        #expect(session.lines.first == .title(PickSession.mostUsedTitle))
        #expect(session.items.prefix(2).map(\.key) == [item.key, other.key])
        // The learned word of the GIFs tab finds it on the Memes tab.
        session.setQuery("loopy")
        #expect(session.items.first?.key == item.key && session.lines.first == .title(PickSession.yoursTitle))
        // "Hide from Your most used" on the old key also counts.
        rig.store.hide("gif:\(id)")
        session.setQuery("")
        #expect(!session.items.prefix(1).contains { $0.key == item.key })
        #expect(rig.store.you.uses["meme:\(id)"]?.count == 2 && rig.store.you.uses["gif:\(id)"]?.count == 4)
        session.close()
    }

    /// Item 8: a name has 240 UTF-8 bytes at most, cut between two characters, so emoji never break.
    @Test func theNameHas240BytesAtMost() throws {
        let emoji = MediaName.fileName(String(repeating: "😀", count: 100))      // 4 bytes each, 100 characters
        #expect(emoji == String(repeating: "😀", count: 60) && emoji.utf8.count == 240)
        let family = MediaName.fileName(String(repeating: "👨‍👩‍👧", count: 20))   // 18 bytes each
        #expect(family == String(repeating: "👨‍👩‍👧", count: 13) && family.utf8.count <= 240)
        let arabic = MediaName.fileName(String(repeating: "سلام ", count: 30))
        #expect(arabic.utf8.count <= 240 && !arabic.hasSuffix(" "))
        // A rename with a long emoji title works, and the full name fits in 255 bytes.
        let folder = try TempFolder()
        let media = folder.defaultFolder
        try put(Data("x".utf8), at: "memes/x.png", in: media)
        let library = LibraryStore(url: media.appendingPathComponent("library-A.json"), mediaFolder: media)
        library.load()
        #expect(try library.rename(MediaHash.id(Data("x".utf8)), to: String(repeating: "🔥", count: 120)))
        let name = try #require(folder.names(in: media.appendingPathComponent("memes")).first)
        #expect(name.utf8.count <= 255 && name.hasSuffix(".png"))
    }

    /// Item 9: a scan while the folder is missing (an unmounted drive) keeps the hash cache. When the drive comes back,
    /// the files need no hash.
    @Test func aMissingFolderKeepsTheCache() throws {
        let folder = try TempFolder()
        let cache = folder.url.appendingPathComponent("Caches/files.json")
        let drive = folder.url.appendingPathComponent("Drive", isDirectory: true)
        let file = try put(Data("kept".utf8), at: "memes/kept.png", in: drive)
        let library = LibraryStore(url: folder.defaultFolder.appendingPathComponent("library-A.json"), mediaFolder: drive,
                                   cacheURL: cache)
        library.load()
        #expect(library.items.count == 1 && FileCache.load(from: cache).files.count == 1)
        let away = folder.url.appendingPathComponent("Away", isDirectory: true)
        try FileManager.default.moveItem(at: drive, to: away)
        #expect(library.reload())
        #expect(library.mediaFolderIsMissing && library.items.isEmpty && FileCache.load(from: cache).files.count == 1)
        // The drive comes back. The file cannot be read now, so only the cache can give its `id`.
        try FileManager.default.moveItem(at: away, to: drive)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(library.reload())
        #expect(!library.mediaFolderIsMissing && library.items.map(\.id) == [MediaHash.id(Data("kept".utf8))])
    }
}
