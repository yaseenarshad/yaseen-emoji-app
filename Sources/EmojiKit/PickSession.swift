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

/// One thing in the grid (D10 and D11 of YAZ-2919): an emoji, your own GIF or meme, or a KLIPY item.
enum PickItem: Equatable {
    case emoji(Emoji)
    /// Your own file in `gifs/` or `memes/`.
    case own(Item)
    /// A KLIPY item, saved or not (D7).
    case online(OnlineItem)

    /// The key of the uses and the learned words in `you-<Mac>.json`: the emoji key, `gif:<id>`, `meme:<id>` or `klipy:<slug>`.
    var key: String {
        switch self {
        case .emoji(let emoji): return emoji.key
        case .own(let item): return item.key
        case .online(let item): return item.youKey
        }
    }

    var emoji: Emoji? {
        if case .emoji(let emoji) = self { return emoji }
        return nil
    }

    /// GIF or meme. Nil for an emoji.
    var kind: ItemKind? {
        switch self {
        case .emoji: return nil
        case .own(let item): return item.kind
        case .online(let item): return ItemKind(rawValue: item.kind.rawValue)
        }
    }

    /// True for the same emoji (the same text), or the same GIF or meme (the same key).
    func isSame(as other: PickItem) -> Bool {
        if let emoji, let otherEmoji = other.emoji { return emoji.text == otherEmoji.text }
        return emoji == nil && other.emoji == nil && key == other.key
    }
}

/// The search entry of one GIF or meme (D11 of YAZ-2919). An item has no name. Its words are the words of the item,
/// and a word with spaces also gives its single words. `order` is the place in the list, newest first.
/// A class: the search copies each entry, and a copy of a reference is cheaper than a copy of the item.
final class TileEntry: Searchable {
    let item: PickItem
    let key: String
    var name: String { "" }
    let nameBytes: [UInt8] = []
    let wordBytes: [[UInt8]]
    let order: Int

    init(item: PickItem, words: [String], order: Int) {
        self.item = item
        key = item.key
        self.order = order
        var all: [String] = []
        for word in words {
            let clean = Search.normalize(word)
            for part in [clean] + clean.split(separator: " ").map(String.init) where !part.isEmpty && !all.contains(part) {
                all.append(part)
            }
        }
        wordBytes = all.map { Array($0.utf8) }
    }
}

/// The rules of the search panel, with no window and no view (D5, D7, D8, D9, D15, D17; D10, D11, D13 of YAZ-2919).
///
/// It holds the tab, the search text, the lines of the grid, the blue box, and what each key does.
/// The panel is a thin adapter: it turns key presses and clicks into these calls and shows
/// what it reads here. The same idea as `DrawSession` in Screendraw.
@MainActor
final class PickSession {
    /// The grid has 9 emojis in each row (D7).
    static let columns = 9
    /// The GIFs and Memes tabs have 3 tiles in each row (D11 of YAZ-2919).
    static let tileColumns = 3
    /// "Your most used": 4 rows of 9, the top 36 by uses (D7, D13). The history keeps every use;
    /// this limit is only for the screen.
    static let mostUsedLimit = 36
    /// "Your most used" of GIFs and memes: 2 rows of 3 (D11 of YAZ-2919).
    static let tileMostUsedLimit = 6
    static let mostUsedTitle = "Your most used"
    /// The title of your own results of a search in the GIFs and Memes tabs (D11 of YAZ-2919).
    static let yoursTitle = "Yours"
    /// The title of the KLIPY results (D11 of YAZ-2919). Subissue 4 fills it.
    static let onlineTitle = "From KLIPY"

    /// The three tabs (D10 of YAZ-2919). Each open starts on Emoji.
    enum Tab: Int, CaseIterable {
        case emoji, gifs, memes

        var title: String {
            switch self {
            case .emoji: return "Emoji"
            case .gifs: return "GIFs"
            case .memes: return "Memes"
            }
        }

        /// The kind of the items of the tab. Nil for Emoji.
        var kind: ItemKind? {
            switch self {
            case .emoji: return nil
            case .gifs: return .gif
            case .memes: return .meme
            }
        }
    }

    enum Direction {
        case left, right, up, down
    }

    /// One item of the right-click menu. The grid makes the `NSMenu` from these, so a test checks the items.
    enum MenuAction: Equatable {
        case addWord, copyOnly, hideFromMostUsed
        /// Your own GIF or meme (D13 of YAZ-2919).
        case showInFinder, moveToTrash
        /// A KLIPY item (D7, D13 of YAZ-2919): "Save to your GIFs" and "Remove from your GIFs" (or memes).
        case saveToYours(ItemKind), removeFromYours(ItemKind)
        /// "Add a GIF or meme…": the add window of subissue 3 (D12 of YAZ-2919).
        case addNew

        var title: String {
            switch self {
            case .addWord: return "Add a word…"
            case .copyOnly: return "Copy only"
            case .hideFromMostUsed: return "Hide from Your most used"
            case .showInFinder: return "Show in Finder"
            case .moveToTrash: return "Move to Trash"
            case .saveToYours(let kind): return "Save to \(PickSession.yourTitle(kind).lowercasedFirst)"
            case .removeFromYours(let kind): return "Remove from \(PickSession.yourTitle(kind).lowercasedFirst)"
            case .addNew: return "Add a GIF or meme…"
            }
        }
    }

    /// One line of the grid: a title, or a row of up to 9 emojis (or 3 tiles).
    enum Line: Equatable {
        case title(String)
        /// The places of the items in `items`.
        case cells(Range<Int>)
    }

    /// True while the panel is open.
    private(set) var isOpen = false
    /// The tab that shows (D10 of YAZ-2919).
    private(set) var tab = Tab.emoji
    /// The text in the search box, as the user typed it.
    private(set) var query = ""
    /// The items of the grid, in the order of the grid. One item can be in two sections.
    private(set) var items: [PickItem] = []
    private(set) var lines: [Line] = []
    /// The places in `items` of the "Your most used" section, or nil when the grid has no such section.
    private(set) var mostUsedItems: Range<Int>?
    /// The place of the blue box in `items`. Nil when no item has the blue box.
    private(set) var selection: Int?
    /// The item that waits for a word from "Add a word…" (with an empty search).
    private(set) var addingWordFor: PickItem?

    weak var panel: PickPanel?
    /// Runs each time the panel opens, before the grid is made. The app reads the changed history files here (D16).
    var willOpen: () -> Void = {}
    /// "Show in Finder" (D13 of YAZ-2919). The app gives `NSWorkspace.activateFileViewerSelecting`.
    var showInFinder: (URL) -> Void = { _ in }
    /// "Add a GIF or meme…" (D12 of YAZ-2919). Subissue 3 opens the add window here. Until then it does nothing.
    var onAddNew: () -> Void = {}

    let catalog: [Emoji]
    let store: YouStore
    /// The list of GIFs and memes of all Macs (D3 of YAZ-2919).
    let library: LibraryStore
    /// KLIPY (subissue 4). Nil: no "From KLIPY" section.
    let online: OnlineResults?
    /// The still pictures of the tiles. The session deletes the still picture of a removed item (D5 of YAZ-2919).
    let thumbnails: Thumbnails?
    private let prefs: Prefs
    private let paster: Paster
    /// The emojis of each group, in Unicode order. Made one time, not at each key press.
    private let groups: [(name: String, emojis: [Emoji])]
    /// The search entries of the GIFs and memes of each tab, newest first. Made again at each open and after a change.
    private var tileEntries: [ItemKind: [TileEntry]] = [:]

    /// `catalog` is the list after the draw check: only the emojis that this Mac can draw.
    init(catalog: [Emoji], store: YouStore, library: LibraryStore, prefs: Prefs, paster: Paster,
         online: OnlineResults? = nil, thumbnails: Thumbnails? = nil) {
        self.catalog = catalog
        self.store = store
        self.library = library
        self.online = online
        self.thumbnails = thumbnails
        self.prefs = prefs
        self.paster = paster
        groups = EmojiCatalog.groupNames.enumerated().compactMap { place, name in
            let emojis = catalog.filter { $0.group == place }
            return emojis.isEmpty ? nil : (name, emojis)
        }
        online?.onChange = { [weak self] in self?.onlineChanged() }
    }

    /// The columns of the grid in this tab: 9 emojis, or 3 tiles.
    var columnCount: Int { tab == .emoji ? PickSession.columns : PickSession.tileColumns }

    // MARK: Open and close

    /// The hotkey and "Find an emoji": open the panel, or close it when it is open (D8).
    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// Each open starts on the Emoji tab with an empty search box (D7; D10 of YAZ-2919).
    func open() {
        guard !isOpen else { return }
        isOpen = true
        tab = .emoji
        query = ""
        addingWordFor = nil
        willOpen()
        // The lists of the other Macs can have new items or new removes.
        tileEntries = [:]
        thumbnails?.retryFailed()
        thumbnails?.removeStills(ofRemoved: library.all.values)
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

    // MARK: The tabs (D10 of YAZ-2919)

    /// Tab goes to the next tab, Shift+Tab to the one before, round the three tabs.
    func nextTab(back: Bool) {
        let all = Tab.allCases
        let step = back ? all.count - 1 : 1
        select(tab: all[(tab.rawValue + step) % all.count])
    }

    /// ⌘1, ⌘2, ⌘3 and a click on a tab. The search text stays, and the new tab searches it.
    /// While "Add a word…" waits, the tab does not change: the search box holds the new word.
    func select(tab new: Tab) {
        guard addingWordFor == nil, new != tab else { return }
        tab = new
        rebuild()
        panel?.reload()
    }

    /// The text in the empty search box (D10 and its update on YAZ-2919).
    var placeholder: String {
        if let item = addingWordFor { return "A word for \(PickSession.name(of: item))" }
        switch tab {
        case .emoji: return "Search emoji"
        case .gifs: return online?.isOn == true ? "Search KLIPY" : "Search your GIFs"
        case .memes: return online?.isOn == true ? "Search KLIPY" : "Search your memes"
        }
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
    /// At the first or the last item the blue box stays. With no blue box, each arrow puts it on the first item.
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

    /// A click or a right-click on one item puts the blue box on it.
    func select(_ index: Int) {
        guard items.indices.contains(index), index != selection else { return }
        selection = index
        panel?.showSelection()
    }

    var selectedItem: PickItem? {
        selection.map { items[$0] }
    }

    var selectedEmoji: Emoji? {
        selectedItem?.emoji
    }

    // MARK: Picks

    /// Puts the item with the blue box into the app in front (D2; D6 of YAZ-2919), and learns the search text (D4).
    /// With no blue box (no results), or a GIF whose file is missing, it does nothing (D8; D4 of YAZ-2919).
    /// The paste starts before the save: with a full `you.json` (5,000 learned pairs)
    /// the save takes about 23 ms in a release build, and the panel must not wait for it.
    func pick(stayOpen: Bool) {
        guard let item = selectedItem, let clip = clip(for: item) else { return }
        let key = pickKey(item)
        let query = self.query
        let paste = paster.willPaste(prefs.pickMode)
        guard stayOpen else {
            close()
            paster.deliver(clip, paste: paste)
            store.recordPick(key, query: query)
            return
        }
        if paste {
            panel?.stepAside()
            paster.deliver(clip, paste: true) { [weak self] in
                guard let self, self.isOpen else { return }
                self.panel?.comeBack()
            }
        } else {
            paster.deliver(clip, paste: false)
        }
        store.recordPick(key, query: query)
        // The list does not move while the panel stays open, so the blue box stays where you
        // look. The new use and the learned word change the order the next time.
    }

    /// ⌘C and the right-click "Copy only": the item goes on the clipboard, and the panel closes (D8).
    /// It is a pick, so it counts a use and learns the search text.
    func copyOnly() {
        guard let item = selectedItem, let clip = clip(for: item) else { return }
        let key = pickKey(item)
        let query = self.query
        close()
        paster.deliver(clip, paste: false)
        store.recordPick(key, query: query)
    }

    /// What a pick puts on the clipboard: the shown emoji, or the file of a GIF or meme (D6 of YAZ-2919).
    /// Nil when the file is not there, or a KLIPY file is not downloaded yet.
    func clip(for item: PickItem) -> Paster.Clip? {
        switch item {
        case .emoji(let emoji):
            return .text(shown(emoji))
        case .own(let item):
            guard !library.mediaFolderIsMissing, !library.missing.contains(item.id), let url = library.fileURL(of: item) else {
                return nil
            }
            return Paster.Clip.file(at: url)
        case .online(let item):
            return online?.pasteFile(for: item).map { .file($0, type: item.fileType) }
        }
    }

    /// The text that `recordPick` gets: the shown emoji (its key has no tone), or the key of the item.
    private func pickKey(_ item: PickItem) -> String {
        if let emoji = item.emoji { return shown(emoji) }
        return item.key
    }

    // MARK: Skin tones (D9, D17)

    /// The form that the grid shows and that a pick pastes: the default tone of Settings for an
    /// emoji that takes a tone, else the emoji itself (yellow). Settings is the only tone choice (D17).
    func shown(_ emoji: Emoji) -> String {
        if let place = SkinTone.formIndex(prefs.defaultTone), emoji.toneForms.indices.contains(place) {
            return emoji.toneForms[place]
        }
        return emoji.text
    }

    // MARK: The right-click menu (D4, D15, D17; D13 of YAZ-2919)

    /// The items for the grid item at `index` (D13 of YAZ-2919). "Hide from Your most used" shows only
    /// in the "Your most used" section. No tone forms (D17).
    /// * An emoji: "Add a word…", "Copy only".
    /// * Your own GIF or meme: "Add a word…", "Copy only", "Show in Finder", "Move to Trash", "Add a GIF or meme…".
    /// * A saved KLIPY item: "Add a word…", "Copy only", "Remove from your GIFs", "Add a GIF or meme…".
    /// * A KLIPY item that is not saved: "Save to your GIFs", "Copy only", "Add a GIF or meme…".
    func menuActions(at index: Int) -> [MenuAction] {
        guard items.indices.contains(index) else { return [] }
        let hide: [MenuAction] = mostUsedItems?.contains(index) == true ? [.hideFromMostUsed] : []
        switch items[index] {
        case .emoji:
            return [.addWord, .copyOnly] + hide
        case .own:
            return [.addWord, .copyOnly] + hide + [.showInFinder, .moveToTrash, .addNew]
        case .online(let item):
            let kind = ItemKind(rawValue: item.kind.rawValue) ?? .gif
            if isSaved(item) { return [.addWord, .copyOnly] + hide + [.removeFromYours(kind), .addNew] }
            return [.saveToYours(kind), .copyOnly, .addNew]
        }
    }

    /// The menu of a right-click on a gap or a title: "Add a GIF or meme…" in the GIFs and Memes tabs (D12 of YAZ-2919).
    var menuActionsOutsideItems: [MenuAction] {
        tab == .emoji ? [] : [.addNew]
    }

    /// Runs one item of the right-click menu on the item with the blue box. The grid calls it.
    func perform(_ action: MenuAction) {
        if action == .addNew { return addNew() }
        guard let item = selectedItem else { return }
        switch action {
        case .addWord: addWord(for: item)
        case .copyOnly: copyOnly()
        case .hideFromMostUsed: hideFromMostUsed(item: item)
        case .showInFinder: showInFinder(item)
        case .moveToTrash: moveToTrash(item)
        case .saveToYours: saveToYours(item)
        case .removeFromYours: removeFromYours(item)
        case .addNew: addNew()
        }
    }

    /// "Hide from Your most used" (D15): the emoji leaves the section, and the next emoji fills its place.
    /// The panel stays open. The search still ranks the emoji the same.
    func hideFromMostUsed(_ emoji: Emoji) {
        hideFromMostUsed(item: .emoji(emoji))
    }

    /// "Hide from Your most used" for an emoji, a GIF or a meme: the same rule (D15; D11 of YAZ-2919).
    func hideFromMostUsed(item: PickItem) {
        store.hide(item.key)
        rebuild()
        panel?.reload()
    }

    /// "Show in Finder" (D13 of YAZ-2919): the panel closes, and Finder shows the file.
    func showInFinder(_ item: PickItem) {
        guard case .own(let own) = item, let url = library.fileURL(of: own) else { return }
        close()
        showInFinder(url)
    }

    /// "Move to Trash" (D13 of YAZ-2919): the file goes to the macOS Trash, and the item is marked `removed`.
    /// Its still picture goes too (D5). No type-to-confirm: "Put Back" in Finder undoes it. The panel stays open.
    /// When the Trash refuses the file, nothing changes.
    func moveToTrash(_ item: PickItem) {
        guard case .own(let own) = item else { return }
        do { try library.remove(own.id) } catch { return }
        thumbnails?.removeStill(of: own.id)
        itemsChanged()
    }

    /// "Save to your GIFs" (or memes) of a KLIPY item (D7 of YAZ-2919): only its slug goes into the list.
    func saveToYours(_ item: PickItem) {
        guard case .online(let online) = item, let kind = item.kind else { return }
        library.saveKlipy(online.id, kind: kind)
        itemsChanged()
    }

    /// "Remove from your GIFs" (or memes) of a saved KLIPY item (D7, D13 of YAZ-2919). It has no file. Its counts stay.
    func removeFromYours(_ item: PickItem) {
        guard case .online(let online) = item else { return }
        try? library.remove(Item.klipyItemID(online.id))
        itemsChanged()
    }

    /// "Add a GIF or meme…" (D12 of YAZ-2919).
    func addNew() {
        onAddNew()
    }

    /// True when a KLIPY item is in your GIFs or memes (D7).
    private func isSaved(_ item: OnlineItem) -> Bool {
        library.item(Item.klipyItemID(item.id)).map { !$0.isRemoved } ?? false
    }

    /// The list changed: the grid shows it at once, with the blue box on the same item when it is still there.
    private func itemsChanged() {
        tileEntries = [:]
        rebuild(keeping: selectedItem)
        panel?.reload()
    }

    private func onlineChanged() {
        tileEntries = [:]
        guard isOpen, tab != .emoji, addingWordFor == nil else { return }
        rebuild(keeping: selectedItem)
        panel?.reload()
    }

    // MARK: Add a word (D4; D13 of YAZ-2919)

    /// The text of the one line while "Add a word…" waits.
    static func addingWordText(_ emoji: Emoji) -> String {
        addingWordText(.emoji(emoji))
    }

    static func addingWordText(_ item: PickItem) -> String {
        "Type a word for \(name(of: item)). Enter adds it. Esc stops."
    }

    /// The emoji itself, "this GIF" or "this meme".
    static func name(of item: PickItem) -> String {
        if let emoji = item.emoji { return emoji.text }
        return item.kind == .meme ? "this meme" : "this GIF"
    }

    func addWord(for emoji: Emoji) {
        addWord(for: .emoji(emoji))
    }

    /// The right-click "Add a word…". With a search, the search text is the word, and the app adds it at once.
    /// With an empty search, the search box asks for the word. An emoji keeps the word in `you-<Mac>.json`,
    /// a GIF or meme in its `words` (D13 of YAZ-2919).
    func addWord(for item: PickItem) {
        if !Search.normalize(query).isEmpty {
            add(query, to: item)
            rebuild(keeping: item)
            panel?.reload()
        } else {
            addingWordFor = item
            lines = [.title(PickSession.addingWordText(item))]
            items = []
            mostUsedItems = nil
            selection = nil
            panel?.reload()
        }
    }

    private func add(_ word: String, to item: PickItem) {
        guard !Search.normalize(word).isEmpty else { return }
        switch item {
        case .emoji(let emoji):
            store.addWord(word, to: emoji.text)
        case .own(let own):
            library.addWords([word], to: own.id)
            tileEntries = [:]
        case .online(let online):
            library.addWords([word], to: Item.klipyItemID(online.id))
            tileEntries = [:]
        }
    }

    /// Enter while "Add a word…" waits. An empty word adds nothing.
    private func finishAddingWord() {
        guard let item = addingWordFor else { return }
        let word = query
        addingWordFor = nil
        add(word, to: item)
        // The search box shows the word, so the item shows as a result at once.
        rebuild(keeping: item)
        panel?.reload()
    }

    private func stopAddingWord() {
        addingWordFor = nil
        query = ""
        rebuild()
        panel?.reload()
    }

    // MARK: The lines of the grid (D7; D11 of YAZ-2919)

    static func resultsTitle(_ count: Int) -> String {
        count == 1 ? "1 result" : "\(count) results"
    }

    static func noMatchTitle(_ query: String) -> String {
        "No match for \"\(query)\". Right-click an emoji below to add this word."
    }

    /// The line of a search with no match in the GIFs and Memes tabs (D11 of YAZ-2919).
    static func noTileMatchTitle(_ query: String) -> String {
        "No match for \"\(query)\"."
    }

    /// "Your GIFs" or "Your memes".
    nonisolated static func yourTitle(_ kind: ItemKind) -> String {
        kind == .gif ? "Your GIFs" : "Your memes"
    }

    /// The line of a tab with no GIFs or no memes.
    static func emptyTitle(_ kind: ItemKind) -> String {
        kind == .gif ? "No GIFs yet. Right-click here to add one." : "No memes yet. Right-click here to add one."
    }

    /// The lines and the items that a rebuild makes.
    private struct Grid {
        let columns: Int
        var items: [PickItem] = []
        var lines: [Line] = []
        var mostUsed: Range<Int>?

        mutating func addSection(_ title: String, _ new: [PickItem]) {
            lines.append(.title(title))
            addRows(new)
        }

        mutating func addRows(_ new: [PickItem]) {
            let start = items.count
            items += new
            for rowStart in stride(from: start, to: items.count, by: columns) {
                lines.append(.cells(rowStart..<min(rowStart + columns, items.count)))
            }
        }
    }

    /// Makes the lines again from the tab and the search text. The blue box goes on the first item,
    /// or on `kept` when it is still in the grid.
    private func rebuild(keeping kept: PickItem? = nil) {
        var grid = Grid(columns: columnCount)
        let firstSelection: Int?
        if let kind = tab.kind {
            firstSelection = buildTiles(kind, into: &grid)
        } else {
            firstSelection = buildEmojis(into: &grid)
        }
        items = grid.items
        lines = grid.lines
        mostUsedItems = grid.mostUsed
        if let kept, firstSelection != nil, let place = grid.items.firstIndex(where: { $0.isSame(as: kept) }) {
            selection = place
        } else {
            selection = grid.items.isEmpty ? nil : firstSelection
        }
    }

    /// The Emoji tab, the same as v0.1. Returns the first place of the blue box: 0, or nil with no match.
    private func buildEmojis(into grid: inout Grid) -> Int? {
        /// "Your most used", then all the groups. Also with no results (D18): then each emoji is in
        /// the grid, and a pick of any emoji learns the new search text in one step (D4).
        func addMostUsedAndGroups() {
            let most = Search.mostUsed(in: catalog, you: store.you, limit: PickSession.mostUsedLimit)
            if !most.isEmpty {
                let start = grid.items.count
                grid.addSection(PickSession.mostUsedTitle, most.map(PickItem.emoji))
                grid.mostUsed = start..<grid.items.count
            }
            for group in groups { grid.addSection(group.name, group.emojis.map(PickItem.emoji)) }
        }

        let text = Search.normalize(query)
        guard !text.isEmpty else {
            addMostUsedAndGroups()
            return 0
        }
        let results = Search.results(for: query, in: catalog, you: store.you)
        guard !results.isEmpty else {
            grid.lines.append(.title(PickSession.noMatchTitle(query.trimmingCharacters(in: .whitespaces))))
            addMostUsedAndGroups()
            // Enter with no results does nothing (D8), until an arrow key puts the blue box on an emoji.
            return nil
        }
        grid.addSection(PickSession.resultsTitle(results.count), results.map(PickItem.emoji))
        return 0
    }

    /// The GIFs or Memes tab (D11 of YAZ-2919). With no search: "Your most used" (6), then "Your GIFs", newest first.
    /// With a search: "Yours", then "From KLIPY". No match anywhere: the line, then the sections of no search.
    private func buildTiles(_ kind: ItemKind, into grid: inout Grid) -> Int? {
        let entries = tiles(kind)
        // D4 of YAZ-2919: the tiles of your files are grey, and search and KLIPY still work.
        if library.mediaFolderIsMissing { grid.lines.append(.title(MediaFolder.missingText)) }
        func addMostUsedAndAll() {
            let most = Search.mostUsed(of: entries + onlineEntries(kind, keys: Array(store.you.uses.keys)), you: store.you,
                                       limit: PickSession.tileMostUsedLimit)
            if !most.isEmpty {
                let start = grid.items.count
                grid.addSection(PickSession.mostUsedTitle, most.map(\.item))
                grid.mostUsed = start..<grid.items.count
            }
            grid.addSection(PickSession.yourTitle(kind), entries.map(\.item))
            if entries.isEmpty { grid.lines.append(.title(PickSession.emptyTitle(kind))) }
        }

        let text = Search.normalize(query)
        guard !text.isEmpty else {
            addMostUsedAndAll()
            return 0
        }
        // "Yours": your files, your saved KLIPY items, and the KLIPY items that you picked for this text before (D7).
        let learned = store.you.learned[text].map { Array($0.keys) } ?? []
        let yours = Search.ranked(for: query, in: entries + onlineEntries(kind, keys: learned), you: store.you)
        let fromOnline = online?.section(for: text, kind: kind)
        if yours.isEmpty && (fromOnline?.items.isEmpty ?? true) {
            grid.lines.append(.title(PickSession.noTileMatchTitle(query.trimmingCharacters(in: .whitespaces))))
            if let line = fromOnline?.line { grid.lines.append(.title(line)) }
            addMostUsedAndAll()
            return nil
        }
        if !yours.isEmpty { grid.addSection(PickSession.yoursTitle, yours.map(\.item)) }
        if let fromOnline {
            // KLIPY's order stays, in its own section (KLIPY's rules 4 and 5).
            grid.addSection(PickSession.onlineTitle, fromOnline.items.map(PickItem.online))
            if let line = fromOnline.line { grid.lines.append(.title(line)) }
        }
        return 0
    }

    /// The search entries of your files and your saved KLIPY items of one kind, newest first.
    /// A saved KLIPY item shows only when KLIPY gave it to this session (D7).
    private func tiles(_ kind: ItemKind) -> [TileEntry] {
        if let entries = tileEntries[kind] { return entries }
        var entries: [TileEntry] = []
        for item in library.items(kind) {
            let pick: PickItem
            if item.file != nil {
                pick = .own(item)
            } else if let slug = item.klipyID, let found = online?.item(slug) {
                pick = .online(found)
            } else {
                continue
            }
            entries.append(TileEntry(item: pick, words: item.words, order: entries.count))
        }
        tileEntries[kind] = entries
        return entries
    }

    /// The KLIPY items of one kind for these `you` keys that are not saved: picked or learned items (D7).
    /// They come after your own items in the order.
    private func onlineEntries(_ kind: ItemKind, keys: [String]) -> [TileEntry] {
        guard let online else { return [] }
        let start = tiles(kind).count
        var entries: [TileEntry] = []
        for key in keys.sorted() where key.hasPrefix("klipy:") {
            guard let item = online.item(String(key.dropFirst("klipy:".count))), item.kind.rawValue == kind.rawValue,
                  !isSaved(item) else { continue }
            entries.append(TileEntry(item: .online(item), words: [], order: start + entries.count))
        }
        return entries
    }
}

private extension String {
    /// "Your GIFs" → "your GIFs".
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
