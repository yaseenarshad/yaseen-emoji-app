import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// The import of a GIF or a meme (D5 and D8 of YAZ-2919): the type and the size check, the change of a video
/// to a GIF, the still picture of a tile, and the words of a meme. Each public call is `async` and runs its work
/// in a detached task, off the main thread. Only Apple's frameworks: AVFoundation, ImageIO, Vision and CryptoKit.
public enum MediaImport {
    /// The largest file after the change, in bytes. Finder shows sizes in this unit (1 MB is 1,000,000 bytes).
    public static let sizeLimit = 10_000_000
    /// A longer video is surely larger than 10 MB as a GIF. It stops before the change.
    static let longestVideo: Double = 60
    /// A larger image file is surely larger than 10 MB after the change. The app does not read it.
    static let largestSource = 100_000_000
    static let framesPerSecond = 15
    /// The widest GIF from a video, in pixels.
    static let widestGIF: CGFloat = 480
    /// The side of the still picture of a tile, in pixels (D5).
    public static let thumbnailSide = 290

    public static let tooLargeText = "This file is larger than 10 MB."
    public static let wrongTypeText = "Yaseen Emoji takes GIF, MP4, MOV, PNG, JPEG and HEIC."
    static let unreadableText = "Yaseen Emoji can't read this file."

    /// Why a file cannot be added. The add window shows the text as the red line.
    public enum Failure: LocalizedError, Equatable {
        case tooLarge
        case wrongType
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return MediaImport.tooLargeText
            case .wrongType: return MediaImport.wrongTypeText
            case .unreadable: return MediaImport.unreadableText
            }
        }
    }

    /// `~/Library/Caches/Yaseen Emoji/thumbs`. It is not synced. Tests never use it.
    public static var defaultThumbnailFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yaseen Emoji/thumbs", isDirectory: true)
    }

    // MARK: Prepare a file (D5)

    /// Reads a file, finds its kind, changes it when needed, and gives the final bytes, their extension and the `id`.
    /// * A GIF with more than 1 frame is a GIF. A GIF with 1 frame, a PNG and a JPEG are memes. They stay as they are.
    /// * HEIC becomes JPEG, so each app can paste it. TIFF becomes PNG.
    /// * MP4 and MOV become a GIF: 15 frames a second, at most 480 pixels wide, loop forever.
    /// * Larger than 10 MB after the change: `Failure.tooLarge`. Each other type: `Failure.wrongType`.
    public static func prepare(_ source: URL) async throws -> PreparedFile {
        try await Task.detached(priority: .userInitiated) {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder) else { throw Failure.unreadable }
            guard !isFolder.boolValue else { throw Failure.wrongType }
            let values = try? source.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
            if let type = values?.contentType ?? UTType(filenameExtension: source.pathExtension), isVideo(type) {
                return try await gif(fromVideo: source)
            }
            if let size = values?.fileSize, size > largestSource { throw Failure.tooLarge }
            guard let bytes = try? Data(contentsOf: source) else { throw Failure.unreadable }
            return try prepareImage(bytes)
        }.value
    }

    /// The same as `prepare(_:)` for the bytes of a paste (D12). `type` is the type on the clipboard.
    /// Video bytes go into a temp file for AVFoundation, and the temp file is removed after the change.
    public static func prepare(data: Data, type: UTType) async throws -> PreparedFile {
        guard isVideo(type) else {
            return try await Task.detached(priority: .userInitiated) { try prepareImage(data) }.value
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YaseenEmoji-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("paste").appendingPathExtension(type.preferredFilenameExtension ?? "mov")
        try data.write(to: file)
        return try await prepare(file)
    }

    static func isVideo(_ type: UTType) -> Bool {
        type.conforms(to: .mpeg4Movie) || type.conforms(to: .quickTimeMovie)
    }

    /// An image: the type comes from the bytes, not from the file name.
    static func prepareImage(_ bytes: Data) throws -> PreparedFile {
        guard bytes.count <= largestSource else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let typeName = CGImageSourceGetType(source) as String?, let type = UTType(typeName),
              CGImageSourceGetCount(source) > 0
        else { throw Failure.wrongType }
        let file: PreparedFile
        if type == .gif {
            file = PreparedFile(bytes: bytes, ext: "gif", kind: CGImageSourceGetCount(source) > 1 ? .gif : .meme)
        } else if type == .png {
            file = PreparedFile(bytes: bytes, ext: "png", kind: .meme)
        } else if type == .jpeg {
            file = PreparedFile(bytes: bytes, ext: "jpg", kind: .meme)
        } else if type.conforms(to: .heic) || type.conforms(to: .heif) {
            file = PreparedFile(bytes: try convert(source, to: .jpeg), ext: "jpg", kind: .meme)
        } else if type == .tiff {
            file = PreparedFile(bytes: try convert(source, to: .png), ext: "png", kind: .meme)
        } else {
            throw Failure.wrongType
        }
        guard file.bytes.count <= sizeLimit else { throw Failure.tooLarge }
        return file
    }

    /// The first picture of `source` in a different type. It keeps the orientation and the color profile.
    private static func convert(_ source: CGImageSource, to type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw Failure.unreadable
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImageFromSource(destination, source, 0, options)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return data as Data
    }

    /// A video as an animated GIF (D5): 15 frames a second, at most 480 pixels wide, loop forever.
    /// A frame that AVFoundation cannot make gets the frame before it, so the GIF keeps its time.
    static func gif(fromVideo url: URL) async throws -> PreparedFile {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { throw Failure.unreadable }
        guard duration <= longestVideo else { throw Failure.tooLarge }

        let shown = naturalSize.applying(transform)
        let width = abs(shown.width), height = abs(shown.height)
        guard width > 0, height > 0 else { throw Failure.unreadable }
        let scale = min(1, widestGIF / width)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        // An exact frame is slow to decode. Half a GIF frame of tolerance is not visible.
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond * 2))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let count = max(1, Int((duration * Double(framesPerSecond)).rounded(.down)))
        let times = (0..<count).map { CMTime(value: CMTimeValue($0), timescale: CMTimeScale(framesPerSecond)) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, count, nil) else {
            throw Failure.unreadable
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        var added = 0
        func add(_ image: CGImage) {
            let delay = frameDelay(added)
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay],
            ] as CFDictionary)
            added += 1
        }
        var waiting = 0     // frames that failed before the first good frame
        var last: CGImage?
        for await result in generator.images(for: times) {
            guard let image = try? result.image else {
                if let last { add(last) } else { waiting += 1 }
                continue
            }
            for _ in 0...waiting { add(image) }
            waiting = 0
            last = image
        }
        guard added == count, CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        let file = PreparedFile(bytes: data as Data, ext: "gif", kind: .gif)
        guard file.bytes.count <= sizeLimit else { throw Failure.tooLarge }
        return file
    }

    /// The time of frame `index` in seconds. A GIF keeps whole hundredths of a second, and 1/15 s is 6.67 of them.
    /// ImageIO makes each 1/15 s into 7, so the GIF plays 5 % too slowly. Thus the frames get 7, 7 and 6 hundredths,
    /// and 3 frames take exactly 20 hundredths.
    static func frameDelay(_ index: Int) -> Double {
        func hundredths(_ frames: Int) -> Int { Int((Double(frames) * 100 / Double(framesPerSecond)).rounded()) }
        return Double(hundredths(index + 1) - hundredths(index)) / 100
    }

    // MARK: The still picture of a tile (D5)

    /// The still picture of an item: a 290 × 290 PNG of the first frame, aspect-fill, in `folder` as `<id>.png`.
    /// The `id` is the hash of the file, not its name: two files with one name in two folders get two stills, and an
    /// edit in place gets a new still (D22 of YAZ-3018). It makes the picture only when it is missing.
    /// `folder` is a parameter, so a test gives a temp folder.
    @discardableResult
    public static func thumbnail(of file: URL, id: String, into folder: URL) async throws -> URL {
        try await Task.detached(priority: .utility) { try makeThumbnail(of: file, id: id, into: folder) }.value
    }

    /// Removes the still picture of an item that is gone (D5).
    public static func removeThumbnail(of id: String, in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id).png"))
    }

    static func makeThumbnail(of file: URL, id: String, into folder: URL) throws -> URL {
        let target = folder.appendingPathComponent("\(id).png")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0
        else { throw Failure.unreadable }
        // The short side must fill the square, so the long side can be larger than 290.
        let side = CGFloat(thumbnailSide)
        let longest = side * CGFloat(max(pixelWidth, pixelHeight)) / CGFloat(min(pixelWidth, pixelHeight))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longest.rounded(.up)),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options), let square = square(image) else {
            throw Failure.unreadable
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.unreadable
        }
        CGImageDestinationAddImage(destination, square, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (data as Data).write(to: target, options: .atomic)
        return target
    }

    /// `image` as a square of 290 × 290 pixels, aspect-fill: the short side fills the square, and the long side is cut
    /// at both ends. The still picture of your tile and of a KLIPY tile (D5, D11 of YAZ-2919).
    static func square(_ image: CGImage) -> CGImage? {
        let side = CGFloat(thumbnailSide)
        guard image.width > 0, image.height > 0,
              let context = CGContext(data: nil, width: thumbnailSide, height: thumbnailSide, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let scale = max(side / CGFloat(image.width), side / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
        return context.makeImage()
    }

    // MARK: The words of a meme (D8)

    /// The small words that the words of a meme never have (D8). Words of 1 letter go too.
    static let smallWords: Set<String> = ["the", "a", "an", "of", "and", "to", "is"]
    /// At most this many read words (D8).
    static let mostWords = 30

    /// The words in the picture of a meme (D8), with Apple's text reader on this Mac (Vision, accurate level).
    /// Lower case, in reading order, no copy, at most 30 words, no word of 1 letter, and no small word.
    /// `bytes` are the bytes of the file, so the add window can read a meme before it is saved. Only for a meme.
    public static func readText(in bytes: Data) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(data: bytes, options: [:])
            guard (try? handler.perform([request])) != nil else { return [] }
            let lines = (request.results ?? [])
                .sorted { a, b in
                    // Vision's boxes have the origin at the bottom left: a larger y is higher.
                    abs(a.boundingBox.midY - b.boundingBox.midY) > 0.02
                        ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
                }
                .compactMap { $0.topCandidates(1).first?.string }
            return words(in: lines.joined(separator: " "))
        }.value
    }

    /// The words of a text, with the rules of D8.
    static func words(in text: String) -> [String] {
        var result: [String] = []
        let parts = text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }
        for part in parts {
            let word = part.trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
            guard word.count > 1, !smallWords.contains(word), !result.contains(word) else { continue }
            result.append(word)
            if result.count == mostWords { break }
        }
        return result
    }
}
