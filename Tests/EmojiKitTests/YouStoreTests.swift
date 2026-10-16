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
        store.hide("🤣")

        let you = store.you
        #expect(you.uses["🤣"]?.count == 2)
        #expect(you.uses["👍"]?.count == 1)
        #expect(you.uses[You.key("❤️")]?.count == 1)
        #expect(you.learned["lol"]?["🤣"]?.count == 2)
        #expect(you.learned["love"]?[You.key("❤️")]?.count == 1)
        #expect(you.learnedPairs == 2)
        #expect(you.added["🚀"] == ["big win"])
        #expect(you.hidden["🤣"]?.on == true)
        #expect(store.saveError == nil)

        // A new start of the app reads the same data.
        let again = YouStore(url: folder.youFile)
        again.load()
        #expect(again.you == you)
    }

    @Test func forgetWordsKeepsTheUsesAndTheHiddenEmojis() throws {
        let folder = try TempFolder()
        let store = YouStore(url: folder.youFile, now: StepClock().now)
        store.recordPick("💪", query: "strong")
        store.addWord("gym", to: "💪")
        store.hide("💪")

        store.forgetWords()
        #expect(store.you.learned.isEmpty)
        #expect(store.you.added.isEmpty)
        #expect(store.you.uses["💪"]?.count == 1)
        #expect(store.hiddenCount == 1)

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

    /// D15: a hidden emoji leaves "Your most used" only. The list still has 36. Its uses and its
    /// learned word stay, so its word still puts it first. "Show them again" brings it back.
    @Test func aHiddenEmojiLeavesYourMostUsedOnly() throws {
        let folder = try TempFolder()
        let clock = StepClock()
        let store = YouStore(url: folder.youFile, now: clock.now)
        let catalog = Catalog.all
        // 40 used emojis: the first has the most uses, and the learned word "lol".
        var you = You()
        for (place, emoji) in catalog.prefix(40).enumerated() {
            you.uses[emoji.key] = You.Use(count: 40 - place, last: clock.now())
        }
        store.replace(with: you)
        let top = catalog[0]
        store.recordPick(top.text, query: "lol")
        #expect(Search.mostUsed(in: catalog, you: store.you).first == top)

        store.hide(top.text)
        // A use after the hide does not bring it back.
        store.recordPick(top.text, query: "")
        let most = Search.mostUsed(in: catalog, you: store.you)
        #expect(most.count == 36)
        #expect(!most.contains(top))
        #expect(most.first == catalog[1] && most.last == catalog[36])
        #expect(store.hiddenCount == 1)
        #expect(store.you.uses[top.key]?.count == 42)
        #expect(Search.results(for: "lol", in: catalog, you: store.you).first == top)

        // The hide is in the file.
        let again = YouStore(url: folder.youFile)
        again.load()
        #expect(again.you == store.you)

        store.showHidden()
        #expect(store.hiddenCount == 0)
        #expect(Search.mostUsed(in: catalog, you: store.you).first == top)
        // The entry stays with `on` false and the time of the change, for a later sync.
        let entry = try #require(store.you.hidden[top.key])
        #expect(!entry.on && entry.at > again.you.hidden[top.key]!.at)
    }

    /// A file in the shape of the real `you.json` before D15 and D17: no `hidden`, and a `tones` key.
    /// It loads with the same uses, words and import time. The next save has no `tones`.
    @Test func anOldFileWithTonesAndNoHiddenLoads() throws {
        let folder = try TempFolder()
        try FileManager.default.createDirectory(at: folder.youFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = """
        {
          "added" : { "🚀" : [ "blastoff" ] },
          "imported" : "2026-10-16T10:00:00.000Z",
          "learned" : { "lol" : { "🤣" : { "count" : 2, "last" : "2026-10-16T11:00:00.000Z" } } },
          "tones" : { "👍" : "👍🏽" },
          "uses" : { "🤣" : { "count" : 358, "last" : "2026-10-16T11:00:00.000Z" } }
        }
        """
        try Data(old.utf8).write(to: folder.youFile)
        let store = YouStore(url: folder.youFile)
        store.load()
        #expect(store.movedBadFile == nil)
        #expect(store.you.uses["🤣"]?.count == 358)
        #expect(store.you.learned["lol"]?["🤣"]?.count == 2)
        #expect(store.you.added["🚀"] == ["blastoff"])
        #expect(store.you.imported == Date(timeIntervalSince1970: 1_792_144_800))
        #expect(store.you.hidden.isEmpty)

        store.hide("🤣")
        let text = try String(contentsOf: folder.youFile, encoding: .utf8)
        #expect(!text.contains("tones") && text.contains("hidden"))
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
