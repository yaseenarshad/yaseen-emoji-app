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

    private let cache = NSCache<NSString, NSImage>()
    private var loading: Set<String> = []
    private var waiting: [Want] = []
    /// The items whose file could not give a still picture. They stay grey. A new open tries again.
    private var failed: Set<String> = []
    /// The removed items whose still picture is deleted already.
    private var removedDone: Set<String> = []

    init(folder: URL) {
        self.folder = folder
        cache.countLimit = Thumbnails.countLimit
    }

    /// The still picture of `id`, or nil when it is not in memory.
    func image(_ id: String) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    /// True when the file of `id` gave no still picture.
    func hasFailed(_ id: String) -> Bool { failed.contains(id) }

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

    /// Deletes the still picture of a removed item, in memory and on disk (D5).
    func removeStill(of id: String) {
        cache.removeObject(forKey: id as NSString)
        removedDone.insert(id)
        let folder = self.folder
        Task.detached(priority: .utility) { MediaImport.removeThumbnail(of: id, in: folder) }
    }

    /// Deletes the still pictures of the items that are removed, on this Mac or on a different Mac (D3, D5).
    /// The panel calls it at each open. An item is done one time only.
    func removeStills(ofRemoved items: some Sequence<Item>) {
        let gone = items.filter { $0.isRemoved && $0.file != nil && !removedDone.contains($0.id) }.map(\.id)
        guard !gone.isEmpty else { return }
        for id in gone {
            cache.removeObject(forKey: id as NSString)
            removedDone.insert(id)
        }
        let folder = self.folder
        Task.detached(priority: .utility) {
            for id in gone { MediaImport.removeThumbnail(of: id, in: folder) }
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

    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
