import Foundation
import Testing
@testable import EmojiKit

/// The search and its order (YAZ-2897, D5). Yaseen may change the order later.
/// A change of `Search.rank` shows here as a row that moves.
@Suite struct SearchTests {
    /// One search on the full catalog with an empty history, and what the results must show.
    struct Row: CustomStringConvertible {
        let query: String
        /// The first result, or nil for no rule.
        var first: String?
        /// Emojis that must be in the results.
        var has: [String] = []
        /// Pairs: the first emoji comes before the second one.
        var before: [(String, String)] = []
        /// True if the search must give no results.
        var empty = false

        var description: String { "\"\(query)\"" }
    }

    static let table: [Row] = [
        Row(query: "lol", has: ["🤣", "😂"], before: [("🤣", "🍭"), ("😂", "🍭")]),
        Row(query: "haha", has: ["🤣"]),
        Row(query: "praise", has: ["🙌"]),
        Row(query: "strong", has: ["💪"]),
        Row(query: "launch", first: "🚀"),
        Row(query: "rocket", first: "🚀"),       // its name, before 🧑‍🚀 with the word "rocket"
        Row(query: "fire", first: "🔥"),
        Row(query: "ship", first: "🚢"),
        Row(query: "red heart", first: "❤️"),
        Row(query: "thumbs up", first: "👍"),
        Row(query: "fingerprint", first: "🫆"),
        Row(query: "👍🏽", first: "👍"),          // a pasted emoji comes first, as its base emoji
        Row(query: "❤", first: "❤️"),            // without U+FE0F
        Row(query: "zzqqxx", empty: true),
        Row(query: "", empty: true),             // the panel shows `mostUsed` instead
        Row(query: "   ", empty: true),
    ]

    @Test(arguments: table)
    func aSearchOnTheFullCatalog(_ row: Row) throws {
        let results = Search.results(for: row.query, in: Catalog.all, you: You()).map(\.text)
        if row.empty { #expect(results.isEmpty) }
        if let first = row.first { #expect(results.first == first, "\(results.prefix(5))") }
        for emoji in row.has { #expect(results.contains(emoji), "\(emoji) is not in \(results.prefix(10))") }
        for (a, b) in row.before {
            let aPlace = try #require(results.firstIndex(of: a), "\(a) is missing")
            let bPlace = try #require(results.firstIndex(of: b), "\(b) is missing")
            #expect(aPlace < bPlace, "\(a) must come before \(b)")
        }
    }

    @Test func caseAndSpacesDoNotChangeTheResults() {
        let lol = Search.results(for: "lol", in: Catalog.all, you: You())
        #expect(!lol.isEmpty)
        #expect(Search.results(for: "LOL ", in: Catalog.all, you: You()) == lol)
        #expect(Search.results(for: "  Red   HEART", in: Catalog.all, you: You())
            == Search.results(for: "red heart", in: Catalog.all, you: You()))
    }

    // MARK: The order, on a small catalog

    /// Four emojis in Unicode order. Each has the word "sun" in a different way.
    let small = [
        Emoji(text: "🌞", name: "sun with face", group: 4, order: 0, words: ["sunny", "bright"]),
        Emoji(text: "☀️", name: "sun", group: 4, order: 1, words: ["weather"]),
        Emoji(text: "🌻", name: "sunflower", group: 2, order: 2, words: ["sun", "flower"]),
        Emoji(text: "🏝️", name: "desert island", group: 4, order: 3, words: ["sun", "beach"]),
        Emoji(text: "🧴", name: "lotion bottle", group: 6, order: 4, words: ["sunscreen"]),
    ]

    func order(_ query: String, _ you: You = You()) -> [String] {
        Search.results(for: query, in: small, you: you).map(\.text)
    }

    func used(_ counts: [String: Int]) -> You {
        var you = You()
        for (emoji, count) in counts {
            you.uses[You.key(emoji)] = You.Use(count: count, last: Date(timeIntervalSince1970: 0))
        }
        return you
    }

    @Test func theOrderOfTheMatchKinds() {
        // Exact (name or word) → prefix of a word → in the name. Same kind: Unicode order.
        #expect(order("sun") == ["☀️", "🌻", "🏝️", "🌞", "🧴"])
        func kind(_ text: String, _ emoji: Emoji) -> Search.Match? {
            Search.match(text: text, terms: text.split(separator: " ").map(String.init), emoji: emoji, added: [])?.match
        }
        #expect(kind("sun", small[1]) == .exact)       // the name
        #expect(kind("sun", small[2]) == .exact)       // a word
        #expect(kind("sun", small[0]) == .prefix)      // "sunny"
        #expect(kind("with", small[0]) == .inName)
        #expect(kind("moon", small[0]) == nil)
    }

    @Test func moreUsesWinsBetweenTwoExactMatches() {
        // ☀️ has the name "sun", so it stays first. The uses order the other exact matches.
        #expect(order("sun", used(["🏝️": 3, "🌻": 1])) == ["☀️", "🏝️", "🌻", "🌞", "🧴"])
        // Uses never lift a weaker match over a better one.
        #expect(order("sun", used(["🧴": 99])).first == "☀️")
    }

    @Test func aLearnedWordBeatsAnExactWord() {
        var you = You()
        you.learned["sun"] = [You.key("🧴"): You.Use(count: 1, last: Date(timeIntervalSince1970: 0))]
        #expect(order("sun", you).first == "🧴")
        // Learned is for the full search text only.
        #expect(order("su", you).first == "🌞")
    }

    @Test func anAddedWordCountsTheSameAsAListWord() {
        var you = You()
        you.added[You.key("🧴")] = ["beach day"]
        #expect(order("beach", you) == ["🏝️", "🧴"])        // exact, then prefix
        #expect(order("beach day", you) == ["🧴"])          // 🏝️ has no "day"
    }

    @Test func eachWordMustMatchAndTheWeakestWordCounts() {
        #expect(order("sun flower") == ["🌻"])
        // "desert": in the name only. "sun": exact. The weakest is "in the name".
        #expect(order("sun desert") == ["🏝️"])
        #expect(order("sun desert", used(["🏝️": 5])) == ["🏝️"])
        #expect(order("sun moon").isEmpty)
    }

    /// "red heart": ❤️ has the name, ❣️ has the two words. Both are exact, and ❣️ is first in Unicode order.
    @Test func theFullTextWinsATieOverSingleWords() {
        let hearts = [
            Emoji(text: "❣️", name: "heart exclamation", group: 0, order: 0, words: ["heart", "red"]),
            Emoji(text: "❤️", name: "red heart", group: 0, order: 1, words: ["love"]),
        ]
        var you = You()
        you.uses[You.key("❣️")] = You.Use(count: 9, last: Date(timeIntervalSince1970: 0))
        #expect(Search.results(for: "red heart", in: hearts, you: You()).map(\.text) == ["❤️", "❣️"])
        #expect(Search.results(for: "red heart", in: hearts, you: you).map(\.text) == ["❤️", "❣️"])
        // Single words only: the uses decide.
        #expect(Search.results(for: "heart red", in: hearts, you: you).map(\.text) == ["❣️", "❤️"])
    }

    // MARK: Your most used

    @Test func mostUsedIsByUsesThenTheLastTime() {
        var you = You()
        you.uses = [
            You.key("🌻"): You.Use(count: 2, last: Date(timeIntervalSince1970: 10)),
            You.key("🧴"): You.Use(count: 2, last: Date(timeIntervalSince1970: 20)),
            You.key("☀️"): You.Use(count: 7, last: Date(timeIntervalSince1970: 1)),
            "not in the catalog": You.Use(count: 50, last: Date(timeIntervalSince1970: 1)),
        ]
        #expect(Search.mostUsed(in: small, you: you).map(\.text) == ["☀️", "🧴", "🌻"])
        #expect(Search.mostUsed(in: small, you: you, limit: 1).map(\.text) == ["☀️"])
        #expect(Search.mostUsed(in: small, you: You()).isEmpty)
    }

    // MARK: Time

    /// The budget is 2 ms for each search in a release build (D5). The number goes into the Result comment.
    /// The bound here is generous, so a slow CI computer does not fail.
    @Test func theTimeOfOneSearchOnTheFullCatalog() {
        var you = You()
        for emoji in Catalog.all.prefix(260) {
            you.uses[emoji.key] = You.Use(count: emoji.order % 40 + 1, last: Date(timeIntervalSince1970: 0))
        }
        let queries = ["l", "lo", "lol", "heart", "red heart", "s", "smiling face", "flag", "zzqqxx", "thumbs up"]
        var worst = 0.0
        var lines: [String] = []
        for query in queries {
            let time = medianMilliseconds(runs: 15) { _ = Search.results(for: query, in: Catalog.all, you: you) }
            worst = max(worst, time)
            lines.append("\(query): \(String(format: "%.3f", time))")
        }
        print("TIMING [\(buildKind)] search median ms on \(Catalog.all.count) emojis: \(lines.joined(separator: ", "))")
        #expect(worst < 100)
    }
}
