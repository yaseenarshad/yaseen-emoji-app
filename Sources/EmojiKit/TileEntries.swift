import Foundation

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

    /// The key of your own file in the other tab (`Item.otherKey`), or nil.
    var otherKey: String? {
        if case .own(let item) = self { return item.otherKey }
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
/// as the name of an emoji. Its words are the words of the item, the folder words of its file (D23 of YAZ-3018) and
/// the title, and a word with spaces also gives its single words. `order` is the place in the list, newest first.
/// A class: the search copies each entry, and a copy of a reference is cheaper than a copy of the item.
final class TileEntry: Searchable {
    let item: PickItem
    let key: String
    /// The key of your own file in the other tab: its uses and learned words count too.
    let otherKey: String?
    /// The title, normalized, or "".
    let name: String
    let nameBytes: [UInt8]
    let wordBytes: [[UInt8]]
    let order: Int

    init(item: PickItem, words: [String], title: String = "", order: Int) {
        self.item = item
        key = item.key
        otherKey = item.otherKey
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

/// The search entries of the GIFs and Memes tabs (D11 of YAZ-2919), and the rules of which items show:
/// your files, your saved KLIPY items (D7), the cards of the KLIPY items that you used (D18), and the KLIPY items with
/// uses of an earlier build (D7). Only the files on disk show (D22 of YAZ-3018). A tab with its KLIPY
/// switch off shows no KLIPY item (D14 update). The lists stay until `forget()`: the session calls it at each open,
/// after a change of the list, for new KLIPY items, and after a switch change.
@MainActor
final class TileEntries {
    private let library: LibraryStore
    private let store: YouStore
    private let prefs: Prefs
    /// KLIPY: `KlipyResults` in the app. Nil: no KLIPY items.
    private let online: OnlineResults?
    /// The entries of your files and your saved KLIPY items of each tab, newest first.
    private var own: [ItemKind: [TileEntry]] = [:]
    /// The entries of the cards of each tab (D18), the last use first.
    private var cardLists: [ItemKind: [TileEntry]] = [:]

    init(library: LibraryStore, store: YouStore, prefs: Prefs, online: OnlineResults?) {
        self.library = library
        self.store = store
        self.prefs = prefs
        self.online = online
    }

    /// KLIPY for the tab of `kind`, or nil when its switch in Settings is off (D14 update of YAZ-2919).
    /// The GIFs and Memes tabs ask KLIPY only through this. Thus a tab with its switch off is the same as a tab
    /// with no `OnlineResults`: no request, no "From KLIPY", and no saved or learned KLIPY items.
    func klipy(_ kind: ItemKind) -> OnlineResults? {
        prefs.searchesKlipy(kind) ? online : nil
    }

    /// All lists are made again at the next build.
    func forget() {
        own = [:]
        cardLists = [:]
    }

    /// A pick wrote a card: the lists of the cards are made again at the next build.
    func forgetCards() {
        cardLists = [:]
    }

    /// True when a KLIPY item is saved by its slug in your GIFs or memes (D7).
    func isSaved(slug: String) -> Bool {
        library.item(Item.klipyItemID(slug)).map { !$0.isRemoved } ?? false
    }

    /// The search entries of your files and your saved KLIPY items of one kind, newest first.
    /// A saved KLIPY item shows from its card (D18), or when KLIPY gave it to this session (D7).
    /// Your files come from the scan of `gifs/` and `memes/` at each open (D22, D27 of YAZ-3018): a file that is
    /// missing is not in `LibraryStore.items`. The folders of a file give search words (D23 of YAZ-3018).
    func tiles(_ kind: ItemKind) -> [TileEntry] {
        if let entries = own[kind] { return entries }
        var entries: [TileEntry] = []
        for item in library.items(kind) {
            let pick: PickItem
            let title: String
            var words = item.words
            if let file = item.file {
                pick = .own(item)
                title = item.title
                words += MediaName.folderWords(ofPath: file)
            } else if let slug = item.klipyID,
                      let found = klipyItem(slug, kind: kind, lastUsed: store.you.uses[KlipyCard.key(slug)]?.last ?? item.added) {
                // A saved KLIPY item keeps KLIPY's title (D15 of YAZ-2919).
                pick = .online(found)
                title = found.title
            } else {
                continue
            }
            entries.append(TileEntry(item: pick, words: words, title: title, order: entries.count))
        }
        own[kind] = entries
        return entries
    }

    /// The cards of one kind (D18 of YAZ-2919), the last use first: the KLIPY items that you used, with no lookup.
    /// Not here: a saved KLIPY item (it is in `tiles`), the card of your own item that "Save to your GIFs" copied
    /// (your item takes its place), and a card that KLIPY deleted and whose file this Mac does not have.
    /// They come after your own items in the order. A tab with its KLIPY switch off has none (D14 update).
    func cards(_ kind: ItemKind) -> [TileEntry] {
        if let entries = cardLists[kind] { return entries }
        guard let online = klipy(kind) else { return [] }
        let copied = Set(library.items(kind).compactMap { item in item.file != nil ? item.klipyID : nil })
        let cards = library.cards.values.filter { $0.kind == kind }.sorted { a, b in
            a.lastUsed != b.lastUsed ? a.lastUsed > b.lastUsed : a.slug < b.slug
        }
        let start = tiles(kind).count
        var entries: [TileEntry] = []
        for card in cards where !copied.contains(card.slug) && !isSaved(slug: card.slug) {
            guard let item = online.item(for: card) else { continue }
            entries.append(TileEntry(item: .online(item), words: [], title: item.title, order: start + entries.count))
        }
        cardLists[kind] = entries
        return entries
    }

    /// The KLIPY items of one kind for these `you` keys that have no card and are not saved: picked or learned items
    /// of an earlier build (D7). They come after the cards in the order.
    func klipyEntries(_ kind: ItemKind, keys: [String]) -> [TileEntry] {
        guard klipy(kind) != nil else { return [] }
        let start = tiles(kind).count + cards(kind).count
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
        cardLists = [:]
        return found
    }
}
