import AppKit
import Testing
@testable import EmojiKit

/// A counter that a `@Sendable` download can change.
private final class DownloadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// D18 of YAZ-2919: each KLIPY GIF or meme that you use is kept, as a synced card in `library-<Mac>.json` and as a
/// file on this Mac (`KlipyFiles`, the 50 used last). The network is a `StubNetwork`, the folders are temp folders,
/// and the clocks are fakes. No test goes online or touches `~/Library/Application Support/Yaseen Emoji`.
@MainActor
@Suite struct KlipyKeepTests {
    /// One GIF of KLIPY with a title, on the network of `klipy`.
    static func gif(_ klipy: KlipyRig, _ slug: String, title: String) -> String {
        KlipySample.gif(number: 1, slug: slug, title: title) { [network = klipy.network] in
            network.mediaURL("\(slug)/\($0)").absoluteString
        }
    }

    /// The `OnlineItem` of one KLIPY answer item, as the app reads it.
    static func item(_ json: String, kind: ItemKind = .gif) throws -> OnlineItem {
        try #require(try KlipyLibrary.decode(Data(KlipySample.items([json]).utf8)).items(kind).first)
    }

    /// The KLIPY item of the grid at `index`.
    static func online(_ session: PickSession, _ index: Int) throws -> OnlineItem {
        guard session.items.indices.contains(index), case .online(let item) = session.items[index] else {
            Issue.record("no KLIPY item at \(index)")
            throw CancellationError()
        }
        return item
    }

    /// A rig that finds "Hello hi" (`hello-hi-662`) for each search, and gives a small GIF for each media URL.
    static func helloRig(after earlier: KlipyRig? = nil) throws -> (KlipyRig, Data) {
        let klipy = try KlipyRig(after: earlier)
        let bytes = makeTestImage(width: 20, height: 20, type: .gif, frames: 2)
        let page = KlipySample.page([gif(klipy, "hello-hi-662", title: "Hello hi")], hasNext: false)
        if earlier == nil {
            klipy.network.setReply { request in
                request.url?.host == "static.klipy.com" ? .answer(status: 200, body: bytes) : .json(page)
            }
        }
        return (klipy, bytes)
    }

    enum PickPath: CaseIterable {
        case enter, shiftEnter, click, copyOnly
    }

    /// Each pick path (Enter, Shift+Enter, a click, Copy only) moves the downloaded paste file into the kept files,
    /// with no second request, and writes the card into this Mac's list file. The clipboard gets the kept file.
    @Test(arguments: PickPath.allCases)
    func aPickKeepsTheCardAndMovesThePasteFile(_ path: PickPath) async throws {
        let (klipy, bytes) = try KlipyKeepTests.helloRig()
        let session = klipy.session
        await klipy.search("hi")
        let found = try KlipyKeepTests.online(session, 0)
        // The prefetch of D6 downloads the paste file.
        klipy.clock.advance(by: 0.3)
        await waitUntil { klipy.klipy.pasteFile(for: found) != nil }
        let temp = try #require(klipy.klipy.pasteFile(for: found))
        #expect(klipy.kept.names.isEmpty)

        switch path {
        case .enter: session.enter(shift: false)
        case .shiftEnter: session.enter(shift: true)
        case .click:
            session.select(0)
            session.pick(stayOpen: false)
        case .copyOnly: session.copyOnly()
        }
        let kept = klipy.kept.folder.appendingPathComponent("hello-hi-662.gif")
        #expect(klipy.kept.names == ["hello-hi-662.gif"])
        #expect(try Data(contentsOf: kept) == bytes && !FileManager.default.fileExists(atPath: temp.path))
        #expect(klipy.rig.clipboard.contents.items.first?.values.first?.data == Data(kept.absoluteString.utf8))
        #expect(klipy.requests("media").map { $0.url?.lastPathComponent } == ["md.gif"])
        #expect(klipy.rig.store.you.uses["klipy:hello-hi-662"]?.count == 1)
        // The pick pastes the kept file from now on, at once.
        #expect(klipy.klipy.pasteFile(for: found) == kept)

        // The card, in this Mac's list file.
        guard case .loaded(let file) = MacFiles.loadOwn(LibraryFile.self, at: klipy.rig.library.url) else {
            Issue.record("no list file")
            return
        }
        let card = try #require(file.cards["klipy:hello-hi-662"])
        #expect(card.slug == "hello-hi-662" && card.kind == .gif && card.title == "Hello hi")
        #expect(card.still == found.still && card.preview == found.preview && card.file == found.file)
        #expect(card.still.lastPathComponent == "sm.jpg" && card.file.lastPathComponent == "md.gif")
        #expect(card.fileType == "com.compuserve.gif" && card.fileExtension == "gif")
        #expect(card.width == 498 && card.height == 498 && card.bytes == 314884)
        #expect(klipy.rig.library.card("hello-hi-662") == card)
        session.close()
    }

    /// A new start of the app (a new session, list and history over the same folders): the card gives its tile in
    /// "Your most used", and in "Yours" for its learned word and for its title, with no request. The still and the
    /// moving picture come from the kept file. A pick pastes the kept file at once.
    @Test func aNewStartShowsTheCardWithNoRequest() async throws {
        let (first, _) = try KlipyKeepTests.helloRig()
        await first.search("hi")
        let found = try KlipyKeepTests.online(first.session, 0)
        first.clock.advance(by: 0.3)
        await waitUntil { first.klipy.pasteFile(for: found) != nil }
        first.session.enter(shift: false)
        #expect(first.kept.names == ["hello-hi-662.gif"])
        let sent = first.network.requests.count

        let (next, _) = try KlipyKeepTests.helloRig(after: first)
        let session = next.session
        session.open()
        session.select(tab: .gifs)
        #expect(session.mostUsedItems == 0..<1 && session.items.first?.key == "klipy:hello-hi-662")
        #expect(PickSession.label(of: session.items[0]) == "Hello hi")
        session.setQuery("hi")
        #expect(session.lines.prefix(2) == [.title("Yours"), .cells(0..<1)])
        session.setQuery("hello")
        #expect(session.lines.prefix(2) == [.title("Yours"), .cells(0..<1)])
        let item = try KlipyKeepTests.online(session, 0)
        _ = next.klipy.still(for: item)
        await waitUntil { next.klipy.still(for: item) != nil }
        next.klipy.wantMoving([item])
        await waitUntil { next.klipy.moving(for: item) != nil }
        #expect(next.klipy.still(for: item) != nil && next.klipy.moving(for: item) != nil)

        // Enter pastes the kept file at once: no "Getting the GIF…", no download.
        session.enter(shift: false)
        #expect(!session.isOpen)
        let kept = next.kept.folder.appendingPathComponent("hello-hi-662.gif")
        #expect(next.rig.clipboard.contents.items.first?.values.first?.data == Data(kept.absoluteString.utf8))
        #expect(next.network.requests.count == sent)
        #expect(next.rig.store.you.uses["klipy:hello-hi-662"]?.count == 2)
    }

    /// At most 50 kept files: the file with the oldest last use goes, and a file that you used again stays.
    /// All the cards stay. The card whose file went still gives a tile (from its URLs), and a pick downloads
    /// its file again and keeps it.
    @Test func theKeptFilesStayAt50AndTheCardsStay() async throws {
        let downloads = DownloadCount()
        let temp = try TempFolder()
        let base = temp.url
        let klipy = try KlipyRig(download: { item in
            downloads.add()
            let url = base.appendingPathComponent("\(UUID().uuidString).gif")
            try Data("GIF89a \(item.id)".utf8).write(to: url)
            return url
        })
        let results = klipy.klipy
        let library = klipy.rig.library
        /// The steps of a pick: the paste file, then the kept file and the card.
        func pick(_ item: OnlineItem) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                results.getPasteFile(for: item) { _ in done.resume() }
            }
            #expect(results.keepFile(of: item) != nil)
            library.useCard(KlipyCard(item, lastUsed: Date()))
        }
        let items = (0...50).map { FakeOnline.gif("g\($0)") }
        for item in items.prefix(50) { await pick(item) }
        #expect(klipy.kept.names.count == 50 && downloads.value == 50)
        // A pick of g0 again: its kept file pastes, with no download, and it is now the newest use.
        await pick(items[0])
        #expect(downloads.value == 50)
        // The 51st file: g1 (the oldest last use) goes. g0 stays.
        await pick(items[50])
        let names = Set(klipy.kept.names)
        #expect(names.count == 50 && names.contains("g0.gif") && names.contains("g50.gif") && !names.contains("g1.gif"))
        #expect(library.cards.count == 51)

        // g1 has a card and no file: its tile comes from the card, and a pick downloads the file again.
        let card = try #require(library.card("g1"))
        #expect(results.item(for: card) == items[1])
        #expect(results.pasteFile(for: items[1]) == nil)
        await pick(items[1])
        #expect(downloads.value == 52 && Set(klipy.kept.names).contains("g1.gif") && klipy.kept.names.count == 50)
    }

    /// At most 200 MB of kept files: the files with the oldest last use go. The file of this pick always stays.
    /// The move into the folder leaves no part file.
    @Test func theKeptFilesStayBelowTheSizeLimit() throws {
        #expect(KlipyFiles.fileLimit == 50 && KlipyFiles.byteLimit == 200 * 1024 * 1024)
        let temp = try TempFolder()
        let files = KlipyFiles(folder: temp.url.appendingPathComponent("klipy"), byteLimit: 1_000, now: StepClock().now)
        func download(_ name: String, bytes: Int) throws -> URL {
            let url = temp.url.appendingPathComponent("\(UUID().uuidString)-\(name)")
            try Data(repeating: 7, count: bytes).write(to: url)
            return url
        }
        for name in ["a", "b"] { _ = try files.keep(try download(name, bytes: 400), slug: name, ext: "gif") }
        #expect(files.names == ["a.gif", "b.gif"])
        // 1,200 bytes: "a" goes.
        let source = try download("c", bytes: 400)
        let kept = try files.keep(source, slug: "c", ext: "gif")
        #expect(files.names == ["b.gif", "c.gif"])
        #expect(!FileManager.default.fileExists(atPath: source.path) && files.file(for: "c") == kept)
        // One file larger than the limit stays alone.
        _ = try files.keep(try download("d", bytes: 1_500), slug: "d", ext: "gif")
        #expect(files.names == ["d.gif"])
        #expect(temp.names(in: files.folder) == ["d.gif"])
        // A new listing (the next open) finds the same file.
        files.reload()
        #expect(files.file(for: "d")?.lastPathComponent == "d.gif" && files.file(for: "c") == nil)
    }

    /// Two Macs: a card from Mac B shows on Mac A at the next open, from its URLs, with no lookup. Mac A has no file
    /// until a pick. The pick downloads the file, keeps it on Mac A, and writes the card into Mac A's list.
    @Test func aCardFromADifferentMacShowsAndAPickKeepsItsFile() async throws {
        let (klipy, _) = try KlipyKeepTests.helloRig()
        let rig = klipy.rig
        let item = try KlipyKeepTests.item(KlipyKeepTests.gif(klipy, "hello-hi-662", title: "Hello hi"))
        let folder = rig.folder.defaultFolder
        let macB = LibraryStore(url: folder.appendingPathComponent("library-B.json"), mediaFolder: folder)
        macB.load()
        macB.useCard(KlipyCard(item, lastUsed: Date()))
        let historyB = YouStore(url: folder.appendingPathComponent("you-B.json"))
        historyB.load()
        historyB.recordPick("klipy:hello-hi-662", query: "hi")

        // Mac A, the next open (the app reads the changed files of the other Macs here).
        rig.store.reload()
        rig.library.reload()
        let session = klipy.session
        session.open()
        session.select(tab: .gifs)
        #expect(session.mostUsedItems == 0..<1 && session.items.first?.key == "klipy:hello-hi-662")
        #expect(klipy.kept.names.isEmpty && klipy.klipy.pasteFile(for: item) == nil)
        // The still comes from the URL of the card.
        _ = klipy.klipy.still(for: item)
        await waitUntil { klipy.klipy.still(for: item) != nil }
        #expect(klipy.requests("media").map { $0.url?.lastPathComponent } == ["sm.jpg"])
        #expect(klipy.requests("items").isEmpty && klipy.requests("search").isEmpty)

        // A pick downloads the file (with the wait of D6), keeps it on Mac A, and writes Mac A's card.
        session.enter(shift: false)
        #expect(session.lines.first == .title("Getting the GIF…"))
        await waitUntil { !session.isOpen }
        #expect(klipy.kept.names == ["hello-hi-662.gif"])
        #expect(klipy.requests("media").map { $0.url?.lastPathComponent } == ["sm.jpg", "md.gif"])
        #expect(rig.library.own.cards["klipy:hello-hi-662"]?.title == "Hello hi")
        // Mac B reads Mac A's newer card.
        macB.reload()
        #expect(macB.card("hello-hi-662")?.lastUsed == rig.library.own.cards["klipy:hello-hi-662"]?.lastUsed)
    }

    /// The migration: a KLIPY item of an earlier build with uses and learned words, but no card, gets its card at the
    /// first lookup that succeeds, with the last use of the history. A new start then shows it with no lookup.
    @Test func anItemWithUsesGetsItsCardAtTheFirstLookup() async throws {
        let klipy = try KlipyRig()
        let items = KlipySample.items([KlipyKeepTests.gif(klipy, "shaq-dance", title: "Shaq cat")])
        klipy.network.setReply { request in
            request.url?.path.hasSuffix("/gifs/items") == true ? .json(items) : .json(KlipySample.items([]))
        }
        klipy.rig.store.recordPick("klipy:shaq-dance", query: "shaq cat")
        klipy.rig.store.recordPick("klipy:shaq-dance", query: "sgaq")
        #expect(klipy.rig.library.cards.isEmpty)
        let session = klipy.session
        session.open()
        session.select(tab: .gifs)
        await waitUntil { session.mostUsedItems == 0..<1 }
        #expect(klipy.requests("items").count == 1)
        let card = try #require(klipy.rig.library.card("shaq-dance"))
        #expect(card.title == "Shaq cat" && card.lastUsed == klipy.rig.store.you.uses["klipy:shaq-dance"]?.last)
        #expect(klipy.kept.names.isEmpty)
        session.close()

        // A new start: the card gives the tile at once. No items call.
        let next = try KlipyRig(after: klipy)
        next.session.open()
        next.session.select(tab: .gifs)
        #expect(next.session.mostUsedItems == 0..<1 && next.session.items.first?.key == "klipy:shaq-dance")
        next.session.setQuery("sgaq")
        #expect(next.session.lines.prefix(2) == [.title("Yours"), .cells(0..<1)])
        for _ in 0..<50 { await Task.yield() }
        #expect(next.requests("items").count == 1)
        next.session.close()
    }

    /// D14 update: with "Search KLIPY in GIFs" off, the cards do not show, and no request goes. They stay.
    @Test func theKLIPYSwitchHidesTheCards() async throws {
        let (klipy, _) = try KlipyKeepTests.helloRig()
        let rig = klipy.rig
        let item = try KlipyKeepTests.item(KlipyKeepTests.gif(klipy, "hello-hi-662", title: "Hello hi"))
        rig.library.useCard(KlipyCard(item, lastUsed: Date()))
        rig.store.recordPick("klipy:hello-hi-662", query: "hi")
        let model = rig.settingsModel()
        model.setSearchesKlipy(false, for: .gif)
        let session = klipy.session
        session.open()
        session.select(tab: .gifs)
        #expect(session.lines == [.title("Your GIFs"), .title(PickSession.emptyTitle(.gif))])
        session.setQuery("hello")
        #expect(session.lines.first == .title(PickSession.noTileMatchTitle("hello")))
        #expect(klipy.onlineSlugs.isEmpty)
        for _ in 0..<50 { await Task.yield() }
        #expect(klipy.network.requests.isEmpty)
        #expect(rig.library.card("hello-hi-662") != nil)

        // On again: the card shows at once.
        model.setSearchesKlipy(true, for: .gif)
        #expect(session.lines.prefix(2) == [.title("Yours"), .cells(0..<1)])
        #expect(klipy.onlineSlugs.first == "hello-hi-662")
        session.close()
    }

    /// A card with no file on this Mac whose still fails: the app asks KLIPY for the slug. KLIPY deleted it, so the
    /// tile goes. The card stays in the list.
    @Test func aCardThatKLIPYDeletedGoesWhenThisMacHasNoFile() async throws {
        let klipy = try KlipyRig()
        klipy.network.setReply { request in
            request.url?.host == "static.klipy.com" ? .json("{}", status: 404) : .json(KlipySample.items([]))
        }
        let rig = klipy.rig
        let item = try KlipyKeepTests.item(KlipyKeepTests.gif(klipy, "gone-1", title: "Gone"))
        rig.library.useCard(KlipyCard(item, lastUsed: Date()))
        rig.store.recordPick("klipy:gone-1", query: "gone")
        let session = klipy.session
        session.open()
        session.select(tab: .gifs)
        #expect(session.mostUsedItems == 0..<1)
        _ = klipy.klipy.still(for: item)
        await waitUntil { session.mostUsedItems == nil }
        #expect(session.lines == [.title("Your GIFs"), .title(PickSession.emptyTitle(.gif))])
        #expect(klipy.requests("items").count == 1 && klipy.requests("media").count == 1)
        #expect(rig.library.card("gone-1") != nil && rig.store.you.uses["klipy:gone-1"]?.count == 1)
        session.close()
    }
}
