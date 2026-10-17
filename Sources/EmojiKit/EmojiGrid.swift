import AppKit

/// The sizes of the grid, in points (D7). A pure struct, so a test can check the places.
@MainActor
struct GridMetrics {
    /// The space on the left and the right of the grid.
    static let inset: CGFloat = 12
    static let titleHeight: CGFloat = 26
    /// 9 cells fill the width of the 460 points panel.
    static let cellSize = (SearchPanelController.width - 2 * inset) / CGFloat(PickSession.columns)

    /// The top of each line, and the full height.
    let tops: [CGFloat]
    let height: CGFloat
    /// The line of each emoji of `items`.
    let lineOfItem: [Int]

    init(lines: [PickSession.Line]) {
        var tops: [CGFloat] = []
        var lineOfItem: [Int] = []
        tops.reserveCapacity(lines.count)
        var y: CGFloat = 4
        for (place, line) in lines.enumerated() {
            tops.append(y)
            switch line {
            case .title: y += GridMetrics.titleHeight
            case .cells(let range):
                y += GridMetrics.cellSize
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
            if tops[middle] + GridMetrics.cellSize < y { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// The emoji grid (D7): the titles, the emojis in rows of 9, and the blue box.
///
/// One view draws the lines that are on the screen. It has no view for each emoji, so a key press
/// does not make 1,914 views again: it reads the new lines of the session and draws again.
@MainActor
final class EmojiGridView: NSView, NSMenuDelegate {
    private let session: PickSession
    private var metrics = GridMetrics(lines: [])
    /// The blue box of the last draw, so a move draws only the old and the new cell again.
    private var drawnSelection: Int?
    /// The emoji of the last mouse-down. A mouse-up on the same emoji is a click.
    private var pressed: Int?
    /// The point of the last mouse-down, in the window, also on a title or a gap. Nil after a drag starts.
    private var downPoint: NSPoint?
    /// True while the right-click menu is open. The panel must not close then.
    private(set) var menuIsOpen = false

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

    init(session: PickSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: SearchPanelController.width, height: 10))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// New lines: a new size, and all draws again. The list goes to the top, with the blue box in sight.
    func reload() {
        metrics = GridMetrics(lines: session.lines)
        let visible = enclosingScrollView?.contentSize ?? bounds.size
        setFrameSize(NSSize(width: visible.width, height: max(metrics.height, visible.height)))
        needsDisplay = true
        drawnSelection = nil
        scroll(.zero)
        showSelection()
    }

    /// The blue box moved: only the two cells draw again, and the list scrolls so the blue box is in sight.
    func showSelection() {
        if let old = drawnSelection, let rect = cellRect(old) { setNeedsDisplay(rect) }
        drawnSelection = session.selection
        if let selection = session.selection, let rect = cellRect(selection) {
            setNeedsDisplay(rect)
            // The title above the first row shows too.
            scrollToVisible(rect.insetBy(dx: 0, dy: -GridMetrics.titleHeight / 2))
        }
    }

    // MARK: Places

    /// The line of the emoji at `index`, and its column.
    private func place(of index: Int) -> (line: Int, column: Int)? {
        guard metrics.lineOfItem.indices.contains(index) else { return nil }
        let line = metrics.lineOfItem[index]
        guard case .cells(let range) = session.lines[line] else { return nil }
        return (line, index - range.lowerBound)
    }

    private func cellRect(_ index: Int) -> NSRect? {
        guard let place = place(of: index), metrics.tops.indices.contains(place.line) else { return nil }
        return NSRect(x: GridMetrics.inset + CGFloat(place.column) * GridMetrics.cellSize,
                      y: metrics.tops[place.line], width: GridMetrics.cellSize, height: GridMetrics.cellSize)
    }

    /// The emoji below a point of the view, or nil.
    private func index(at point: NSPoint) -> Int? {
        let line = max(0, metrics.firstLine(below: point.y) - 1)
        for place in line..<min(line + 3, session.lines.count) {
            guard case .cells(let range) = session.lines[place] else { continue }
            let top = metrics.tops[place]
            guard point.y >= top, point.y < top + GridMetrics.cellSize else { continue }
            let column = Int((point.x - GridMetrics.inset) / GridMetrics.cellSize)
            guard point.x >= GridMetrics.inset, column >= 0, column < range.count else { return nil }
            return range.lowerBound + column
        }
        return nil
    }

    // MARK: Drawing

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
                    let cell = NSRect(x: GridMetrics.inset + CGFloat(index - range.lowerBound) * GridMetrics.cellSize,
                                      y: top, width: GridMetrics.cellSize, height: GridMetrics.cellSize)
                    if index == session.selection { drawBlueBox(in: cell) }
                    guard case .emoji(let emoji) = session.items[index] else { continue }
                    let textRect = NSRect(x: cell.minX, y: cell.minY + (cell.height - EmojiGridView.emojiLineHeight) / 2,
                                          width: cell.width, height: EmojiGridView.emojiLineHeight)
                    (session.shown(emoji) as NSString)
                        .draw(with: textRect, options: .usesLineFragmentOrigin, attributes: EmojiGridView.emojiAttributes)
                }
            }
            place += 1
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
        pressed = index(at: convert(event.locationInWindow, from: nil))
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
        guard let pressed, index(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        session.pick(stayOpen: false)
    }

    /// The right-click menu: the items of `PickSession.menuActions(at:)` (D15, D17).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
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
