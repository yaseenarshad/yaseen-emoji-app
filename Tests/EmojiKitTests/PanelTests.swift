import AppKit
import Testing
@testable import EmojiKit

/// The search panel with no window (YAZ-2899): the session, the paste, the grid, the tone and the menu.
/// The fakes keep the clipboard, the keys and the clock, so no test posts a key or waits.
@MainActor
@Suite struct PanelTests {
    /// The "Done when" test of YAZ-2899: type "ship", pick 🚀, ⌘V, the old clipboard comes back,
    /// "ship" is learned, and the next "ship" search has 🚀 first.
    @Test func endToEndSearchPickPasteLearnSearchAgain() throws {
        let rig = try PickRig()
        rig.setEnter(keep: false)
        rig.session.toggle()
        #expect(rig.session.isOpen)
        #expect(rig.panel.calls == ["show"])

        rig.session.setQuery("ship")
        // Before the pick, 🚀 ("ship" is one of its words) is not first.
        #expect(rig.session.emojis.first?.text != "🚀")
        #expect(rig.session.lines.first == .title(PickSession.resultsTitle(rig.session.emojis.count)))
        try rig.select("🚀")
        rig.session.enter(shift: false)

        // The panel closes first, so the ⌘V goes to the app in front.
        #expect(!rig.session.isOpen)
        #expect(rig.panel.calls == ["show", "hide"])
        #expect(rig.clipboard.contents == .text("🚀"))
        // The emoji is there for the paste only, so clipboard history apps do not keep it.
        #expect(rig.clipboard.lastWriteIsTransient)
        #expect(rig.keys.sent.isEmpty)

        rig.later.advance(by: Paster.postDelay)
        #expect(rig.keys.sent == [HotKeyCombo(keyCode: 9, modifiers: .command)])
        #expect(rig.clipboard.contents == .text("🚀"))

        rig.later.advance(by: Paster.restoreDelay)
        // Both items with all their types are back.
        #expect(rig.clipboard.contents == FakeClipboard.rich)
        #expect(rig.later.isEmpty)

        // The store saved the pick and the word, and a new store on the same file has them.
        let saved = YouStore(url: rig.folder.youFile)
        saved.load()
        #expect(saved.you.learned["ship"]?[You.key("🚀")]?.count == 1)
        #expect(saved.you.uses[You.key("🚀")]?.count == 1)
        // A new start of the app gives the same search, in any case.
        #expect(Search.results(for: "SHIP ", in: Catalog.all, you: saved.you).first?.text == "🚀")
        #expect(Search.mostUsed(in: Catalog.all, you: saved.you).map(\.text) == ["🚀"])

        rig.session.toggle()
        #expect(rig.session.query == "")
        rig.session.setQuery("ship")
        #expect(rig.session.emojis.first?.text == "🚀")
        #expect(rig.session.selection == 0)
    }

    /// Shift+Enter pastes and stays open (D8). Two picks in the wait still bring back the clipboard of the user.
    /// D13: an empty search shows 4 rows of "Your most used" (36), then the groups. The history keeps all 50.
    @Test func yourMostUsedShowsFourRows() throws {
        let rig = try PickRig()
        for emoji in Catalog.all.prefix(50) { rig.store.recordPick(emoji.text, query: "") }
        rig.session.open()
        let lines = rig.session.lines
        let start = try #require(lines.firstIndex(of: .title(PickSession.mostUsedTitle)))
        let rows = lines[(start + 1)...].prefix { if case .cells = $0 { return true } else { return false } }
        #expect(rows.count == 4)
        #expect(rows.reduce(0) { total, line in
            if case .cells(let range) = line { return total + range.count } else { return total }
        } == 36)
        #expect(rig.store.you.uses.count == 50)
    }

    /// D14: the grid drags the panel itself, after a move of more than 4 points. A mouse-down alone
    /// never moves the panel, so a click with no move still picks.
    @Test func theGridDragsThePanelOnlyAfterAMove() throws {
        let rig = try PickRig()
        #expect(EmojiGridView(session: rig.session).mouseDownCanMoveWindow == false)
        let start = NSPoint(x: 100, y: 100)
        // Each row: the end of the move, and whether it is a drag.
        let table: [(end: NSPoint, isDrag: Bool)] = [
            (NSPoint(x: 100, y: 100), false),
            (NSPoint(x: 104, y: 100), false),       // exactly 4 points: still a click
            (NSPoint(x: 102.8, y: 102.8), false),   // about 3.96 points on a slant
            (NSPoint(x: 102.9, y: 102.9), true),    // about 4.1 points on a slant
            (NSPoint(x: 100, y: 95.9), true),
            (NSPoint(x: 140, y: 60), true),
        ]
        for row in table {
            #expect(EmojiGridView.isDrag(from: start, to: row.end) == row.isDrag, "\(row.end)")
        }
    }

    @Test func shiftEnterKeepsThePanelOpen() throws {
        let rig = try PickRig()
        rig.setEnter(keep: false)
        rig.session.open()
        rig.session.setQuery("thumb")
        try rig.select("👍")
        let before = (items: rig.session.emojis, selection: rig.session.selection)
        rig.session.enter(shift: true)
        #expect(rig.session.isOpen)
        // The list does not move while the panel stays open.
        #expect(rig.session.emojis == before.items && rig.session.selection == before.selection)
        #expect(rig.session.query == "thumb")
        #expect(rig.session.selectedEmoji?.text == "👍")
        #expect(rig.panel.calls == ["show", "stepAside"])

        rig.later.advance(by: Paster.postDelay + Paster.comeBackDelay)
        #expect(rig.keys.sent.count == 1)
        #expect(rig.panel.calls == ["show", "stepAside", "comeBack"])

        // A second pick before the first restore.
        try rig.select("👎")
        let second = try #require(rig.session.selectedEmoji)
        rig.session.enter(shift: true)
        rig.later.runAll()
        #expect(rig.keys.sent.count == 2)
        #expect(rig.session.isOpen)
        #expect(rig.clipboard.contents == FakeClipboard.rich)
        // Each Shift+Enter pick counts and learns (D4).
        #expect(rig.store.you.learned["thumb"]?.count == 2)
        #expect(rig.store.you.uses[second.key]?.count == 1)
    }

    /// Copy only (Settings, and ⌘C) posts no key and does not bring back the old clipboard.
    /// Esc closes with no paste (D8).
    @Test func copyOnlyAndEscPostNoKey() throws {
        let rig = try PickRig()
        rig.setEnter(.copyOnly, keep: true)
        rig.session.open()
        rig.session.setQuery("rocket")
        try rig.select("🚀")
        rig.session.enter(shift: false)
        rig.later.runAll()
        #expect(rig.keys.sent.isEmpty)
        #expect(rig.clipboard.contents == .text("🚀"))
        #expect(!rig.clipboard.lastWriteIsTransient)
        #expect(rig.clipboard.restores == 0)
        #expect(!rig.session.isOpen)

        // ⌘C in Paste mode: copy only too, and the panel closes (D8).
        rig.setEnter(.paste, keep: true)
        rig.session.open()
        rig.session.setQuery("fire")
        try rig.select("🔥")
        rig.session.copyOnly()
        rig.later.runAll()
        #expect(rig.keys.sent.isEmpty)
        #expect(rig.clipboard.contents == .text("🔥"))
        #expect(!rig.session.isOpen)
        #expect(rig.store.you.learned["fire"]?[You.key("🔥")]?.count == 1)

        // Esc: the panel closes, and nothing changes.
        rig.session.open()
        rig.session.setQuery("thumbs up")
        rig.session.escape()
        rig.later.runAll()
        #expect(!rig.session.isOpen)
        #expect(rig.keys.sent.isEmpty)
        #expect(rig.clipboard.contents == .text("🔥"))
        #expect(rig.store.you.uses[You.key("👍")] == nil)
    }

    /// No Accessibility, or a password field (secure input): copy only. The emoji stays on the clipboard (D2).
    @Test func noAccessibilityMeansCopyOnly() throws {
        let rig = try PickRig(trusted: false)
        rig.session.open()
        rig.session.setQuery("rocket")
        try rig.select("🚀")
        rig.session.enter(shift: true)
        // Copy only does not step aside for a ⌘V. Shift+Enter closes too: you paste it yourself (D20 of YAZ-2919).
        #expect(rig.panel.calls == ["show", "hide"] && !rig.session.isOpen)
        rig.later.runAll()
        #expect(rig.keys.sent.isEmpty)
        #expect(rig.clipboard.contents == .text("🚀"))

        rig.access.isTrusted = true
        rig.access.secureInputIsOn = true
        rig.session.open()
        rig.session.setQuery("fire")
        try rig.select("🔥")
        rig.session.enter(shift: false)
        rig.later.runAll()
        #expect(rig.keys.sent.isEmpty)
        #expect(rig.clipboard.contents == .text("🔥"))
        #expect(rig.clipboard.restores == 0)
    }

    /// The user copies something new in the 0.3 s wait: the new copy stays (D2).
    /// A Copy only pick in the wait: its emoji stays, and the restore of the first pick does nothing.
    @Test func aNewCopyDuringTheWaitIsKept() throws {
        let rig = try PickRig()
        rig.setEnter(keep: false)
        rig.session.open()
        rig.session.setQuery("rocket")
        rig.session.enter(shift: false)
        rig.later.advance(by: Paster.postDelay)
        #expect(rig.keys.sent.count == 1)
        rig.clipboard.userCopies("new copy")
        rig.later.runAll()
        #expect(rig.clipboard.contents == .text("new copy"))
        #expect(rig.clipboard.restores == 0)

        rig.session.open()
        rig.session.setQuery("fire")
        rig.session.enter(shift: false)
        rig.later.advance(by: Paster.postDelay)
        rig.session.open()
        rig.session.setQuery("rocket")
        rig.session.copyOnly()
        rig.later.runAll()
        #expect(rig.keys.sent.count == 2)
        #expect(rig.clipboard.contents == .text("🚀"))
        #expect(rig.clipboard.restores == 0)
    }

    /// The blue box in a grid of 9 columns: 20 emojis are rows of 9, 9 and 2.
    @Test func theBlueBoxStopsAtTheEdges() throws {
        let rig = try PickRig(catalog: smallCatalog(20))
        rig.session.open()
        let session = rig.session
        #expect(session.lines == [.title("Smileys & Emotion"), .cells(0..<9), .cells(9..<18), .cells(18..<20)])
        #expect(session.selection == 0)
        session.move(.left)
        session.move(.up)
        #expect(session.selection == 0)
        // Right goes on to the next row. Up and Down keep the column.
        for _ in 0..<9 { session.move(.right) }
        #expect(session.selection == 9)
        session.move(.right)
        session.move(.down)
        #expect(session.selection == 19)
        // The last row is short: Down from column 5 goes to the last emoji.
        session.select(5)
        session.move(.down)
        session.move(.down)
        #expect(session.selection == 19)
        session.move(.right)
        session.move(.down)
        #expect(session.selection == 19)
        session.move(.up)
        #expect(session.selection == 10)

        // No results: the D7 line, no blue box, and Enter does nothing (D8). An arrow puts the box on the first emoji.
        session.setQuery("zzqqxx")
        #expect(session.lines.first == .title(PickSession.noMatchTitle("zzqqxx")))
        #expect(session.selection == nil)
        session.enter(shift: false)
        #expect(session.isOpen)
        #expect(rig.keys.sent.isEmpty && rig.later.isEmpty)
        session.move(.down)
        #expect(session.selection == 0)
    }

    /// D18: a search with no results shows "Your most used" and all the groups. A pick of an emoji
    /// from a group learns the new search text, so the next search with it puts that emoji first.
    @Test func aNewWordCanTeachAnyEmoji() throws {
        let rig = try PickRig()
        for emoji in Catalog.all.prefix(40) { rig.store.recordPick(emoji.text, query: "") }
        let otter = try #require(Catalog.emoji("🦦"))
        let session = rig.session
        session.open()
        session.setQuery("zzbet")
        #expect(session.lines.first == .title(PickSession.noMatchTitle("zzbet")))
        #expect(session.lines.contains(.title(PickSession.mostUsedTitle)))
        for group in EmojiCatalog.groupNames { #expect(session.lines.contains(.title(group)), "\(group)") }
        #expect(session.selection == nil)
        let place = try #require(session.emojis.firstIndex(of: otter))
        #expect(!(session.mostUsedItems?.contains(place) ?? false))
        // "Hide from Your most used" stays only in that section.
        #expect(session.menuActions(at: place) == [.addWord, .copyOnly])
        #expect(session.menuActions(at: 0).last == .hideFromMostUsed)

        session.select(place)
        session.enter(shift: false)
        #expect(rig.store.you.learned["zzbet"]?[otter.key]?.count == 1)
        session.open()
        session.setQuery("zzbet")
        #expect(session.emojis.first == otter && session.selection == 0)
    }

    /// The shown form (D9, D17): the default tone of Settings for an emoji that takes a tone, else the
    /// emoji itself. Settings is the only tone choice. A pick of a tone form counts the base emoji.
    @Test func theShownFormOfAnEmoji() throws {
        let rig = try PickRig()
        let thumbs = try #require(Catalog.emoji("👍"))
        let rocket = try #require(Catalog.emoji("🚀"))
        #expect(rig.session.shown(thumbs) == "👍")

        rig.prefs.defaultTone = "\u{1F3FD}"
        #expect(rig.session.shown(thumbs) == "👍🏽")
        #expect(rig.session.shown(rocket) == "🚀")

        rig.session.open()
        rig.session.setQuery("thumbs up")
        rig.session.enter(shift: false)
        #expect(rig.clipboard.contents == .text("👍🏽"))
        #expect(rig.store.you.uses[You.key("👍")]?.count == 1)
        // "Your most used" shows the form with the tone.
        rig.session.open()
        #expect(rig.session.lines.first == .title(PickSession.mostUsedTitle))
        #expect(rig.shownItems.first == "👍🏽")
    }

    /// The right-click menu (D15, D17): no tone forms. "Hide from Your most used" shows only for an
    /// emoji in that section. The hide rebuilds the grid, the panel stays open, and the next emoji fills the place.
    @Test func hideIsOnlyInYourMostUsed() throws {
        let rig = try PickRig()
        for emoji in Catalog.all.prefix(40) { rig.store.recordPick(emoji.text, query: "") }
        let thumbs = try #require(Catalog.emoji("👍"))
        rig.store.recordPick(thumbs.text, query: "")
        rig.store.recordPick(thumbs.text, query: "")
        rig.session.open()
        let session = rig.session
        let most = try #require(session.mostUsedItems)
        #expect(most == 0..<36 && session.emojis.first == thumbs)
        #expect(session.menuActions(at: 0) == [.addWord, .copyOnly, .hideFromMostUsed])
        #expect(session.menuActions(at: 35).last == .hideFromMostUsed)
        // The same 👍 in its group, below "Your most used".
        let inGroup = try #require(session.emojis.indices.first { $0 >= 36 && session.emojis[$0] == thumbs })
        #expect(session.menuActions(at: inGroup) == [.addWord, .copyOnly])
        #expect(session.menuActions(at: session.emojis.count).isEmpty)
        #expect(PickSession.MenuAction.hideFromMostUsed.title == "Hide from Your most used")
        let before = Set(session.emojis[0..<36].map(\.text))

        session.hideFromMostUsed(thumbs)
        #expect(session.isOpen)
        #expect(rig.panel.calls == ["show"])
        #expect(session.mostUsedItems == 0..<36)
        let after = Set(session.emojis[0..<36].map(\.text))
        #expect(!after.contains(thumbs.text))
        #expect(before.subtracting([thumbs.text]).isSubset(of: after) && after.subtracting(before).count == 1)

        // A search result has no hide item, and the search still finds 👍.
        session.setQuery("thumbs up")
        #expect(session.mostUsedItems == nil)
        #expect(session.emojis.first == thumbs)
        #expect(session.menuActions(at: 0) == [.addWord, .copyOnly])
    }

    /// "Add a word…" (D4): with a search it adds the search text. With an empty search the box asks for the word.
    @Test func addAWord() throws {
        let rig = try PickRig()
        let rocket = try #require(Catalog.emoji("🚀"))
        rig.session.open()
        rig.session.setQuery("zoomies")
        #expect(rig.session.selection == nil)
        rig.session.addWord(for: rocket)
        #expect(rig.session.emojis.first?.text == "🚀")

        rig.session.escape()
        rig.session.open()
        rig.session.addWord(for: rocket)
        #expect(rig.session.lines == [.title(PickSession.addingWordText(rocket))])
        rig.session.setQuery("blastoff")
        // Esc stops the question, and the panel stays open.
        rig.session.escape()
        #expect(rig.session.isOpen && rig.session.addingWordFor == nil)
        rig.session.addWord(for: rocket)
        rig.session.setQuery("blastoff")
        rig.session.enter(shift: false)
        #expect(rig.session.isOpen)
        #expect(rig.session.emojis.first?.text == "🚀")
        #expect(rig.store.you.added[You.key("🚀")] == ["zoomies", "blastoff"])
        // Adding a word is not a pick.
        #expect(rig.keys.sent.isEmpty && rig.clipboard.restores == 0 && rig.store.you.uses.isEmpty)
    }

    /// D7: the middle of the screen with the mouse, in the upper third, 460 points wide.
    @Test func thePanelOpensInTheUpperThird() {
        let screen = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let frame = PanelPlace.frame(size: CGSize(width: SearchPanelController.width, height: 392), visibleFrame: screen)
        #expect(frame.width == 460)
        #expect(frame.midX == screen.midX)
        #expect(frame.maxY < screen.maxY && frame.maxY > screen.maxY - screen.height / 3)
        // A small screen: the panel stays on it.
        let small = CGRect(x: 0, y: 0, width: 800, height: 300)
        #expect(PanelPlace.frame(size: CGSize(width: 460, height: 392), visibleFrame: small).minY == 0)
    }
}
