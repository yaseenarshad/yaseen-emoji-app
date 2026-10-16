import Foundation
import Testing
@testable import EmojiKit

/// Your history in `you.json` (YAZ-2898, D4 and D6). Each test has its own temp folder
/// and sample data. No test reads the real `you.json` or the EmojiFinder database.
@Suite struct YouStoreTests {
    @Test func aPickIsSavedAndComesBackTheSame() throws {
        let folder = try TempFolder()
        let clock = StepClock()
        let store = YouStore(url: folder.youFile, now: clock.now)
        store.load()
        #expect(store.you == You())

        store.recordPick("🤣", query: "  LOL ")
        store.recordPick("🤣", query: "lol")
        store.recordPick("👍🏽", query: "")            // a tone form counts as 👍 (D9); no search, no word
        store.recordPick("❤", query: "love")          // "❤" and "❤️" are one emoji
        store.addWord("Big Win", to: "🚀")
        store.addWord("big win", to: "🚀")            // a copy is not added
        store.setTone("👍🏽", for: "👍")

        let you = store.you
        #expect(you.uses["🤣"]?.count == 2)
        #expect(you.uses["👍"]?.count == 1)
        #expect(you.uses[You.key("❤️")]?.count == 1)
        #expect(you.learned["lol"]?["🤣"]?.count == 2)
        #expect(you.learned["love"]?[You.key("❤️")]?.count == 1)
        #expect(you.learnedPairs == 2)
        #expect(you.added["🚀"] == ["big win"])
        #expect(you.tones["👍"] == "👍🏽")
        #expect(store.saveError == nil)

        // A new start of the app reads the same data.
        let again = YouStore(url: folder.youFile)
        again.load()
        #expect(again.you == you)

        store.setTone(nil, for: "👍🏽")
        #expect(store.you.tones.isEmpty)
    }

    @Test func forgetWordsKeepsTheUsesAndTheTones() throws {
        let folder = try TempFolder()
        let store = YouStore(url: folder.youFile, now: StepClock().now)
        store.recordPick("💪", query: "strong")
        store.addWord("gym", to: "💪")
        store.setTone("💪🏾", for: "💪")

        store.forgetWords()
        #expect(store.you.learned.isEmpty)
        #expect(store.you.added.isEmpty)
        #expect(store.you.uses["💪"]?.count == 1)
        #expect(store.you.tones["💪"] == "💪🏾")

        let again = YouStore(url: folder.youFile)
        again.load()
        #expect(again.you == store.you)
    }

    /// At most 5,000 learned pairs. One more drops the pair with the lowest count, then the oldest.
    @Test func theLearnedLimitDropsTheCorrectPair() throws {
        let folder = try TempFolder()
        let old = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        // 5,000 pairs on disk: most have the count 2, two have the count 1.
        var you = You()
        for number in 0..<4_998 {
            you.learned["word \(number)"] = ["🙂": You.Use(count: 2, last: old)]
        }
        you.learned["oldest one"] = ["🙃": You.Use(count: 1, last: old)]
        you.learned["newer one"] = ["🙃": You.Use(count: 1, last: newer)]
        you.learned["word 7"]?["😎"] = You.Use(count: 1, last: old.addingTimeInterval(-1))   // the oldest of count 1
        you.learned["word 8"] = nil
        #expect(you.learnedPairs == YouStore.learnedLimit)
        try FileManager.default.createDirectory(at: folder.youFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try YouStore.encoder.encode(you).write(to: folder.youFile)

        let store = YouStore(url: folder.youFile, now: { Date(timeIntervalSince1970: 3_000) })
        store.load()
        #expect(store.you.learnedPairs == 5_000)

        store.recordPick("🚀", query: "ship it")
        #expect(store.you.learnedPairs == 5_000)
        #expect(store.you.learned["word 7"]?["😎"] == nil)       // dropped: count 1 and the oldest
        #expect(store.you.learned["word 7"]?["🙂"]?.count == 2)  // the other emoji of the word stays
        #expect(store.you.learned["oldest one"] != nil)
        #expect(store.you.learned["ship it"]?["🚀"]?.count == 1)

        store.recordPick("🚀", query: "ship")
        #expect(store.you.learned["oldest one"] == nil)          // next: count 1, the oldest
        #expect(store.you.learned["newer one"] != nil)
        #expect(store.you.learnedPairs == 5_000)
    }

    /// Each pair has the count 2. A new word has the count 1, but it is the pick of now, so it stays.
    /// Without this, the app could never learn a new word again.
    @Test func theLearnedLimitKeepsTheNewWord() throws {
        let folder = try TempFolder()
        var you = You()
        for number in 0..<YouStore.learnedLimit {
            you.learned["word \(number)"] = ["🙂": You.Use(count: 2, last: Date(timeIntervalSince1970: Double(1_000 + number)))]
        }
        try FileManager.default.createDirectory(at: folder.youFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try YouStore.encoder.encode(you).write(to: folder.youFile)

        let store = YouStore(url: folder.youFile, now: { Date(timeIntervalSince1970: 9_000) })
        store.load()
        store.recordPick("🚀", query: "brand new")
        #expect(store.you.learned["brand new"]?["🚀"]?.count == 1)
        #expect(store.you.learned["word 0"] == nil)               // the oldest of the lowest count
        #expect(store.you.learned["word 1"] != nil)
        #expect(store.you.learnedPairs == YouStore.learnedLimit)
    }

    @Test func aBadFileBecomesYouBadJson() throws {
        let folder = try TempFolder()
        let dir = folder.youFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Each row: what is in `you.json`, and the name that the bad file gets.
        let table: [(content: String, badName: String)] = [
            ("{ this is not json", "you.bad.json"),
            ("", "you.bad-2.json"),                                   // the first name is in use
            ("{\"uses\": {\"🤣\": {\"count\": \"many\"}}}", "you.bad-3.json"),
        ]
        for row in table {
            try Data(row.content.utf8).write(to: folder.youFile)
            let store = YouStore(url: folder.youFile)
            store.load()
            #expect(store.you == You())
            #expect(store.movedBadFile?.lastPathComponent == row.badName)
            #expect(try String(contentsOf: dir.appendingPathComponent(row.badName), encoding: .utf8) == row.content)
            #expect(!FileManager.default.fileExists(atPath: folder.youFile.path))
        }

        // The next change writes a new, good file. The bad files stay.
        let store = YouStore(url: folder.youFile)
        store.load()
        store.recordPick("🔥", query: "fire")
        #expect(folder.names(in: dir) == ["you.bad-2.json", "you.bad-3.json", "you.bad.json", "you.json"])
    }

    @Test func anOlderFileWithMissingFieldsStillLoads() throws {
        let folder = try TempFolder()
        try FileManager.default.createDirectory(at: folder.youFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"uses": {"🤣": {"count": 3, "last": "2026-10-16T10:00:00Z"}}}"#.utf8).write(to: folder.youFile)
        let store = YouStore(url: folder.youFile)
        store.load()
        #expect(store.you.uses["🤣"]?.count == 3)
        #expect(store.movedBadFile == nil)
    }

    // MARK: The import from EmojiFinder (D6)

    @Test func theImportGivesTheCorrectCounts() throws {
        let folder = try TempFolder()
        // A sample in the shape of `sqlite3 -json`. Not the real EmojiFinder data.
        let sample = """
        [{"emoji": "🤣", "count": 358}, {"emoji": "🙌", "count": 356},
         {"emoji": "❤", "count": 40}, {"emoji": "❤️", "count": 2},
         {"emoji": "👍🏽", "count": 5}, {"emoji": "👍", "count": 1}]
        """
        let summary = try YouImport.run(Data(sample.utf8), into: folder.youFile)
        #expect(summary == YouImport.Summary(emojis: 4, picks: 762, changed: true))
        #expect(summary.line == "Imported 762 picks of 4 emojis from EmojiFinder.")

        let store = YouStore(url: folder.youFile)
        store.load()
        let counts = store.you.uses.mapValues(\.count)
        #expect(counts == ["🤣": 358, "🙌": 356, "\u{2764}": 42, "👍": 6])
        #expect(Search.mostUsed(in: Catalog.all, you: store.you).map(\.text) == ["🤣", "🙌", "❤️", "👍"])

        // A second run changes nothing, so no pick counts two times.
        let again = try YouImport.run(Data(sample.utf8), into: folder.youFile)
        #expect(again.changed == false)
        let after = YouStore(url: folder.youFile)
        after.load()
        #expect(after.you == store.you)
    }

    @Test func theImportAddsToUsesThatAreAlreadyThere() throws {
        let folder = try TempFolder()
        let store = YouStore(url: folder.youFile)
        store.recordPick("🤣", query: "lol")
        _ = try YouImport.run(Data(#"[{"emoji": "🤣", "count": 10}]"#.utf8), into: folder.youFile)
        store.load()
        #expect(store.you.uses["🤣"]?.count == 11)
        #expect(store.you.learned["lol"]?["🤣"]?.count == 1)
    }

    @Test func theImportOfEmptyOrBadInput() throws {
        let folder = try TempFolder()
        // `sqlite3 -json` prints nothing for an empty table. No file is written.
        for empty in ["", "\n", "[]"] {
            let summary = try YouImport.run(Data(empty.utf8), into: folder.youFile)
            #expect(summary.changed == false)
            #expect(!FileManager.default.fileExists(atPath: folder.youFile.path))
        }
        // Bad input throws, and the file does not change.
        let bad = [
            "not json",
            #"{"emoji": "🤣", "count": 3}"#,
            #"[{"emoji": "🤣"}]"#,
            #"[{"emoji": "🤣", "count": "3"}]"#,
            #"[{"emoji": "🤣", "count": -1}]"#,
            #"[{"emoji": "", "count": 1}]"#,
        ]
        for input in bad {
            #expect(throws: YouImport.BadInput.self, "\(input)") {
                try YouImport.run(Data(input.utf8), into: folder.youFile)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.youFile.path))
    }

    @Test func theDefaultFileIsInApplicationSupport() {
        #expect(YouStore.defaultURL.path.hasSuffix("/Library/Application Support/Yaseen Emoji/you.json"))
    }
}
