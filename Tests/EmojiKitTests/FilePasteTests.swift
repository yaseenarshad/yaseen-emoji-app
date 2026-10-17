import AppKit
import Testing
import UniformTypeIdentifiers
@testable import EmojiKit

/// The paste of a GIF or meme file and the right-click actions, with no window (YAZ-2926; D6 and D13 of YAZ-2919).
/// The fake clipboard uses the same item as the real one (`ClipboardContents.fileItem`). No test touches the
/// real clipboard or Finder.
@MainActor
@Suite struct FilePasteTests {
    /// The one clipboard item of D6: the file URL, the file's own bytes in its own type, and the transient mark.
    private func fileItem(_ url: URL, _ type: UTType, transient: Bool) throws -> ClipboardContents {
        ClipboardContents(items: [.init(values: [
            ("public.file-url", Data(url.absoluteString.utf8)),
            (type.identifier, try Data(contentsOf: url)),
        ] + (transient ? [("org.nspasteboard.TransientType", Data())] : []))])
    }

    /// D6: a GIF pick writes the file URL and the GIF bytes (no TIFF), posts ⌘V, and the old clipboard comes back
    /// after 1.0 s, not 0.3 s. A new copy of the user in the wait stays.
    @Test func aGIFPickPastesTheFileAndRestoresAfterOneSecond() throws {
        let rig = try PickRig()
        let gif = try rig.addOwn(words: ["dance"])
        let url = try #require(rig.library.fileURL(of: gif))
        rig.session.open()
        rig.session.select(tab: .gifs)
        rig.session.setQuery("dance")
        rig.session.enter(shift: false)

        #expect(!rig.session.isOpen)
        let written = try fileItem(url, .gif, transient: true)
        #expect(rig.clipboard.contents == written)
        #expect(written.items[0].values.map(\.type) == ["public.file-url", "com.compuserve.gif", "org.nspasteboard.TransientType"])
        #expect(!rig.clipboard.contents.items[0].values.contains { $0.type == "public.tiff" || $0.type == "public.png" })
        rig.later.advance(by: Paster.postDelay)
        #expect(rig.keys.sent == [Paster.pasteKey])
        // At 0.3 s, the time of an emoji, the GIF is still on the clipboard.
        rig.later.advance(by: Paster.restoreDelay)
        #expect(rig.clipboard.contents == written && rig.clipboard.restores == 0)
        // 1.0 s after the ⌘V (a small extra step for the sum of the floating-point times).
        rig.later.advance(by: Paster.fileRestoreDelay - Paster.restoreDelay - 0.01)
        #expect(rig.clipboard.restores == 0)
        rig.later.advance(by: 0.011)
        #expect(rig.clipboard.contents == FakeClipboard.rich)
        #expect(rig.store.you.uses[gif.key]?.count == 1)

        // The user copies in the wait: no restore.
        rig.session.open()
        rig.session.select(tab: .gifs)
        rig.session.setQuery("dance")
        rig.session.enter(shift: false)
        rig.later.advance(by: Paster.postDelay + 0.5)
        rig.clipboard.userCopies("new copy")
        rig.later.runAll()
        #expect(rig.clipboard.contents == .text("new copy"))
        #expect(rig.clipboard.restores == 1)

        // A meme pastes its PNG bytes as `public.png`.
        let meme = try rig.addOwn(.meme, words: ["fine"])
        let memeURL = try #require(rig.library.fileURL(of: meme))
        rig.session.open()
        rig.session.select(tab: .memes)
        rig.session.setQuery("fine")
        rig.session.enter(shift: false)
        #expect(rig.clipboard.contents == (try fileItem(memeURL, .png, transient: true)))
        rig.later.runAll()
    }

    /// Copy only (⌘C) of a GIF: the file stays on the clipboard with no transient mark, no ⌘V and no restore.
    /// The panel closes, as for an emoji (D8). Shift+Enter pastes and stays open.
    @Test func copyOnlyOfAGIF() throws {
        let rig = try PickRig()
        let gif = try rig.addOwn(words: ["dance"])
        let url = try #require(rig.library.fileURL(of: gif))
        rig.session.open()
        rig.session.select(tab: .gifs)
        rig.session.copyOnly()
        rig.later.runAll()
        #expect(!rig.session.isOpen)
        #expect(rig.clipboard.contents == (try fileItem(url, .gif, transient: false)))
        #expect(!rig.clipboard.lastWriteIsTransient && rig.clipboard.restores == 0 && rig.keys.sent.isEmpty)
        #expect(rig.store.you.uses[gif.key]?.count == 1)

        // Copy only in Settings: Enter copies too.
        rig.prefs.pickMode = .copyOnly
        rig.session.open()
        rig.session.select(tab: .gifs)
        rig.session.enter(shift: false)
        rig.later.runAll()
        #expect(rig.keys.sent.isEmpty && rig.clipboard.restores == 0)

        rig.prefs.pickMode = .paste
        rig.session.open()
        rig.session.select(tab: .gifs)
        rig.session.enter(shift: true)
        #expect(rig.session.isOpen && rig.panel.calls.last == "stepAside")
        rig.later.runAll()
        // The clipboard before the paste was the copied GIF. It comes back.
        #expect(rig.panel.calls.last == "comeBack" && rig.clipboard.restores == 1)
        #expect(rig.clipboard.contents == (try fileItem(url, .gif, transient: false)))
    }

    /// D4: a GIF whose file is missing (git did not pull it yet) shows a grey tile, and a pick does nothing.
    @Test func aMissingFileDoesNothing() throws {
        let rig = try PickRig()
        let gif = try rig.addOwn(words: ["dance"])
        try FileManager.default.removeItem(at: try #require(rig.library.fileURL(of: gif)))
        rig.session.willOpen = { rig.library.reload() }
        rig.session.open()
        rig.session.select(tab: .gifs)
        #expect(rig.library.missing == [gif.id])
        #expect(rig.session.items == [.own(gif)] && rig.session.selection == 0)
        rig.session.enter(shift: false)
        rig.session.copyOnly()
        rig.later.runAll()
        #expect(rig.session.isOpen)
        #expect(rig.clipboard.contents == FakeClipboard.rich && rig.keys.sent.isEmpty)
        #expect(rig.store.you.uses.isEmpty)
    }

    /// D13: "Show in Finder" closes the panel and shows the file. "Add a GIF or meme…" calls the hook of subissue 3.
    /// "Copy only" and "Add a word…" of the menu are the same calls as the keys.
    @Test func theOtherMenuActions() throws {
        let rig = try PickRig()
        let gif = try rig.addOwn(words: ["dance"])
        var adds = 0
        rig.session.onAddNew = { adds += 1 }
        rig.session.open()
        rig.session.select(tab: .gifs)
        rig.session.perform(.addNew)
        #expect(adds == 1 && rig.session.isOpen)

        rig.session.setQuery("boogie")
        rig.session.select(0)
        rig.session.perform(.addWord)
        #expect(rig.library.item(gif.id)?.words == ["dance", "boogie"])

        rig.session.perform(.showInFinder)
        #expect(!rig.session.isOpen)
        #expect(rig.shownInFinder == [try #require(rig.library.fileURL(of: gif))])
        #expect(rig.clipboard.contents == FakeClipboard.rich)

        rig.session.open()
        rig.session.select(tab: .gifs)
        rig.session.perform(.copyOnly)
        #expect(!rig.session.isOpen && rig.store.you.uses[gif.key]?.count == 1)
    }
}
