import AppKit

/// The moving pictures of the GIF tiles on the screen (D11 update on YAZ-2925): your own GIF files and the
/// `sm.gif` previews of KLIPY. One class for both kinds, with the load as a parameter, so a test gives a fake one.
///
/// The grid gives the tiles on the screen with `want(_:)`, in the order of the grid. At most `atOnce` loads run at
/// the same time, the first tiles first. A load for a tile that left the screen stops. At most `kept` pictures
/// stay in memory. The bytes load and the `NSImage` decodes off the main thread.
@MainActor
final class MovingPictures {
    typealias Load = @Sendable (URL) async throws -> Data

    /// The most loads at the same time.
    let atOnce: Int
    /// Runs on the main thread when a moving picture is in memory. The grid shows it.
    var onLoad: () -> Void = {}

    private let load: Load
    private let cache = NSCache<NSString, NSImage>()
    private var running: [URL: Task<Void, Never>] = [:]
    /// The tiles on the screen with no picture and no load yet, in the order of the grid.
    private var waiting: [URL] = []
    /// The files that gave no picture. They stay still pictures. A new open tries again.
    private var failed: Set<URL> = []

    init(kept: Int, atOnce: Int, load: @escaping Load) {
        self.atOnce = atOnce
        self.load = load
        cache.countLimit = kept
    }

    /// The URL of your own GIF file for `want(_:)`: the file with its `id` as the fragment. The cache key then has the
    /// path and the `id`, so an edit in place (a new hash at the same path, D22 of YAZ-3018) loads the new picture.
    /// A load of a file URL ignores the fragment.
    static func ownURL(_ file: URL, id: String) -> URL {
        var parts = URLComponents(url: file, resolvingAgainstBaseURL: false)
        parts?.fragment = id
        return parts?.url ?? file
    }

    /// The moving picture of `url`, or nil when it is not in memory.
    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    /// The URLs whose load runs now. For a test.
    var loading: Set<URL> { Set(running.keys) }

    /// The tiles on the screen now, first to last. The loads of the other tiles stop.
    func want(_ urls: [URL]) {
        var seen: Set<URL> = []
        let wanted = urls.filter { seen.insert($0).inserted && image(for: $0) == nil && !failed.contains($0) }
        let keep = Set(wanted)
        for (url, task) in running where !keep.contains(url) {
            task.cancel()
            running[url] = nil
        }
        waiting = wanted.filter { running[$0] == nil }
        startLoads()
    }

    /// The panel hides: all loads stop. The pictures in memory stay.
    func stop() {
        want([])
    }

    /// A new open of the panel: the files that failed get a new try.
    func retryFailed() {
        failed = []
    }

    private func startLoads() {
        while running.count < atOnce, !waiting.isEmpty {
            let url = waiting.removeFirst()
            let load = self.load
            running[url] = Task { [weak self] in
                let data = try? await load(url)
                let image = await MovingPictures.decode(data)
                guard !Task.isCancelled else { return }
                self?.finish(url, image?.image)
            }
        }
    }

    private func finish(_ url: URL, _ image: NSImage?) {
        guard running.removeValue(forKey: url) != nil else { return }
        if let image {
            cache.setObject(image, forKey: url.absoluteString as NSString)
            onLoad()
        } else {
            failed.insert(url)
        }
        startLoads()
    }

    /// An `NSImage` that crosses from the decode thread to the main thread. Nothing else uses it on the way.
    struct Decoded: @unchecked Sendable {
        let image: NSImage
    }

    /// Makes the `NSImage` of a GIF off the main thread. `NSImageView` decodes the frames while it plays.
    nonisolated static func decode(_ data: Data?) async -> Decoded? {
        guard let data else { return nil }
        return await Task.detached(priority: .utility) { NSImage(data: data).map(Decoded.init) }.value
    }
}

/// One moving picture over a GIF tile (D11 update on YAZ-2925): round corners, the GIF in aspect-fill, and the
/// "KLIPY" mark of a KLIPY tile. It lets the mouse through, so a click, a drag and a right-click go to the grid.
/// The grid keeps at most 15 and uses them again for new tiles.
final class MovingTileView: PassThroughView {
    /// The place in the grid and the file or preview that this view shows. Nil when the view is free.
    var slot: (index: Int, url: URL)?
    private let imageView = NSImageView()
    private let mark = KlipyMarkView()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = EmojiGridView.tileRadius
        layer?.masksToBounds = true
        isHidden = true
        imageView.animates = true
        imageView.imageScaling = .scaleAxesIndependently
        addSubview(imageView)
        addSubview(mark)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// True when the moving picture shows.
    var isPlaying: Bool { !isHidden && imageView.image != nil }

    /// Puts the view over a tile. It stays hidden until `play(_:)`, so the still picture shows until then.
    func place(_ tile: NSRect, isKlipy: Bool) {
        frame = tile
        mark.frame = bounds
        mark.isHidden = !isKlipy
        mark.needsDisplay = true
        layOutImage()
    }

    func play(_ image: NSImage) {
        if imageView.image !== image {
            imageView.image = image
            layOutImage()
        }
        isHidden = false
    }

    /// The view is free: no picture, nothing plays, hidden.
    func clear() {
        slot = nil
        imageView.image = nil
        isHidden = true
    }

    /// Aspect-fill: the short side fills the tile, and the round box cuts the long side.
    private func layOutImage() {
        let box = bounds.size
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            imageView.frame = bounds
            return
        }
        let scale = max(box.width / image.size.width, box.height / image.size.height)
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = NSRect(x: (box.width - drawn.width) / 2, y: (box.height - drawn.height) / 2,
                                 width: drawn.width, height: drawn.height)
    }
}

/// The "KLIPY" mark above a moving KLIPY tile. The grid draws the same mark under it on the still picture.
final class KlipyMarkView: PassThroughView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        EmojiGridView.drawMark(in: bounds)
    }
}
