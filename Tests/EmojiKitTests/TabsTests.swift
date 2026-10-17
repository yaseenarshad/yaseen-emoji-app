import Foundation
import Testing
@testable import EmojiKit

/// The tabs, the search and the picks of GIFs and memes, with no window (YAZ-2924; D7, D10, D11, D13 of YAZ-2919).
/// The GIFs are small files made in the test, in a temp folder.
@MainActor
@Suite struct TabsTests {
    /// D10: each open starts on Emoji with an empty search, also after the GIFs tab was used.
    @Test func eachOpenStartsOnEmojiWithAnEmptySearch() throws {
        let rig = try PickRig()
        try rig.addOwn(words: ["dance"])
        let session = rig.session
        session.open()
        let firstGrid = session.lines
        #expect(session.tab == .emoji && session.query == "")
        #expect(session.placeholder == "Search emoji")

        session.select(tab: .gifs)
        session.setQuery("dan")
        #expect(session.tab == .gifs && session.columnCount == 3)
        session.close()
        session.open()
        #expect(session.tab == .emoji && session.query == "" && session.columnCount == 9)
        #expect(session.lines == firstGrid)
        #expect(session.items.allSatisfy { $0.emoji != nil })
    }

    /// D10: Tab and Shift+Tab go round the three tabs, and the search text stays. ⌘1 to ⌘3 go to a tab.
    /// The placeholders of the D10 update: "Search KLIPY" only with a KLIPY key.
    @Test func tabAndShiftTabGoRoundTheThreeTabs() throws {
        let rig = try PickRig()
        let session = rig.session
        session.open()
        session.setQuery("party")
        var seen: [PickSession.Tab] = []
        for _ in 0..<3 {
            session.nextTab(back: false)
            seen.append(session.tab)
            #expect(session.query == "party")
        }
        #expect(seen == [.gifs, .memes, .emoji])
        session.nextTab(back: true)
        #expect(session.tab == .memes && session.query == "party")
        #expect(session.placeholder == "Search your memes")
        session.select(tab: .gifs)
        #expect(session.placeholder == "Search your GIFs")
        #expect(PickSession.Tab.allCases.map(\.title) == ["Emoji", "GIFs", "Memes"])

        let online = FakeOnline()
        let withKey = try PickRig(online: online)
        withKey.session.open()
        withKey.session.select(tab: .memes)
        #expect(withKey.session.placeholder == "Search KLIPY")
        withKey.session.select(tab: .emoji)
        #expect(withKey.session.placeholder == "Search emoji")
    }

    /// A GIF with the word "dance" shows in "Yours" for "dan". A pick of it with "party" counts one use of `gif:<id>`,
    /// and the next search "party" shows it first. No match: the line and the sections of no search (D11).
    @Test func aPickOfAGIFCountsAndLearnsTheWord() throws {
        let rig = try PickRig()
        let gif = try rig.addOwn(words: ["dance"])
        let other = try rig.addOwn(words: ["wave"], seed: 1)
        let session = rig.session
        session.open()
        session.select(tab: .gifs)
        // No search: "Your GIFs", newest first. No uses yet, so no "Your most used".
        #expect(session.lines == [.title("Your GIFs"), .cells(0..<2)])
        #expect(session.items.map(\.key) == [other.key, gif.key])

        session.setQuery("dan")
        #expect(session.lines == [.title(PickSession.yoursTitle), .cells(0..<1)])
        #expect(session.items == [.own(gif)] && session.selection == 0)

        session.setQuery("party")
        #expect(session.lines.first == .title(PickSession.noTileMatchTitle("party")))
        #expect(session.lines.dropFirst().first == .title("Your GIFs"))
        #expect(session.selection == nil)
        session.select(try rig.place(of: gif.key))
        session.enter(shift: false)
        #expect(!session.isOpen)
        #expect(rig.store.you.uses["gif:\(gif.id)"]?.count == 1)
        #expect(rig.store.you.learned["party"]?["gif:\(gif.id)"]?.count == 1)

        session.open()
        session.select(tab: .gifs)
        // "Your most used" now has the GIF: 6 at most, the same order rule as emojis.
        #expect(session.lines.first == .title(PickSession.mostUsedTitle))
        #expect(session.mostUsedItems == 0..<1 && session.items.first == .own(gif))
        session.setQuery("party")
        #expect(session.lines.first == .title(PickSession.yoursTitle))
        #expect(session.items.first == .own(gif) && session.selection == 0)
        // The Memes tab does not show a GIF.
        session.select(tab: .memes)
        #expect(session.lines.first == .title(PickSession.noTileMatchTitle("party")))
        #expect(!session.items.contains(.own(gif)))
    }

    /// D11: "Your most used" of a tab has at most 6 items, and leaves out a hidden item (D15 of YAZ-2894).
    @Test func yourMostUsedOfATab() throws {
        let rig = try PickRig()
        var gifs: [Item] = []
        for seed in 0..<8 { gifs.append(try rig.addOwn(words: ["g\(seed)"], seed: seed)) }
        for (place, gif) in gifs.enumerated() {
            for _ in 0...place { rig.store.recordPick(gif.key, query: "") }
        }
        let session = rig.session
        session.open()
        session.select(tab: .gifs)
        #expect(session.mostUsedItems == 0..<6)
        #expect(session.lines.prefix(3) == [.title(PickSession.mostUsedTitle), .cells(0..<3), .cells(3..<6)])
        #expect(session.items.prefix(6).map(\.key) == gifs.reversed().prefix(6).map(\.key))
        session.hideFromMostUsed(item: .own(gifs[7]))
        #expect(session.mostUsedItems == 0..<6)
        #expect(!session.items.prefix(6).contains { $0.key == gifs[7].key })
        // It is still in "Your GIFs", and the search still finds it.
        #expect(session.items.dropFirst(6).contains { $0.key == gifs[7].key })
        session.setQuery("g7")
        #expect(session.items.first?.key == gifs[7].key)
    }

    /// D13: the menu items for your GIF in "Your most used", a saved KLIPY item, a KLIPY item that is not saved, and an emoji.
    @Test func theMenuItemsOfEachKind() throws {
        let online = FakeOnline()
        let saved = FakeOnline.gif("saved-1")
        let found = FakeOnline.gif("found-2")
        online.known = ["saved-1": saved, "found-2": found]
        online.results["cat"] = OnlineSection(items: [found, saved])
        let rig = try PickRig(online: online)
        let gif = try rig.addOwn(words: ["cat"])
        rig.library.saveKlipy("saved-1", kind: .gif, words: ["cat"])
        rig.store.recordPick(gif.key, query: "")
        let session = rig.session
        session.open()
        session.select(tab: .gifs)

        // Your GIF in "Your most used", and the same GIF in "Your GIFs".
        #expect(session.menuActions(at: 0) == [.addWord, .copyOnly, .hideFromMostUsed, .showInFinder, .moveToTrash, .addNew])
        let inList = try #require(session.items.indices.first { $0 > 0 && session.items[$0] == .own(gif) })
        #expect(session.menuActions(at: inList) == [.addWord, .copyOnly, .showInFinder, .moveToTrash, .addNew])
        // The saved KLIPY item shows in "Your GIFs".
        let savedPlace = try rig.place(of: "klipy:saved-1")
        #expect(session.menuActions(at: savedPlace) == [.addWord, .copyOnly, .removeFromYours(.gif), .addNew])
        #expect(session.menuActionsOutsideItems == [.addNew])

        // A search: "Yours" (your GIF and the saved item), then "From KLIPY" in KLIPY's order.
        session.setQuery("cat")
        #expect(session.lines == [.title("Yours"), .cells(0..<2), .title("From KLIPY"), .cells(2..<4)])
        #expect(Array(session.items[2...]) == [.online(found), .online(saved)])
        #expect(session.menuActions(at: 2) == [.saveToYours(.gif), .copyOnly, .addNew])
        #expect(session.menuActions(at: 3) == [.addWord, .copyOnly, .removeFromYours(.gif), .addNew])
        #expect(PickSession.MenuAction.saveToYours(.gif).title == "Save to your GIFs")
        #expect(PickSession.MenuAction.removeFromYours(.meme).title == "Remove from your memes")
        #expect(PickSession.MenuAction.addNew.title == "Add a GIF or meme…")

        // An emoji: no change (v0.1).
        session.select(tab: .emoji)
        session.setQuery("")
        #expect(session.menuActions(at: 0) == [.addWord, .copyOnly])
        #expect(session.menuActionsOutsideItems.isEmpty)
    }

    /// D15 of YAZ-2894 for each item of "Your most used": a KLIPY GIF that you picked but did not save gets
    /// "Hide from Your most used". Yaseen: "and there's no option to forget the gif?" The tile leaves the section,
    /// the next item fills its place, and the hide is the key `klipy:<slug>` in `you-<Mac>.json`.
    @Test func aPickedKLIPYGIFCanLeaveYourMostUsed() throws {
        let online = FakeOnline()
        let slugs = (0..<7).map { "picked-\($0)" }
        for slug in slugs { online.known[slug] = FakeOnline.gif(slug) }
        let rig = try PickRig(online: online)
        // picked-0 has the most uses, picked-6 the fewest: only 6 fit in "Your most used".
        for (place, slug) in slugs.enumerated() {
            for _ in 0..<(slugs.count - place) { rig.store.recordPick("klipy:\(slug)", query: "") }
        }
        let session = rig.session
        session.open()
        session.select(tab: .gifs)
        #expect(session.mostUsedItems == 0..<6)
        #expect(session.items.prefix(6).map(\.key) == slugs.prefix(6).map { "klipy:\($0)" })
        #expect(session.menuActions(at: 0) == [.saveToYours(.gif), .copyOnly, .hideFromMostUsed, .addNew])

        session.perform(.hideFromMostUsed)
        #expect(rig.store.you.isHidden("klipy:picked-0"))
        #expect(session.isOpen && session.mostUsedItems == 0..<6)
        #expect(session.items.prefix(6).map(\.key) == slugs.dropFirst().map { "klipy:\($0)" })
        // The uses stay.
        #expect(rig.store.you.uses["klipy:picked-0"]?.count == 7)
    }

    /// D7: a pick of a KLIPY item counts `klipy:<slug>`, also when it is not saved. "Yours" then shows it for that text.
    /// "Save to your GIFs" keeps only its slug. With no KLIPY part, a saved KLIPY item does not show.
    @Test func aKLIPYPickCountsItsSlug() throws {
        let folder = try TempFolder()
        let file = folder.url.appendingPathComponent("found-2.gif")
        try makeTestImage(width: 20, height: 20, type: .gif, frames: 2).write(to: file)
        let online = FakeOnline()
        let found = FakeOnline.gif("found-2")
        online.known = ["found-2": found]
        online.results["cat"] = OnlineSection(items: [found])
        online.files = ["found-2": file]
        let rig = try PickRig(online: online)
        let session = rig.session
        session.open()
        session.select(tab: .gifs)
        session.setQuery("cat")
        #expect(session.lines == [.title("From KLIPY"), .cells(0..<1)])
        session.enter(shift: false)
        #expect(rig.store.you.uses["klipy:found-2"]?.count == 1)
        #expect(rig.store.you.learned["cat"]?["klipy:found-2"]?.count == 1)

        session.open()
        session.select(tab: .gifs)
        session.setQuery("cat")
        #expect(session.lines == [.title("Yours"), .cells(0..<1), .title("From KLIPY"), .cells(1..<2)])
        session.saveToYours(.online(found))
        #expect(rig.library.item(Item.klipyItemID("found-2"))?.file == nil)
        #expect(rig.library.item(Item.klipyItemID("found-2"))?.klipyID == "found-2")
        session.removeFromYours(.online(found))
        #expect(rig.library.item(Item.klipyItemID("found-2"))?.isRemoved == true)

        // No KLIPY part: the saved item stays in the list, but the tab cannot draw it.
        let plain = try PickRig()
        plain.library.saveKlipy("found-2", kind: .gif)
        plain.session.open()
        plain.session.select(tab: .gifs)
        #expect(plain.session.lines == [.title("Your GIFs"), .title(PickSession.emptyTitle(.gif))])
        plain.session.setQuery("cat")
        #expect(!plain.session.lines.contains(.title(PickSession.onlineTitle)))
    }

    /// "Add a word…" of a GIF adds the word to the item's `words` (D13), not to `you-<Mac>.json`.
    @Test func addAWordToAGIF() throws {
        let rig = try PickRig()
        let gif = try rig.addOwn(words: ["dance"])
        let session = rig.session
        session.open()
        session.select(tab: .gifs)
        session.setQuery("boogie")
        session.addWord(for: .own(gif))
        #expect(rig.library.item(gif.id)?.words == ["dance", "boogie"])
        #expect(session.items.first?.key == gif.key && session.selection == 0)

        session.setQuery("")
        session.addWord(for: .own(gif))
        #expect(session.lines == [.title(PickSession.addingWordText(.own(gif)))])
        #expect(session.placeholder == "A word for this GIF")
        // The tab does not change while the word waits.
        session.nextTab(back: false)
        #expect(session.tab == .gifs)
        session.setQuery("Shimmy")
        session.enter(shift: false)
        #expect(rig.library.item(gif.id)?.words == ["dance", "boogie", "shimmy"])
        #expect(rig.store.you.added.isEmpty && rig.store.you.uses.isEmpty)
    }

    /// The emoji search budget stays 2 ms (D5). The same search over 2,000 made-up items, with 3 words each.
    /// The number goes into the Result comment. The bound here is generous, so a slow CI computer does not fail.
    @Test func theTimeOfASearchOverTwoThousandItems() {
        let vocabulary = ["dance", "party", "happy", "sad", "cat", "dog", "lol", "fine", "this", "is", "wow", "omg",
                          "yes", "no", "facepalm", "clap", "cheers", "hello", "bye", "thanks", "love", "angry", "cry",
                          "laugh", "shrug", "wink", "hype", "fire", "cool", "sleepy"]
        var seed: UInt32 = 7
        func next() -> Int {
            seed = seed &* 1_103_515_245 &+ 12345
            return Int(seed >> 8)
        }
        let entries = (0..<2_000).map { place -> TileEntry in
            let words = (0..<3).map { _ in vocabulary[next() % vocabulary.count] + (next() % 3 == 0 ? "\(next() % 50)" : "") }
            let item = Item(id: String(format: "%016x", place), kind: .gif, file: "gifs/\(place).gif", klipyID: nil,
                            words: words, added: Date(timeIntervalSince1970: Double(place)), changed: Date())
            return TileEntry(item: .own(item), words: words, order: place)
        }
        var you = You()
        for entry in entries.prefix(300) { you.uses[entry.key] = You.Use(count: entry.order % 20 + 1, last: Date()) }
        you.learned["party"] = [entries[1_999].key: You.Use(count: 2, last: Date())]
        let queries = ["d", "da", "dance", "party", "happy dance", "cat12", "zzqqxx", "s"]
        var worst = 0.0
        var lines: [String] = []
        for query in queries {
            let time = medianMilliseconds(runs: 15) { _ = Search.ranked(for: query, in: entries, you: you) }
            worst = max(worst, time)
            lines.append("\(query): \(String(format: "%.3f", time))")
        }
        let most = medianMilliseconds(runs: 15) { _ = Search.mostUsed(of: entries, you: you, limit: 6) }
        print("TIMING [\(buildKind)] search median ms on 2000 items: \(lines.joined(separator: ", ")); most used: \(String(format: "%.3f", most))")
        #expect(Search.ranked(for: "party", in: entries, you: you).first?.key == entries[1_999].key)
        #expect(worst < 100)
    }

    /// The demo command `--add-media` (YAZ-2925): it adds into this Mac's list and `gifs/` or `memes/` of the
    /// preferences folder of the prefs. With no words, the words come from the file name. Fake prefs and a temp folder.
    @Test func theDemoCommandAddsGIFsAndMemes() async throws {
        let folder = try TempFolder()
        let gif = folder.url.appendingPathComponent("party.gif")
        try makeTestImage(width: 40, height: 30, type: .gif, frames: 2).write(to: gif)
        let meme = folder.url.appendingPathComponent("Happy-Dance_2024.png")
        try makeTestImage(width: 60, height: 40, type: .png).write(to: meme)
        let text = folder.url.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: text)
        var lines: [String] = []
        let defaults = MemoryDefaults()
        func run(_ arguments: [String]) async -> Int32 {
            await AddCommand.run(arguments, defaults: defaults, defaultFolder: folder.defaultFolder,
                                 computerName: { "Test Mac" }) { lines.append($0) }
        }
        #expect(await run([]) == 2 && lines == [AddCommand.usage])
        #expect(await run([gif.path, "--words", "Dance  party"]) == 0)
        #expect(await run([meme.path, text.path]) == 1)
        #expect(lines.count == 4 && lines[3].hasPrefix("notes.txt: ") && lines[3].hasSuffix(MediaImport.wrongTypeText))

        let library = LibraryStore(url: folder.defaultFolder.appendingPathComponent("library-Test-Mac.json"),
                                   mediaFolder: folder.defaultFolder, trash: FakeTrash(folder: folder.url))
        library.load()
        #expect(library.items(.gif).map(\.words) == [["dance", "party"]])
        #expect(library.items(.meme).map(\.words) == [["happy", "dance"]])
        #expect(library.missing.isEmpty && library.items.allSatisfy { library.fileURL(of: $0) != nil })
        #expect(folder.names(in: folder.defaultFolder.appendingPathComponent("gifs")).count == 1)
        // The same file again: "Already there", and the new words are added.
        #expect(await run([gif.path, "--words", "yay"]) == 0)
        #expect(lines.last?.hasPrefix("Already there: GIF") == true)
    }
}
