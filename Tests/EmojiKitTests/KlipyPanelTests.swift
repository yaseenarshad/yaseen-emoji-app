import AppKit
import Testing
import UniformTypeIdentifiers
@testable import EmojiKit

/// KLIPY in the GIFs and Memes tabs with `KlipyResults` (YAZ-2928 part 2; D1, D2, D6, D7, D11 of YAZ-2919).
/// The network is a `StubNetwork`, the key store is a fake, the pause is a `ManualSleep`, and the clock of the
/// prefetch and the wait is a `FakeLater`. No test goes online, waits 350 ms, or touches the real Keychain.
@MainActor
final class KlipyRig {
    let network: StubNetwork
    let keys: FakeKeyStore
    /// The pause of the search (D11). It ends only with `pause.wake()`.
    let pause: ManualSleep
    /// The clock of the 300 ms prefetch and the 3 s wait.
    let clock: FakeLater
    let cache: TempFolder
    let klipy: KlipyResults
    let rig: PickRig
    var session: PickSession { rig.session }

    /// `download` replaces the real download of the paste file, for a test of a slow file.
    init(key: Bool = true, download: KlipyResults.Download? = nil) throws {
        let network = StubNetwork { _ in .fail(.badServerResponse) }
        let keys = FakeKeyStore(key ? network.key : nil)
        let pause = ManualSleep()
        let clock = FakeLater()
        let cache = try TempFolder()
        let files = PasteFiles(cache: cache.url, session: network.session)
        let session = network.session
        klipy = KlipyResults(library: KlipyLibrary(keys: keys, session: session), keys: keys, later: clock,
                             download: download ?? { try await files.download($0) },
                             fetchPicture: { try await KlipyLibrary.fetch($0, session: session) },
                             sleep: { try await pause.sleep($0) })
        self.network = network
        self.keys = keys
        self.pause = pause
        self.clock = clock
        self.cache = cache
        rig = try PickRig(online: klipy)
    }

    /// One GIF item of KLIPY with its media on this network.
    func gif(_ slug: String, number: Int = 1) -> String {
        KlipySample.gif(number: number, slug: slug, title: slug) { [network] name in network.mediaURL("\(slug)/\(name)").absoluteString }
    }

    /// The requests to a KLIPY call (`search` or `items`), or to the media host.
    func requests(_ call: String) -> [URLRequest] {
        network.requests.filter { request in
            let path = request.url?.path ?? ""
            return call == "media" ? request.url?.host == "static.klipy.com" : path.hasSuffix("/\(call)")
        }
    }

    /// Opens the panel on a tab and types `text`. The pause ends, and the test waits for KLIPY's answer.
    /// A search that the session has in memory sends no request, so there is nothing to wait for.
    func search(_ text: String, tab: PickSession.Tab = .gifs) async {
        if !session.isOpen { session.open() }
        session.select(tab: tab)
        session.setQuery(text)
        guard session.lines.contains(.title(KlipyResults.searchingText)) else { return }
        await waitUntil { pause.waiting == 1 }
        pause.wake()
        await waitUntil { !session.lines.contains(.title(KlipyResults.searchingText)) }
    }

    /// The KLIPY items of the grid, by slug, in the order of the grid.
    var onlineSlugs: [String] {
        session.items.compactMap { item in
            if case .online(let online) = item { return online.id }
            return nil
        }
    }
}

/// A page of `slugs` as KLIPY sends it.
@MainActor
func klipyPage(_ rig: KlipyRig, _ slugs: [String], page: Int = 1, hasNext: Bool = true) -> String {
    KlipySample.page(slugs.enumerated().map { rig.gif($0.element, number: page * 100 + $0.offset) }, page: page, hasNext: hasNext)
}

@MainActor
@Suite struct KlipyPanelTests {
    /// D11: the search starts only after the pause, and each new key cancels the wait of the key before it.
    /// One request goes, for the last text. The results keep KLIPY's order, in "From KLIPY", below "Yours".
    @Test func theSearchSendsOneRequestAfterThePause() async throws {
        let klipy = try KlipyRig()
        let page = klipyPage(klipy, ["dance-2", "cat-1", "cat-3"], hasNext: false)
        klipy.network.setReply { _ in .json(page) }
        let own = try klipy.rig.addOwn(words: ["cat"])
        let session = klipy.session
        session.open()
        session.select(tab: .gifs)
        #expect(session.placeholder == "Search KLIPY")

        session.setQuery("c")
        session.setQuery("ca")
        session.setQuery("cat")
        // Before the pause ends: no request, "Yours" shows, and the grid does not say "No match".
        #expect(session.lines == [.title("Yours"), .cells(0..<1), .title("From KLIPY"), .title(KlipyResults.searchingText)])
        await waitUntil { klipy.pause.waiting == 1 }
        #expect(klipy.network.requests.isEmpty)
        #expect(klipy.pause.durations.allSatisfy { $0 == .milliseconds(350) })

        klipy.pause.wake()
        await waitUntil { klipy.onlineSlugs.count == 3 }
        let requests = klipy.requests("search")
        #expect(requests.count == 1 && klipy.network.requests.count == 1)
        #expect(OnlineLibraryTests.query(requests[0])["q"] == "cat")
        #expect(session.lines == [.title("Yours"), .cells(0..<1), .title("From KLIPY"), .cells(1..<4)])
        #expect(session.items[0] == .own(own))
        #expect(klipy.onlineSlugs == ["dance-2", "cat-1", "cat-3"])
        // New results keep the scroll of the grid.
        #expect(klipy.rig.panel.calls.last == "update")

        // A tab change back sends no new request: the search stays in memory for the session.
        session.select(tab: .memes)
        session.select(tab: .gifs)
        #expect(klipy.onlineSlugs == ["dance-2", "cat-1", "cat-3"])
        await waitUntil { klipy.pause.waiting == 1 }
        // Only the Memes search waits for its pause.
        #expect(klipy.requests("search").count == 1)
    }

    enum Failure: CaseIterable {
        case wrongKey401, wrongKey404, busy, timeOut, offline, serverError

        var reply: StubReply {
            switch self {
            case .wrongKey401: return .json("{}", status: 401)
            case .wrongKey404: return .json(#"{"result":false,"errors":{"message":["The provided API key is invalid."]}}"#, status: 404)
            case .busy: return .json("{}", status: 429)
            case .timeOut: return .fail(.timedOut)
            case .offline: return .fail(.notConnectedToInternet)
            case .serverError: return .json("<html>", status: 500)
            }
        }

        var line: String {
            switch self {
            case .wrongKey401, .wrongKey404: return "KLIPY refused the key. Check it in Settings."
            case .busy: return "KLIPY is busy. Try again in a minute."
            case .timeOut, .offline: return "Can't reach KLIPY."
            case .serverError: return "KLIPY sent an answer that the app can't read."
            }
        }
    }

    /// D2: each failure gives one grey line in "From KLIPY", and your own items still show.
    /// With no match in "Yours", the line comes after "No match", and then the sections of no search.
    @Test(arguments: Failure.allCases)
    func eachFailureGivesItsGreyLine(_ failure: Failure) async throws {
        let klipy = try KlipyRig()
        klipy.network.setReply { _ in failure.reply }
        let own = try klipy.rig.addOwn(words: ["cat"])
        await klipy.search("cat")
        #expect(klipy.session.lines == [.title("Yours"), .cells(0..<1), .title("From KLIPY"), .title(failure.line)])
        #expect(klipy.session.items == [.own(own)])

        klipy.session.setQuery("dog")
        await waitUntil { klipy.pause.waiting == 1 }
        klipy.pause.wake()
        await waitUntil { klipy.session.lines.contains(.title(failure.line)) }
        #expect(klipy.session.lines.prefix(4) == [.title(PickSession.noTileMatchTitle("dog")), .title(failure.line),
                                                  .title("Your GIFs"), .cells(0..<1)])
        // A failed search does not stay: the next open asks KLIPY again.
        klipy.session.close()
        let sent = klipy.requests("search").count
        await klipy.search("cat")
        #expect(klipy.requests("search").count == sent + 1)
    }

    /// D2: with no key, no request goes, the placeholder has no "KLIPY", and one grey line asks for a key.
    @Test func noKeySendsNoRequest() async throws {
        let klipy = try KlipyRig(key: false)
        klipy.rig.store.recordPick("klipy:cat-1", query: "cat")
        let own = try klipy.rig.addOwn(words: ["cat"])
        let session = klipy.session
        session.open()
        session.select(tab: .gifs)
        #expect(session.placeholder == "Search your GIFs")
        session.setQuery("cat")
        #expect(session.lines == [.title("Yours"), .cells(0..<1), .title("From KLIPY"), .title(OnlineError.noKey.line)])
        #expect(session.items == [.own(own)])
        session.reachedEnd()
        for _ in 0..<50 { await Task.yield() }
        #expect(klipy.pause.waiting == 0 && klipy.network.requests.isEmpty)

        // A key in Settings: the next open searches KLIPY.
        try klipy.keys.write(klipy.network.key)
        session.close()
        session.open()
        session.select(tab: .memes)
        #expect(session.placeholder == "Search KLIPY")
    }

    /// D11: 24 a page, the next page when the grid reaches its end (a scroll, or the blue box in the last row),
    /// KLIPY's order, and at most 96 (4 pages).
    @Test func theNextPageComesAtTheEndAndStopsAt96() async throws {
        let klipy = try KlipyRig()
        var pages: [Int: String] = [:]
        for page in 1...5 {
            pages[page] = klipyPage(klipy, (0..<24).map { "p\(page)-\($0)" }, page: page)
        }
        klipy.network.setReply { [pages] request in
            .json(pages[Int(OnlineLibraryTests.query(request)["page"] ?? "") ?? 0] ?? KlipySample.page([]))
        }
        await klipy.search("party")
        #expect(klipy.onlineSlugs.count == 24)
        #expect(OnlineLibraryTests.query(klipy.requests("search")[0])["per_page"] == "24")

        // A scroll to the end of the grid.
        klipy.session.reachedEnd()
        klipy.session.reachedEnd()
        await waitUntil { klipy.onlineSlugs.count == 48 }
        #expect(klipy.requests("search").count == 2)
        #expect(klipy.rig.panel.calls.last == "update")
        // The blue box in the last row.
        klipy.session.select(klipy.session.items.count - 1)
        await waitUntil { klipy.onlineSlugs.count == 72 }
        klipy.session.reachedEnd()
        await waitUntil { klipy.onlineSlugs.count == 96 }
        klipy.session.reachedEnd()
        for _ in 0..<50 { await Task.yield() }
        #expect(klipy.requests("search").map { OnlineLibraryTests.query($0)["page"] } == ["1", "2", "3", "4"])
        #expect(klipy.onlineSlugs == (1...4).flatMap { page in (0..<24).map { "p\(page)-\($0)" } })
    }

    /// D7: "Save to your GIFs" keeps only the slug, with the search text as its word, so it shows in "Yours"
    /// for that word. "Remove from your GIFs" removes it on both Macs (two library files).
    @Test func saveShowsItInYoursAndRemoveIsOnBothMacs() async throws {
        let klipy = try KlipyRig()
        let page = klipyPage(klipy, ["cat-1", "cat-2"], hasNext: false)
        klipy.network.setReply { _ in .json(page) }
        let rig = klipy.rig
        let session = klipy.session
        await klipy.search("cat")
        session.select(1)
        #expect(session.menuActions(at: 1) == [.saveToYours(.gif), .copyOnly, .addNew])
        session.perform(.saveToYours(.gif))
        let id = Item.klipyItemID("cat-2")
        #expect(rig.library.item(id)?.file == nil && rig.library.item(id)?.klipyID == "cat-2")
        #expect(rig.library.item(id)?.words == ["cat"])
        // At once: "Yours" has it, and "From KLIPY" keeps KLIPY's order.
        #expect(session.lines == [.title("Yours"), .cells(0..<1), .title("From KLIPY"), .cells(1..<3)])
        #expect(klipy.onlineSlugs == ["cat-2", "cat-1", "cat-2"])

        // Mac B reads the list of this Mac and sees the saved item.
        let macB = LibraryStore(url: rig.folder.defaultFolder.appendingPathComponent("library-B.json"),
                                mediaFolder: rig.folder.defaultFolder, trash: FakeTrash(folder: rig.folder.url))
        macB.load()
        #expect(macB.items.map(\.id) == [id])

        // The next open: "Your GIFs" shows it with no search, and "Yours" with the word.
        session.close()
        session.open()
        session.select(tab: .gifs)
        #expect(session.lines == [.title("Your GIFs"), .cells(0..<1)])
        await klipy.search("cat")
        #expect(klipy.requests("search").count == 1)
        #expect(session.items.first == .online(try #require(klipy.klipy.item("cat-2", kind: .gif))))
        session.select(0)
        #expect(session.menuActions(at: 0) == [.addWord, .copyOnly, .removeFromYours(.gif), .addNew])
        session.perform(.removeFromYours(.gif))
        #expect(rig.library.item(id)?.isRemoved == true)
        #expect(session.lines == [.title("From KLIPY"), .cells(0..<2)])

        // Mac B: gone at its next reload.
        macB.reload()
        #expect(macB.items.isEmpty && macB.item(id)?.isRemoved == true)
    }

    /// D7: "Yours" also shows the saved KLIPY items and the KLIPY items that you picked for this text before.
    /// The app gets them in one items call by slug. An item that KLIPY deleted drops, with no grey line.
    @Test func learnedAndSavedItemsComeByOneItemsCall() async throws {
        let klipy = try KlipyRig()
        let items = KlipySample.items([klipy.gif("hello-hi-662"), klipy.gif("shaq-dance"), klipy.gif("saved-1")])
        klipy.network.setReply { request in
            request.url?.path.hasSuffix("/items") == true ? .json(items) : .json(KlipySample.page([]))
        }
        let rig = klipy.rig
        rig.store.recordPick("klipy:hello-hi-662", query: "cat")
        rig.store.recordPick("klipy:gone-1", query: "cat")
        rig.store.recordPick("klipy:shaq-dance", query: "dance")
        rig.library.saveKlipy("saved-1", kind: .gif, words: ["cat"])
        let session = klipy.session
        session.open()
        session.select(tab: .gifs)
        session.setQuery("cat")
        await waitUntil { session.lines.first == .title("Yours") }
        let calls = klipy.requests("items")
        #expect(calls.count == 1)
        #expect(calls.first.map { OnlineLibraryTests.query($0)["slugs"] } == "gone-1,hello-hi-662,saved-1,shaq-dance")
        #expect(calls.first?.url?.path.hasSuffix("/gifs/items") == true)
        // Learned first (D5 of YAZ-2894), then the saved item with the word. No line for the deleted item.
        #expect(klipy.onlineSlugs.prefix(2) == ["hello-hi-662", "saved-1"])
        #expect(session.lines.prefix(2) == [.title("Yours"), .cells(0..<2)])
        #expect(!session.lines.contains { line in
            if case .title(let text) = line { return text.contains("KLIPY") && text != "From KLIPY" && text != KlipyResults.searchingText }
            return false
        })

        // The items stay in memory for the session: a new search and a new open send no new items call.
        session.setQuery("dance")
        #expect(klipy.onlineSlugs.first == "shaq-dance")
        session.close()
        session.open()
        session.select(tab: .gifs)
        // "Your most used" has the two items with uses that KLIPY still has.
        #expect(session.mostUsedItems == 0..<2)
        for _ in 0..<50 { await Task.yield() }
        #expect(klipy.requests("items").count == 1)
    }

    /// D6: the paste file downloads when the blue box sits on a KLIPY tile for 300 ms. A move before that stops it.
    /// Then Enter pastes the file at once, and the pick counts `klipy:<slug>`.
    @Test func thePrefetchStartsAfter300ms() async throws {
        let klipy = try KlipyRig()
        let page = klipyPage(klipy, ["hello-hi-662", "shaq-dance"], hasNext: false)
        let bytes = makeTestImage(width: 20, height: 20, type: .gif, frames: 2)
        klipy.network.setReply { request in
            request.url?.host == "static.klipy.com" ? .answer(status: 200, body: bytes) : .json(page)
        }
        let session = klipy.session
        await klipy.search("hi")
        #expect(session.selection == 0)
        klipy.clock.advance(by: 0.2)
        session.move(.right)
        klipy.clock.advance(by: 0.2)
        for _ in 0..<50 { await Task.yield() }
        #expect(klipy.requests("media").isEmpty)
        klipy.clock.advance(by: 0.1)
        let shaq = try #require(klipy.klipy.item("shaq-dance", kind: .gif))
        await waitUntil { klipy.klipy.pasteFile(for: shaq) != nil }
        #expect(klipy.requests("media").map { $0.url?.lastPathComponent } == ["md.gif"])
        #expect(klipy.requests("media").first?.url?.path.contains("shaq-dance") == true)
        let file = try #require(klipy.klipy.pasteFile(for: shaq))
        #expect(file.path.hasPrefix(klipy.cache.url.appendingPathComponent("paste").path))
        #expect(try Data(contentsOf: file) == bytes)

        session.enter(shift: false)
        #expect(!session.isOpen)
        #expect(klipy.rig.clipboard.contents.items.first?.values.first?.data == Data(file.absoluteString.utf8))
        #expect(klipy.rig.clipboard.contents.items.first?.values.map(\.type).prefix(2) == ["public.file-url", "com.compuserve.gif"])
        #expect(klipy.rig.store.you.uses["klipy:shaq-dance"]?.count == 1)
        #expect(klipy.rig.store.you.learned["hi"]?["klipy:shaq-dance"]?.count == 1)
    }

    /// D6: Enter before the file is ready waits with "Getting the GIF…". After 3 s with no file:
    /// "Can't get this GIF from KLIPY.", no paste and no count. A file in time pastes at once.
    @Test func aPickWaitsUpTo3sForTheFile() async throws {
        let gate = ManualSleep()
        let folder = try TempFolder()
        let ready = folder.url.appendingPathComponent("hello.gif")
        try makeTestImage(width: 20, height: 20, type: .gif, frames: 2).write(to: ready)
        let klipy = try KlipyRig(download: { _ in
            try await gate.sleep(.seconds(60))
            return ready
        })
        let page = klipyPage(klipy, ["hello-hi-662"], hasNext: false)
        klipy.network.setReply { _ in .json(page) }
        let session = klipy.session
        await klipy.search("hi")
        let before = klipy.rig.clipboard.contents
        session.enter(shift: false)
        #expect(session.isOpen && session.lines.first == .title("Getting the GIF…"))
        #expect(session.selection == 0 && session.waitingFor != nil)
        klipy.clock.advance(by: 2.9)
        #expect(session.lines.first == .title("Getting the GIF…"))
        klipy.clock.advance(by: 0.1)
        #expect(session.lines.first == .title("Can't get this GIF from KLIPY."))
        #expect(session.isOpen && session.waitingFor == nil)
        #expect(klipy.rig.clipboard.contents == before && klipy.rig.store.you.uses.isEmpty)
        // The next key takes the line away.
        session.setQuery("hi ")
        #expect(session.lines.first == .title("From KLIPY") && session.selection == 0)

        // A file that comes within 3 s pastes then, and the panel closes.
        session.enter(shift: false)
        #expect(session.lines.first == .title("Getting the GIF…"))
        await waitUntil { gate.waiting > 0 }
        gate.wake()
        await waitUntil { !session.isOpen }
        #expect(klipy.rig.clipboard.contents.items.first?.values.first?.data == Data(ready.absoluteString.utf8))
        #expect(klipy.rig.store.you.uses["klipy:hello-hi-662"]?.count == 1)
        #expect(PickSession.cantGetText(.meme) == "Can't get this meme from KLIPY.")
    }

    /// D6: the paste files older than 5 minutes go at each open of the panel, and all of them at quit.
    @Test func theAppCleansUpThePasteFiles() async throws {
        let rig = try PickRig()
        let parts = rig.parts(catalog: smallCatalog(5))
        let paste = parts.cacheFolder.appendingPathComponent("paste", isDirectory: true)
        let old = paste.appendingPathComponent("old", isDirectory: true)
        let new = paste.appendingPathComponent("new", isDirectory: true)
        for folder in [old, new] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-6 * 60)], ofItemAtPath: old.path)
        let app = AppController(hotKeys: FakeHotKeyRegistrar(), loginItem: FakeLoginItem(), parts: parts)
        app.start()
        await app.ready?.value
        #expect(app.pasteFiles.folder == paste)
        try #require(app.session).open()
        await waitUntil { rig.folder.names(in: paste) == ["new"] }
        #expect(rig.folder.names(in: paste) == ["new"])
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(rig.folder.names(in: paste).isEmpty)
    }
}
