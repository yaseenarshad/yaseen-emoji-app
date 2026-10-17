import AppKit

/// The sizes of the grid, in points (D7; D11 of YAZ-2919). A pure struct, so a test can check the places.
@MainActor
struct GridMetrics {
    /// The space on the left and the right of the grid.
    static let inset: CGFloat = 12
    static let titleHeight: CGFloat = 26

    /// The side of one cell when `columns` cells fill the width of the 460 points panel:
    /// about 48 points for 9 emojis, about 145 points for 3 tiles.
    static func cellSize(columns: Int) -> CGFloat {
        (SearchPanelController.width - 2 * inset) / CGFloat(columns)
    }

    let lines: [PickSession.Line]
    let cellSize: CGFloat
    /// The top of each line, and the full height.
    let tops: [CGFloat]
    let height: CGFloat
    /// The line of each item of `items`.
    let lineOfItem: [Int]

    init(lines: [PickSession.Line], columns: Int) {
        self.lines = lines
        let cellSize = GridMetrics.cellSize(columns: columns)
        self.cellSize = cellSize
        var tops: [CGFloat] = []
        var lineOfItem: [Int] = []
        tops.reserveCapacity(lines.count)
        var y: CGFloat = 4
        for (place, line) in lines.enumerated() {
            tops.append(y)
            switch line {
            case .title: y += GridMetrics.titleHeight
            case .cells(let range):
                y += cellSize
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
            if tops[middle] + cellSize < y { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The cell of the item at `index`.
    func rect(of index: Int) -> NSRect? {
        guard lineOfItem.indices.contains(index) else { return nil }
        let line = lineOfItem[index]
        guard case .cells(let range) = lines[line] else { return nil }
        return NSRect(x: GridMetrics.inset + CGFloat(index - range.lowerBound) * cellSize, y: tops[line],
                      width: cellSize, height: cellSize)
    }

    /// The item below a point of the grid, or nil on a title or a gap.
    func index(at point: NSPoint) -> Int? {
        let line = max(0, firstLine(below: point.y) - 1)
        for place in line..<min(line + 3, lines.count) {
            guard case .cells(let range) = lines[place] else { continue }
            let top = tops[place]
            guard point.y >= top, point.y < top + cellSize else { continue }
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
}

/// Lets the mouse through to the grid below: the moving tile must not take a click, a drag or a right-click.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The grid (D7; D11 of YAZ-2919): the titles, the emojis in rows of 9 or the tiles in rows of 3, and the blue box.
///
/// One view draws the lines that are on the screen. It has no view for each emoji or tile, so a key press
/// does not make 1,914 views again: it reads the new lines of the session and draws again.
/// Only the tile with the blue box moves: one `NSImageView` over that tile (D11).
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

    /// The moving picture of the tile with the blue box: a view with round corners and the blue border, and the GIF in it.
    private let movingBox = PassThroughView()
    private let movingImage = NSImageView()
    /// The key of the item whose GIF is in `movingImage`, or loads.
    private var movingKey: String?

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
        movingBox.wantsLayer = true
        movingBox.layer?.cornerRadius = EmojiGridView.tileRadius
        movingBox.layer?.masksToBounds = true
        movingBox.layer?.borderWidth = EmojiGridView.tileBorder
        movingBox.isHidden = true
        movingImage.animates = true
        movingImage.imageScaling = .scaleAxesIndependently
        movingBox.addSubview(movingImage)
        addSubview(movingBox)
        session.thumbnails?.onLoad = { [weak self] _ in
            guard let self else { return }
            setNeedsDisplay(visibleRect)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// New lines: a new size, and all draws again. The list goes to the top, with the blue box in sight.
    func reload() {
        metrics = GridMetrics(lines: session.lines, columns: session.columnCount)
        let visible = enclosingScrollView?.contentSize ?? bounds.size
        setFrameSize(NSSize(width: visible.width, height: max(metrics.height, visible.height)))
        needsDisplay = true
        drawnSelection = nil
        scroll(.zero)
        showSelection()
    }

    /// The blue box moved: only the two cells draw again, and the list scrolls so the blue box is in sight.
    func showSelection() {
        if let old = drawnSelection, let rect = metrics.rect(of: old) { setNeedsDisplay(rect) }
        drawnSelection = session.selection
        if let selection = session.selection, let rect = metrics.rect(of: selection) {
            setNeedsDisplay(rect)
            // The title above the first row shows too.
            scrollToVisible(rect.insetBy(dx: 0, dy: -GridMetrics.titleHeight / 2))
        }
        showMovingTile()
    }

    // MARK: The tile that moves (D11)

    /// Puts the GIF of the tile with the blue box over that tile, or hides it. No other tile decodes the full GIF.
    private func showMovingTile() {
        guard let selection = session.selection, let cell = metrics.rect(of: selection) else { return hideMovingTile() }
        let item = session.items[selection]
        movingBox.frame = EmojiGridView.tileRect(cell)
        movingBox.layer?.borderColor = NSColor.controlAccentColor.cgColor
        guard item.key != movingKey else { return }
        hideMovingTile()
        switch item {
        case .own(let own) where own.kind == .gif && !isMissing(own):
            guard let url = session.library.fileURL(of: own) else { return }
            movingKey = item.key
            // The bytes load off the main thread. `NSImage` decodes the frames while it plays.
            Task { [weak self] in
                let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
                guard let self, self.movingKey == item.key, let data, let image = NSImage(data: data) else { return }
                self.play(image)
            }
        case .online(let online):
            guard let image = session.online?.moving(for: online) else { return }
            movingKey = item.key
            play(image)
        default:
            return
        }
    }

    private func play(_ image: NSImage) {
        movingImage.image = image
        // Aspect-fill: the short side fills the tile, and the box cuts the long side.
        let box = movingBox.bounds.size
        let size = image.size.width > 0 && image.size.height > 0 ? image.size : box
        let scale = max(box.width / size.width, box.height / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        movingImage.frame = NSRect(x: (box.width - drawn.width) / 2, y: (box.height - drawn.height) / 2,
                                   width: drawn.width, height: drawn.height)
        movingBox.isHidden = false
    }

    private func hideMovingTile() {
        movingKey = nil
        movingImage.image = nil
        movingBox.isHidden = true
    }

    // MARK: Drawing

    /// The tile inside its cell.
    static func tileRect(_ cell: NSRect) -> NSRect {
        cell.insetBy(dx: tileInset, dy: tileInset)
    }

    /// True when the file of your item is not there: a grey tile, and a pick does nothing (D4 of YAZ-2919).
    private func isMissing(_ item: Item) -> Bool {
        session.library.mediaFolderIsMissing || session.library.missing.contains(item.id)
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
            let image = isMissing(own) ? nil : session.thumbnails?.image(own.id)
            drawTile(image, in: cell, selected: selected)
        case .online(let online):
            drawTile(session.online?.still(for: online), in: cell, selected: selected)
            drawMark(in: EmojiGridView.tileRect(cell))
        }
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

    /// A tile: the still picture with round corners, or a grey tile with no text (a missing file, or while it loads).
    /// The still picture is a square already (D5), so it fills the tile.
    private func drawTile(_ image: NSImage?, in cell: NSRect, selected: Bool) {
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
        if selected {
            let border = NSBezierPath(roundedRect: tile.insetBy(dx: EmojiGridView.tileBorder / 2, dy: EmojiGridView.tileBorder / 2),
                                      xRadius: EmojiGridView.tileRadius, yRadius: EmojiGridView.tileRadius)
            border.lineWidth = EmojiGridView.tileBorder
            NSColor.controlAccentColor.setStroke()
            border.stroke()
        }
    }

    /// The small "KLIPY" mark of a KLIPY tile (D11 of YAZ-2919).
    private func drawMark(in tile: NSRect) {
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
        let near = visibleRect.insetBy(dx: 0, dy: -metrics.cellSize)
        let wants = metrics.items(in: near).compactMap { index -> Thumbnails.Want? in
            guard case .own(let own) = session.items[index], !isMissing(own), let file = session.library.fileURL(of: own)
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

    /// The right-click menu: the items of `PickSession.menuActions(at:)` (D15, D17).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = metrics.index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        session.select(index)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for action in session.menuActions(at: index) {
            let selector: Selector
            switch action {
            case .addWord: selector = #selector(addWord)
            case .copyOnly: selector = #selector(copyOnly)
            case .hideFromMostUsed: selector = #selector(hideFromMostUsed)
            default: continue
            }
            let item = NSMenuItem(title: action.title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func addWord() {
        guard let item = session.selectedItem else { return }
        session.addWord(for: item)
    }

    @objc private func copyOnly() { session.copyOnly() }

    @objc private func hideFromMostUsed() {
        guard let item = session.selectedItem else { return }
        session.hideFromMostUsed(item: item)
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }
}
