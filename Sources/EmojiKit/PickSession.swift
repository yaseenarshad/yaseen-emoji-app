import Foundation

/// What the session needs from the search panel on the screen. A test uses a fake one,
/// so no test makes a window.
@MainActor
protocol PickPanel: AnyObject {
    /// Places the panel by D7, shows it, and gives it the keyboard.
    func show()
    /// Hides the panel. The session is closed.
    func hide()
    /// Hides the panel for a ⌘V, so the ⌘V goes to the app in front. The session stays open.
    func stepAside()
    /// Shows the panel again after `stepAside()`, with the keyboard.
    func comeBack()
    /// The query, the lines or the items changed.
    func reload()
    /// Only the blue box moved.
    func showSelection()
}

/// The rules of the search panel, with no window and no view (D5, D7, D8, D9).
///
/// It holds the search text, the lines of the grid, the blue box, and what each key does.
/// The panel is a thin adapter: it turns key presses and clicks into these calls and shows
/// what it reads here. The same idea as `DrawSession` in Screendraw.
@MainActor
final class PickSession {
    /// The grid has 9 emojis in each row (D7).
    static let columns = 9
    /// "Your most used": the top 18 by uses (D7).
    static let mostUsedLimit = 18
    static let mostUsedTitle = "Your most used"

    enum Direction {
        case left, right, up, down
    }

    /// One line of the grid: a title, or a row of up to 9 emojis.
    enum Line: Equatable {
        case title(String)
        /// The places of the emojis in `items`.
        case cells(Range<Int>)
    }

    /// True while the panel is open.
    private(set) var isOpen = false
    /// The text in the search box, as the user typed it.
    private(set) var query = ""
    /// The emojis of the grid, in the order of the grid. One emoji can be in two sections.
    private(set) var items: [Emoji] = []
    private(set) var lines: [Line] = []
    /// The place of the blue box in `items`. Nil when no emoji has the blue box.
    private(set) var selection: Int?
    /// The emoji that waits for a word from "Add a word…" (with an empty search).
    private(set) var addingWordFor: Emoji?

    weak var panel: PickPanel?

    let catalog: [Emoji]
    let store: YouStore
    private let prefs: Prefs
    private let paster: Paster
    /// The emojis of each group, in Unicode order. Made one time, not at each key press.
    private let groups: [(name: String, emojis: [Emoji])]

    /// `catalog` is the list after the draw check: only the emojis that this Mac can draw.
    init(catalog: [Emoji], store: YouStore, prefs: Prefs, paster: Paster) {
        self.catalog = catalog
        self.store = store
        self.prefs = prefs
        self.paster = paster
        groups = EmojiCatalog.groupNames.enumerated().compactMap { place, name in
            let emojis = catalog.filter { $0.group == place }
            return emojis.isEmpty ? nil : (name, emojis)
        }
    }

    // MARK: Open and close

    /// The hotkey and "Find an emoji": open the panel, or close it when it is open (D8).
    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// The search box is empty each time the panel opens (D7).
    func open() {
        guard !isOpen else { return }
        isOpen = true
        query = ""
        addingWordFor = nil
        rebuild()
        panel?.reload()
        panel?.show()
    }

    /// Esc, a click outside, the hotkey again, or a pick that closes. Safe to call two times.
    func close() {
        guard isOpen else { return }
        isOpen = false
        addingWordFor = nil
        panel?.hide()
    }

    // MARK: The keys

    /// The search box changed.
    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        // The word for "Add a word…" is not a search.
        guard addingWordFor == nil else { return }
        rebuild()
        panel?.reload()
    }

    /// Enter picks and closes. Shift+Enter picks and stays open (D8).
    /// While "Add a word…" waits, Enter adds the word.
    func enter(shift: Bool) {
        if addingWordFor != nil {
            finishAddingWord()
        } else {
            pick(stayOpen: shift)
        }
    }

    /// Esc stops "Add a word…". Else it closes the panel with no paste (D8).
    func escape() {
        if addingWordFor != nil {
            stopAddingWord()
        } else {
            close()
        }
    }

    /// The arrow keys. Left and Right go along the order of the grid. Up and Down keep the column.
    /// At the first or the last emoji the blue box stays. With no blue box, each arrow puts it on the first emoji.
    func move(_ direction: Direction) {
        guard addingWordFor == nil, !items.isEmpty else { return }
        guard let current = selection else {
            select(0)
            return
        }
        switch direction {
        case .left: select(max(0, current - 1))
        case .right: select(min(items.count - 1, current + 1))
        case .up, .down:
            let rows = lines.compactMap { line -> Range<Int>? in
                if case .cells(let range) = line { return range }
                return nil
            }
            guard let row = rows.firstIndex(where: { $0.contains(current) }) else { return }
            let next = direction == .up ? row - 1 : row + 1
            guard rows.indices.contains(next) else { return }
            let column = current - rows[row].lowerBound
            select(min(rows[next].lowerBound + column, rows[next].upperBound - 1))
        }
    }

    /// A click or a right-click on one emoji puts the blue box on it.
    func select(_ index: Int) {
        guard items.indices.contains(index), index != selection else { return }
        selection = index
        panel?.showSelection()
    }

    var selectedEmoji: Emoji? {
        selection.map { items[$0] }
    }

    // MARK: Picks

    /// Puts the emoji with the blue box into the app in front (D2), and learns the search text (D4).
    /// With no blue box (no results), it does nothing (D8).
    func pick(stayOpen: Bool) {
        guard let emoji = selectedEmoji else { return }
        let text = shown(emoji)
        store.recordPick(text, query: query)
        let paste = paster.willPaste(prefs.pickMode)
        if stayOpen {
            // The learned word can move the emoji up. The blue box stays on the same emoji.
            rebuild(keeping: emoji)
            panel?.reload()
            guard paste else {
                paster.deliver(text, paste: false)
                return
            }
            panel?.stepAside()
            paster.deliver(text, paste: true) { [weak self] in
                guard let self, self.isOpen else { return }
                self.panel?.comeBack()
            }
        } else {
            close()
            paster.deliver(text, paste: paste)
        }
    }

    /// ⌘C and the right-click "Copy only": the emoji goes on the clipboard, and the panel closes (D8).
    /// It is a pick, so it counts a use and learns the search text.
    func copyOnly() {
        guard let emoji = selectedEmoji else { return }
        let text = shown(emoji)
        store.recordPick(text, query: query)
        close()
        paster.deliver(text, paste: false)
    }

    // MARK: Skin tones (D9)

    /// The form that the grid shows and that a pick pastes: the tone of this emoji, then the
    /// default tone of Settings, then yellow.
    func shown(_ emoji: Emoji) -> String {
        if let own = store.you.tones[emoji.key] { return own }
        if let place = SkinTone.formIndex(prefs.defaultTone), emoji.toneForms.indices.contains(place) {
            return emoji.toneForms[place]
        }
        return emoji.text
    }

    /// The six forms of the right-click menu: yellow, then light to dark. Empty if the emoji takes no tone.
    func toneChoices(for emoji: Emoji) -> [String] {
        emoji.takesTone ? [emoji.text] + emoji.toneForms : []
    }

    /// A right-click tone: it is for this emoji only, and it wins over the default tone.
    func setTone(_ form: String, for emoji: Emoji) {
        guard toneChoices(for: emoji).contains(form) else { return }
        store.setTone(form, for: emoji.text)
        panel?.reload()
    }

    // MARK: Add a word (D4)

    /// The text of the one line while "Add a word…" waits.
    static func addingWordText(_ emoji: Emoji) -> String {
        "Type a word for \(emoji.text). Enter adds it. Esc stops."
    }

    /// The right-click "Add a word…". With a search, the search text is the word, and the app adds it at once.
    /// With an empty search, the search box asks for the word.
    func addWord(for emoji: Emoji) {
        if !Search.normalize(query).isEmpty {
            store.addWord(query, to: emoji.text)
            rebuild(keeping: emoji)
            panel?.reload()
        } else {
            addingWordFor = emoji
            lines = [.title(PickSession.addingWordText(emoji))]
            items = []
            selection = nil
            panel?.reload()
        }
    }

    /// Enter while "Add a word…" waits. An empty word adds nothing.
    private func finishAddingWord() {
        guard let emoji = addingWordFor else { return }
        let word = query
        addingWordFor = nil
        if !Search.normalize(word).isEmpty { store.addWord(word, to: emoji.text) }
        // The search box shows the word, so the emoji shows as a result at once.
        rebuild(keeping: emoji)
        panel?.reload()
    }

    private func stopAddingWord() {
        addingWordFor = nil
        query = ""
        rebuild()
        panel?.reload()
    }

    // MARK: The lines of the grid (D7)

    static func resultsTitle(_ count: Int) -> String {
        count == 1 ? "1 result" : "\(count) results"
    }

    static func noMatchTitle(_ query: String) -> String {
        "No match for \"\(query)\". Right-click an emoji below to add this word."
    }

    /// Makes the lines again from the search text. The blue box goes on the first emoji,
    /// or on `emoji` when it is still in the grid.
    private func rebuild(keeping emoji: Emoji? = nil) {
        var newItems: [Emoji] = []
        var newLines: [Line] = []
        func addSection(_ title: String, _ emojis: [Emoji]) {
            newLines.append(.title(title))
            let start = newItems.count
            newItems += emojis
            for rowStart in stride(from: start, to: newItems.count, by: PickSession.columns) {
                newLines.append(.cells(rowStart..<min(rowStart + PickSession.columns, newItems.count)))
            }
        }
        func addMostUsedOrGroups() {
            let most = Search.mostUsed(in: catalog, you: store.you, limit: PickSession.mostUsedLimit)
            if !most.isEmpty {
                addSection(PickSession.mostUsedTitle, most)
            } else {
                // No uses yet: all groups, so a right-click can still teach the word.
                for group in groups { addSection(group.name, group.emojis) }
            }
        }

        let text = Search.normalize(query)
        var firstSelection: Int? = 0
        if text.isEmpty {
            let most = Search.mostUsed(in: catalog, you: store.you, limit: PickSession.mostUsedLimit)
            if !most.isEmpty { addSection(PickSession.mostUsedTitle, most) }
            for group in groups { addSection(group.name, group.emojis) }
        } else {
            let results = Search.results(for: query, in: catalog, you: store.you)
            if results.isEmpty {
                newLines.append(.title(PickSession.noMatchTitle(query.trimmingCharacters(in: .whitespaces))))
                addMostUsedOrGroups()
                // Enter with no results does nothing (D8).
                firstSelection = nil
            } else {
                addSection(PickSession.resultsTitle(results.count), results)
            }
        }
        items = newItems
        lines = newLines
        if let emoji, let place = newItems.firstIndex(where: { $0.text == emoji.text }), firstSelection != nil {
            selection = place
        } else {
            selection = newItems.isEmpty ? nil : firstSelection
        }
    }
}
