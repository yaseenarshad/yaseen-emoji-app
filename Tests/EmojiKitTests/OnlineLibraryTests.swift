import Foundation
import Testing
import UniformTypeIdentifiers
@testable import EmojiKit

/// KLIPY search, items by ID, the errors, the search pause and the paste file (YAZ-2928, D1, D2, D6, D7 of YAZ-2919).
/// Each test has a fake network (`StubNetwork`) and a fake key store. No test makes a real request
/// or touches the real Keychain.
@Suite struct OnlineLibraryTests {
    /// A GIF search page with the two sample GIFs of the docs.
    static func gifPage(_ network: StubNetwork, hasNext: Bool = true) -> String {
        KlipySample.page([
            KlipySample.gif(number: 8041071659142944, slug: "hello-hi-662", title: "Hello") { network.mediaURL("hello/\($0)").absoluteString },
            KlipySample.gif(number: 2525964843568523, slug: "shaq-dance", title: "Shaq's Excited Dance") { network.mediaURL("shaq/\($0)").absoluteString },
        ], hasNext: hasNext)
    }

    /// The query items of a request, by name.
    static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func aSearchSendsTheRequestThatKlipyAsksFor() async throws {
        let network = StubNetwork { _ in .json(KlipySample.page([])) }
        let library = KlipyLibrary(keys: FakeKeyStore(network.key), session: network.session)

        _ = try await library.search("  thumbs up+1 ", kind: .gif, page: 2)
        _ = try await library.search("3 am", kind: .meme, page: 1)

        let requests = network.requests
        try #require(requests.count == 2)
        let gif = requests[0]
        #expect(gif.httpMethod == "GET")
        #expect(gif.url?.host == "api.klipy.com")
        #expect(gif.url?.path == "/api/v1/\(network.key)/gifs/search")
        #expect(Self.query(gif) == ["q": "thumbs up+1", "page": "2", "per_page": "24"])
        // `+` goes as %2B, so the server never reads it as a space.
        #expect(gif.url?.absoluteString.contains("q=thumbs%20up%2B1") == true)
        #expect(gif.timeoutInterval == 5)
        // No user ID, no ad parameters: KLIPY sends no ads.
        #expect(gif.url?.query?.contains("customer_id") == false)
        #expect(gif.url?.query?.contains("ad-") == false)
        #expect(requests[1].url?.path == "/api/v1/\(network.key)/static-memes/search")
        #expect(Self.query(requests[1])["q"] == "3 am")
    }

    @Test func theSampleGifPageGivesItemsInKlipysOrder() async throws {
        let network = StubNetwork { _ in .json("") }
        network.setReply { [page = Self.gifPage(network)] _ in .json(page) }
        let library = KlipyLibrary(keys: FakeKeyStore(network.key), session: network.session)

        let page = try await library.search("hello", kind: .gif, page: 1)

        #expect(page.hasMore)
        #expect(page.items.map(\.id) == ["hello-hi-662", "shaq-dance"])
        let hello = try #require(page.items.first)
        #expect(hello.kind == .gif)
        #expect(hello.title == "Hello")
        #expect(hello.still == network.mediaURL("hello/sm.jpg"))
        #expect(hello.preview == network.mediaURL("hello/sm.gif"))
        #expect(hello.file == network.mediaURL("hello/md.gif"))
        #expect(hello.fileType == .gif)
        #expect(hello.fileExtension == "gif")
        #expect(hello.width == 498 && hello.height == 498)
        #expect(hello.bytes == 314884)
        #expect(hello.youKey == "klipy:hello-hi-662")
    }

    @Test func theSampleMemeGivesThePngFiles() async throws {
        let network = StubNetwork { _ in .json("") }
        let meme = KlipySample.meme(number: 4895743751814617, slug: "3-am-video-game-meme", title: "3 Am Video Game Meme") {
            network.mediaURL("meme/\($0)").absoluteString
        }
        network.setReply { _ in .json(KlipySample.page([meme], hasNext: false)) }
        let library = KlipyLibrary(keys: FakeKeyStore(network.key), session: network.session)

        let page = try await library.search("3 am", kind: .meme, page: 1)

        #expect(!page.hasMore)
        let item = try #require(page.items.first)
        #expect(item.kind == .meme)
        #expect(item.still == network.mediaURL("meme/sm.png"))
        #expect(item.preview == nil)
        #expect(item.file == network.mediaURL("meme/hd.png"))
        #expect(item.fileType == .png)
        #expect(item.fileExtension == "png")
        #expect(item.width == 498 && item.height == 467)
    }

    /// An item with no file (an ad) has no tile. The other items keep their order.
    @Test func anItemWithNoFileIsSkipped() async throws {
        let network = StubNetwork { _ in .json("") }
        let first = KlipySample.gif(number: 1, slug: "first", title: "First") { network.mediaURL("first/\($0)").absoluteString }
        let second = KlipySample.gif(number: 2, slug: "second", title: "Second") { network.mediaURL("second/\($0)").absoluteString }
        network.setReply { _ in .json(KlipySample.page([first, KlipySample.ad, second])) }
        let library = KlipyLibrary(keys: FakeKeyStore(network.key), session: network.session)

        let page = try await library.search("x", kind: .gif, page: 1)
        #expect(page.items.map(\.id) == ["first", "second"])
    }

    /// D7: the saved and learned KLIPY items come back in one call by their slugs.
    /// A slug that KLIPY deleted is not in the answer, and gives no error.
    @Test func itemsByIDsUseOneCallWithTheSlugs() async throws {
        let network = StubNetwork { _ in .json("") }
        let kept = KlipySample.gif(number: 1, slug: "hello-hi-662", title: "Hello") { network.mediaURL("kept/\($0)").absoluteString }
        network.setReply { _ in .json(KlipySample.items([kept])) }
        let library = KlipyLibrary(keys: FakeKeyStore(network.key), session: network.session)

        let items = try await library.items(ids: ["hello-hi-662", "deleted-one"], kind: .gif)
        #expect(items.map(\.id) == ["hello-hi-662"])
        try #require(network.requests.count == 1)
        let request = network.requests[0]
        #expect(request.url?.path == "/api/v1/\(network.key)/gifs/items")
        #expect(request.url?.query == "slugs=hello-hi-662,deleted-one")

        _ = try await library.items(ids: ["a"], kind: .meme)
        #expect(network.requests.last?.url?.path == "/api/v1/\(network.key)/static-memes/items")

        // No IDs: no request.
        #expect(try await library.items(ids: [], kind: .gif).isEmpty)
        #expect(network.requests.count == 2)
    }

    /// One failure of the network or of KLIPY, and its error (D2 of YAZ-2919).
    enum Failure: String, CaseIterable, Sendable {
        case unauthorized, forbidden, wrongKey, notFound, tooMany, serverError, timeOut, offline, notJSON, resultFalse

        var reply: StubReply {
            switch self {
            case .unauthorized: return .json(#"{"error": {"isError": true, "errorMessage": "Unauthorized"}}"#, status: 401)
            case .forbidden: return .json("{}", status: 403)
            // The real answer of KLIPY to a wrong key (16 Oct 2026).
            case .wrongKey: return .json(#"{"result":false,"errors":{"message":["The provided API key is invalid."]}}"#, status: 404)
            case .notFound: return .json("{}", status: 404)
            case .tooMany: return .json("{}", status: 429)
            case .serverError: return .json("{}", status: 500)
            case .timeOut: return .fail(.timedOut)
            case .offline: return .fail(.notConnectedToInternet)
            case .notJSON: return .json("<html>no</html>")
            case .resultFalse: return .json(#"{"result": false}"#)
            }
        }

        var error: OnlineError {
            switch self {
            case .unauthorized, .forbidden, .wrongKey: return .refused
            case .tooMany: return .busy
            case .timeOut, .offline: return .unreachable
            case .notFound, .serverError, .notJSON, .resultFalse: return .badResponse
            }
        }
    }

    @Test(arguments: Failure.allCases)
    func eachFailureGivesItsError(_ failure: Failure) async throws {
        let network = StubNetwork { _ in failure.reply }
        let library = KlipyLibrary(keys: FakeKeyStore(network.key), session: network.session)

        await #expect(throws: failure.error) { try await library.search("hello", kind: .gif, page: 1) }
        await #expect(throws: failure.error) { try await library.items(ids: ["a"], kind: .meme) }
    }

    @Test func theGreyLinesAreTheLinesOfD2() {
        #expect(OnlineError.noKey.line == "Add a KLIPY key in Settings to search online.")
        #expect(OnlineError.refused.line == "KLIPY refused the key. Check it in Settings.")
        #expect(OnlineError.busy.line == "KLIPY is busy. Try again in a minute.")
        #expect(OnlineError.unreachable.line == "Can't reach KLIPY.")
    }

    @Test func noKeyGivesNoKeyAndSendsNoRequest() async throws {
        let network = StubNetwork { _ in .json(KlipySample.page([])) }
        let keys = FakeKeyStore()
        let library = KlipyLibrary(keys: keys, session: network.session)

        await #expect(throws: OnlineError.noKey) { try await library.search("hello", kind: .gif, page: 1) }
        await #expect(throws: OnlineError.noKey) { try await library.items(ids: ["a"], kind: .gif) }
        #expect(network.requests.isEmpty)

        // The library reads the key at each request: a key from Settings works at once,
        // and an empty text removes it again.
        try keys.write("  \(network.key)\n")
        _ = try await library.search("hello", kind: .gif, page: 1)
        #expect(network.requests.count == 1)
        try keys.write("   ")
        await #expect(throws: OnlineError.noKey) { try await library.search("hello", kind: .gif, page: 1) }
        #expect(network.requests.count == 1)
    }

    @Test func anEmptySearchSendsNoRequest() async throws {
        let network = StubNetwork { _ in .json(KlipySample.page([])) }
        let library = KlipyLibrary(keys: FakeKeyStore(network.key), session: network.session)

        #expect(try await library.search("   ", kind: .gif, page: 1) == OnlinePage(items: [], hasMore: false))
        #expect(network.requests.isEmpty)
    }

    /// 24 a page, at most 96: page 4 says there is no more, and page 5 sends no request.
    @Test func thePagesStopAt96() async throws {
        let network = StubNetwork { _ in .json("") }
        let media = network.mediaURL("").absoluteString
        network.setReply { request in
            let page = Int(OnlineLibraryTests.query(request)["page"] ?? "") ?? 0
            let items = (0..<24).map { number in
                KlipySample.gif(number: page * 100 + number, slug: "p\(page)-\(number)", title: "") { "\(media)\(page)/\(number)/\($0)" }
            }
            return .json(KlipySample.page(items, page: page, hasNext: true))
        }
        let library = KlipyLibrary(keys: FakeKeyStore(network.key), session: network.session)

        var all: [OnlineItem] = []
        var page = 1
        while true {
            let result = try await library.search("cat", kind: .gif, page: page)
            all += result.items
            guard result.hasMore else { break }
            page += 1
        }
        #expect(page == 4)
        #expect(all.count == 96)
        #expect(all.first?.id == "p1-0")
        #expect(all.last?.id == "p4-23")
        #expect(network.requests.count == 4)

        #expect(try await library.search("cat", kind: .gif, page: 5).items.isEmpty)
        #expect(try await library.search("cat", kind: .gif, page: 0).items.isEmpty)
        #expect(network.requests.count == 4)
    }

    // MARK: The search pause

    /// The work starts only after the pause, and a second change cancels the first.
    @MainActor
    @Test func theSearchStartsAfterThePauseAndANewKeyCancelsTheOld() async {
        let clock = ManualSleep()
        let debouncer = SearchDebouncer(sleep: { try await clock.sleep($0) })
        let started = Locked<[String]>([])
        var results: [String] = []

        for text in ["c", "ca"] {
            debouncer.change({ started.change { $0.append(text) }; return text }) { result in
                if case .success(let value) = result { results.append(value) }
            }
            await waitUntil { clock.waiting == 1 }
        }
        // Two pauses were asked for, and the first one was cancelled. Nothing ran yet.
        #expect(clock.durations == [.milliseconds(350), .milliseconds(350)])
        #expect(clock.waiting == 1)
        #expect(started.value.isEmpty)

        clock.wake()
        await waitUntil { !results.isEmpty }
        #expect(started.value == ["ca"])
        #expect(results == ["ca"])
    }

    /// A new key also cancels a request that already runs. Its result never comes to the panel.
    @MainActor
    @Test func aNewKeyCancelsARequestThatRuns() async {
        let clock = ManualSleep()
        let network = ManualSleep()   // the "request": it ends only on wake, or on cancel
        let debouncer = SearchDebouncer(sleep: { try await clock.sleep($0) })
        let cancelled = Locked(false)
        var results: [String] = []

        debouncer.change({
            do { try await network.sleep(.zero) } catch { cancelled.change { $0 = true }; throw error }
            return "c"
        }) { result in
            if case .success(let value) = result { results.append(value) }
        }
        await waitUntil { clock.waiting == 1 }
        clock.wake()
        await waitUntil { network.waiting == 1 }

        debouncer.change({ "ca" }) { result in
            if case .success(let value) = result { results.append(value) }
        }
        await waitUntil { cancelled.value }
        #expect(cancelled.value)
        await waitUntil { clock.waiting == 1 }
        clock.wake()
        await waitUntil { !results.isEmpty }
        #expect(results == ["ca"])
    }

    /// The panel's flow with the real client: two keys, one pause, one request for the last text.
    @MainActor
    @Test func twoKeysSendOneRequestForTheLastText() async throws {
        let network = StubNetwork { _ in .json("") }
        network.setReply { [page = Self.gifPage(network)] _ in .json(page) }
        let library = KlipyLibrary(keys: FakeKeyStore(network.key), session: network.session)
        let clock = ManualSleep()
        let debouncer = SearchDebouncer(sleep: { try await clock.sleep($0) })
        var pages: [OnlinePage] = []

        for text in ["c", "ca"] {
            debouncer.change({ try await library.search(text, kind: .gif, page: 1) }) { result in
                if case .success(let page) = result { pages.append(page) }
            }
            await waitUntil { clock.waiting == 1 }
        }
        #expect(network.requests.isEmpty)

        clock.wake()
        await waitUntil { !pages.isEmpty }
        #expect(network.requests.count == 1)
        #expect(network.requests.first.map(Self.query)?["q"] == "ca")
        #expect(pages.first?.items.count == 2)

        // An empty text: the panel cancels, and nothing more runs.
        debouncer.cancel()
        #expect(network.requests.count == 1)
    }

    // MARK: The paste file

    @Test func thePasteFileGoesIntoItsOwnFolderAndGoesAway() async throws {
        let folder = try TempFolder()
        let network = StubNetwork { _ in .json("") }
        let gifBytes = Data("GIF89a-sample".utf8)
        network.setReply { _ in .answer(status: 200, body: gifBytes) }
        let start = Date()
        let clock = Locked(start)
        let files = PasteFiles(cache: folder.url, session: network.session, now: { clock.value })

        let item = OnlineItem(id: "hello-hi-662", kind: .gif, title: "Hello",
                              still: network.mediaURL("sm.jpg"), preview: nil, file: network.mediaURL("md.gif"),
                              fileType: .gif, fileExtension: "gif", width: 498, height: 498, bytes: nil)
        let first = try await files.download(item)
        let second = try await files.download(item)

        // `<cache>/paste/<uuid>/<id>.<ext>`, a new folder for each paste.
        #expect(first.lastPathComponent == "hello-hi-662.gif")
        #expect(first.deletingLastPathComponent().deletingLastPathComponent() == folder.url.appendingPathComponent("paste", isDirectory: true))
        #expect(UUID(uuidString: first.deletingLastPathComponent().lastPathComponent) != nil)
        #expect(first.deletingLastPathComponent() != second.deletingLastPathComponent())
        #expect(try Data(contentsOf: first) == gifBytes)
        #expect(network.requests.first?.url == network.mediaURL("md.gif"))

        // The first one is 6 minutes old: the clean-up deletes it and keeps the second one.
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-6 * 60)],
                                              ofItemAtPath: first.deletingLastPathComponent().path)
        files.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))

        // 4 minutes later, the second one stays. At quit, everything goes.
        clock.change { $0 = start.addingTimeInterval(4 * 60) }
        files.cleanUp()
        #expect(FileManager.default.fileExists(atPath: second.path))
        files.cleanUp(all: true)
        #expect(folder.names(in: files.folder).isEmpty)
    }

    @Test func aPasteFileThatFailsWritesNothing() async throws {
        let folder = try TempFolder()
        let network = StubNetwork { _ in .fail(.timedOut) }
        let files = PasteFiles(cache: folder.url, session: network.session)
        let item = OnlineItem(id: "x", kind: .meme, title: "", still: network.mediaURL("s.png"), preview: nil,
                              file: network.mediaURL("x.png"), fileType: .png, fileExtension: "png", width: 1, height: 1, bytes: nil)

        await #expect(throws: OnlineError.unreachable) { try await files.download(item) }
        #expect(folder.names(in: files.folder).isEmpty)
    }

    @Test func theKeychainItemHasTheNamesOfD2() {
        // Only the names: no test runs the real Keychain code.
        #expect(KeychainKeyStore.service == "com.yaseenarshad.yaseenemoji")
        #expect(KeychainKeyStore.account == "klipy")
        #expect(KlipyKey.clean("  abc\n") == "abc")
    }
}

/// A value that several tasks read and change.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value { lock.withLock { stored } }

    func change(_ body: (inout Value) -> Void) {
        lock.withLock { body(&stored) }
    }
}
