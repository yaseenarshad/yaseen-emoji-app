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
    /// The query, the lines or the items changed. The grid goes to the top, with the blue box in sight.
    func reload()
    /// New KLIPY results or items came (D11 of YAZ-2919). The grid takes the new lines and keeps its scroll.
    func update()
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
        case .online(let item): return item.kind
        }
    }

    /// The row of Settings → "When you press Enter" that a pick of this item uses (D16 of YAZ-2919).
    var pickKind: PickKind { kind.map(PickKind.init) ?? .emoji }

    /// True for a GIF: its tile plays while it is on the screen (D11 update on YAZ-2925). A meme and an emoji stay still.
    var plays: Bool { kind == .gif }

    /// True for the same emoji (the same text), or the same GIF or meme (the same key).
    func isSame(as other: PickItem) -> Bool {
        if let emoji, let otherEmoji = other.emoji { return emoji.text == otherEmoji.text }
        return emoji == nil && other.emoji == nil && key == other.key
    }
}

/// The search entry of one GIF or meme (D11 of YAZ-2919). Its name is its title (D15): the full title gives `isName`,
/// as the name of an emoji. Its words are the words of the item and of the title, and a word with spaces also gives
/// its single words. `order` is the place in the list, newest first.
/// A class: the search copies each entry, and a copy of a reference is cheaper than a copy of the item.
final class TileEntry: Searchable {
    let item: PickItem
    let key: String
    /// The title, normalized, or "".
    let name: String
    let nameBytes: [UInt8]
    let wordBytes: [[UInt8]]
    let order: Int

    init(item: PickItem, words: [String], title: String = "", order: Int) {
        self.item = item
        key = item.key
        self.order = order
        name = Search.normalize(title)
        nameBytes = Array(name.utf8)
        var all: [String] = []
        for word in words + (name.isEmpty ? [] : [name]) {
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
    /// The title of the KLIPY results (D11 of YAZ-2919).
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
        /// "Rename…" of your own GIF or meme (D15 of YAZ-2919).
        case rename
        /// Your own GIF or meme (D13 of YAZ-2919).
        case showInFinder
        /// A KLIPY item (D7, D13 of YAZ-2919): "Save to your GIFs" and "Remove from your GIFs" (or memes).
        case saveToYours(ItemKind), removeFromYours(ItemKind)
        /// "Add a GIF or meme…": the add window of subissue 3 (D12 of YAZ-2919).
        case addNew

        var title: String {
            switch self {
            case .addWord: return "Add a word…"
            case .rename: return "Rename…"
            case .copyOnly: return "Copy only"
            case .hideFromMostUsed: return "Hide from Your most used"
            case .showInFinder: return "Show in Finder"
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
    private(set) var selection: Int? {
        didSet { online?.selectionChanged(to: selectedOnlineItem) }
    }
    /// What the search box asks for, while the grid shows only the line of the question: a word for "Add a word…"
    /// (with an empty search, D4), or a title for "Rename…" (D15 of YAZ-2919). The tabs and the arrows wait.
    enum Question: Equatable {
        case word(PickItem)
        case title(PickItem)

        var item: PickItem {
            switch self {
            case .word(let item), .title(let item): return item
            }
        }
    }

    /// The question of the search box, or nil.
    private(set) var question: Question?

    /// The item that waits for a word from "Add a word…" (with an empty search).
    var addingWordFor: PickItem? {
        if case .word(let item) = question { return item }
        return nil
    }
    /// The KLIPY item of a pick that waits for its paste file (up to 3 s, D6 of YAZ-2919).
    private(set) var waitingFor: PickItem?
    /// The grey line at the top of the GIFs and Memes tabs: "Getting the GIF…" or "Can't get this GIF from KLIPY.".
    private(set) var notice: String?
    /// Changes at each wait, so an old answer does nothing.
    private var waitCount = 0

    weak var panel: PickPanel?
    /// Runs each time the panel opens, before the grid is made. The app reads the changed history files here (D16).
    var willOpen: () -> Void = {}
    /// "Show in Finder" (D13 of YAZ-2919). The app gives `NSWorkspace.activateFileViewerSelecting`.
    var showInFinder: (URL) -> Void = { _ in }
    /// "Add a GIF or meme…" (D12 of YAZ-2919). The app opens the add window here.
    var onAddNew: () -> Void = {}
    /// A drop of files on the panel (D12 of YAZ-2919). The app opens the add window with one row for each file.
    var onAddFiles: ([AddSource]) -> Void = { _ in }

    let catalog: [Emoji]
    let store: YouStore
    /// The list of GIFs and memes of all Macs (D3 of YAZ-2919).
    let library: LibraryStore
    /// KLIPY (D1 of YAZ-2919): `KlipyResults` in the app. Nil: no "From KLIPY" section.
    let online: OnlineResults?
    /// The still pictures of the tiles. At each open, the session deletes the still pictures of the items that do not
    /// show (D5 of YAZ-2919).
    let thumbnails: Thumbnails?
    private let prefs: Prefs
    private let paster: Paster
    /// The emojis of each group, in Unicode order. Made one time, not at each key press.
    private let groups: [(name: String, emojis: [Emoji])]
    /// The search entries of the GIFs and memes of each tab, newest first. Made again at each open and after a change.
    private var tileEntries: [ItemKind: [TileEntry]] = [:]
    /// The search entries of the cards of each tab (D18 of YAZ-2919), the last use first. Made with `tileEntries`.
    private var cardEntryLists: [ItemKind: [TileEntry]] = [:]

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
        question = nil
        stopWaiting()
        willOpen()
        online?.refresh()
        // The lists of the other Macs can have new items or new removes.
        forgetEntries()
        thumbnails?.retryFailed()
        // A missing GIFs and memes folder (an unmounted drive) hides all your items: their still pictures stay.
        if !library.mediaFolderIsMissing {
            thumbnails?.removeStills(keeping: Set(library.items.compactMap { item in
                item.file != nil && !library.missing.contains(item.id) ? item.id : nil
            }))
        }
        rebuild()
        panel?.reload()
        panel?.show()
    }

    /// Esc, a click outside, the hotkey again, or a pick that closes. Safe to call two times.
    func close() {
        guard isOpen else { return }
        isOpen = false
        question = nil
        stopWaiting()
        online?.stop()
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
        guard question == nil, new != tab else { return }
        tab = new
        stopWaiting()
        rebuild()
        panel?.reload()
    }

    /// The text in the empty search box (D10 and its update on YAZ-2919).
    var placeholder: String {
        switch question {
        case .word(let item): return "A word for \(PickSession.name(of: item))"
        case .title(let item): return "A title for \"\(PickSession.shortName(of: item))\""
        case nil: break
        }
        switch tab {
        case .emoji: return "Search emoji"
        case .gifs: return klipy(.gif)?.isOn == true ? "Search KLIPY" : "Search your GIFs"
        case .memes: return klipy(.meme)?.isOn == true ? "Search KLIPY" : "Search your memes"
        }
    }

    /// KLIPY for the tab of `kind`, or nil when its switch in Settings is off (D14 update of YAZ-2919).
    /// The GIFs and Memes tabs ask KLIPY only through this. Thus a tab with its switch off is the same as a tab
    /// with no `OnlineResults`: no request, no "From KLIPY", and no saved or learned KLIPY items.
    private func klipy(_ kind: ItemKind) -> OnlineResults? {
        prefs.searchesKlipy(kind) ? online : nil
    }

    /// A KLIPY switch changed: the tabs use it at once. The saved and learned KLIPY items go, or come back.
    func klipySwitchChanged() {
        forgetEntries()
        guard isOpen, tab != .emoji, question == nil else { return }
        stopWaiting()
        rebuild(keeping: selectedItem)
        panel?.reload()
    }

    // MARK: The keys

    /// The search box changed.
    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        // The word for "Add a word…" is not a search.
        guard question == nil else { return }
        stopWaiting()
        rebuild()
        panel?.reload()
    }

    /// Enter picks and closes. Shift+Enter picks and stays open (D8).
    /// While "Add a word…" waits, Enter adds the word. While "Rename…" waits, Enter saves the title.
    func enter(shift: Bool) {
        if question != nil {
            finishQuestion()
        } else {
            pick(stayOpen: shift)
        }
    }

    /// Esc stops "Add a word…" or "Rename…". Else it closes the panel with no paste (D8).
    func escape() {
        if question != nil {
            stopQuestion()
        } else {
            close()
        }
    }

    /// The arrow keys. Left and Right go along the order of the grid. Up and Down keep the column.
    /// At the first or the last item the blue box stays. With no blue box, each arrow puts it on the first item.
    func move(_ direction: Direction) {
        guard question == nil, !items.isEmpty else { return }
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
        if notice != nil || waitingFor != nil {
            // The line of a pick that waits or failed goes, with the blue box on the new item.
            stopWaiting()
            rebuild(keeping: items[index])
            panel?.update()
        }
        panel?.showSelection()
        // The blue box in the last row: the next page of "From KLIPY" (D11 of YAZ-2919).
        if let selection, selection >= items.count - columnCount { reachedEnd() }
    }

    /// The grid is near its end, or the blue box is in the last row: the next page of "From KLIPY" (D11 of YAZ-2919).
    func reachedEnd() {
        guard isOpen, let kind = tab.kind, question == nil else { return }
        let text = Search.normalize(query)
        guard !text.isEmpty else { return }
        klipy(kind)?.loadMore(for: text, kind: kind)
    }

    var selectedItem: PickItem? {
        selection.map { items[$0] }
    }

    var selectedEmoji: Emoji? {
        selectedItem?.emoji
    }

    private var selectedOnlineItem: OnlineItem? {
        if case .online(let item) = selectedItem { return item }
        return nil
    }

    // MARK: Picks

    /// How a pick puts its item: a paste (that closes the panel, or stays open), or "Copy only".
    private enum Delivery {
        case paste(stayOpen: Bool)
        case copy
    }

    /// Puts the item with the blue box into the app in front (D2; D6 of YAZ-2919), and learns the search text (D4).
    /// With no blue box (no results), or a GIF whose file went away while the panel is open, it does nothing (D8; D4 of YAZ-2919).
    /// A KLIPY item whose paste file is not ready waits up to 3 s, with "Getting the GIF…".
    func pick(stayOpen: Bool) {
        start(.paste(stayOpen: stayOpen))
    }

    /// ⌘C and the right-click "Copy only": the item goes on the clipboard, and the panel closes (D8).
    /// It is a pick, so it counts a use and learns the search text.
    func copyOnly() {
        start(.copy)
    }

    private func start(_ delivery: Delivery) {
        guard let item = selectedItem else { return }
        if let clip = clip(for: item) { return deliver(item, clip, delivery) }
        guard case .online(let found) = item, let online else { return }
        waitCount += 1
        let count = waitCount
        waitingFor = item
        show(notice: PickSession.gettingText(found.kind))
        online.getPasteFile(for: found) { [weak self] url in
            guard let self, self.isOpen, self.waitCount == count, self.waitingFor != nil else { return }
            self.waitingFor = nil
            guard let url else { return self.show(notice: PickSession.cantGetText(found.kind)) }
            self.show(notice: nil)
            self.deliver(item, .file(url, type: found.fileType), delivery)
        }
    }

    /// The paste starts before the save: with a full `you.json` (5,000 learned pairs)
    /// the save takes about 23 ms in a release build, and the panel must not wait for it.
    /// A pick of a KLIPY item (D18 of YAZ-2919) moves its file into the kept files first, so the clipboard gets the
    /// kept file, not the temp file. After the paste starts, its card goes into the list with the new last use.
    private func deliver(_ item: PickItem, _ clip: Paster.Clip, _ delivery: Delivery) {
        let key = pickKey(item)
        let query = self.query
        let clip = keptClip(of: item) ?? clip
        func record() {
            store.recordPick(key, query: query)
            if case .online(let found) = item { useCard(found) }
        }
        guard case .paste(let stayOpen) = delivery else {
            close()
            paster.deliver(clip, paste: false)
            record()
            return
        }
        // The mode and the Keep value of the kind of the item (D16 of YAZ-2919).
        let paste = paster.willPaste(prefs.pickMode(item.pickKind))
        let keep = prefs.keepsOnClipboard(item.pickKind)
        guard stayOpen else {
            close()
            paster.deliver(clip, paste: paste, keep: keep)
            record()
            return
        }
        if paste {
            panel?.stepAside()
            paster.deliver(clip, paste: true, keep: keep) { [weak self] in
                guard let self, self.isOpen else { return }
                self.panel?.comeBack()
            }
        } else {
            paster.deliver(clip, paste: false)
        }
        record()
        // The list does not move while the panel stays open, so the blue box stays where you
        // look. The new use and the learned word change the order the next time.
    }

    /// The kept file of a KLIPY item that you pick (D18 of YAZ-2919), or nil.
    private func keptClip(of item: PickItem) -> Paster.Clip? {
        guard case .online(let found) = item, let url = online?.keepFile(of: found) else { return nil }
        return .file(url, type: found.fileType)
    }

    /// The card of a KLIPY item that you picked (D18 of YAZ-2919), with the new last use. It syncs.
    private func useCard(_ item: OnlineItem) {
        library.useCard(KlipyCard(item, lastUsed: Date()))
        cardEntryLists = [:]
    }

    /// "Getting the GIF…" or "Getting the meme…".
    static func gettingText(_ kind: ItemKind) -> String {
        kind == .gif ? "Getting the GIF…" : "Getting the meme…"
    }

    /// "Can't get this GIF from KLIPY." or the same for a meme.
    static func cantGetText(_ kind: ItemKind) -> String {
        kind == .gif ? "Can't get this GIF from KLIPY." : "Can't get this meme from KLIPY."
    }

    /// Shows or hides the grey line at the top of the tab, and keeps the blue box and the scroll.
    private func show(notice text: String?) {
        guard notice != text else { return }
        notice = text
        guard isOpen else { return }
        rebuild(keeping: selectedItem)
        panel?.update()
    }

    /// A key, a tab or a different item stops the wait and the line. The caller builds the grid again.
    private func stopWaiting() {
        waitingFor = nil
        notice = nil
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
    /// * Your own GIF or meme: "Add a word…", "Rename…" (D15), "Copy only", "Show in Finder", "Add a GIF or meme…".
    ///   No "Move to Trash": you delete the file in Finder (D13 update on YAZ-2926).
    ///   A KLIPY item has no "Rename…": it keeps KLIPY's title.
    /// * A saved KLIPY item: "Add a word…", "Copy only", "Remove from your GIFs", "Add a GIF or meme…".
    /// * A KLIPY item that is not saved: "Save to your GIFs", "Copy only", "Add a GIF or meme…". In "Your most used"
    ///   (a KLIPY item that you picked) also "Hide from Your most used": D15 applies to each item of that section.
    func menuActions(at index: Int) -> [MenuAction] {
        guard items.indices.contains(index) else { return [] }
        let hide: [MenuAction] = mostUsedItems?.contains(index) == true ? [.hideFromMostUsed] : []
        switch items[index] {
        case .emoji:
            return [.addWord, .copyOnly] + hide
        case .own:
            return [.addWord, .rename, .copyOnly] + hide + [.showInFinder, .addNew]
        case .online(let item):
            if isSaved(item) { return [.addWord, .copyOnly] + hide + [.removeFromYours(item.kind), .addNew] }
            return [.saveToYours(item.kind), .copyOnly] + hide + [.addNew]
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
        case .rename: rename(item)
        case .copyOnly: copyOnly()
        case .hideFromMostUsed: hideFromMostUsed(item: item)
        case .showInFinder: showInFinder(item)
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

    /// "Save to your GIFs" (or memes) of a KLIPY item (D18 of YAZ-2919): its file becomes your own item in `gifs/`
    /// or `memes/`, with KLIPY's title. The file is the kept file, else the paste file (a download of up to 3 s).
    /// With a search, the search text is the word of the item. The card of the item stays.
    func saveToYours(_ item: PickItem) {
        guard case .online(let found) = item, let online else { return }
        // The search text is its word, so the next search with that word shows it in "Yours".
        let word = Search.normalize(query)
        online.getPasteFile(for: found) { [weak self] url in
            guard let self else { return }
            guard let url else { return self.show(notice: PickSession.cantGetText(found.kind)) }
            Task { await self.copyToYours(url, found, words: word.isEmpty ? [] : [word]) }
        }
    }

    /// The steps of the add window (D5, D12 of YAZ-2919): `MediaImport.prepare` and the write of the file off the
    /// main thread, then `LibraryStore.add` on the main thread. The file of KLIPY stays where it is.
    private func copyToYours(_ url: URL, _ found: OnlineItem, words: [String]) async {
        do {
            let file = try await MediaImport.prepare(url)
            if let target = library.place(of: file, as: found.kind) {
                try await Task.detached(priority: .userInitiated) { try LibraryStore.writeMediaFile(file.bytes, to: target) }.value
            }
            try library.add(file, as: found.kind, words: words, title: found.title, klipyID: found.id)
            forgetEntries()
            guard isOpen, question == nil else { return }
            rebuild(keeping: selectedItem)
            panel?.reload()
        } catch {
            show(notice: error.localizedDescription)
        }
    }

    /// "Remove from your GIFs" (or memes) of a saved KLIPY item (D7, D13 of YAZ-2919). It has no file. Its counts stay.
    func removeFromYours(_ item: PickItem) {
        guard case .online(let online) = item else { return }
        library.remove(Item.klipyItemID(online.id))
        itemsChanged()
    }

    /// "Add a GIF or meme…" (D12 of YAZ-2919).
    func addNew() {
        onAddNew()
    }

    /// A drop of files on the panel (D12 of YAZ-2919): the panel closes, and the add window opens with the files.
    /// The add window stays open, so the files do not go when you click away.
    func addFiles(_ sources: [AddSource]) {
        guard !sources.isEmpty else { return }
        close()
        onAddFiles(sources)
    }

    /// True when a KLIPY item is saved by its slug in your GIFs or memes (D7).
    private func isSaved(_ item: OnlineItem) -> Bool { isSaved(slug: item.id) }

    private func isSaved(slug: String) -> Bool {
        library.item(Item.klipyItemID(slug)).map { !$0.isRemoved } ?? false
    }

    /// The lists of search entries are made again at the next build: after an open, a change of the list,
    /// new KLIPY items, or a switch.
    private func forgetEntries() {
        tileEntries = [:]
        cardEntryLists = [:]
    }

    /// The list changed: the grid shows it at once, with the blue box on the same item when it is still there.
    private func itemsChanged() {
        forgetEntries()
        rebuild(keeping: selectedItem)
        panel?.reload()
    }

    /// New KLIPY results or items: the grid shows them, with the blue box on the same item and the same scroll.
    private func onlineChanged() {
        forgetEntries()
        guard isOpen, tab != .emoji, question == nil else { return }
        rebuild(keeping: selectedItem)
        panel?.update()
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
            ask(.word(item), line: PickSession.addingWordText(item))
        }
    }

    /// The grid shows only the line of the question, and the search box takes the answer.
    private func ask(_ new: Question, line: String) {
        question = new
        lines = [.title(line)]
        items = []
        mostUsedItems = nil
        selection = nil
        panel?.reload()
    }

    private func add(_ word: String, to item: PickItem) {
        guard !Search.normalize(word).isEmpty else { return }
        switch item {
        case .emoji(let emoji):
            store.addWord(word, to: emoji.text)
        case .own(let own):
            library.addWords([word], to: own.id)
            forgetEntries()
        case .online(let online):
            library.addWords([word], to: Item.klipyItemID(online.id))
            forgetEntries()
        }
    }

    /// Enter while "Add a word…" or "Rename…" waits. An empty word adds nothing. An empty title clears the title.
    private func finishQuestion() {
        guard let question else { return }
        let text = query
        self.question = nil
        switch question {
        case .word(let item):
            add(text, to: item)
        case .title(let item):
            guard case .own(let own) = item else { break }
            library.setTitle(text, of: own.id)
            forgetEntries()
            query = Item.cleanTitle(text)
        }
        // The search box shows the word or the title, so the item shows as a result at once.
        rebuild(keeping: question.item)
        panel?.reload()
    }

    private func stopQuestion() {
        question = nil
        query = ""
        rebuild()
        panel?.reload()
    }

    // MARK: Titles (D15 of YAZ-2919)

    /// The text of the one line while "Rename…" waits.
    static func renameText(_ item: PickItem) -> String {
        "Type a title for \"\(shortName(of: item))\". Enter saves. Esc stops."
    }

    /// The text below a tile: the title, else the first 3 words of the item. A KLIPY tile shows KLIPY's title.
    /// An emoji has none.
    static func label(of item: PickItem) -> String {
        switch item {
        case .emoji: return ""
        case .own(let own): return own.title.isEmpty ? own.words.prefix(3).joined(separator: " ") : own.title
        case .online(let online): return online.title
        }
    }

    /// The name of an item in a question: the text of its tile, else "this GIF" or "this meme".
    static func shortName(of item: PickItem) -> String {
        let label = label(of: item)
        return label.isEmpty ? name(of: item) : label
    }

    /// The right-click "Rename…" of your own GIF or meme. The search box asks for the title, and starts with the
    /// title that the item has. The file keeps its name (D4).
    func rename(_ item: PickItem) {
        guard case .own(let own) = item else { return }
        query = library.item(own.id)?.title ?? own.title
        ask(.title(item), line: PickSession.renameText(item))
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

    /// "All your GIFs" or "All your memes": the rest of your items below the results of a search (D17 of YAZ-2919).
    nonisolated static func allYourTitle(_ kind: ItemKind) -> String {
        kind == .gif ? "All your GIFs" : "All your memes"
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
    /// With a search: "Yours", then "From KLIPY", then "All your GIFs" (the rest, D17). No match anywhere: the line,
    /// then the sections of no search.
    private func buildTiles(_ kind: ItemKind, into grid: inout Grid) -> Int? {
        let entries = tiles(kind)
        if let notice { grid.lines.append(.title(notice)) }
        // D4 of YAZ-2919: your files do not show (they are all missing), and search and KLIPY still work.
        if library.mediaFolderIsMissing { grid.lines.append(.title(MediaFolder.missingText)) }
        func addMostUsedAndAll() {
            let used = entries + cardEntries(kind) + onlineEntries(kind, keys: Array(store.you.uses.keys))
            let most = Search.mostUsed(of: used, you: store.you, limit: PickSession.tileMostUsedLimit)
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
        // "Yours": your files, your saved KLIPY items, the cards of the KLIPY items that you used (D18), and the KLIPY
        // items with no card that you picked for this text before (D7). A card matches by its title and its learned words.
        let learned = store.you.learned[text].map { Array($0.keys) } ?? []
        let candidates = entries + cardEntries(kind) + onlineEntries(kind, keys: learned)
        let yours = Search.ranked(for: query, in: candidates, you: store.you)
        let fromOnline = klipy(kind)?.section(for: text, kind: kind)
        // While KLIPY searches, the grid does not say "No match" yet.
        if yours.isEmpty && (fromOnline?.items.isEmpty ?? true) && fromOnline?.isLoading != true {
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
        // D17 of YAZ-2919: the rest of your items, newest first, so a pick or "Add a word…" teaches this text
        // to an item that the search did not find.
        let found = Set(yours.map(\.item.key))
        let rest = entries.filter { !found.contains($0.item.key) }
        if !rest.isEmpty { grid.addSection(PickSession.allYourTitle(kind), rest.map(\.item)) }
        return 0
    }

    /// The search entries of your files and your saved KLIPY items of one kind, newest first.
    /// A saved KLIPY item shows from its card (D18), or when KLIPY gave it to this session (D7).
    /// Your item whose file is missing does not show (D13 update on YAZ-2926): it stays in the list, and it shows
    /// again at the next open when the file is back. `LibraryStore.missing` comes from one listing of `gifs/` and
    /// `memes/` at each open, not from a check of each tile.
    private func tiles(_ kind: ItemKind) -> [TileEntry] {
        if let entries = tileEntries[kind] { return entries }
        var entries: [TileEntry] = []
        for item in library.items(kind) {
            let pick: PickItem
            let title: String
            if item.file != nil {
                guard !library.missing.contains(item.id) else { continue }
                pick = .own(item)
                title = item.title
            } else if let slug = item.klipyID,
                      let found = klipyItem(slug, kind: kind, lastUsed: store.you.uses[KlipyCard.key(slug)]?.last ?? item.added) {
                // A saved KLIPY item keeps KLIPY's title (D15 of YAZ-2919).
                pick = .online(found)
                title = found.title
            } else {
                continue
            }
            entries.append(TileEntry(item: pick, words: item.words, title: title, order: entries.count))
        }
        tileEntries[kind] = entries
        return entries
    }

    /// The cards of one kind (D18 of YAZ-2919), the last use first: the KLIPY items that you used, with no lookup.
    /// Not here: a saved KLIPY item (it is in `tiles`), the card of your own item that "Save to your GIFs" copied
    /// (your item takes its place), and a card that KLIPY deleted and whose file this Mac does not have.
    /// They come after your own items in the order. A tab with its KLIPY switch off has none (D14 update).
    private func cardEntries(_ kind: ItemKind) -> [TileEntry] {
        if let entries = cardEntryLists[kind] { return entries }
        guard let online = klipy(kind) else { return [] }
        let copied = Set(library.items(kind).compactMap { item in
            item.file != nil && !library.missing.contains(item.id) ? item.klipyID : nil
        })
        let cards = library.cards.values.filter { $0.kind == kind }.sorted { a, b in
            a.lastUsed != b.lastUsed ? a.lastUsed > b.lastUsed : a.slug < b.slug
        }
        let start = tiles(kind).count
        var entries: [TileEntry] = []
        for card in cards where !copied.contains(card.slug) && !isSaved(slug: card.slug) {
            guard let item = online.item(for: card) else { continue }
            entries.append(TileEntry(item: .online(item), words: [], title: item.title, order: start + entries.count))
        }
        cardEntryLists[kind] = entries
        return entries
    }

    /// The KLIPY items of one kind for these `you` keys that have no card and are not saved: picked or learned items
    /// of an earlier build (D7). They come after the cards in the order.
    private func onlineEntries(_ kind: ItemKind, keys: [String]) -> [TileEntry] {
        guard klipy(kind) != nil else { return [] }
        let start = tiles(kind).count + cardEntries(kind).count
        var entries: [TileEntry] = []
        for key in keys.filter({ $0.hasPrefix("klipy:") }).sorted() {
            let slug = String(key.dropFirst("klipy:".count))
            guard library.card(slug) == nil, !isSaved(slug: slug),
                  let item = klipyItem(slug, kind: kind, lastUsed: store.you.uses[key]?.last) else { continue }
            entries.append(TileEntry(item: .online(item), words: [], title: item.title, order: start + entries.count))
        }
        return entries
    }

    /// The KLIPY item of a slug in the tab of `kind`: from its card with no request (D18), else from a lookup by slug
    /// (D7). The first lookup that gives the item makes its card, with this last use (the items of an earlier build).
    private func klipyItem(_ slug: String, kind: ItemKind, lastUsed: Date?) -> OnlineItem? {
        guard let online = klipy(kind) else { return nil }
        if let card = library.card(slug) { return card.kind == kind ? online.item(for: card) : nil }
        guard let found = online.item(slug, kind: kind) else { return nil }
        library.addCard(KlipyCard(found, lastUsed: lastUsed ?? Date()))
        cardEntryLists = [:]
        return found
    }
}

private extension String {
    /// "Your GIFs" → "your GIFs".
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
