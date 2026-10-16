import Foundation

/// What the app knows about you (D4 on YAZ-2894): the contents of `you.json`.
/// Each emoji key is `You.key(emoji)`, so "❤" and "❤️" are one emoji, and 👍🏽 counts as 👍 (D9).
public struct You: Codable, Equatable, Sendable {
    /// How many times you picked one emoji, and the last time.
    public struct Use: Codable, Equatable, Sendable {
        public var count: Int
        public var last: Date
        public init(count: Int, last: Date) {
            self.count = count
            self.last = last
        }
    }

    /// One emoji hidden from "Your most used" (D15), or shown again. `at` is the time of the change,
    /// so a later sync can keep the newest change of each emoji.
    public struct Hide: Codable, Equatable, Sendable {
        public var on: Bool
        public var at: Date
        public init(on: Bool, at: Date) {
            self.on = on
            self.at = at
        }
    }

    /// The emojis for each search text: search text → emoji key → how many times, and the last time.
    public typealias Learned = [String: [String: Use]]

    /// Emoji key → your picks. "Your most used" comes from this.
    public var uses: [String: Use]
    /// The search text you typed → the emoji you picked. The search text is `Search.normalize(query)`.
    public var learned: Learned
    /// Emoji key → the words you added by hand.
    public var added: [String: [String]]
    /// Emoji key → hidden from "Your most used" or not (D15). The search does not read it.
    public var hidden: [String: Hide]
    /// The time of the import from EmojiFinder (D6). An import happens one time only.
    public var imported: Date?

    public init(uses: [String: Use] = [:], learned: Learned = [:], added: [String: [String]] = [:],
                hidden: [String: Hide] = [:], imported: Date? = nil) {
        self.uses = uses
        self.learned = learned
        self.added = added
        self.hidden = hidden
        self.imported = imported
    }

    /// A field that is missing gives an empty value, so an older file still loads.
    /// An unknown field is ignored: an older file with `tones` (D9, removed by D17) still loads.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uses = try values.decodeIfPresent([String: Use].self, forKey: .uses) ?? [:]
        learned = try values.decodeIfPresent(Learned.self, forKey: .learned) ?? [:]
        added = try values.decodeIfPresent([String: [String]].self, forKey: .added) ?? [:]
        hidden = try values.decodeIfPresent([String: Hide].self, forKey: .hidden) ?? [:]
        imported = try values.decodeIfPresent(Date.self, forKey: .imported)
    }

    /// The number of learned pairs (one search text and one emoji).
    public var learnedPairs: Int { learned.values.reduce(0) { $0 + $1.count } }

    /// True if the emoji with this key is hidden from "Your most used" now.
    public func isHidden(_ key: String) -> Bool { hidden[key]?.on == true }

    /// The key of an emoji in `you.json`: the emoji without U+FE0F and without a skin tone mark.
    /// The sources and EmojiFinder do not agree on U+FE0F. The store, the search and the import
    /// all use this one helper.
    public static func key(_ emoji: String) -> String {
        String(String.UnicodeScalarView(emoji.unicodeScalars.filter { scalar in
            scalar.value != 0xFE0F && !(0x1F3FB...0x1F3FF).contains(scalar.value)
        }))
    }
}

/// Keeps `You` in `you.json` (D4). Each change saves the file at once.
/// The path is a parameter, so a test gives a temp folder and never touches the real file.
public final class YouStore {
    /// At most this many learned pairs. A pick past it drops the pair with the lowest count, then the oldest.
    public static let learnedLimit = 5_000

    /// `~/Library/Application Support/Yaseen Emoji/you.json`. Tests never use it.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yaseen Emoji", isDirectory: true)
            .appendingPathComponent("you.json")
    }

    public let url: URL
    public private(set) var you = You()
    /// The last error of a save, or nil. The app keeps the data in memory and tries again at the next change.
    public private(set) var saveError: Error?
    /// The file that `load()` moved away because it was bad, or nil.
    public private(set) var movedBadFile: URL?

    /// True when a bad file could not move away. Then the store never writes over it.
    private var saveIsBlocked = false
    private let now: () -> Date

    /// `now` is a parameter, so a test can give each change its own time.
    public init(url: URL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    /// Reads the file. No file gives an empty `You`. A file that cannot be read becomes
    /// `you.bad.json` (or `you.bad-2.json` and on), and the store starts empty.
    /// It never deletes your history in silence.
    public func load() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            you = You()
            return
        }
        do {
            you = try YouStore.decoder.decode(You.self, from: Data(contentsOf: url))
        } catch {
            let bad = YouStore.freeBadURL(next: url)
            do {
                try fileManager.moveItem(at: url, to: bad)
                movedBadFile = bad
            } catch {
                // The bad file stays in place. A save must not write over it.
                saveError = error
                saveIsBlocked = true
            }
            you = You()
        }
    }

    /// One pick: one more use of the emoji, and the search text learns the emoji.
    /// An empty search learns no word. It still counts a use.
    public func recordPick(_ emoji: String, query: String) {
        let key = You.key(emoji)
        guard !key.isEmpty else { return }
        let time = now()
        you.uses[key, default: You.Use(count: 0, last: time)].count += 1
        you.uses[key]?.last = time

        let text = Search.normalize(query)
        // A pasted emoji is not a word.
        if !text.isEmpty && You.key(text) != key {
            you.learned[text, default: [:]][key, default: You.Use(count: 0, last: time)].count += 1
            you.learned[text]?[key]?.last = time
            YouStore.dropPastLimit(&you, limit: YouStore.learnedLimit, keeping: (text, key))
        }
        save()
    }

    /// Adds a word by hand. The search finds it at once.
    public func addWord(_ word: String, to emoji: String) {
        let clean = Search.normalize(word)
        let key = You.key(emoji)
        guard !clean.isEmpty, !key.isEmpty else { return }
        var words = you.added[key] ?? []
        guard !words.contains(clean) else { return }
        words.append(clean)
        you.added[key] = words
        save()
    }

    /// The right-click "Hide from Your most used" (D15). The uses and the learned words stay,
    /// so the search ranks the emoji the same as before.
    public func hide(_ emoji: String) {
        let key = You.key(emoji)
        guard !key.isEmpty else { return }
        you.hidden[key] = You.Hide(on: true, at: now())
        save()
    }

    /// Settings → "Show them again" (D15). Each entry stays, with `on` false and the time of now,
    /// so a later sync knows that this change is newer than the hide.
    public func showHidden() {
        guard !you.hidden.isEmpty else { return }
        let time = now()
        for key in you.hidden.keys { you.hidden[key] = You.Hide(on: false, at: time) }
        save()
    }

    /// The number of emojis hidden from "Your most used" now.
    public var hiddenCount: Int { you.hidden.values.filter(\.on).count }

    /// Settings → "Forget learned words": clears `learned` and `added`. It keeps `uses` and `hidden`.
    public func forgetWords() {
        you.learned = [:]
        you.added = [:]
        save()
    }

    /// Puts a new `You` in place and saves it. The import uses it.
    func replace(with new: You) {
        you = new
        save()
    }

    /// Writes the file atomically: a new file, then a swap. A crash never leaves half a file.
    @discardableResult
    func save() -> Bool {
        guard !saveIsBlocked else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try YouStore.encoder.encode(you).write(to: url, options: .atomic)
            saveError = nil
            return true
        } catch {
            saveError = error
            return false
        }
    }

    /// Drops pairs until at most `limit` are left: the lowest count first, then the oldest (D4).
    /// It never drops `keeping`, the pair of the pick that happens now. A new pair has the count 1.
    /// Without this, a full list of pairs with a count of 2 or more would drop each new word at once.
    static func dropPastLimit(_ you: inout You, limit: Int, keeping: (text: String, key: String)) {
        var extra = you.learnedPairs - limit
        guard extra > 0 else { return }
        let pairs = you.learned.flatMap { text, emojis in emojis.map { (text: text, key: $0.key, use: $0.value) } }
            .sorted { a, b in
                if a.use.count != b.use.count { return a.use.count < b.use.count }
                if a.use.last != b.use.last { return a.use.last < b.use.last }
                return (a.text, a.key) < (b.text, b.key)
            }
        for pair in pairs where extra > 0 && (pair.text, pair.key) != keeping {
            you.learned[pair.text]?[pair.key] = nil
            if you.learned[pair.text]?.isEmpty == true { you.learned[pair.text] = nil }
            extra -= 1
        }
    }

    /// `you.bad.json` next to the file, or `you.bad-2.json` and on if that name is in use.
    static func freeBadURL(next url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var number = 1
        while true {
            let name = number == 1 ? "\(base).bad.json" : "\(base).bad-\(number).json"
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    // MARK: The file format

    /// Dates are ISO 8601 text with milliseconds, so a person can read the file.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: dateStyle) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return decoder
    }()

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
