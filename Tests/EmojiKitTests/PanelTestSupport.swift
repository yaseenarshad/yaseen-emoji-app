import AppKit
import Testing
import UniformTypeIdentifiers
@testable import EmojiKit

// The fakes of the panel and Settings tests. Nothing here shows a window, posts a key event,
// or reads the real clipboard, the real prefs or the real `you.json`.

/// A `UserDefaults` that keeps its values in memory (the same as `MemoryDefaults` in Screendraw).
final class MemoryDefaults: UserDefaults {
    private(set) var values: [String: Any] = [:]

    init() {
        // The name is never used: each call that the app makes is overridden below.
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Int, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

extension ClipboardContents {
    /// One text item, as the app writes an emoji.
    static func text(_ text: String) -> ClipboardContents {
        ClipboardContents(items: [Item(values: [(NSPasteboard.PasteboardType.string.rawValue, Data(text.utf8))])])
    }
}

/// A clipboard in memory. `changeCount` goes up at each change, as on macOS.
@MainActor
final class FakeClipboard: Clipboard {
    private(set) var contents: ClipboardContents
    private(set) var changeCount = 100
    private(set) var restores = 0
    /// True when the last write of the app was only for a paste.
    private(set) var lastWriteIsTransient = false

    init(_ contents: ClipboardContents) {
        self.contents = contents
    }

    func read() -> ClipboardContents { contents }

    func write(_ text: String, transient: Bool) -> Int {
        contents = .text(text)
        lastWriteIsTransient = transient
        changeCount += 1
        return changeCount
    }

    /// The same item as `SystemClipboard`: `ClipboardContents.fileItem`.
    func write(file: URL, type: UTType, transient: Bool) -> Int? {
        guard let item = ClipboardContents.fileItem(file, type: type, transient: transient) else { return nil }
        contents = ClipboardContents(items: [item])
        lastWriteIsTransient = transient
        changeCount += 1
        return changeCount
    }

    func restore(_ saved: ClipboardContents) {
        contents = saved
        changeCount += 1
        restores += 1
    }

    /// The user copies something in a different app.
    func userCopies(_ text: String) {
        contents = .text(text)
        changeCount += 1
    }

    /// Two items with two types each, as a copy from a rich text app.
    static let rich = ClipboardContents(items: [
        .init(values: [("public.utf8-plain-text", Data("old text".utf8)), ("public.rtf", Data("{\\rtf1 old}".utf8))]),
        .init(values: [("public.png", Data([0x89, 0x50, 0x4E, 0x47])), ("public.url", Data("https://a.b".utf8))]),
    ])
}

/// Keeps the keys that the app would post. It posts nothing.
@MainActor
final class FakeKeySender: KeySender {
    private(set) var sent: [HotKeyCombo] = []
    func post(_ combo: HotKeyCombo) { sent.append(combo) }
}

@MainActor
final class FakePasteAccess: PasteAccess {
    var isTrusted: Bool
    var secureInputIsOn = false
    private(set) var asks = 0

    init(trusted: Bool = true) {
        isTrusted = trusted
    }

    func ask() { asks += 1 }
}

/// A clock for `Later`: the work runs only when the test moves the clock. No test sleeps.
@MainActor
final class FakeLater: Later {
    private var now: TimeInterval = 0
    private var next = 0
    private var waiting: [(due: TimeInterval, order: Int, work: @MainActor () -> Void)] = []

    var isEmpty: Bool { waiting.isEmpty }

    func run(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        waiting.append((now + seconds, next, work))
        next += 1
    }

    /// Moves the clock by `seconds` and runs the work that is due, in time order.
    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let first = waiting.enumerated().min(by: { ($0.element.due, $0.element.order) < ($1.element.due, $1.element.order) }),
              first.element.due <= end {
            waiting.remove(at: first.offset)
            now = first.element.due
            first.element.work()
        }
        now = end
    }

    /// Runs all the work, also the work that it adds.
    func runAll() { advance(by: 1_000) }
}

/// The search panel with no window. It keeps the calls of the session.
@MainActor
final class FakePanel: PickPanel {
    private(set) var calls: [String] = []

    func show() { calls.append("show") }
    func hide() { calls.append("hide") }
    func stepAside() { calls.append("stepAside") }
    func comeBack() { calls.append("comeBack") }
    func reload() {}
    /// New KLIPY results: the grid keeps its scroll.
    func update() { calls.append("update") }
    func showSelection() {}
}

/// A session with fakes on a temp folder: the parts of the panel, and nothing on the screen.
@MainActor
final class PickRig {
    let folder: TempFolder
    let defaults = MemoryDefaults()
    let prefs: Prefs
    let store: YouStore
    let clipboard = FakeClipboard(FakeClipboard.rich)
    let keys = FakeKeySender()
    let access: FakePasteAccess
    let later = FakeLater()
    let panel = FakePanel()
    let session: PickSession
    /// The list of GIFs and memes, in the default preferences folder of the rig, with a step clock.
    let library: LibraryStore
    let thumbnails: Thumbnails
    /// The files that "Show in Finder" showed.
    private(set) var shownInFinder: [URL] = []
    /// The default preferences folder of the rig, and the Mac name "Test-Mac".
    var folders: PreferencesFolder { PreferencesFolder(defaultFolder: folder.defaultFolder, macName: "Test-Mac") }

    /// The KLIPY key of `parts`: none by default.
    let klipyKey = FakeKeyStore()

    init(catalog: [Emoji] = Catalog.all, trusted: Bool = true, online: OnlineResults? = nil) throws {
        folder = try TempFolder()
        prefs = Prefs(defaults: defaults)
        store = YouStore(url: folder.youFile)
        store.load()
        library = LibraryStore(url: folder.defaultFolder.appendingPathComponent("library-Test-Mac.json"),
                               mediaFolder: folder.defaultFolder, now: StepClock().now)
        library.load()
        thumbnails = Thumbnails(folder: folder.url.appendingPathComponent("thumbs", isDirectory: true))
        access = FakePasteAccess(trusted: trusted)
        let paster = Paster(clipboard: clipboard, keys: keys, access: access, later: later)
        session = PickSession(catalog: catalog, store: store, library: library, prefs: prefs, paster: paster,
                              online: online, thumbnails: thumbnails)
        session.panel = panel
        session.showInFinder = { [unowned self] in self.shownInFinder.append($0) }
    }

    /// The emoji texts of the grid.
    var shownItems: [String] { session.emojis.map { session.shown($0) } }

    /// Puts the blue box on the first emoji with this text.
    func select(_ text: String) throws {
        let place = try #require(session.emojis.firstIndex { $0.text == text }, "\(text) is not in the grid")
        session.select(place)
    }

    /// Adds your own GIF (2 frames, made in the test) or meme (a PNG) with these words. `seed` makes the bytes different.
    @discardableResult
    func addOwn(_ kind: ItemKind = .gif, words: [String], seed: Int = 0) throws -> Item {
        let type: UTType = kind == .gif ? .gif : .png
        let bytes = makeTestImage(width: 40 + seed, height: 30, type: type, frames: kind == .gif ? 2 : 1)
        return try library.add(PreparedFile(bytes: bytes, ext: kind == .gif ? "gif" : "png", kind: kind), words: words).item
    }

    /// The place in the grid of the item with this key.
    func place(of key: String) throws -> Int {
        try #require(session.items.firstIndex { $0.key == key }, "\(key) is not in the grid")
    }

    /// A `SettingsModel` on the same prefs, history and list. A change of a KLIPY switch goes to the session,
    /// the same as in the app.
    func settingsModel() -> SettingsModel {
        let model = SettingsModel(prefs: prefs, hotKeys: FakeHotKeyRegistrar(), loginItem: FakeLoginItem(), access: access,
                                  store: store, folders: folders, library: library, keyStore: klipyKey)
        model.onKlipySwitchChanged = { [session] in session.klipySwitchChanged() }
        return model
    }

    /// The parts of an `AppController` with the same fakes, and a catalog that loads with no file.
    func parts(catalog: [Emoji]) -> AppParts {
        AppParts(defaults: defaults, defaultFolder: folder.defaultFolder, computerName: { "Test Mac" },
                 loadCatalog: { catalog },
                 clipboard: clipboard, keys: keys, access: access, later: later,
                 thumbnailFolder: folder.url.appendingPathComponent("thumbs", isDirectory: true),
                 showInFinder: { _ in },
                 klipyKey: klipyKey,
                 // A stub session with no route: each request fails as "not connected". No test goes online.
                 onlineSession: KlipyLibrary.makeSession(protocolClasses: [StubURLProtocol.self]),
                 cacheFolder: folder.url.appendingPathComponent("Caches", isDirectory: true),
                 makePanel: { [panel] _ in panel })
    }
}

/// A small catalog of `count` emojis in one group, for the moves of the grid.
func smallCatalog(_ count: Int, group: Int = 0) -> [Emoji] {
    (0..<count).map { place in
        Emoji(text: String(UnicodeScalar(0x1F600 + place)!), name: "face \(place)", group: group, order: place, words: [])
    }
}

extension PickSession {
    /// The emojis of the grid. The v0.1 tests read the Emoji tab with it: there each item is an emoji.
    var emojis: [Emoji] { items.compactMap(\.emoji) }
}

/// KLIPY with no network (the seam of `OnlineResults`). The test gives the known items and the results.
@MainActor
final class FakeOnline: OnlineResults {
    var isOn = true
    var onChange: () -> Void = {}
    var onPicture: () -> Void = {}
    /// The items that this session knows, by slug.
    var known: [String: OnlineItem] = [:]
    /// The "From KLIPY" results of each search text.
    var results: [String: OnlineSection] = [:]
    /// The downloaded paste files, by slug.
    var files: [String: URL] = [:]
    private(set) var asked: [String] = []

    func item(_ slug: String, kind: ItemKind) -> OnlineItem? { known[slug].flatMap { $0.kind == kind ? $0 : nil } }

    func section(for text: String, kind: ItemKind) -> OnlineSection? {
        asked.append(text)
        return results[text]
    }

    func loadMore(for text: String, kind: ItemKind) {}
    func selectionChanged(to item: OnlineItem?) {}
    func pasteFile(for item: OnlineItem) -> URL? { files[item.id] }
    func getPasteFile(for item: OnlineItem, done: @escaping @MainActor (URL?) -> Void) { done(files[item.id]) }
    func still(for item: OnlineItem) -> NSImage? { nil }
    func moving(for item: OnlineItem) -> NSImage? { nil }
    func wantMoving(_ items: [OnlineItem]) {}
    func refresh() {}
    func stop() {}

    /// A KLIPY GIF with this slug. The URLs are never loaded.
    static func gif(_ slug: String, kind: ItemKind = .gif) -> OnlineItem {
        let base = URL(string: "https://static.klipy.com/\(slug)")!
        return OnlineItem(id: slug, number: nil, kind: kind, title: slug, still: base.appendingPathComponent("sm.jpg"),
                          preview: base.appendingPathComponent("sm.gif"), file: base.appendingPathComponent("md.gif"),
                          fileType: kind == .gif ? .gif : .png, fileExtension: kind == .gif ? "gif" : "png",
                          width: 100, height: 100, bytes: nil)
    }
}
