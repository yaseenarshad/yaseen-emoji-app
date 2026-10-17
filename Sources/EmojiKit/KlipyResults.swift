import AppKit
import ImageIO

/// KLIPY in the GIFs and Memes tabs (D1, D2, D7, D11 of YAZ-2919): the real `OnlineResults` of the app.
///
/// It runs the search after the pause (`SearchDebouncer`), the next pages, the lookup of saved and learned items
/// by slug, the 300 ms prefetch and the 3 s wait of a paste file, and the tile pictures. All of it stays in memory
/// for the session. Only the paste file goes on disk, as a temp file (`PasteFiles`, D6 and D7).
/// The network, the download, the sleep of the pause and the clock are parameters, so a test never goes online and never waits.
@MainActor
final class KlipyResults: OnlineResults {
    /// The grey line of "From KLIPY" while KLIPY searches.
    static let searchingText = "Searching KLIPY…"
    /// The blue box sits this long on a KLIPY tile before the paste file downloads.
    static let prefetchDelay: TimeInterval = 0.3
    /// A pick waits this long for a paste file that is not ready.
    static let pasteWait: TimeInterval = 3
    /// The searches (text and kind) that stay in memory. A tab change back or a Backspace sends no new request.
    static let searchesKept = 8
    /// The KLIPY items that stay known by their slug.
    static let itemsKept = 500
    /// The still pictures in memory (D11 of YAZ-2919), and the moving pictures.
    static let stillsKept = 120
    static let movingKept = 4
    /// The still pictures that load at the same time.
    static let stillsAtOnce = 4
    /// The most slugs in one items call. A normal lookup has fewer, so it is one call.
    static let slugsPerCall = 50
    /// The side of a still picture in pixels: the same square as your own tiles (D5 of YAZ-2919).
    nonisolated static let stillSide = 290

    typealias Download = @Sendable (OnlineItem) async throws -> URL
    typealias FetchPicture = @Sendable (URL) async throws -> Data

    private(set) var isOn = false
    var onChange: () -> Void = {}
    var onPicture: () -> Void = {}

    private let library: OnlineLibrary
    private let keys: KeyStore
    private let download: Download
    private let fetchPicture: FetchPicture
    private let later: Later
    private let debouncer: SearchDebouncer

    // MARK: The state of the searches

    private struct SearchKey: Hashable {
        let text: String
        let kind: ItemKind
    }

    private struct SearchState {
        var items: [OnlineItem] = []
        var nextPage = 1
        var hasMore = true
        var isLoading = true
        var error: OnlineError?
    }

    private var searches: [SearchKey: SearchState] = [:]
    /// The order of `searches`, the oldest first.
    private var searchOrder: [SearchKey] = []
    /// The search whose request waits for the pause or runs. One at a time.
    private var current: SearchKey?
    private var pageTask: Task<Void, Never>?

    // MARK: The items by slug (D7)

    private var known: [ItemKind: [String: OnlineItem]] = [:]
    /// The order of `known`, the oldest first.
    private var knownOrder: [(kind: ItemKind, slug: String)] = []
    /// The slugs that KLIPY does not have for a kind: deleted items, or a learned slug of the other kind.
    private var deleted: [ItemKind: Set<String>] = [:]
    private var wanted: [ItemKind: Set<String>] = [:]
    private var asking: [ItemKind: Set<String>] = [:]
    /// The slugs of a lookup that failed. The next open tries again.
    private var failedLookups: [ItemKind: Set<String>] = [:]
    private var lookupIsPlanned = false

    // MARK: The paste files (D6)

    private var files: [String: URL] = [:]
    private var downloads: [String: (token: Int, task: Task<Void, Never>)] = [:]
    private var waiters: [String: [Int: @MainActor (URL?) -> Void]] = [:]
    private var nextToken = 0
    /// The KLIPY item with the blue box, and a count that changes at each move.
    private var hovered: String?
    private var hoverCount = 0

    // MARK: The pictures

    private let stills = NSCache<NSString, NSImage>()
    private let movings = NSCache<NSString, NSImage>()
    private var stillsLoading: Set<URL> = []
    /// The still pictures that the grid wants, the newest last.
    private var stillsWaiting: [URL] = []
    private var failedPictures: Set<URL> = []
    private var movingLoad: (url: URL, task: Task<Void, Never>)?

    init(library: OnlineLibrary, keys: KeyStore, later: Later, download: @escaping Download,
         fetchPicture: @escaping FetchPicture,
         sleep: @escaping SearchDebouncer.Sleep = { try await Task.sleep(for: $0) }) {
        self.library = library
        self.keys = keys
        self.later = later
        self.download = download
        self.fetchPicture = fetchPicture
        debouncer = SearchDebouncer(sleep: sleep)
        stills.countLimit = KlipyResults.stillsKept
        movings.countLimit = KlipyResults.movingKept
        isOn = keys.read() != nil
    }

    /// The app: KLIPY, the paste files and the pictures on one session with the 5 s time-out.
    convenience init(keys: KeyStore, session: URLSession, pasteFiles: PasteFiles, later: Later,
                     sleep: @escaping SearchDebouncer.Sleep = { try await Task.sleep(for: $0) }) {
        self.init(library: KlipyLibrary(keys: keys, session: session), keys: keys, later: later,
                  download: { try await pasteFiles.download($0) },
                  fetchPicture: { try await KlipyLibrary.fetch($0, session: session) },
                  sleep: sleep)
    }

    func refresh() {
        isOn = keys.read() != nil
        failedLookups = [:]
        failedPictures = []
        // A search with an error does not stay: the next time, KLIPY gets the request again.
        for (key, state) in searches where state.error != nil && key != current { forget(key) }
    }

    func stop() {
        debouncer.cancel()
        pageTask?.cancel()
        pageTask = nil
        dropCurrent()
        for download in downloads.values { download.task.cancel() }
        downloads = [:]
        waiters = [:]
        hovered = nil
        hoverCount += 1
        movingLoad?.task.cancel()
        movingLoad = nil
    }

    // MARK: Search and pages

    func section(for text: String, kind: ItemKind) -> OnlineSection? {
        // D2: no key, no request.
        guard isOn else { return OnlineSection(items: [], line: OnlineError.noKey.line) }
        let key = SearchKey(text: text, kind: kind)
        if let state = searches[key] { return KlipyResults.section(of: state) }
        startSearch(key)
        return OnlineSection(items: [], line: KlipyResults.searchingText, isLoading: true)
    }

    private static func section(of state: SearchState) -> OnlineSection {
        if state.isLoading && state.items.isEmpty {
            return OnlineSection(items: [], line: searchingText, isLoading: true)
        }
        return OnlineSection(items: state.items, line: state.error?.line, isLoading: state.isLoading)
    }

    /// The first page, after the pause of D11. A new text cancels the wait and the request of the old text.
    private func startSearch(_ key: SearchKey) {
        pageTask?.cancel()
        pageTask = nil
        dropCurrent()
        for (old, state) in searches where state.error != nil { forget(old) }
        current = key
        searches[key] = SearchState()
        remember(key)
        let library = self.library
        debouncer.change({ try await library.search(key.text, kind: key.kind, page: 1) }) { [weak self] result in
            self?.finish(key, page: 1, result)
        }
    }

    func loadMore(for text: String, kind: ItemKind) {
        let key = SearchKey(text: text, kind: kind)
        guard isOn, current == nil, var state = searches[key], !state.isLoading, state.hasMore, state.error == nil,
              state.nextPage <= KlipyLibrary.lastPage else { return }
        state.isLoading = true
        searches[key] = state
        current = key
        let page = state.nextPage
        let library = self.library
        pageTask = Task { [weak self] in
            let result: Result<OnlinePage, Error>
            do {
                result = .success(try await library.search(key.text, kind: key.kind, page: page))
            } catch {
                result = .failure(error)
            }
            if Task.isCancelled { return }
            if case .failure(let error) = result, error is CancellationError { return }
            self?.finish(key, page: page, result)
        }
    }

    private func finish(_ key: SearchKey, page: Int, _ result: Result<OnlinePage, Error>) {
        guard current == key, var state = searches[key] else { return }
        current = nil
        pageTask = nil
        state.isLoading = false
        switch result {
        case .success(let answer):
            // KLIPY's order stays (KLIPY's rule 4).
            state.items += answer.items
            state.hasMore = answer.hasMore
            state.nextPage = page + 1
            keep(answer.items)
        case .failure(let error):
            state.error = error as? OnlineError ?? .badResponse
        }
        searches[key] = state
        onChange()
    }

    /// The search that waits or runs stops. A first page that did not come goes away; a next page can come later.
    private func dropCurrent() {
        guard let key = current else { return }
        current = nil
        guard var state = searches[key] else { return }
        if state.items.isEmpty {
            forget(key)
        } else {
            state.isLoading = false
            searches[key] = state
        }
    }

    private func remember(_ key: SearchKey) {
        searchOrder.removeAll { $0 == key }
        searchOrder.append(key)
        while searchOrder.count > KlipyResults.searchesKept, let oldest = searchOrder.first(where: { $0 != current }) {
            forget(oldest)
        }
    }

    private func forget(_ key: SearchKey) {
        searches[key] = nil
        searchOrder.removeAll { $0 == key }
    }

    // MARK: Items by slug (D7)

    func item(_ slug: String, kind: ItemKind) -> OnlineItem? {
        if let item = known[kind]?[slug] { return item }
        guard isOn, deleted[kind]?.contains(slug) != true, failedLookups[kind]?.contains(slug) != true,
              asking[kind]?.contains(slug) != true else { return nil }
        wanted[kind, default: []].insert(slug)
        if !lookupIsPlanned {
            lookupIsPlanned = true
            // After the build of the grid: all the unknown slugs of one build go in one call.
            Task { [weak self] in self?.lookUp() }
        }
        return nil
    }

    private func lookUp() {
        lookupIsPlanned = false
        for kind in ItemKind.allCases {
            let slugs = (wanted[kind] ?? []).sorted()
            wanted[kind] = nil
            guard !slugs.isEmpty else { continue }
            asking[kind, default: []].formUnion(slugs)
            for start in stride(from: 0, to: slugs.count, by: KlipyResults.slugsPerCall) {
                let part = Array(slugs[start..<min(start + KlipyResults.slugsPerCall, slugs.count)])
                let library = self.library
                Task { [weak self] in
                    let result: Result<[OnlineItem], Error>
                    do {
                        result = .success(try await library.items(ids: part, kind: kind))
                    } catch {
                        result = .failure(error)
                    }
                    self?.lookedUp(part, kind: kind, result)
                }
            }
        }
    }

    private func lookedUp(_ slugs: [String], kind: ItemKind, _ result: Result<[OnlineItem], Error>) {
        asking[kind]?.subtract(slugs)
        switch result {
        case .success(let items):
            let found = items.filter { $0.kind == kind }
            keep(found)
            // D7: an item that KLIPY deleted drops from "Yours", with no grey line. Its counts stay.
            deleted[kind, default: []].formUnion(Set(slugs).subtracting(found.map(\.id)))
            if !found.isEmpty { onChange() }
        case .failure:
            failedLookups[kind, default: []].formUnion(slugs)
        }
    }

    /// Keeps the items by their slug, at most `itemsKept`. The oldest go first.
    private func keep(_ items: [OnlineItem]) {
        for item in items {
            if known[item.kind]?[item.id] == nil { knownOrder.append((item.kind, item.id)) }
            known[item.kind, default: [:]][item.id] = item
        }
        if knownOrder.count > KlipyResults.itemsKept {
            for old in knownOrder.prefix(knownOrder.count - KlipyResults.itemsKept) { known[old.kind]?[old.slug] = nil }
            knownOrder.removeFirst(knownOrder.count - KlipyResults.itemsKept)
        }
    }

    // MARK: The paste file (D6): the prefetch and the wait

    private static func fileKey(_ item: OnlineItem) -> String { "\(item.kind.rawValue):\(item.id)" }

    func pasteFile(for item: OnlineItem) -> URL? {
        let key = KlipyResults.fileKey(item)
        guard let url = files[key] else { return nil }
        // The 5-minute clean-up can delete it.
        guard FileManager.default.fileExists(atPath: url.path) else {
            files[key] = nil
            return nil
        }
        return url
    }

    func selectionChanged(to item: OnlineItem?) {
        let key = item.map(KlipyResults.fileKey)
        guard key != hovered else { return }
        // A move stops the prefetch of the tile before, unless a pick waits for it.
        if let old = hovered, waiters[old]?.isEmpty ?? true, let running = downloads.removeValue(forKey: old) {
            running.task.cancel()
        }
        hovered = key
        hoverCount += 1
        guard let item, pasteFile(for: item) == nil else { return }
        let count = hoverCount
        later.run(after: KlipyResults.prefetchDelay) { [weak self] in
            guard let self, self.hoverCount == count else { return }
            self.startDownload(item)
        }
    }

    func getPasteFile(for item: OnlineItem, done: @escaping @MainActor (URL?) -> Void) {
        if let url = pasteFile(for: item) { return done(url) }
        let key = KlipyResults.fileKey(item)
        nextToken += 1
        let token = nextToken
        waiters[key, default: [:]][token] = done
        startDownload(item)
        later.run(after: KlipyResults.pasteWait) { [weak self] in
            guard let done = self?.waiters[key]?.removeValue(forKey: token) else { return }
            done(nil)
        }
    }

    private func startDownload(_ item: OnlineItem) {
        let key = KlipyResults.fileKey(item)
        guard downloads[key] == nil, pasteFile(for: item) == nil else { return }
        nextToken += 1
        let token = nextToken
        let download = self.download
        let task = Task { [weak self] in
            let url = try? await download(item)
            self?.downloaded(key, token: token, url)
        }
        downloads[key] = (token, task)
    }

    private func downloaded(_ key: String, token: Int, _ url: URL?) {
        if let url { files[key] = url }
        // A download that a move stopped, or that a new one replaced, has no one to tell.
        guard downloads[key]?.token == token else { return }
        downloads[key] = nil
        let waiting = waiters.removeValue(forKey: key) ?? [:]
        for (_, done) in waiting.sorted(by: { $0.key < $1.key }) { done(url) }
    }

    // MARK: The pictures of the tiles

    func still(for item: OnlineItem) -> NSImage? {
        if let image = stills.object(forKey: item.still.absoluteString as NSString) { return image }
        wantStill(item.still)
        return nil
    }

    func moving(for item: OnlineItem) -> NSImage? {
        guard let url = item.preview else { return nil }
        if let image = movings.object(forKey: url.absoluteString as NSString) { return image }
        guard movingLoad?.url != url, !failedPictures.contains(url) else { return nil }
        // Only the tile with the blue box moves, so only its picture loads.
        movingLoad?.task.cancel()
        let fetch = fetchPicture
        let task = Task { [weak self] in
            let data = try? await fetch(url)
            self?.movingCame(url, data)
        }
        movingLoad = (url, task)
        return nil
    }

    private func movingCame(_ url: URL, _ data: Data?) {
        guard movingLoad?.url == url else { return }
        movingLoad = nil
        guard let data, let image = NSImage(data: data) else {
            failedPictures.insert(url)
            return
        }
        movings.setObject(image, forKey: url.absoluteString as NSString)
        onPicture()
    }

    /// The grid asks for the tiles that it draws. The newest wish loads first, and only the last 24 wishes wait,
    /// so a fast scroll does not load each tile that it passed.
    private func wantStill(_ url: URL) {
        guard !stillsLoading.contains(url), !failedPictures.contains(url) else { return }
        stillsWaiting.removeAll { $0 == url }
        stillsWaiting.append(url)
        if stillsWaiting.count > KlipyLibrary.pageSize { stillsWaiting.removeFirst(stillsWaiting.count - KlipyLibrary.pageSize) }
        startStills()
    }

    private func startStills() {
        while stillsLoading.count < KlipyResults.stillsAtOnce, let url = stillsWaiting.popLast() {
            stillsLoading.insert(url)
            let fetch = fetchPicture
            Task { [weak self] in
                let image = await KlipyResults.loadStill(url, fetch: fetch)
                self?.stillCame(url, image)
            }
        }
    }

    private func stillCame(_ url: URL, _ image: CGImage?) {
        stillsLoading.remove(url)
        if let image {
            let side = CGFloat(KlipyResults.stillSide) / 2
            stills.setObject(NSImage(cgImage: image, size: NSSize(width: side, height: side)), forKey: url.absoluteString as NSString)
            onPicture()
        } else {
            failedPictures.insert(url)
        }
        startStills()
    }

    /// Gets the still picture and makes it a square (aspect-fill), off the main thread, the same as your own tiles.
    nonisolated static func loadStill(_ url: URL, fetch: FetchPicture) async -> CGImage? {
        guard let data = try? await fetch(url) else { return nil }
        return await Task.detached(priority: .utility) { square(data) }.value
    }

    /// The picture in `data`, cut to a square of `stillSide` pixels from its middle.
    nonisolated static func square(_ data: Data) -> CGImage? {
        let side = stillSide
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0,
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let scale = max(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height))
        return context.makeImage()
    }
}
