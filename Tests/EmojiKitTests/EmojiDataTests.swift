import CoreText
import Foundation
import Testing
@testable import EmojiKit

/// The catalog `emoji.json` (YAZ-2896, D3) and the draw check.
@Suite struct EmojiDataTests {
    @Test func theFileLoadsWithEachEmojiOfEmoji17() throws {
        let all = try EmojiCatalog.bundled()
        #expect(all.count > 1_900)
        #expect(all.map(\.order) == Array(all.indices))
        #expect(all.allSatisfy { EmojiCatalog.groupNames.indices.contains($0.group) })
        #expect(EmojiCatalog.groupNames.count == 9)
        #expect(all.first?.text == "😀")
        #expect(all.last.map { EmojiCatalog.groupNames[$0.group] } == "Flags")

        // Each emoji has a name and words. The words are in lower case, and the name is not a word.
        for emoji in all {
            #expect(!emoji.name.isEmpty && !emoji.words.isEmpty, "\(emoji.text)")
            #expect(emoji.words.allSatisfy { $0 == $0.lowercased() && !$0.contains("_") }, "\(emoji.text)")
            #expect(!emoji.words.contains(emoji.name.lowercased()), "\(emoji.text)")
            #expect(Set(emoji.words).count == emoji.words.count, "\(emoji.text)")
        }
    }

    @Test func theEmojisAndWordsOfTheIssue() throws {
        // Each row: the emoji, and words that it must have.
        let table: [(emoji: String, words: [String])] = [
            ("🫆", []),                 // fingerprint, Emoji 16: the old app does not have it
            ("🤣", ["lol", "haha"]),
            ("🙌", ["praise"]),
            ("🚀", ["launch"]),
            ("💪", ["strong"]),
        ]
        for row in table {
            let emoji = try #require(Catalog.emoji(row.emoji), "\(row.emoji) is missing")
            for word in row.words {
                #expect(emoji.words.contains(word), "\(row.emoji) has no \"\(word)\"")
            }
        }
        #expect(Catalog.emoji("🫆")?.name == "fingerprint")
    }

    @Test func skinToneForms() throws {
        let thumbsUp = try #require(Catalog.emoji("👍"))
        #expect(thumbsUp.takesTone)
        #expect(thumbsUp.toneForms == ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"])

        // Two people: the form is not the emoji plus one tone mark.
        let holdingHands = try #require(Catalog.emoji("🧑‍🤝‍🧑"))
        #expect(holdingHands.toneForms.first == "🧑🏻‍🤝‍🧑🏻")

        #expect(Catalog.emoji("😀")?.takesTone == false)
        #expect(Catalog.all.filter(\.takesTone).count == 330)
        #expect(Catalog.all.allSatisfy { $0.toneForms.isEmpty || $0.toneForms.count == 5 })
    }

    @Test func redHeartIsTheFullFormWithFE0F() throws {
        let heart = try #require(Catalog.all.first { $0.name == "red heart" })
        #expect(Array(heart.text.unicodeScalars.map(\.value)) == [0x2764, 0xFE0F])
        #expect(heart.key == "\u{2764}")
    }

    /// One key for each emoji, and each tone form has the key of its emoji (D9: uses count the base emoji).
    @Test func theKeyOfEachEmojiAndToneForm() {
        let keys = Catalog.all.map(\.key)
        #expect(Set(keys).count == Catalog.all.count)
        for emoji in Catalog.all {
            #expect(emoji.toneForms.allSatisfy { You.key($0) == emoji.key }, "\(emoji.text)")
        }
    }

    @Test func theDrawCheckHidesWhatTheFontCannotDraw() {
        func fake(_ text: String, order: Int) -> Emoji {
            Emoji(text: text, name: "test", group: 0, order: order, words: [])
        }
        let list = [
            fake("😀", order: 0),
            fake("😀😀", order: 1),             // two pictures
            fake("a", order: 2),                // not in the emoji font
            fake("\u{1FAFF}", order: 3),        // no emoji has this code point
            fake("👍🏽", order: 4),
            fake("🧑\u{200D}🦒", order: 5),     // a ZWJ form that Unicode does not have: two pictures
            fake("👩‍❤️‍👨", order: 6),              // two glyphs, but the first one has no width: one picture
        ]
        #expect(DrawCheck.drawable(list).map(\.order) == [0, 4, 6])
    }

    /// The numbers go into the Result comment. This Mac (macOS 26.6) draws each emoji of Emoji 17.
    @Test func timingsOfTheLoadAndTheDrawCheck() throws {
        guard let url = try? EmojiCatalog.bundledURL() else { Issue.record("no emoji.json"); return }
        var loaded: [Emoji] = []
        let load = try medianMilliseconds(runs: 9) { loaded = try EmojiCatalog.load(from: url) }

        let clock = ContinuousClock()
        let start = clock.now
        let drawable = DrawCheck.drawable(loaded)
        let check = clock.now - start

        let bytes = (try? Data(contentsOf: url).count) ?? 0
        let words = loaded.reduce(0) { $0 + $1.words.count }
        print("TIMING [\(buildKind)] emoji.json: \(loaded.count) emojis, \(words) words, \(bytes) bytes; load median \(String(format: "%.2f", load)) ms; draw check \(check), \(loaded.count - drawable.count) hidden")
        // A generous bound, so CI is not flaky. The budget is 50 ms in a release build.
        #expect(load < 500)
        // An older macOS on CI can miss the newest emojis. Almost all must draw.
        #expect(drawable.count > 1_800)
    }
}
