import AppKit

/// The sizes of the grid, in points (D7; D11 of YAZ-2919). A pure struct, so a test can check the places.
@MainActor
struct GridMetrics {
    /// The space on the left and the right of the grid.
    static let inset: CGFloat = 12
    static let titleHeight: CGFloat = 26
    /// The line of text below each GIF and meme tile (D15 of YAZ-2919). The Emoji tab has none.
    static let labelHeight: CGFloat = 16

    /// The side of one cell when `columns` cells fill the width of the 460 points panel:
    /// about 48 points for 9 emojis, about 145 points for 3 tiles.
    static func cellSize(columns: Int) -> CGFloat {
        (SearchPanelController.width - 2 * inset) / CGFloat(columns)
    }

    let lines: [PickSession.Line]
    /// The width of a cell, and the side of the square of its picture.
    let cellSize: CGFloat
    /// The height of a row of cells: the side of the cell, and the line of text below a tile.
    let rowHeight: CGFloat
    /// The top of each line, and the full height.
    let tops: [CGFloat]
    let height: CGFloat
    /// The line of each item of `items`.
    let lineOfItem: [Int]

    init(lines: [PickSession.Line], columns: Int) {
        self.lines = lines
        let cellSize = GridMetrics.cellSize(columns: columns)
        self.cellSize = cellSize
        let rowHeight = cellSize + (columns == PickSession.columns ? 0 : GridMetrics.labelHeight)
        self.rowHeight = rowHeight
        var tops: [CGFloat] = []
        var lineOfItem: [Int] = []
        tops.reserveCapacity(lines.count)
        var y: CGFloat = 4
        for (place, line) in lines.enumerated() {
            tops.append(y)
            switch line {
            case .title: y += GridMetrics.titleHeight
            case .cells(let range):
                y += rowHeight
                lineOfItem += Array(repeating: place, count: range.count)
            }
        }
        self.tops = tops
        self.lineOfItem = lineOfItem
        height = y + 8
    }

    /// The first line that reaches below `y`: a binary search, so a scroll does not walk all lines.
    func firstLine(below y: CGFloat) -> Int {
        var low = 0
        var high = tops.count
        while low < high {
            let middle = (low + high) / 2
            if tops[middle] + rowHeight < y { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The cell of the item at `index`: its picture, and the line of text below a tile.
    func rect(of index: Int) -> NSRect? {
        guard lineOfItem.indices.contains(index) else { return nil }
        let line = lineOfItem[index]
        guard case .cells(let range) = lines[line] else { return nil }
        return NSRect(x: GridMetrics.inset + CGFloat(index - range.lowerBound) * cellSize, y: tops[line],
                      width: cellSize, height: rowHeight)
    }

    /// The item below a point of the grid, or nil on a title or a gap.
    func index(at point: NSPoint) -> Int? {
        let line = max(0, firstLine(below: point.y) - 1)
        for place in line..<min(line + 3, lines.count) {
            guard case .cells(let range) = lines[place] else { continue }
            let top = tops[place]
            guard point.y >= top, point.y < top + rowHeight else { continue }
            let column = Int((point.x - GridMetrics.inset) / cellSize)
            guard point.x >= GridMetrics.inset, column >= 0, column < range.count else { return nil }
            return range.lowerBound + column
        }
        return nil
    }

    /// The items of the lines that reach into `rect`, first to last.
    func items(in rect: NSRect) -> [Int] {
        var result: [Int] = []
        var place = firstLine(below: rect.minY)
        while place < lines.count, tops[place] <= rect.maxY {
            if case .cells(let range) = lines[place] { result += range }
            place += 1
        }
        return result
    }

    /// The most GIF tiles that play at the same time: 3 columns × 5 rows (D11 update on YAZ-2925).
    /// The grid is 310 points high, so at most 3 rows of 161 points (the tile and its line of text) show.
    static let playingLimit = 15

    /// The GIF tiles that play (D11 update on YAZ-2925): each GIF whose cell reaches into `visible` (a part of a tile
    /// counts), in the order of the grid, at most `playingLimit`. Memes and emojis never play.
    func playing(in visible: NSRect, items: [PickItem]) -> [Int] {
        var result: [Int] = []
        for index in self.items(in: visible) where items.indices.contains(index) && items[index].plays {
            guard let cell = rect(of: index), cell.intersects(visible) else { continue }
            result.append(index)
            if result.count == GridMetrics.playingLimit { break }
        }
        return result
    }

    /// The part of the grid that must be in sight when the blue box is on `index`: the cell, all of the titles right
    /// above its row, and half a title below. The first row of the grid goes to the very top.
    /// Without the titles, a move up to the first row showed only the bottom half of "From KLIPY".
    func scrollRect(of index: Int) -> NSRect? {
        guard let cell = rect(of: index) else { return nil }
        var line = lineOfItem[index]
        var top = cell.minY - GridMetrics.titleHeight / 2
        while line > 0, case .title = lines[line - 1] {
            line -= 1
            top = tops[line]
        }
        if line == 0 { top = 0 }
        return NSRect(x: cell.minX, y: top, width: cell.width, height: cell.maxY + GridMetrics.titleHeight / 2 - top)
    }

    /// The top of the visible part after the smallest scroll that shows `rect`, as `scrollToVisible` does.
    /// It stays in the grid: from 0 to `height` minus the visible height.
    func scrollTop(showing rect: NSRect, in visible: NSRect) -> CGFloat {
        var top = visible.minY
        if rect.maxY > visible.maxY { top = rect.maxY - visible.height }
        if rect.minY < top { top = rect.minY }
        return min(max(0, top), max(0, height - visible.height))
    }
}

/// Lets the mouse through to the grid below: a moving tile must not take a click, a drag or a right-click.
class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The grid (D7; D11 of YAZ-2919): the titles, the emojis in rows of 9 or the tiles in rows of 3, and the blue box.
///
/// One view draws the lines that are on the screen. It has no view for each emoji or tile, so a key press
/// does not make 1,914 views again: it reads the new lines of the session and draws again.
/// Each GIF tile on the screen plays (D11 update on YAZ-2925): a pool of at most 15 `MovingTileView`s over the tiles.
@MainActor
final class EmojiGridView: NSView, NSMenuDelegate {
    private let session: PickSession
    private var metrics = GridMetrics(lines: [], columns: PickSession.columns)
    /// The blue box of the last draw, so a move draws only the old and the new cell again.
    private var drawnSelection: Int?
    /// The item of the last mouse-down. A mouse-up on the same item is a click.
    private var pressed: Int?
    /// The point of the last mouse-down, in the window, also on a title or a gap. Nil after a drag starts.
    private var downPoint: NSPoint?
    /// True while the right-click menu is open. The panel must not close then.
    private(set) var menuIsOpen = false

    /// The moving views over the GIF tiles on the screen, at most `GridMetrics.playingLimit`. A free view is hidden.
    private(set) var movingViews: [MovingTileView] = []
    /// The moving pictures of your own GIF files (D11 update on YAZ-2925).
    let ownMoving = MovingPictures(kept: EmojiGridView.ownMovingKept, atOnce: EmojiGridView.ownMovingAtOnce,
                                   load: { try Data(contentsOf: $0) })
    /// The blue box of a tile: a border above the moving views.
    private let tileBorder = PassThroughView()
    /// True while the panel shows. The GIFs play only then.
    private(set) var isPlaying = false

    /// The moving pictures of your own GIFs in memory, and the loads at the same time.
    static let ownMovingKept = 30
    static let ownMovingAtOnce = 4

    private static let emojiFont = NSFont.systemFont(ofSize: 30)
    private static let emojiLineHeight = ceil(emojiFont.ascender - emojiFont.descender + emojiFont.leading)
    private static let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
    private static let emojiAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return [.font: emojiFont, .paragraphStyle: paragraph]
    }()
    /// The text below a tile (D15 of YAZ-2919): one line, secondary color, cut with "…".
    private static let labelAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
    }()
    private static let markAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    /// The space between a tile and the edge of its cell, and the corners of a tile.
    static let tileInset: CGFloat = 4
    static let tileRadius: CGFloat = 8
    static let tileBorder: CGFloat = 3

    init(session: PickSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: SearchPanelController.width, height: 10))
        tileBorder.wantsLayer = true
        tileBorder.layer?.cornerRadius = EmojiGridView.tileRadius
        tileBorder.layer?.borderWidth = EmojiGridView.tileBorder
        tileBorder.isHidden = true
        addSubview(tileBorder)
        session.thumbnails?.onLoad = { [weak self] _ in
            guard let self else { return }
            setNeedsDisplay(visibleRect)
        }
        ownMoving.onLoad = { [weak self] in self?.updateMovingTiles() }
        // A KLIPY still or moving picture came (D11 of YAZ-2919).
        session.online?.onPicture = { [weak self] in
            guard let self else { return }
            setNeedsDisplay(visibleRect)
            updateMovingTiles()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// New lines: a new size, and all draws again. The list goes to the top, with the blue box in sight.
    /// With `keepingScroll` (new KLIPY results, D11 of YAZ-2919), the list stays where you scrolled it.
    func reload(keepingScroll: Bool = false) {
        metrics = GridMetrics(lines: session.lines, columns: session.columnCount)
        let visible = enclosingScrollView?.contentSize ?? bounds.size
        setFrameSize(NSSize(width: visible.width, height: max(metrics.height, visible.height)))
        needsDisplay = true
        drawnSelection = nil
        if keepingScroll {
            drawnSelection = session.selection
            showTileBorder()
            updateMovingTiles()
        } else {
            scroll(.zero)
            showSelection()
        }
    }

    /// True when the bottom of the list is in sight, or less than two rows away: time for the next KLIPY page.
    var isNearEnd: Bool {
        visibleRect.maxY >= bounds.height - 2 * metrics.rowHeight
    }

    /// The blue box moved: only the two cells draw again, and the list scrolls so the blue box is in sight,
    /// with the titles above its row (`GridMetrics.scrollRect(of:)`).
    func showSelection() {
        if let old = drawnSelection, let rect = metrics.rect(of: old) { setNeedsDisplay(rect) }
        drawnSelection = session.selection
        if let selection = session.selection, let rect = metrics.rect(of: selection) {
            setNeedsDisplay(rect)
            if let wanted = metrics.scrollRect(of: selection) {
                let visible = visibleRect
                let top = metrics.scrollTop(showing: wanted, in: visible)
                if top != visible.minY { scroll(NSPoint(x: 0, y: top)) }
            }
        }
        showTileBorder()
        updateMovingTiles()
    }

    /// The scroll view moved the grid: other tiles are on the screen now.
    func visibleRectChanged() {
        updateMovingTiles()
    }

    // MARK: The tiles that move (D11 update on YAZ-2925)

    /// The panel shows: the GIFs on the screen play.
    func startPlaying() {
        isPlaying = true
        updateMovingTiles()
    }

    /// The panel hides: each moving view stops and hides, and the loads stop. The pictures in memory stay.
    func stopPlaying() {
        isPlaying = false
        updateMovingTiles()
    }

    /// The blue box of a tile is a border above the moving views. An emoji draws its own blue box.
    private func showTileBorder() {
        guard let selection = session.selection, session.items.indices.contains(selection),
              session.items[selection].emoji == nil, let cell = metrics.rect(of: selection) else {
            tileBorder.isHidden = true
            return
        }
        tileBorder.frame = EmojiGridView.tileRect(cell)
        tileBorder.layer?.borderColor = NSColor.controlAccentColor.cgColor
        tileBorder.isHidden = false
    }

    /// The URL of the moving picture of a GIF tile: your file, or the KLIPY preview.
    private func movingURL(of item: PickItem) -> URL? {
        switch item {
        case .own(let own): return session.library.fileURL(of: own)
        case .online(let online): return online.preview
        case .emoji: return nil
        }
    }

    /// Gives the GIF tiles on the screen a moving view, and frees the views of the tiles that left.
    /// A view keeps its tile when the tile still plays, so a scroll does not start a GIF again.
    /// A view stays hidden until its picture is in memory: the still picture shows until then.
    func updateMovingTiles() {
        let items = session.items
        var wanted: [(index: Int, url: URL)] = []
        if isPlaying {
            for index in metrics.playing(in: visibleRect, items: items) {
                if let url = movingURL(of: items[index]) { wanted.append((index, url)) }
            }
        }
        // The loads: in the order of the grid. The loads of the tiles that left stop.
        func online(_ index: Int) -> OnlineItem? {
            if case .online(let item) = items[index] { return item }
            return nil
        }
        ownMoving.want(wanted.filter { online($0.index) == nil }.map(\.url))
        session.online?.wantMoving(wanted.compactMap { online($0.index) })

        var open = wanted
        var free: [MovingTileView] = []
        for view in movingViews {
            if let slot = view.slot, let place = open.firstIndex(where: { $0.index == slot.index && $0.url == slot.url }) {
                open.remove(at: place)
            } else {
                free.append(view)
            }
        }
        for tile in open {
            // A free view with the same picture only moves. Else a free view, or a new one up to the limit.
            let view: MovingTileView
            if let same = free.firstIndex(where: { $0.slot?.url == tile.url }) {
                view = free.remove(at: same)
            } else if !free.isEmpty {
                view = free.removeFirst()
                view.clear()
            } else if movingViews.count < GridMetrics.playingLimit {
                view = MovingTileView(frame: .zero)
                movingViews.append(view)
                addSubview(view, positioned: .below, relativeTo: tileBorder)
            } else {
                break
            }
            view.slot = tile
            guard let cell = metrics.rect(of: tile.index) else { continue }
            view.place(EmojiGridView.tileRect(cell), isKlipy: online(tile.index) != nil)
        }
        for view in free { view.clear() }
        // Each view whose picture is in memory plays.
        for view in movingViews {
            guard let slot = view.slot else { continue }
            let image: NSImage?
            if let item = online(slot.index) {
                image = session.online?.moving(for: item)
            } else {
                image = ownMoving.image(for: slot.url)
            }
            if let image { view.play(image) }
        }
    }

    // MARK: Drawing

    /// The picture of a tile: the square at the top of its cell, inside the inset.
    static func tileRect(_ cell: NSRect) -> NSRect {
        NSRect(x: cell.minX, y: cell.minY, width: cell.width, height: cell.width).insetBy(dx: tileInset, dy: tileInset)
    }

    /// The line of text below the picture of a tile (D15 of YAZ-2919).
    static func labelRect(_ cell: NSRect) -> NSRect {
        NSRect(x: cell.minX + tileInset, y: cell.minY + cell.width - 1, width: cell.width - 2 * tileInset,
               height: GridMetrics.labelHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let lines = session.lines
        guard !lines.isEmpty else { return }
        var place = metrics.firstLine(below: dirtyRect.minY)
        while place < lines.count, metrics.tops[place] <= dirtyRect.maxY {
            let top = metrics.tops[place]
            switch lines[place] {
            case .title(let text):
                let rect = NSRect(x: GridMetrics.inset + 4, y: top + 7, width: bounds.width - 2 * GridMetrics.inset - 8,
                                  height: GridMetrics.titleHeight - 7)
                (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: EmojiGridView.titleAttributes)
            case .cells(let range):
                for index in range {
                    guard let cell = metrics.rect(of: index) else { continue }
                    draw(session.items[index], in: cell, selected: index == session.selection)
                }
            }
            place += 1
        }
        askForStills()
    }

    private func draw(_ item: PickItem, in cell: NSRect, selected: Bool) {
        switch item {
        case .emoji(let emoji):
            if selected { drawBlueBox(in: cell) }
            let textRect = NSRect(x: cell.minX, y: cell.minY + (cell.height - EmojiGridView.emojiLineHeight) / 2,
                                  width: cell.width, height: EmojiGridView.emojiLineHeight)
            (session.shown(emoji) as NSString)
                .draw(with: textRect, options: .usesLineFragmentOrigin, attributes: EmojiGridView.emojiAttributes)
        case .own(let own):
            drawTile(session.thumbnails?.image(own.id), in: cell)
            drawLabel(of: item, in: cell)
        case .online(let online):
            drawTile(session.online?.still(for: online), in: cell)
            EmojiGridView.drawMark(in: EmojiGridView.tileRect(cell))
            drawLabel(of: item, in: cell)
        }
    }

    /// The title of a tile, else its first 3 words, or KLIPY's title (`PickSession.label(of:)`).
    private func drawLabel(of item: PickItem, in cell: NSRect) {
        let text = PickSession.label(of: item)
        guard !text.isEmpty else { return }
        (text as NSString).draw(with: EmojiGridView.labelRect(cell), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: EmojiGridView.labelAttributes)
    }

    /// The blue box: the accent colour of the Mac, which is blue unless the user changed it.
    private func drawBlueBox(in cell: NSRect) {
        let path = NSBezierPath(roundedRect: cell.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    /// A tile: the still picture with round corners, or a grey tile with no text while it loads, or for a file with no picture.
    /// The still picture is a square already (D5), so it fills the tile. The blue box of a tile is `tileBorder`,
    /// above the moving view.
    private func drawTile(_ image: NSImage?, in cell: NSRect) {
        let tile = EmojiGridView.tileRect(cell)
        let path = NSBezierPath(roundedRect: tile, xRadius: EmojiGridView.tileRadius, yRadius: EmojiGridView.tileRadius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image {
            image.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor.quaternaryLabelColor.setFill()
            tile.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The small "KLIPY" mark of a KLIPY tile (D11 of YAZ-2919). The moving view draws it too, above the GIF.
    static func drawMark(in tile: NSRect) {
        let text = "KLIPY" as NSString
        let size = text.size(withAttributes: EmojiGridView.markAttributes)
        let box = NSRect(x: tile.minX + 6, y: tile.maxY - size.height - 10, width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: EmojiGridView.markAttributes)
    }

    /// Asks for the still pictures of the tiles on the screen, and of one row above and below.
    private func askForStills() {
        guard let thumbnails = session.thumbnails, session.tab != .emoji else { return }
        let near = visibleRect.insetBy(dx: 0, dy: -metrics.rowHeight)
        let wants = metrics.items(in: near).compactMap { index -> Thumbnails.Want? in
            guard case .own(let own) = session.items[index], let file = session.library.fileURL(of: own)
            else { return nil }
            return Thumbnails.Want(id: own.id, file: file)
        }
        thumbnails.want(wants)
    }

    // MARK: The mouse

    /// A move of more than this many points is a drag of the panel, not a click (D14).
    static let dragDistance: CGFloat = 4

    /// True when the mouse moved more than `dragDistance` points from the mouse-down (D14).
    static func isDrag(from start: NSPoint, to end: NSPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) > dragDistance
    }

    /// AppKit must not move the panel on a mouse-down here: then a click could not pick.
    /// The view starts the drag itself, after a real move (D14).
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        pressed = metrics.index(at: convert(event.locationInWindow, from: nil))
        if let pressed { session.select(pressed) }
    }

    /// Press and move anywhere on the grid drags the panel: an emoji, a title or a gap (D14).
    /// macOS moves the panel until the mouse-up, so the mouse-up never picks.
    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, EmojiGridView.isDrag(from: start, to: event.locationInWindow) else { return }
        downPoint = nil
        pressed = nil
        window?.performDrag(with: event)
    }

    /// A click with no move is the same as Enter (D8).
    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            downPoint = nil
        }
        guard let pressed, metrics.index(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        session.pick(stayOpen: false)
    }

    /// The right-click menu: the items of `PickSession.menuActions(at:)` (D15, D17; D13 of YAZ-2919).
    /// On a gap or a title of the GIFs and Memes tabs: "Add a GIF or meme…" (D12 of YAZ-2919).
    override func menu(for event: NSEvent) -> NSMenu? {
        let actions: [PickSession.MenuAction]
        if let index = metrics.index(at: convert(event.locationInWindow, from: nil)) {
            session.select(index)
            actions = session.menuActions(at: index)
        } else {
            actions = session.menuActionsOutsideItems
        }
        guard !actions.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for action in actions {
            if action == .addNew, !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: action.title, action: #selector(runAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuActionBox(action)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MenuActionBox else { return }
        session.perform(box.action)
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }
}

/// One action of the right-click menu, in `NSMenuItem.representedObject`.
final class MenuActionBox: NSObject {
    let action: PickSession.MenuAction

    init(_ action: PickSession.MenuAction) {
        self.action = action
    }
}
