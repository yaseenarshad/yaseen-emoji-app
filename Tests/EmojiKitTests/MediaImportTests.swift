import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EmojiKit

/// The add of a file (YAZ-2922, D5 and D8 of YAZ-2919): the type, the size limit, MP4 to GIF, the still picture
/// and the words of a meme. Each file is made in the test, in a temp folder.
@Suite struct MediaImportTests {
    private func store(in folder: TempFolder) -> LibraryStore {
        let store = LibraryStore(url: folder.defaultFolder.appendingPathComponent("library-A.json"), mediaFolder: folder.defaultFolder,
                                 trash: FakeTrash(folder: folder.url.appendingPathComponent("Trash")), now: StepClock().now)
        store.load()
        return store
    }

    /// D5: a 1-second MP4 becomes an animated GIF of 15 frames, at most 480 pixels wide, that loops forever.
    @Test func anMP4BecomesAnAnimatedGIF() async throws {
        let folder = try TempFolder()
        let video = folder.url.appendingPathComponent("clip.mp4")
        try await makeTestVideo(at: video, seconds: 1)

        let file = try await MediaImport.prepare(video)
        #expect(file.kind == .gif && file.ext == "gif" && file.id.count == 16)
        #expect(file.id == String(MediaHash.hex(file.bytes).prefix(16)))
        let info = frameInfo(file.bytes)
        #expect(info.frames == 15)
        #expect(info.width == 480 && info.height == 270)
        #expect(file.bytes.count > 0 && file.bytes.count < MediaImport.sizeLimit)
        let source = try #require(CGImageSourceCreateWithData(file.bytes as CFData, nil))
        let gif = (CGImageSourceCopyProperties(source, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect(gif?[kCGImagePropertyGIFLoopCount] as? Int == 0)
        // 15 frames play in 1 s: ImageIO keeps whole hundredths, so the frames get 7, 7 and 6 of them.
        let delays = (0..<info.frames).map { index in
            ((CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary]
                as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
        }
        #expect(abs(delays.reduce(0, +) - 1) < 0.001, "\(delays)")

        // A MOV and the bytes of a paste (D12) also become a GIF.
        let movie = folder.url.appendingPathComponent("clip.mov")
        try await makeTestVideo(at: movie, seconds: 0.5, width: 320, height: 240, fileType: .mov)
        let fromMovie = try await MediaImport.prepare(data: Data(contentsOf: movie), type: .quickTimeMovie)
        #expect(fromMovie.kind == .gif && frameInfo(fromMovie.bytes).frames == 7 && frameInfo(fromMovie.bytes).width == 320)
    }

    /// D5 and D12: the same file added two times is one item. The second add adds only its new words, and says so.
    /// The kind of each still file, and a GIF that the add window marks as a meme.
    @Test func theSameFileTwoTimesIsOneItem() async throws {
        let folder = try TempFolder()
        let library = store(in: folder)
        let animated = folder.url.appendingPathComponent("dance.gif")
        try makeTestImage(width: 40, height: 30, type: .gif, frames: 3).write(to: animated)

        let first = try await MediaImport.prepare(animated)
        #expect(try first.kind == .gif && first.bytes == Data(contentsOf: animated))     // kept as it is
        let added = try library.add(first, words: ["dance"])
        let second = try library.add(try await MediaImport.prepare(animated), words: ["dance", "party"])
        #expect(second == .alreadyThere(library.item(first.id)!))
        #expect(library.items.count == 1 && library.items[0].words == ["dance", "party"])
        #expect(library.items[0].added == added.item.added)
        #expect(folder.names(in: library.mediaFolder.appendingPathComponent("gifs")) == ["\(first.id).gif"])

        // The kind of each still file.
        let still = folder.url.appendingPathComponent("still.gif")
        try makeTestImage(width: 40, height: 30, type: .gif).write(to: still)
        let png = folder.url.appendingPathComponent("meme.png")
        try makeTestImage(width: 40, height: 30, type: .png).write(to: png)
        let jpeg = folder.url.appendingPathComponent("photo.jpeg")
        try makeTestImage(width: 40, height: 30, type: .jpeg).write(to: jpeg)
        let heic = folder.url.appendingPathComponent("photo.heic")
        try makeTestImage(width: 40, height: 30, type: .heic).write(to: heic)
        let named = folder.url.appendingPathComponent("named-wrong.gif")     // a PNG with a GIF name
        try Data(contentsOf: png).write(to: named)
        for (url, ext) in [(still, "gif"), (png, "png"), (jpeg, "jpg"), (heic, "jpg"), (named, "png")] {
            let file = try await MediaImport.prepare(url)
            #expect(file.kind == .meme && file.ext == ext, "\(url.lastPathComponent)")
        }
        let fromHEIC = try await MediaImport.prepare(heic)
        #expect(CGImageSourceCreateWithData(fromHEIC.bytes as CFData, nil).flatMap(CGImageSourceGetType) as String? == UTType.jpeg.identifier)
        let tiff = try await MediaImport.prepare(data: makeTestImage(width: 40, height: 30, type: .tiff), type: .tiff)
        #expect(tiff.kind == .meme && tiff.ext == "png")

        // The add window marks the GIF as a meme: it goes into `memes/`.
        let other = folder.url.appendingPathComponent("wave.gif")
        try makeTestImage(width: 41, height: 30, type: .gif, frames: 2).write(to: other)
        let meme = try library.add(try await MediaImport.prepare(other), as: .meme, words: ["wave"]).item
        #expect(meme.kind == .meme && meme.file == "memes/\(meme.id).gif" && meme.key == "meme:\(meme.id)")
    }

    /// D5: a file larger than 10 MB, a text file, a PDF and a folder give the right red line.
    @Test func theSizeLimitAndTheWrongTypes() async throws {
        let folder = try TempFolder()
        // Noise does not compress: a 2,200 × 1,600 PNG of noise is about 10.6 MB.
        let large = folder.url.appendingPathComponent("large.png")
        try makeTestImage(width: 2_200, height: 1_600, type: .png, noise: true).write(to: large)
        #expect(try Data(contentsOf: large).count > MediaImport.sizeLimit)
        await #expect(throws: MediaImport.Failure.tooLarge) { try await MediaImport.prepare(large) }
        #expect(MediaImport.Failure.tooLarge.localizedDescription == "This file is larger than 10 MB.")

        let text = folder.url.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        await #expect(throws: MediaImport.Failure.wrongType) { try await MediaImport.prepare(text) }
        #expect(MediaImport.Failure.wrongType.localizedDescription == "Yaseen Emoji takes GIF, MP4, MOV, PNG, JPEG and HEIC.")
        let pdf = folder.url.appendingPathComponent("page.pdf")
        try Data("%PDF-1.4\n1 0 obj << >> endobj\n%%EOF\n".utf8).write(to: pdf)
        await #expect(throws: MediaImport.Failure.wrongType) { try await MediaImport.prepare(pdf) }
        await #expect(throws: MediaImport.Failure.wrongType) { try await MediaImport.prepare(folder.url) }
        // A file with a video name that is not a video.
        let fake = folder.url.appendingPathComponent("fake.mp4")
        try Data("not a video".utf8).write(to: fake)
        await #expect(throws: MediaImport.Failure.unreadable) { try await MediaImport.prepare(fake) }
    }

    /// D5: the still picture is a 290 × 290 PNG of the first frame. It is made again when it is missing.
    @Test func theStillPictureOfATile() async throws {
        let folder = try TempFolder()
        let file = folder.url.appendingPathComponent("3fa9c1d2e8b04a77.gif")
        try makeTestImage(width: 600, height: 200, type: .gif, frames: 2).write(to: file)
        let thumbs = folder.url.appendingPathComponent("Caches/thumbs", isDirectory: true)

        let thumb = try await MediaImport.thumbnail(of: file, into: thumbs)
        #expect(thumb == thumbs.appendingPathComponent("3fa9c1d2e8b04a77.png"))
        let bytes = try Data(contentsOf: thumb)
        let info = frameInfo(bytes)
        #expect(info.frames == 1 && info.width == 290 && info.height == 290)
        #expect(CGImageSourceCreateWithData(bytes as CFData, nil).flatMap(CGImageSourceGetType) as String? == UTType.png.identifier)

        let made = try FileManager.default.attributesOfItem(atPath: thumb.path)[.modificationDate] as? Date
        try await MediaImport.thumbnail(of: file, into: thumbs)            // it is there: no new picture
        #expect(try FileManager.default.attributesOfItem(atPath: thumb.path)[.modificationDate] as? Date == made)
        MediaImport.removeThumbnail(of: "3fa9c1d2e8b04a77", in: thumbs)
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
        try await MediaImport.thumbnail(of: file, into: thumbs)            // missing: made again
        #expect(frameInfo(try Data(contentsOf: thumb)).width == 290)
    }

    /// D8: Apple's text reader reads a word drawn into a picture. Then the rules of the words.
    @Test func readTextReadsTheWordsOfAMeme() async throws {
        let picture = makeTestImage(width: 800, height: 240, type: .png, text: "HELLO")
        let words = await MediaImport.readText(in: picture)
        #expect(words.contains("hello"), "\(words)")

        #expect(MediaImport.words(in: "THE Cat is ON a mat, and the CAT's hat! I") == ["cat", "on", "mat", "cat's", "hat"])
        #expect(MediaImport.words(in: "'Don't' stop 2 me 42").contains("don't"))
        let many = (1...40).map { "word\($0)" }.joined(separator: " ")
        #expect(MediaImport.words(in: many).count == 30)
        #expect(await MediaImport.readText(in: Data("not a picture".utf8)).isEmpty)
    }

    /// The numbers of YAZ-2922: the change of a 5-second MP4 to a GIF, and the size of the GIF.
    /// Run `swift test -c release -Xswiftc -enable-testing --filter MediaImportTests` for the release numbers.
    @Test func theTimeOfAFiveSecondClip() async throws {
        let folder = try TempFolder()
        let video = folder.url.appendingPathComponent("five.mp4")
        try await makeTestVideo(at: video, seconds: 5, width: 1_280, height: 720)
        let videoBytes = try Data(contentsOf: video).count

        var times: [Double] = []
        var size = 0
        var frames = 0
        let clock = ContinuousClock()
        for _ in 0..<3 {
            let start = clock.now
            let file = try await MediaImport.prepare(video)
            let elapsed = clock.now - start
            times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            size = file.bytes.count
            frames = frameInfo(file.bytes).frames
        }
        let median = times.sorted()[1]
        print("TIMING [\(buildKind)] MP4 to GIF: 5 s clip 1280x720 30 fps, \(videoBytes) bytes; GIF \(frames) frames 480x270, \(size) bytes; median \(String(format: "%.0f", median)) ms of \(times.map { String(format: "%.0f", $0) })")
        #expect(frames == 75)
        #expect(size < MediaImport.sizeLimit)
        // A generous bound, so CI is not flaky. The estimate of D5 is about 1 s.
        #expect(median < 20_000)
    }
}
