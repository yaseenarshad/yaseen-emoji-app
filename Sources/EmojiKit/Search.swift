import Foundation

/// The search of the panel (D5 on YAZ-2894). A full scan of the catalog for each key press, with no index.
/// The catalog has 1,914 emojis and about 19,000 words. The budget is 2 ms in a release build.
/// GIFs and memes use the same match and the same order (`Searchable`, D11 of YAZ-2919).
public enum Search {
    /// How well an emoji matches the search, best first.
    public enum Match: Int, Comparable, Sendable {
        /// You picked this emoji for this exact search text before (D4).
        case learned
        /// One of its words, or its name, is the search text.
        case exact
        /// One of its words starts with the search text.
        case prefix
        /// Its name contains the search text.
        case inName

        public static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
    }

    /// One emoji that matches, with the facts that `rank` sorts by.
    /// It has no `Emoji` value, so the sort moves only small values.
    public struct Candidate: Sendable {
        /// The place of the emoji in the catalog that the search got.
        public let index: Int
        /// `Emoji.order`: the place in the Unicode order.
        public let order: Int
        public let match: Match
        /// True if the full search text gave the match, as one search word.
        /// False if the match comes from the single words of the search.
        public let isWholeText: Bool
        /// True if the name of the emoji is the search text: "rocket" for 🚀.
        public let isName: Bool
        /// Your picks of this emoji (`You.uses`).
        public let uses: Int
    }

    /// The search text: trimmed, in lower case, with one space between words.
    /// The store learns this text, so a search and a pick always agree.
    public static func normalize(_ query: String) -> String {
        query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The emojis for a search, best first. An empty search gives no results:
    /// the panel then shows `mostUsed`. A typed or pasted emoji comes first.
    public static func results(for query: String, in catalog: [Emoji], you: You) -> [Emoji] {
        ranked(for: query, in: catalog, you: you)
    }

    /// The search of emojis and of GIFs and memes (D11 of YAZ-2919): the same match and the same order.
    /// An entry whose key is the typed text comes first: a typed or pasted emoji.
    static func ranked<Entry: Searchable>(for query: String, in catalog: [Entry], you: You) -> [Entry] {
        let text = normalize(query)
        guard !text.isEmpty else { return [] }
        let textBytes = Array(text.utf8)
        let terms = text.split(separator: " ").map { Array($0.utf8) }
        let typedKey = You.key(text)
        let learned = you.learned[text] ?? [:]
        let added = you.added.mapValues { words in words.map { Array($0.utf8) } }

        var typed: [Entry] = []
        var candidates: [Candidate] = []
        for (index, entry) in catalog.enumerated() {
            if entry.key == typedKey {
                typed.append(entry)
                continue
            }
            let found: (match: Match, isWholeText: Bool)?
            if !learned.isEmpty && learned[entry.key] != nil {
                found = (.learned, true)
            } else {
                let addedWords = added.isEmpty ? [] : added[entry.key] ?? []
                found = match(text: textBytes, terms: terms, entry: entry, added: addedWords)
            }
            if let found {
                let uses = you.uses.isEmpty ? 0 : you.uses[entry.key]?.count ?? 0
                candidates.append(Candidate(index: index, order: entry.order, match: found.match,
                                            isWholeText: found.isWholeText,
                                            isName: found.match == .exact && normalize(entry.name) == text,
                                            uses: uses))
            }
        }
        candidates.sort(by: rank)
        return typed + candidates.map { catalog[$0.index] }
    }

    /// The order of the results (D5). Yaseen may change this rule later
    /// (Decision D5 on https://linear.app/growprofit/issue/YAZ-2894/main-scoping-agent-working-log).
    /// A change of the order must touch only this function and the table in `SearchTests`.
    /// Today: the better match first. Same match: the emoji whose name is the search text, so
    /// "rocket" gives 🚀 before 🧑‍🚀 (which has the word "rocket"). Then the full search text before
    /// single words, so "red heart" gives ❤️ before ❣️ (the words "red" and "heart"). Then more uses
    /// first. Same uses: Unicode order. A learned word beats all of these, so one pick changes it.
    public static func rank(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.match != b.match { return a.match < b.match }
        if a.isName != b.isName { return a.isName }
        if a.isWholeText != b.isWholeText { return a.isWholeText }
        if a.uses != b.uses { return a.uses > b.uses }
        return a.order < b.order
    }

    /// The match of one emoji, or nil. The full text first, so "red heart" is an exact match of the
    /// name of ❤️. With two or more words, each word must match, and the weakest word gives the match.
    /// Added words count the same as the words of the list.
    /// `isWholeText` is true when the full text gives the match.
    static func match(text: String, terms: [String], emoji: Emoji, added: [String]) -> (match: Match, isWholeText: Bool)? {
        match(text: Array(text.utf8), terms: terms.map { Array($0.utf8) }, entry: emoji,
              added: added.map { Array($0.utf8) })
    }

    private static func match<Entry: Searchable>(
        text: [UInt8], terms: [[UInt8]], entry: Entry, added: [[UInt8]]
    ) -> (match: Match, isWholeText: Bool)? {
        let whole = match(term: text, entry: entry, added: added)
        guard terms.count > 1, whole != .exact else { return whole.map { ($0, true) } }
        var weakest = Match.learned
        for term in terms {
            guard let match = match(term: term, entry: entry, added: added) else { return whole.map { ($0, true) } }
            weakest = max(weakest, match)
        }
        if let whole, whole <= weakest { return (whole, true) }
        return (weakest, false)
    }

    /// The best match of one search word, on UTF-8 bytes. Both sides are in lower case.
    private static func match<Entry: Searchable>(term: [UInt8], entry: Entry, added: [[UInt8]]) -> Match? {
        term.withUnsafeBufferPointer { term in
            if same(entry.nameBytes, term) { return .exact }
            var best: Match?
            for word in entry.wordBytes {
                if same(word, term) { return .exact }
                if best == nil && hasPrefix(word, term) { best = .prefix }
            }
            for word in added {
                if same(word, term) { return .exact }
                if best == nil && hasPrefix(word, term) { best = .prefix }
            }
            if best == nil && contains(entry.nameBytes, term) { best = .inName }
            return best
        }
    }

    // `memcmp` and `memmem` compare the bytes. They are fast in a debug build too, so `swift test` stays fast.

    private static func same(_ bytes: [UInt8], _ term: UnsafeBufferPointer<UInt8>) -> Bool {
        bytes.count == term.count && hasPrefix(bytes, term)
    }

    private static func hasPrefix(_ bytes: [UInt8], _ term: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count >= term.count else { return false }
        guard let termStart = term.baseAddress, term.count > 0 else { return true }
        return bytes.withUnsafeBufferPointer { memcmp($0.baseAddress!, termStart, term.count) == 0 }
    }

    private static func contains(_ bytes: [UInt8], _ term: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count >= term.count else { return false }
        guard let termStart = term.baseAddress, term.count > 0 else { return true }
        return bytes.withUnsafeBufferPointer { memmem($0.baseAddress!, $0.count, termStart, term.count) != nil }
    }

    /// "Your most used": the emojis with the most uses, then the last use first, then Unicode order.
    /// A hidden emoji is not in it (D15), and the next emoji takes its place, so the list stays full.
    public static func mostUsed(in catalog: [Emoji], you: You, limit: Int = 36) -> [Emoji] {
        mostUsed(of: catalog, you: you, limit: limit)
    }

    /// "Your most used" of emojis, and of GIFs and memes (D11 of YAZ-2919): the same rule. For an item,
    /// `order` is newest first.
    static func mostUsed<Entry: Searchable>(of catalog: [Entry], you: You, limit: Int) -> [Entry] {
        let used = catalog.compactMap { entry in
            you.isHidden(entry.key) ? nil : you.uses[entry.key].map { (entry: entry, use: $0) }
        }
        let sorted = used.sorted { a, b in
            if a.use.count != b.use.count { return a.use.count > b.use.count }
            if a.use.last != b.use.last { return a.use.last > b.use.last }
            return a.entry.order < b.entry.order
        }
        return sorted.prefix(max(0, limit)).map(\.entry)
    }
}

/// One thing that the search can find (D5 on YAZ-2894, D11 of YAZ-2919): an emoji, or a GIF or meme of the grid.
/// The search compares UTF-8 bytes in lower case.
protocol Searchable {
    /// The key in `you-<Mac>.json`: the uses, the learned words and the added words.
    var key: String { get }
    /// The name. An item has no name ("").
    var name: String { get }
    var nameBytes: [UInt8] { get }
    var wordBytes: [[UInt8]] { get }
    /// The last rule of the order: Unicode order for an emoji, newest first for an item.
    var order: Int { get }
}

extension Emoji: Searchable {}
