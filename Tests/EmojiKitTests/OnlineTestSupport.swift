import Foundation
@testable import EmojiKit

/// A key store in memory. No test touches the real Keychain.
final class FakeKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private(set) var reads = 0

    init(_ key: String? = nil) {
        self.key = key
    }

    func read() -> String? {
        lock.withLock {
            reads += 1
            return key
        }
    }

    func write(_ key: String) throws {
        let clean = KlipyKey.clean(key)
        lock.withLock { self.key = clean.isEmpty ? nil : clean }
    }
}

/// What the fake network gives for one request.
enum StubReply: Sendable {
    case answer(status: Int, body: Data)
    case fail(URLError.Code)

    static func json(_ text: String, status: Int = 200) -> StubReply {
        .answer(status: status, body: Data(text.utf8))
    }
}

/// A fake network for one test (a `URLProtocol` stub). No test makes a real request.
/// Each test has its own `token`. The fake key and the fake file URLs hold it, so tests that run
/// at the same time never get the answers of a different test.
final class StubNetwork: @unchecked Sendable {
    let token = UUID().uuidString.lowercased()
    let session = KlipyLibrary.makeSession(protocolClasses: [StubURLProtocol.self])
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private var reply: @Sendable (URLRequest) -> StubReply

    init(reply: @escaping @Sendable (URLRequest) -> StubReply) {
        self.reply = reply
        StubURLProtocol.routes.add(self)
    }

    deinit {
        StubURLProtocol.routes.remove(token)
    }

    /// A key that routes to this network.
    var key: String { "key-\(token)" }

    /// A media URL that routes to this network.
    func mediaURL(_ name: String) -> URL {
        URL(string: "https://static.klipy.com/ii/\(token)/\(name)")!
    }

    var requests: [URLRequest] { lock.withLock { seen } }

    func setReply(_ reply: @escaping @Sendable (URLRequest) -> StubReply) {
        lock.withLock { self.reply = reply }
    }

    fileprivate func answer(_ request: URLRequest) -> StubReply {
        lock.withLock {
            seen.append(request)
            return reply(request)
        }
    }
}

/// The `URLProtocol` of `StubNetwork`. It answers each request of a stub session, and never goes online.
final class StubURLProtocol: URLProtocol {
    /// The networks of the tests that run now, by token.
    final class Routes: @unchecked Sendable {
        private let lock = NSLock()
        private var networks: [String: WeakNetwork] = [:]

        struct WeakNetwork {
            weak var network: StubNetwork?
        }

        func add(_ network: StubNetwork) {
            lock.withLock { networks[network.token] = WeakNetwork(network: network) }
        }

        func remove(_ token: String) {
            lock.withLock { networks[token] = nil }
        }

        func network(for url: URL?) -> StubNetwork? {
            guard let text = url?.absoluteString else { return nil }
            return lock.withLock { networks.first { text.contains($0.key) }?.value.network }
        }
    }

    static let routes = Routes()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // An unknown URL fails as "not connected". It never goes to the real network.
        let reply = StubURLProtocol.routes.network(for: request.url)?.answer(request) ?? .fail(.notConnectedToInternet)
        switch reply {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .answer(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// A sleep that ends only when the test calls `wake()`. Thus a test of the 350 ms pause never waits.
/// A cancelled sleep throws `CancellationError`, as `Task.sleep` does.
final class ManualSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var asked: [Duration] = []

    /// Each duration that a caller asked for.
    var durations: [Duration] { lock.withLock { asked } }
    /// The sleeps that wait now.
    var waiting: Int { lock.withLock { sleepers.count } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    asked.append(duration)
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        sleepers[id] = continuation
                    }
                }
            }
        } onCancel: {
            let continuation = lock.withLock { sleepers.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Ends each sleep that waits now.
    func wake() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            defer { sleepers.removeAll() }
            return Array(sleepers.values)
        }
        for continuation in all { continuation.resume() }
    }
}

/// A picture fetch that waits until the test lets it go (D11 update on YAZ-2925). Thus a test sees which loads
/// run at the same time. A cancelled fetch throws `CancellationError`. A fetch that the test lets go asks `then`
/// (the stub network), so no test goes online.
final class PictureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: (url: URL, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var startedURLs: [URL] = []
    private var cancelledURLs: [URL] = []
    private var most = 0

    /// Each fetch that started, in the order of the start.
    var started: [URL] { lock.withLock { startedURLs } }
    /// The fetches that stopped because their task was cancelled.
    var cancelled: [URL] { lock.withLock { cancelledURLs } }
    /// The fetches that wait now.
    var waiting: Set<URL> { lock.withLock { Set(waiters.values.map(\.url)) } }
    /// The most fetches that waited at the same time.
    var mostAtOnce: Int { lock.withLock { most } }

    func fetch(_ url: URL, then: @Sendable (URL) async throws -> Data) async throws -> Data {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    startedURLs.append(url)
                    if Task.isCancelled {
                        cancelledURLs.append(url)
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters[id] = (url, continuation)
                        most = max(most, waiters.count)
                    }
                }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> (url: URL, continuation: CheckedContinuation<Void, Error>)? in
                guard let waiter = waiters.removeValue(forKey: id) else { return nil }
                cancelledURLs.append(waiter.url)
                return waiter
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
        return try await then(url)
    }

    /// Lets each fetch that waits now go on.
    func releaseAll() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            defer { waiters.removeAll() }
            return waiters.values.map(\.continuation)
        }
        for continuation in all { continuation.resume() }
    }
}

/// Lets the other tasks run until `condition` is true. It gives up after about 3 s, so a fault fails the test
/// and does not hang it. It is not a wait for the 350 ms pause: the pause ends only with `ManualSleep.wake()`.
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    for _ in 0..<3_000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// The KLIPY answers of the tests, written by hand from the samples of docs.klipy.com (16 Oct 2026).
enum KlipySample {
    /// One format of one size.
    static func format(_ url: String, _ width: Int, _ height: Int, _ size: Int) -> String {
        #"{"url": "\#(url)", "width": \#(width), "height": \#(height), "size": \#(size)}"#
    }

    /// One GIF item, with all 4 sizes and all 5 formats, as on the GIF search page of the docs.
    static func gif(number: Int, slug: String, title: String, media: (String) -> String) -> String {
        func size(_ name: String, _ side: Int, _ videoSide: Int) -> String {
            #"""
            "\#(name)": {
              "gif": \#(format(media("\(name).gif"), side, side, 314884)),
              "webp": \#(format(media("\(name).webp"), side, side, 80118)),
              "jpg": \#(format(media("\(name).jpg"), side, side, 8560)),
              "mp4": \#(format(media("\(name).mp4"), videoSide, videoSide, 49565)),
              "webm": \#(format(media("\(name).webm"), videoSide, videoSide, 48827))
            }
            """#
        }
        return #"""
        {
          "id": \#(number),
          "slug": "\#(slug)",
          "title": "\#(title)",
          "file": {
            \#(size("hd", 498, 498)),
            \#(size("md", 498, 498)),
            \#(size("sm", 220, 320)),
            \#(size("xs", 90, 150))
          },
          "tags": [],
          "type": "gif",
          "blur_preview": "data:image/jpeg;base64,AAAA"
        }
        """#
    }

    /// One meme item: `png` and `webp` in 4 sizes, as on the meme search page of the docs.
    static func meme(number: Int, slug: String, title: String, media: (String) -> String) -> String {
        func size(_ name: String, _ width: Int, _ height: Int) -> String {
            #"""
            "\#(name)": {
              "png": \#(format(media("\(name).png"), width, height, 90568)),
              "webp": \#(format(media("\(name).webp"), width, height, 27248))
            }
            """#
        }
        return #"""
        {
          "id": \#(number),
          "slug": "\#(slug)",
          "title": "\#(title)",
          "file": {
            \#(size("hd", 498, 467)),
            \#(size("md", 498, 467)),
            \#(size("sm", 220, 206)),
            \#(size("xs", 90, 84))
          },
          "tags": [],
          "type": "static-meme",
          "blur_preview": "data:image/jpeg;base64,AAAA"
        }
        """#
    }

    /// An ad item: HTML and no `file`. KLIPY sends it only when a request asks for ads.
    static let ad = #"{"type": "ad", "content": "<div>ad</div>", "width": 300, "height": 250}"#

    /// A search page around `items`.
    static func page(_ items: [String], page: Int = 1, hasNext: Bool = true) -> String {
        #"{"result": true, "data": {"data": [\#(items.joined(separator: ","))], "current_page": \#(page), "per_page": 24, "has_next": \#(hasNext)}}"#
    }

    /// An items answer around `items`: no page fields.
    static func items(_ items: [String]) -> String {
        #"{"result": true, "data": {"data": [\#(items.joined(separator: ","))]}}"#
    }
}
