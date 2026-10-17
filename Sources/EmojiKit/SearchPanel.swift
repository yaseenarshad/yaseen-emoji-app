import AppKit
import Carbon.HIToolbox

/// Where the panel opens (D7): in the middle of the screen with the mouse, in the upper third, like Spotlight.
/// You can drag the panel while it is open, from any part (D12, D14). The next open puts it in the middle again.
/// A pure function, so a test checks it with no screen.
enum PanelPlace {
    /// The top of the panel is this part of the screen height below the top of the visible frame.
    /// Then the search box is in the upper third.
    static let topPart: CGFloat = 1.0 / 6.0

    static func frame(size: CGSize, visibleFrame: CGRect) -> CGRect {
        let x = (visibleFrame.midX - size.width / 2).rounded()
        let top = visibleFrame.maxY - (visibleFrame.height * topPart).rounded()
        // A small screen: the panel stays on the screen.
        let y = max(visibleFrame.minY, top - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// The borderless search panel. It does not activate the app: the app in front stays in front,
/// so the ⌘V of a pick goes to it (D2). It takes the keyboard with `makeKey()`.
final class SearchPanel: NSPanel {
    /// ⌘C: "Copy only" (D8).
    var onCopy: () -> Void = {}
    /// ⌘1, ⌘2, ⌘3: the Emoji, GIFs or Memes tab (D10 of YAZ-2919). The number is 0, 1 or 2.
    var onTab: (Int) -> Void = { _ in }

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // A panel takes the keyboard only for a text field, and hides when its app is not active.
        // This panel needs the keyboard at once, and it must stay while the app is not active.
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .floating
        // On the Space of the user, also over a full-screen app.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        // D12: drag an empty part of the panel to move it. The grid starts its own drag (D14).
        // The search box does not drag, so you can select its text.
        isMovableByWindowBackground = true
    }

    // A borderless window refuses the keyboard by default. The search box needs it.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The app has no main menu, so no menu gives the edit keys to the search box. The panel does it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let combo = HotKeyCombo(keyDown: event) else { return super.performKeyEquivalent(with: event) }
        let command = NSEvent.ModifierFlags.command
        switch (Int(combo.keyCode), combo.modifiers) {
        case (kVK_ANSI_C, command):
            onCopy()
            return true
        case (kVK_ANSI_1, command), (kVK_ANSI_2, command), (kVK_ANSI_3, command):
            onTab([kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3].firstIndex(of: Int(combo.keyCode)) ?? 0)
            return true
        case (kVK_ANSI_V, command): return send(#selector(NSText.paste(_:)))
        case (kVK_ANSI_X, command): return send(#selector(NSText.cut(_:)))
        case (kVK_ANSI_A, command): return send(#selector(NSText.selectAll(_:)))
        case (kVK_ANSI_Z, command): return send(Selector(("undo:")))
        case (kVK_ANSI_Z, [.command, .shift]): return send(Selector(("redo:")))
        default: return super.performKeyEquivalent(with: event)
        }
    }

    private func send(_ action: Selector) -> Bool {
        firstResponder?.tryToPerform(action, with: self) ?? false
    }
}

/// The background of the search panel. A drop of files on any part of the panel goes to the add window (D12 of YAZ-2919).
final class PanelBackgroundView: NSVisualEffectView {
    let fileDrop = FileDropTarget()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(FileDrop.types)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileDrop.entered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { fileDrop.exited() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { fileDrop.perform(sender) }
}

/// The field editor of the search box. A text view takes a file drag and types its path. This one gives
/// a drag with files to the panel, so the drop goes to the add window. A drag of text works as before.
final class SearchFieldEditor: NSTextView {
    weak var panelBackground: PanelBackgroundView?

    private func takesFiles(_ info: NSDraggingInfo) -> Bool {
        panelBackground != nil && FileDrop.accepts(info)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard takesFiles(sender), let panelBackground else { return super.draggingEntered(sender) }
        return panelBackground.fileDrop.entered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        takesFiles(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, takesFiles(sender) { return }
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        takesFiles(sender) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard takesFiles(sender), let panelBackground else { return super.performDragOperation(sender) }
        return panelBackground.fileDrop.perform(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, takesFiles(sender) { return }
        super.concludeDragOperation(sender)
    }
}

/// The search panel on the screen: the search box, the tabs and the grid (D7, D8; D10 of YAZ-2919). It is the thin adapter of
/// `PickSession`: it turns keys and clicks into calls of the session, and shows what the session holds.
/// One panel for the life of the app. It hides and shows again, so it opens fast.
@MainActor
final class SearchPanelController: NSObject, PickPanel, NSWindowDelegate, NSTextFieldDelegate {
    /// D7: 460 points wide.
    static let width: CGFloat = 460
    static let fieldHeight: CGFloat = 52
    /// The row of the three tabs below the search box (D10 of YAZ-2919). The panel keeps its 392 points.
    static let tabBarHeight: CGFloat = 30
    static let gridHeight: CGFloat = 310
    static let cornerRadius: CGFloat = 14

    private let session: PickSession
    private let panel: SearchPanel
    private let field = NSTextField()
    /// The field editor of `field`: a drop of files on the search box goes to the add window, not into the text.
    private let fieldEditor = SearchFieldEditor()
    private let tabs = NSSegmentedControl(labels: PickSession.Tab.allCases.map(\.title), trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let grid: EmojiGridView
    private let scrollView = NSScrollView()
    /// True between `stepAside()` and `comeBack()`. The panel loses the keyboard then, but the session stays open.
    private var isSteppingAside = false

    init(session: PickSession) {
        self.session = session
        panel = SearchPanel(size: NSSize(width: SearchPanelController.width,
                                         height: SearchPanelController.fieldHeight + SearchPanelController.tabBarHeight
                                             + SearchPanelController.gridHeight))
        grid = EmojiGridView(session: session)
        super.init()
        panel.delegate = self
        panel.onCopy = { [weak session] in session?.copyOnly() }
        panel.onTab = { [weak session] place in session?.select(tab: PickSession.Tab.allCases[place]) }
        layOut()
    }

    // MARK: The views

    private func layOut() {
        let size = panel.frame.size
        // The material of macOS popovers, with rounded corners. `.active`: the app is never the active app,
        // and an inactive material looks flat and grey.
        let background = PanelBackgroundView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = SearchPanelController.roundedMask(radius: SearchPanelController.cornerRadius)
        panel.contentView = background
        // D12 of YAZ-2919: a drop of files closes the panel and opens the add window with them.
        // The call runs after the drop call returns, so the panel does not hide in the middle of the drop.
        background.fileDrop.onDrop = { [weak session] sources in
            Task { @MainActor in session?.addFiles(sources) }
        }
        fieldEditor.isFieldEditor = true
        fieldEditor.panelBackground = background

        let fieldTop = size.height - SearchPanelController.fieldHeight
        let glass = NSImageView(frame: NSRect(x: 16, y: fieldTop + 15, width: 22, height: 22))
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glass.contentTintColor = .secondaryLabelColor
        glass.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        background.addSubview(glass)

        field.frame = NSRect(x: 46, y: fieldTop + 12, width: size.width - 62, height: 28)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22)
        field.placeholderString = session.placeholder
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        background.addSubview(field)

        let line = NSBox(frame: NSRect(x: 0, y: fieldTop, width: size.width, height: 1))
        line.boxType = .separator
        background.addSubview(line)

        // The tabs never take the keyboard: the search box keeps it.
        tabs.frame = NSRect(x: 12, y: SearchPanelController.gridHeight + 3, width: size.width - 24, height: 24)
        tabs.segmentDistribution = .fillEqually
        tabs.refusesFirstResponder = true
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabClicked)
        background.addSubview(tabs)

        scrollView.frame = NSRect(x: 0, y: 0, width: size.width, height: SearchPanelController.gridHeight)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = grid
        background.addSubview(scrollView)
        // A scroll near the end asks for the next KLIPY page (D11 of YAZ-2919).
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Other GIF tiles are on the screen now (D11 update on YAZ-2925).
                self.grid.visibleRectChanged()
                guard self.grid.isNearEnd else { return }
                self.session.reachedEnd()
            }
        }
    }

    /// A mask with round corners. The material and the shadow of the window follow it.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: PickPanel

    func show() {
        isSteppingAside = false
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let screen {
            panel.setFrame(PanelPlace.frame(size: panel.frame.size, visibleFrame: screen.visibleFrame), display: false)
        }
        takeKeyboard()
        grid.startPlaying()
    }

    /// The GIFs stop with the panel, so a closed panel uses no CPU (D11 update on YAZ-2925).
    func hide() {
        isSteppingAside = false
        grid.stopPlaying()
        panel.orderOut(nil)
    }

    func stepAside() {
        isSteppingAside = true
        grid.stopPlaying()
        panel.orderOut(nil)
    }

    func comeBack() {
        takeKeyboard()
        isSteppingAside = false
        grid.startPlaying()
    }

    func reload() {
        if field.stringValue != session.query { field.stringValue = session.query }
        field.placeholderString = session.placeholder
        tabs.selectedSegment = session.tab.rawValue
        grid.reload()
    }

    func update() {
        field.placeholderString = session.placeholder
        grid.reload(keepingScroll: true)
    }

    func showSelection() {
        grid.showSelection()
    }

    /// `orderFrontRegardless` does not need the active app, and a panel that does not activate
    /// the app can take the keyboard without it (Screendraw).
    private func takeKeyboard() {
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)
        // The cursor at the end, not all the text selected.
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
        panel.invalidateShadow()
    }

    // MARK: The keys (D8)

    func controlTextDidChange(_ notification: Notification) {
        session.setQuery(field.stringValue)
    }

    /// The search box always has the keyboard. The arrow keys move the blue box, not the text cursor.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)): session.move(.left)
        case #selector(NSResponder.moveRight(_:)): session.move(.right)
        case #selector(NSResponder.moveUp(_:)): session.move(.up)
        case #selector(NSResponder.moveDown(_:)): session.move(.down)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            session.enter(shift: shift || selector == #selector(NSResponder.insertLineBreak(_:)))
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            session.escape()
        // The keyboard stays in the search box. Tab and Shift+Tab go round the tabs (D10 of YAZ-2919).
        case #selector(NSResponder.insertTab(_:)): session.nextTab(back: false)
        case #selector(NSResponder.insertBacktab(_:)): session.nextTab(back: true)
        default:
            return false
        }
        return true
    }

    @objc private func tabClicked() {
        guard let tab = PickSession.Tab(rawValue: tabs.selectedSegment) else { return }
        session.select(tab: tab)
        // A click while "Add a word…" waits does not change the tab.
        tabs.selectedSegment = session.tab.rawValue
    }

    // MARK: NSWindowDelegate

    /// The search box uses `SearchFieldEditor`, so a file drop on it goes to the add window.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === field ? fieldEditor : nil
    }

    /// A click outside, or a different window takes the keyboard: the panel closes (D7).
    /// Not for a ⌘V of Shift+Enter, and not while the right-click menu is open.
    func windowDidResignKey(_ notification: Notification) {
        guard !isSteppingAside, !grid.menuIsOpen else { return }
        session.close()
    }
}
