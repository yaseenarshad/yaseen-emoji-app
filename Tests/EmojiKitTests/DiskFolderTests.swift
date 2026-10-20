import Foundation
import Testing
@testable import EmojiKit

/// Your folder is your collection (YAZ-3020; D22, D23 and D27 of YAZ-3018): the scan of the full tree of `gifs/`
/// and `memes/`, the hash cache, the titles from the file names, and the folder words. Each test has its own temp
/// folder and its own cache file. No test reads the real GIFs and memes folder or the real cache.
@MainActor
@Suite struct DiskFolderTests {
    /// Writes `bytes` at `path` in the GIFs and memes folder, with the folders on the way.
    @discardableResult
    private func put(_ bytes: Data, at path: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    private func store(_ folder: TempFolder, cache: URL? = nil) -> LibraryStore {
        LibraryStore(url: folder.defaultFolder.appendingPathComponent("library-A.json"), mediaFolder: folder.defaultFolder,
                     cacheURL: cache, now: StepClock().now)
    }

    /// D22, D23: a file that you put in `memes/a/b/` in Finder shows on the Memes tab at the next open, with the title
    /// of its file name and the words of its folders. A GIF file below `memes/` is a meme. A file with no record has no
    /// words, and its creation date gives its place: the newest first.
    @Test func aFileInASubfolderShowsWithItsTitleAndFolderWords() throws {
        let rig = try PickRig()
        let media = rig.folder.defaultFolder
        let x = try put(makeTestImage(width: 40, height: 30, type: .png), at: "memes/a/b/x.png", in: media)
        let still = try put(makeTestImage(width: 41, height: 30, type: .gif), at: "memes/spot-the-dog_2 (1).gif", in: media)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: x.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: still.path)
        #expect(rig.library.reload())

        let memes = rig.library.items(.meme)
        #expect(memes.map(\.title) == ["spot the dog 2", "x"] && rig.library.items(.gif).isEmpty)
        let item = memes[1]
        #expect(item.file == "memes/a/b/x.png" && item.words.isEmpty && item.added == Date(timeIntervalSince1970: 1_000))
        #expect(item.id == MediaHash.id(try Data(contentsOf: x)) && rig.library.fileURL(of: item) == x)
        #expect(rig.library.own.items.isEmpty)        // no record until a change
        #expect(MediaName.folderWords(ofPath: item.file!) == ["a", "b"])

        // The search finds it by each folder word, and by its title.
        let session = rig.session
        session.open()
        session.select(tab: .memes)
        for text in ["a", "b", "x"] {
            session.setQuery(text)
            #expect(session.lines.prefix(2) == [.title(PickSession.yoursTitle), .cells(0..<1)], "\(text)")
            #expect(session.items.first?.key == item.key, "\(text)")
        }
        #expect(PickSession.label(of: .own(item)) == "x")
        session.close()
    }

    /// D23: the title of a file name. `-` and `_` are spaces, a copy mark goes, a code name gives none,
    /// and a camera name stays as it is.
    @Test func theTitleOfAFileName() {
        #expect(MediaName.title(ofPath: "memes/infinite game circle.png") == "infinite game circle")
        #expect(MediaName.title(ofPath: "memes/Infinite game/finite-vs_infinite.png") == "finite vs infinite")
        #expect(MediaName.title(ofPath: "memes/this is fine (1).png") == "this is fine")
        #expect(MediaName.title(ofPath: "memes/IMG_2231.png") == "IMG 2231")
        #expect(MediaName.title(ofPath: "memes/01bb8611accdad57.png") == "")
        #expect(MediaName.title(ofPath: "gifs/01BB8611ACCDAD57EE.gif") == "")
        #expect(MediaName.title(ofPath: "memes/2024.jpg") == "2024")
        #expect(MediaName.folderWords(ofPath: "memes/Infinite_game/loops-2/x.png") == ["Infinite game", "loops 2"])
        #expect(MediaName.folderWords(ofPath: "gifs/x.gif").isEmpty)
    }

    /// D22: "Add a word…" on a file with no record makes its record. A rename and a move in Finder keep the hash, so the
    /// words stay. The title and the folder words follow the file. A changed picture is a new item with no words, and
    /// the old record stays hidden. A deleted file leaves, and comes back with its words.
    @Test func aRenameOrAMoveInFinderKeepsTheWords() throws {
        let folder = try TempFolder()
        let media = folder.defaultFolder
        let first = try put(makeTestImage(width: 40, height: 30, type: .png), at: "memes/circle.png", in: media)
        let library = store(folder)
        library.load()
        let id = try #require(library.items.first?.id)
        library.addWords(["loop"], to: id)
        let record = try #require(library.own.items[id])
        #expect(record.words == ["loop"] && record.file == "memes/circle.png" && record.title == "circle")

        // Rename in Finder, then move into a subfolder.
        let renamed = media.appendingPathComponent("memes/loop of life.png")
        try FileManager.default.moveItem(at: first, to: renamed)
        #expect(library.reload())
        #expect(library.items.map(\.id) == [id] && library.items[0].title == "loop of life" && library.items[0].words == ["loop"])
        let moved = media.appendingPathComponent("memes/Infinite game/loop of life.png")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: renamed, to: moved)
        #expect(library.reload())
        #expect(library.items[0].file == "memes/Infinite game/loop of life.png" && library.items[0].words == ["loop"])
        #expect(library.fileURL(of: library.items[0]) == moved && library.missing.isEmpty)
        #expect(!library.reload())       // nothing changed
        // The scan never writes the JSON: the record keeps the path of its add.
        #expect(library.own.items[id]?.file == "memes/circle.png")

        // A crop: a new hash, a new item with no words. The old record stays, hidden.
        try makeTestImage(width: 30, height: 30, type: .png).write(to: moved)
        #expect(library.reload())
        #expect(library.items.count == 1 && library.items[0].id != id && library.items[0].words.isEmpty)
        #expect(library.missing == [id] && library.all[id]?.words == ["loop"])
    }

    /// D27: the scan takes only GIF, PNG and JPEG files (any case). It skips hidden files, hidden folders, symbolic links
    /// and packages. A file larger than 10 MB shows: the limit is only for an add.
    @Test func theScanSkipsOtherTypesAndHiddenFiles() throws {
        let folder = try TempFolder()
        let media = folder.defaultFolder
        for (path, text) in [("memes/ok.PNG", "1"), ("memes/photo.JPEG", "2"), ("gifs/dance.gif", "3"), ("memes/a.jpg", "4"),
                             ("memes/x.webp", "5"), ("memes/x.heic", "6"), ("memes/clip.mp4", "7"), ("memes/notes.pdf", "8"),
                             ("memes/.hidden.png", "9"), ("memes/.hidden/inside.png", "10"), ("memes/Thing.app/Contents/in.png", "11"),
                             ("other/elsewhere.png", "12"), ("top.png", "13")] {
            try put(Data("bytes \(text)".utf8), at: path, in: media)
        }
        try put(Data(count: MediaImport.sizeLimit + 1), at: "memes/big.png", in: media)
        try FileManager.default.createSymbolicLink(at: media.appendingPathComponent("memes/link.png"),
                                                   withDestinationURL: media.appendingPathComponent("memes/ok.PNG"))
        try FileManager.default.createSymbolicLink(at: media.appendingPathComponent("memes/linked"),
                                                   withDestinationURL: media.appendingPathComponent("other"))
        let library = store(folder)
        library.load()
        #expect(library.items(.meme).map(\.file!).sorted() == ["memes/a.jpg", "memes/big.png", "memes/ok.PNG", "memes/photo.JPEG"])
        #expect(library.items(.gif).map(\.file!) == ["gifs/dance.gif"])
    }

    /// D27: the same picture in two places is one tile. The first path in sorted order gives its file and its title.
    @Test func theSamePictureTwiceIsOneTile() throws {
        let folder = try TempFolder()
        let bytes = makeTestImage(width: 40, height: 30, type: .png)
        try put(bytes, at: "memes/zebra.png", in: folder.defaultFolder)
        try put(bytes, at: "memes/Animals/apple.png", in: folder.defaultFolder)
        let library = store(folder)
        library.load()
        #expect(library.items.count == 1)
        #expect(library.items[0].file == "memes/Animals/apple.png" && library.items[0].title == "apple")
    }

    /// D27: a file with the same path, size and date as in the cache needs no hash. The cache file holds only the files
    /// of the last scan. A changed date needs a hash again.
    @Test func theCacheGivesTheIDWithNoHash() throws {
        let folder = try TempFolder()
        let cache = folder.url.appendingPathComponent("Caches/files.json")
        let kept = try put(Data("kept".utf8), at: "memes/kept.png", in: folder.defaultFolder)
        let gone = try put(Data("gone".utf8), at: "gifs/gone.gif", in: folder.defaultFolder)
        let first = store(folder, cache: cache)
        first.load()
        #expect(first.items.count == 2)
        try FileManager.default.removeItem(at: gone)
        first.reload()
        let saved = FileCache.load(from: cache)
        #expect(saved.files.keys.sorted() == ["memes/kept.png"] && saved.files["memes/kept.png"]?.id == MediaHash.id(Data("kept".utf8)))

        // The file cannot be read now. A new start still knows it from the cache.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: kept.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kept.path) }
        let second = store(folder, cache: cache)
        second.load()
        #expect(second.items.map(\.id) == [MediaHash.id(Data("kept".utf8))])
        // A new date: the file needs a hash, and a file that cannot be read does not show.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: kept.path)
        #expect(second.reload())
        #expect(second.items.isEmpty)
    }

    /// D27: with `onHashed`, the hashes of new files run off the main thread. The known files show at once, the new file
    /// shows when its hash is ready, and `onHashed` runs on the main thread.
    @Test func newFilesGetTheirHashOffTheMainThread() async throws {
        let folder = try TempFolder()
        let cache = folder.url.appendingPathComponent("Caches/files.json")
        try put(Data("known".utf8), at: "memes/known.png", in: folder.defaultFolder)
        let warm = store(folder, cache: cache)
        warm.load()
        try put(Data("new".utf8), at: "memes/new.png", in: folder.defaultFolder)

        let library = store(folder, cache: cache)
        var calls = 0
        var onMain = true
        library.onHashed = {
            calls += 1
            onMain = onMain && Thread.isMainThread
        }
        library.load()
        #expect(library.items.map(\.title) == ["known"])
        await waitUntil { calls == 1 }
        #expect(calls == 1 && onMain)
        #expect(library.items.map(\.title).sorted() == ["known", "new"])
        #expect(FileCache.load(from: cache).files.count == 2)
        #expect(!library.reload() && calls == 1)
    }

    /// D27: a scan of 500 files in subfolders with a warm cache takes less than 15 ms. It reads only the listing.
    /// The number goes into the Result comment. Other tests run at the same time.
    @Test func aScanOf500FilesWithAWarmCache() throws {
        let folder = try TempFolder()
        let cache = folder.url.appendingPathComponent("Caches/files.json")
        for place in 0..<500 {
            let kind = place % 5 == 0 ? "gifs" : "memes"
            try put(Data("file \(place)".utf8), at: "\(kind)/folder \(place % 10)/sub \(place % 3)/file \(place).png",
                    in: folder.defaultFolder)
        }
        let library = store(folder, cache: cache)
        let first = medianMilliseconds(runs: 1) { library.load() }
        #expect(library.items.count == 500)
        let scan = medianMilliseconds(runs: 15) { library.reload() }
        let start = medianMilliseconds(runs: 5) { store(folder, cache: cache).load() }
        let bytes = (try FileManager.default.attributesOfItem(atPath: cache.path)[.size] as? Int) ?? 0
        print("TIMING [\(buildKind)] scan of 500 files: first load with hashes \(String(format: "%.1f", first)) ms; "
              + "scan with a warm cache median \(String(format: "%.1f", scan)) ms; new start from the cache file median "
              + "\(String(format: "%.1f", start)) ms; cache file \(bytes) bytes")
        #expect(scan < 15)
    }

    /// D27: "Set GIFs and memes folder…" copies the full tree, with the subfolders, and removes the old copies. A hidden
    /// folder stays in the old place. The words stay, because the hashes do not change.
    @Test func theFolderMoveKeepsTheSubfolders() throws {
        let folder = try TempFolder()
        let old = folder.defaultFolder
        try put(makeTestImage(width: 40, height: 30, type: .png), at: "memes/Infinite game/circle.png", in: old)
        try put(makeTestImage(width: 41, height: 30, type: .png), at: "memes/a/b/x.png", in: old)
        try put(makeTestImage(width: 42, height: 30, type: .gif, frames: 2), at: "gifs/dance.gif", in: old)
        try put(Data("secret".utf8), at: "memes/.hidden/secret.png", in: old)
        let library = store(folder)
        library.load()
        let circle = try #require(library.items.first { $0.title == "circle" })
        library.addWords(["loop"], to: circle.id)

        let new = folder.url.appendingPathComponent("Media", isDirectory: true)
        try library.useMediaFolder(new)
        #expect(library.mediaFolder == new && library.items.count == 3 && library.missing.isEmpty)
        #expect(library.item(circle.id)?.words == ["loop"] && library.item(circle.id)?.file == "memes/Infinite game/circle.png")
        for path in ["memes/Infinite game/circle.png", "memes/a/b/x.png", "gifs/dance.gif"] {
            #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent(path).path), "\(path)")
            #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent(path).path), "\(path)")
        }
        #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("gifs").path))
        #expect(folder.names(in: old.appendingPathComponent("memes")) == [".hidden"])
        #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("memes/.hidden").path))
    }
}
