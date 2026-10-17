import AppKit
import ImageIO

/// The still pictures of the tiles (D5 and D11 of YAZ-2919). `MediaImport.thumbnail` makes the 290 × 290 PNG
/// in the thumbs folder when it is missing. This class decodes it off the main thread and keeps at most 120 in memory.
///
/// The grid asks for the tiles on the screen with `want(_:)`. At most 4 loads run at a time, so a fast scroll
/// to the end of 2,000 GIFs does not start 2,000 loads: a tile that left the screen before its load started is dropped.
@MainActor
final class Thumbnails {
    /// The most still pictures in memory (D11 of YAZ-2919). 290 × 290 pixels × 4 bytes is about 336 KB each,
    /// so 120 is about 40 MB.
    static let countLimit = 120
    /// The most loads at the same time.
    static let loadsAtOnce = 4

    /// One tile that the grid wants: the `id` of the item and its file.
    struct Want: Equatable {
        let id: String
        let file: URL
    }

    /// `~/Library/Caches/Yaseen Emoji/thumbs` in the app, a temp folder in a test.
    let folder: URL
    /// Runs on the main thread when the still picture of `id` is in memory. The grid draws that tile again.
    var onLoad: (String) -> Void = { _ in }

    /// The still pictures in memory: your tiles by `id`, and the KLIPY tiles by URL (`KlipyResults` gets this cache).
    /// One limit of 120 for both kinds (D11). An `id` has 16 hex characters, so it is never a URL.
    let cache = NSCache<NSString, NSImage>()
    private var loading: Set<String> = []
    private var waiting: [Want] = []
    /// The items whose file could not give a still picture. They stay grey. A new open tries again.
    private var failed: Set<String> = []
    /// The items that showed at the last clean-up of the still pictures, or nil before the first one.
    private var shownAtCleanUp: Set<String>?

    init(folder: URL) {
        self.folder = folder
        cache.countLimit = Thumbnails.countLimit
    }

    /// The still picture of `id`, or nil when it is not in memory.
    func image(_ id: String) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    /// Puts one still picture in memory. The cache drops the oldest when it has 120.
    func keep(_ image: NSImage, for id: String) {
        cache.setObject(image, forKey: id as NSString)
    }

    /// The tiles on the screen now, first to last. The loads that wait for tiles that left the screen stop.
    func want(_ tiles: [Want]) {
        waiting = tiles.filter { image($0.id) == nil && !loading.contains($0.id) && !failed.contains($0.id) }
        startLoads()
    }

    /// A new open of the panel: the files that failed get a new try (git can pull them).
    func retryFailed() {
        failed = []
    }

    /// Deletes the still picture of each item that does not show (D5): removed on this Mac or on a different Mac,
    /// or its file is gone (deleted in Finder, D13 update on YAZ-2926). `shown` are the `id`s of your items that show.
    /// The panel calls it at each open. It works only when `shown` changed, and the folder list and the deletes run
    /// off the main thread. A file that comes back (a `git pull`) gets its still picture again when its tile shows.
    func removeStills(keeping shown: Set<String>) {
        guard shown != shownAtCleanUp else { return }
        for id in (shownAtCleanUp ?? []).subtracting(shown) { cache.removeObject(forKey: id as NSString) }
        shownAtCleanUp = shown
        let folder = self.folder
        Task.detached(priority: .utility) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".png") {
                let id = String(name.dropLast(".png".count))
                if !shown.contains(id) { MediaImport.removeThumbnail(of: id, in: folder) }
            }
        }
    }

    private func startLoads() {
        while loading.count < Thumbnails.loadsAtOnce, !waiting.isEmpty {
            let next = waiting.removeFirst()
            loading.insert(next.id)
            let folder = self.folder
            Task { [weak self] in
                let image = await Thumbnails.load(next.file, into: folder)
                self?.finish(next.id, image)
            }
        }
    }

    private func finish(_ id: String, _ image: CGImage?) {
        loading.remove(id)
        if let image {
            keep(NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2)), for: id)
            onLoad(id)
        } else {
            failed.insert(id)
        }
        startLoads()
    }

    /// Makes the PNG when it is missing, then decodes it, all off the main thread.
    /// The decode happens here, not at the first draw, so a scroll does not wait for it.
    nonisolated static func load(_ file: URL, into folder: URL) async -> CGImage? {
        guard let png = try? await MediaImport.thumbnail(of: file, into: folder) else { return nil }
        return await Task.detached(priority: .utility) { decode(png) }.value
    }

    /// Decodes the PNG into a bitmap that this app owns. ImageIO keeps its own decode in memory that macOS can
    /// purge, and then the first draw decodes again on the main thread. A draw into our own bitmap stops that.
    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
