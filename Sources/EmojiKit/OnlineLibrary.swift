import Foundation
import UniformTypeIdentifiers

/// GIF or meme, for an online item. The raw values are the `kind` of a library item (D3 of YAZ-2919).
enum OnlineKind: String, Codable, Sendable, CaseIterable {
    case gif
    case meme
}

/// One GIF or meme of KLIPY (D1 of YAZ-2919). It holds only the URLs, never the file (D7).
/// The URLs stay exactly as KLIPY gives them (KLIPY's rule 1).
struct OnlineItem: Equatable, Sendable, Identifiable {
    /// The KLIPY slug, for example `hello-hi-662`. It is the `klipyID` of D3 and D7,
    /// because the items call of KLIPY takes slugs, not the number ID.
    let id: String
    /// KLIPY's number ID. The app does not need it today.
    let number: Int?
    let kind: OnlineKind
    let title: String
    /// The small still picture of the tile: `sm.jpg` of a GIF, `sm.png` of a meme.
    let still: URL
    /// The small moving picture of the tile with the blue box: `sm.gif`. Nil for a meme.
    let preview: URL?
    /// The file that a pick pastes: `md.gif` (else `hd`, else `sm`) of a GIF, `hd.png` (else `md`, else `sm`) of a meme.
    let file: URL
    /// The type of `file`, for the clipboard (D6): `com.compuserve.gif`, `public.png` or `public.jpeg`.
    let fileType: UTType
    /// The extension of `file`, without the dot: `gif`, `png` or `jpg`.
    let fileExtension: String
    /// The size of `file` in pixels.
    let width: Int
    let height: Int
    /// The size of `file` in bytes, when KLIPY gives it.
    let bytes: Int?

    /// The key of the pick counts and the learned words in `you-<Mac>.json` (D7 of YAZ-2919).
    var youKey: String { "klipy:\(id)" }
}

/// One page of KLIPY search results, in KLIPY's order.
struct OnlinePage: Equatable, Sendable {
    var items: [OnlineItem]
    /// True when one more page can come. It is false at the last page that the app asks for.
    var hasMore: Bool
}

/// Why an online call gave no items (D2 of YAZ-2919). The panel shows `line` as one grey line in "From KLIPY".
enum OnlineError: Error, Equatable, Sendable {
    /// No key in the Keychain. The app sends no request.
    case noKey
    /// HTTP 401 or 403: KLIPY refused the key.
    case refused
    /// HTTP 429: too many requests.
    case busy
    /// No internet, no answer within 5 s, or a different network failure.
    case unreachable
    /// An answer that the app cannot read, or a different HTTP status.
    case badResponse

    /// The grey line of D2.
    var line: String {
        switch self {
        case .noKey: return "Add a KLIPY key in Settings to search online."
        case .refused: return "KLIPY refused the key. Check it in Settings."
        case .busy: return "KLIPY is busy. Try again in a minute."
        case .unreachable: return "Can't reach KLIPY."
        case .badResponse: return "KLIPY sent an answer that the app can't read."
        }
    }
}

/// An online library of GIFs and memes. A test gives a fake one, or `KlipyLibrary` with a stub network.
protocol OnlineLibrary: Sendable {
    /// One page of results for `text`. `page` starts at 1. The order is the order of the library.
    /// An empty text, or a page after the last one, gives no items and sends no request.
    func search(_ text: String, kind: OnlineKind, page: Int) async throws -> OnlinePage
    /// The items with these IDs, in one call (D7 of YAZ-2919). An ID that the library deleted is not in the result.
    func items(ids: [String], kind: OnlineKind) async throws -> [OnlineItem]
}

/// KLIPY over `URLSession` (D1 of YAZ-2919). The requests come from this Mac, as KLIPY asks.
/// The key is a part of the path: `https://api.klipy.com/api/v1/<key>/gifs/search`.
final class KlipyLibrary: OnlineLibrary {
    static let base = URL(string: "https://api.klipy.com/api/v1/")!
    /// Results on one page (D11 of YAZ-2919).
    static let pageSize = 24
    /// The most results of one search: 4 pages (D11 of YAZ-2919).
    static let maxItems = 96
    static var lastPage: Int { maxItems / pageSize }
    /// The time-out of one request (D2 of YAZ-2919).
    static let timeout: TimeInterval = 5

    private let keys: KeyStore
    private let session: URLSession

    init(keys: KeyStore, session: URLSession = KlipyLibrary.makeSession()) {
        self.keys = keys
        self.session = session
    }

    /// A session with no cache and no cookies, and the 5 s time-out. A test gives its stub in `protocolClasses`.
    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration)
    }

    func search(_ text: String, kind: OnlineKind, page: Int) async throws -> OnlinePage {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, (1...KlipyLibrary.lastPage).contains(page) else { return OnlinePage(items: [], hasMore: false) }
        let url = try KlipyLibrary.url(key: key(), kind: kind, call: "search", query: [
            ("q", text),
            ("page", String(page)),
            ("per_page", String(KlipyLibrary.pageSize)),
        ])
        let list = try KlipyLibrary.decode(try await KlipyLibrary.fetch(url, session: session))
        // KLIPY's order stays (KLIPY's rule 4). The page after the 4th is never asked for.
        return OnlinePage(items: list.items(kind), hasMore: list.hasNext && page < KlipyLibrary.lastPage)
    }

    func items(ids: [String], kind: OnlineKind) async throws -> [OnlineItem] {
        guard !ids.isEmpty else { return [] }
        let url = try KlipyLibrary.url(key: key(), kind: kind, call: "items", query: [("slugs", ids.joined(separator: ","))])
        return try KlipyLibrary.decode(try await KlipyLibrary.fetch(url, session: session)).items(kind)
    }

    /// The key, or `noKey` before any request.
    private func key() throws -> String {
        guard let key = keys.read(), !key.isEmpty else { throw OnlineError.noKey }
        return key
    }

    // MARK: The request

    /// The path of a kind: `gifs` or `static-memes`.
    static func path(_ kind: OnlineKind) -> String {
        switch kind {
        case .gif: return "gifs"
        case .meme: return "static-memes"
        }
    }

    /// `<base>/<key>/<kind>/<call>?<query>`. The key and the values are percent-encoded,
    /// also `+` and `,` in a search text, so the server never reads them as a space or a list.
    static func url(key: String, kind: OnlineKind, call: String, query: [(String, String)]) throws -> URL {
        // The unreserved characters of RFC 3986. Each other character is percent-encoded.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        let items = query.map { name, value in
            // A slug list keeps its commas: they are the separator of the list.
            let encoded = name == "slugs" ? value.split(separator: ",").map { encode(String($0)) }.joined(separator: ",") : encode(value)
            return "\(name)=\(encoded)"
        }
        let text = base.absoluteString + "\(encode(key))/\(path(kind))/\(call)?" + items.joined(separator: "&")
        guard let url = URL(string: text) else { throw OnlineError.badResponse }
        return url
    }

    /// Gets the bytes at `url`. It maps each failure to an `OnlineError` (D2 of YAZ-2919).
    /// A cancelled task throws `CancellationError`, so a new search can replace the old one in silence.
    static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                throw CancellationError()
            }
            throw OnlineError.unreachable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw OnlineError.badResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw OnlineError.refused
        case 429: throw OnlineError.busy
        default: throw OnlineError.badResponse
        }
    }

    static func decode(_ data: Data) throws -> KlipyList {
        guard let answer = try? JSONDecoder().decode(KlipyAnswer.self, from: data),
              answer.result != false, let list = answer.data else { throw OnlineError.badResponse }
        return list
    }
}

// MARK: The answer of KLIPY

/// `{"result": true, "data": {...}}`: the outer object of each KLIPY answer.
struct KlipyAnswer: Decodable {
    let result: Bool?
    let data: KlipyList?
}

/// `data` of an answer: the items, and for a search the page fields.
struct KlipyList: Decodable {
    let data: [Lenient<KlipyRaw>]
    let hasNext: Bool

    enum CodingKeys: String, CodingKey {
        case data
        case hasNext = "has_next"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([Lenient<KlipyRaw>].self, forKey: .data)
        hasNext = (try? container.decodeIfPresent(Bool.self, forKey: .hasNext)) ?? false
    }

    /// The items that the panel can show, in KLIPY's order. An item with no usable file
    /// (for example an ad, which has HTML and no `file`) has no tile, so it is skipped.
    func items(_ kind: OnlineKind) -> [OnlineItem] {
        data.compactMap { $0.value?.item(kind) }
    }
}

/// One item that does not stop the full list when it cannot be read.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// One item as KLIPY sends it.
struct KlipyRaw: Decodable {
    /// `{url, width, height, size}` of one format of one size.
    struct Format: Decodable {
        let url: URL
        let width: Int?
        let height: Int?
        let size: Int?
    }

    let number: Int?
    let slug: String
    let title: String?
    /// size (`hd`, `md`, `sm`, `xs`) → format (`gif`, `jpg`, `png`, …) → the file.
    let file: [String: [String: Lenient<Format>]]

    enum CodingKeys: String, CodingKey {
        case number = "id"
        case slug, title, file
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // KLIPY sends the ID as a number. A text ID also works.
        number = (try? container.decodeIfPresent(Int.self, forKey: .number))
            ?? (try? container.decodeIfPresent(String.self, forKey: .number)).flatMap { Int($0) }
        slug = try container.decode(String.self, forKey: .slug)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        file = try container.decode([String: [String: Lenient<Format>]].self, forKey: .file)
    }

    /// The first of these (size, format) pairs that KLIPY has.
    private func first(_ choices: [(String, String)]) -> (format: String, file: Format)? {
        for (size, format) in choices {
            if let found = file[size]?[format]?.value { return (format, found) }
        }
        return nil
    }

    /// The item for the panel, with the files of the decision "the KLIPY ID is the slug" on YAZ-2928.
    func item(_ kind: OnlineKind) -> OnlineItem? {
        guard !slug.isEmpty else { return nil }
        let still: (format: String, file: Format)?
        let preview: (format: String, file: Format)?
        let paste: (format: String, file: Format)?
        switch kind {
        case .gif:
            still = first([("sm", "jpg"), ("md", "jpg"), ("xs", "jpg")])
            preview = first([("sm", "gif"), ("xs", "gif")])
            paste = first([("md", "gif"), ("hd", "gif"), ("sm", "gif")])
        case .meme:
            still = first([("sm", "png"), ("md", "png"), ("xs", "png")])
            preview = nil
            paste = first([("hd", "png"), ("md", "png"), ("sm", "png")])
        }
        guard let paste, let type = UTType(filenameExtension: paste.format) else { return nil }
        return OnlineItem(
            id: slug,
            number: number,
            kind: kind,
            title: title ?? "",
            still: still?.file.url ?? paste.file.url,
            preview: preview?.file.url,
            file: paste.file.url,
            fileType: type,
            fileExtension: paste.format,
            width: paste.file.width ?? 0,
            height: paste.file.height ?? 0,
            bytes: paste.file.size
        )
    }
}

// MARK: The search pause

/// Waits for a pause in the typing, then runs one search (D11 of YAZ-2919).
/// Each change cancels the wait and the request of the change before it.
/// `sleep` is a parameter, so a test decides when the pause ends and never waits 350 ms.
@MainActor
final class SearchDebouncer {
    /// From the last key to the request.
    static let pause: Duration = .milliseconds(350)

    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let sleep: Sleep
    private var task: Task<Void, Never>?

    init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Starts `work` after the pause, and gives its result to `done` on the main thread.
    /// A cancelled `work` gives nothing to `done`.
    func change<Value: Sendable>(
        _ work: @escaping @Sendable () async throws -> Value,
        done: @escaping @MainActor (Result<Value, Error>) -> Void
    ) {
        task?.cancel()
        task = Task { [sleep] in
            do { try await sleep(SearchDebouncer.pause) } catch { return }
            guard !Task.isCancelled else { return }
            let result: Result<Value, Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            if Task.isCancelled { return }
            if case .failure(let error) = result, error is CancellationError { return }
            done(result)
        }
    }

    /// Stops the wait and the request, for example when the panel closes or the search text is empty.
    func cancel() {
        task?.cancel()
        task = nil
    }
}

// MARK: The paste file

/// The temp files for the paste of a KLIPY item (D6 of YAZ-2919): `<cache>/paste/<uuid>/<id>.<ext>`.
/// They are the only copies of KLIPY files (D7). `cleanUp` deletes them after 5 minutes, and at quit.
final class PasteFiles: Sendable {
    /// How long a paste file stays.
    static let keep: TimeInterval = 5 * 60

    /// `<cache>/paste`.
    let folder: URL
    private let session: URLSession
    private let now: @Sendable () -> Date

    /// `cache` is `~/Library/Caches/Yaseen Emoji` in the app, and a temp folder in a test.
    init(cache: URL, session: URLSession = KlipyLibrary.makeSession(), now: @escaping @Sendable () -> Date = { Date() }) {
        folder = cache.appendingPathComponent("paste", isDirectory: true)
        self.session = session
        self.now = now
    }

    /// Downloads the paste file of `item` into a new `<uuid>` folder and gives its URL.
    /// A cancelled task (the blue box moved) writes nothing.
    func download(_ item: OnlineItem) async throws -> URL {
        let data = try await KlipyLibrary.fetch(item.file, session: session)
        try Task.checkCancellation()
        let place = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = place.appendingPathComponent("\(PreferencesFolder.safeName(item.id)).\(item.fileExtension)")
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Deletes each `<uuid>` folder that is older than 5 minutes. With `all`, it deletes everything (at quit).
    func cleanUp(all: Bool = false) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let oldest = now().addingTimeInterval(-PasteFiles.keep)
        for entry in entries {
            let changed = (try? entry.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if all || changed < oldest { try? manager.removeItem(at: entry) }
        }
    }
}
