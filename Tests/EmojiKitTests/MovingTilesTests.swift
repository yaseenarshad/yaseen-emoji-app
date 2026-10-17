import AppKit
import Testing
@testable import EmojiKit

/// Every GIF on the screen plays (D11 update on YAZ-2925), and the first title stays in sight after a move up.
/// The grid view lives in a scroll view with no window. No test makes a window, and no test goes online.
@MainActor
@Suite struct MovingTilesTests {
    private static let side = GridMetrics.cellSize(columns: PickSession.tileColumns)

    private static func gif(_ slug: String) -> PickItem { .online(FakeOnline.gif(slug)) }
    private static func meme(_ slug: String) -> PickItem { .online(FakeOnline.gif(slug, kind: .meme)) }

    /// The rule: the GIF tiles whose cell reaches into the visible rect play (a part counts), in the order of the grid,
    /// at most 15. A meme and an emoji never play.
    @Test func theGIFsOnTheScreenPlay() {
        // "Your most used" (a meme in the middle), then "Your GIFs" in rows of 3.
        let items = [Self.gif("a"), Self.meme("b"), Self.gif("c")] + (0..<30).map { Self.gif("g\($0)") }
        var lines: [PickSession.Line] = [.title("Your most used"), .cells(0..<3), .title("Your GIFs")]
        for start in stride(from: 3, to: items.count, by: 3) { lines.append(.cells(start..<min(start + 3, items.count))) }
        let metrics = GridMetrics(lines: lines, columns: PickSession.tileColumns)
        let side = Self.side

        // The top of the panel: row 1, and a part of row 2 (from 201 to 346 points, the grid is 310 high).
        let top = NSRect(x: 0, y: 0, width: 460, height: 310)
        #expect(metrics.playing(in: top, items: items) == [0, 2, 3, 4, 5])
        // A scroll of 2 points less than the bottom of row 1: its tiles still play. At its bottom: they stop.
        let row1Bottom = 4 + GridMetrics.titleHeight + side
        #expect(metrics.playing(in: top.offsetBy(dx: 0, dy: row1Bottom - 2), items: items).prefix(2) == [0, 2])
        #expect(!metrics.playing(in: top.offsetBy(dx: 0, dy: row1Bottom), items: items).contains(0))
        // A tall rect: only the first 15 in the order of the grid.
        let all = metrics.playing(in: NSRect(x: 0, y: 0, width: 460, height: 10_000), items: items)
        #expect(all.count == GridMetrics.playingLimit && GridMetrics.playingLimit == 15)
        #expect(all == [0, 2] + Array(3..<16))
        // At most 4 rows show in the 310 points of the grid, so 15 views are enough.
        for y in stride(from: CGFloat(0), to: metrics.height, by: 7) {
            #expect(metrics.playing(in: top.offsetBy(dx: 0, dy: y), items: items).count <= 12)
        }
        // The Emoji tab: nothing plays.
        let emojis = GridMetrics(lines: [.cells(0..<9)], columns: PickSession.columns)
        #expect(emojis.playing(in: top, items: smallCatalog(9).map(PickItem.emoji)).isEmpty)
        #expect(!Self.meme("m").plays && Self.gif("g").plays)
    }

    /// The cut-off title of Yaseen's screenshot: after a scroll down, the blue box goes back to the first row of
    /// "From KLIPY". The old rule (the cell and half a title) stopped the scroll at 17 points, so the top of the title
    /// text (from 11 points) was under the tab bar. Now the title above the row is all in sight.
    @Test func aMoveUpShowsAllOfTheTitleAboveTheRow() throws {
        let side = Self.side
        let lines: [PickSession.Line] = [.title("From KLIPY"), .cells(0..<3), .cells(3..<6), .cells(6..<9), .cells(9..<12)]
        let metrics = GridMetrics(lines: lines, columns: PickSession.tileColumns)
        let down = NSRect(x: 0, y: 400, width: 460, height: 310)
        let first = try #require(metrics.rect(of: 0))
        #expect(metrics.scrollTop(showing: first.insetBy(dx: 0, dy: -GridMetrics.titleHeight / 2), in: down) == 17)
        #expect(metrics.scrollTop(showing: try #require(metrics.scrollRect(of: 1)), in: down) == 0)

        // A row in the middle: half a title above and below, as before. No scroll when it is in sight.
        let middle = try #require(metrics.scrollRect(of: 4))
        #expect(middle.minY == 30 + side - GridMetrics.titleHeight / 2 && middle.maxY == 30 + 2 * side + GridMetrics.titleHeight / 2)
        #expect(metrics.scrollTop(showing: middle, in: NSRect(x: 0, y: 100, width: 460, height: 310)) == 100)
        // A move down to the last row: the smallest scroll, and never past the end of the grid.
        let last = try #require(metrics.scrollRect(of: 10))
        #expect(metrics.scrollTop(showing: last, in: NSRect(x: 0, y: 0, width: 460, height: 310)) == metrics.height - 310)

        // "Yours" and "From KLIPY": a move up to the first KLIPY row shows the title "From KLIPY".
        let two = GridMetrics(lines: [.title("Yours"), .cells(0..<3), .title("From KLIPY"), .cells(3..<6), .cells(6..<9)],
                              columns: PickSession.tileColumns)
        let fromKlipy = try #require(two.scrollRect(of: 3))
        #expect(fromKlipy.minY == two.tops[2])
        #expect(two.scrollTop(showing: fromKlipy, in: NSRect(x: 0, y: 400, width: 460, height: 310)) == two.tops[2])
        // Two titles above the first row (a grey line and a section): both show.
        let notice = GridMetrics(lines: [.title("Getting the GIF…"), .title("From KLIPY"), .cells(0..<3)], columns: 3)
        #expect(notice.scrollRect(of: 2)?.minY == 0)
    }

    /// Your own GIFs: at most 4 loads at a time from the files, and at most 30 moving pictures in memory, the newest kept.
    @Test func theOwnMovingPicturesKeepAtMost30() async throws {
        let folder = try TempFolder()
        var urls: [URL] = []
        for place in 0..<40 {
            let url = folder.url.appendingPathComponent("\(place).gif")
            try makeTestImage(width: 20 + place, height: 20, type: .gif, frames: 2).write(to: url)
            urls.append(url)
        }
        let pictures = MovingPictures(kept: EmojiGridView.ownMovingKept, atOnce: EmojiGridView.ownMovingAtOnce,
                                      load: { try Data(contentsOf: $0) })
        var most = 0
        pictures.onLoad = { most = max(most, pictures.loading.count + 1) }
        pictures.want(urls)
        #expect(pictures.loading == Set(urls[0..<4]))
        await waitUntil { pictures.loading.isEmpty }
        #expect(most <= 4 && EmojiGridView.ownMovingAtOnce == 4)
        let kept = urls.filter { pictures.image(for: $0) != nil }
        #expect(kept.count == EmojiGridView.ownMovingKept && EmojiGridView.ownMovingKept == 30)
        #expect(kept.contains(urls[39]) && !kept.contains(urls[0]))
        #expect(pictures.image(for: urls[39])?.size == NSSize(width: 59, height: 20))
    }

    /// The pool: each GIF tile on the screen gets a moving view, at most 15. A scroll gives the views to the new tiles.
    /// A view shows only when its picture is in memory (the still picture shows until then). The views let the mouse
    /// through, the blue box lies above them, and all stop and hide when the panel hides.
    @Test func thePoolPlaysTheTilesOnTheScreen() async throws {
        let rig = try PickRig()
        for seed in 0..<30 { try rig.addOwn(words: ["gif"], seed: seed) }
        rig.session.open()
        rig.session.select(tab: .gifs)
        let grid = EmojiGridView(session: rig.session)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: SearchPanelController.gridHeight))
        scrollView.documentView = grid
        grid.reload()
        // The panel does not show yet: nothing plays.
        #expect(grid.movingViews.isEmpty)

        grid.startPlaying()
        // "Your GIFs": row 1 and a part of row 2 are on the screen.
        let first = Array(0..<6)
        #expect(grid.movingViews.compactMap { $0.slot?.index }.sorted() == first)
        #expect(grid.movingViews.allSatisfy { !$0.isPlaying })
        await waitUntil { grid.movingViews.allSatisfy(\.isPlaying) }
        #expect(grid.movingViews.allSatisfy { $0.isPlaying })
        for view in grid.movingViews {
            let index = try #require(view.slot?.index)
            #expect(view.frame == EmojiGridView.tileRect(try #require(GridMetrics(lines: rig.session.lines, columns: 3).rect(of: index))))
            #expect(view.hitTest(NSPoint(x: view.frame.midX, y: view.frame.midY)) == nil)
        }
        // The blue box of the tile lies above the moving views.
        #expect(!(grid.subviews.last is MovingTileView) && grid.subviews.last?.isHidden == false)

        // A scroll down: the views go to the new tiles, and the pool stays at 15 or fewer.
        for y in stride(from: CGFloat(100), through: grid.frame.height, by: 100) {
            grid.scroll(NSPoint(x: 0, y: y))
            grid.visibleRectChanged()
            let metrics = GridMetrics(lines: rig.session.lines, columns: 3)
            let wanted = metrics.playing(in: grid.visibleRect, items: rig.session.items)
            #expect(grid.movingViews.compactMap { $0.slot?.index }.sorted() == wanted)
            #expect(grid.movingViews.count <= GridMetrics.playingLimit)
        }
        // The panel hides: each view stops, and the loads stop.
        grid.stopPlaying()
        #expect(grid.movingViews.allSatisfy { $0.isHidden && $0.slot == nil && !$0.isPlaying })
        #expect(grid.ownMoving.loading.isEmpty)
        // It shows again at the top: the pictures in memory play at once.
        grid.scroll(.zero)
        grid.startPlaying()
        #expect(grid.movingViews.filter(\.isPlaying).compactMap { $0.slot?.index }.sorted() == first)
    }
}
