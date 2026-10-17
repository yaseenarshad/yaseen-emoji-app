import CryptoKit
import Foundation

/// A GIF or a meme (D5 of YAZ-2919). The kind selects the tab and the folder of the file.
public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case gif
    case meme

    /// The folder of the files of this kind in the GIFs and memes folder (D4): `gifs` or `memes`.
    public var folderName: String {
        switch self {
        case .gif: return "gifs"
        case .meme: return "memes"
        }
    }
}

/// One GIF or meme of the list (D3 of YAZ-2919): your own file, or a saved KLIPY item (D7).
public struct Item: Codable, Equatable, Sendable {
    /// The first 16 hex characters of the SHA-256 of the file. `klipy-<klipyID>` for a KLIPY item.
    public var id: String
    public var kind: ItemKind
    /// The path in the GIFs and memes folder, for example `gifs/3fa9c1d2e8b04a77.gif`. Nil for a KLIPY item.
    public var file: String?
    /// The ID of a saved KLIPY item. Nil for your own file.
    public var klipyID: String?
    /// The words of the item: typed at add, or read from a meme (D8). "Forget learned words" keeps them.
    public var words: [String]
    /// The title of the tile (D15 of YAZ-2919), or "". It syncs with the item. The file keeps its code name (D4).
    public var title: String
    public var added: Date
    /// The time of "Remove from your GIFs" (or of "Move to Trash" in an earlier build), or nil.
    public var removed: Date?
    /// The time of the last change. The newest change of all Macs wins (D3).
    public var changed: Date

    public init(id: String, kind: ItemKind, file: String?, klipyID: String?, words: [String], title: String = "",
                added: Date, removed: Date? = nil, changed: Date) {
        self.id = id
        self.kind = kind
        self.file = file
        self.klipyID = klipyID
        self.words = words
        self.title = title
        self.added = added
        self.removed = removed
        self.changed = changed
    }

    /// A list file from an earlier build has no `title`: it gives "" (D15 of YAZ-2919).
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(ItemKind.self, forKey: .kind)
        file = try values.decodeIfPresent(String.self, forKey: .file)
        klipyID = try values.decodeIfPresent(String.self, forKey: .klipyID)
        words = try values.decode([String].self, forKey: .words)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        added = try values.decode(Date.self, forKey: .added)
        removed = try values.decodeIfPresent(Date.self, forKey: .removed)
        changed = try values.decode(Date.self, forKey: .changed)
    }

    /// The key of the item in `you-<Mac>.json` (D3): `gif:<id>`, `meme:<id>`, or `klipy:<klipyID>`.
    public var key: String {
        if let klipyID, file == nil { return "klipy:\(klipyID)" }
        return "\(kind.rawValue):\(id)"
    }

    public var isRemoved: Bool { removed != nil }

    /// The `id` of a saved KLIPY item. Two Macs that save the same KLIPY item get the same `id`.
    public static func klipyItemID(_ klipyID: String) -> String { "klipy-\(klipyID)" }

    /// The words to keep: each one `Search.normalize`d, no empty word, no copy, in the order given.
    static func clean(_ words: [String]) -> [String] {
        var result: [String] = []
        for word in words.map(Search.normalize) where !word.isEmpty && !result.contains(word) {
            result.append(word)
        }
        return result
    }

    /// Typed words, in the words box of the add window or in `--add-media --words`: split at spaces and commas,
    /// then `clean`. "Dance, party" gives "dance" and "party".
    static func words(typed text: String) -> [String] {
        clean(text.split { $0.isWhitespace || $0 == "," }.map(String.init))
    }

    /// A title as the list keeps it (D15 of YAZ-2919): trimmed, one space between words, the case as typed.
    static func cleanTitle(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The item that wins for one `id` (D3): the newest `changed`. The same time: the delete wins.
    /// The same time and the same state: more words, then the larger text of the words, then the larger title,
    /// so each Mac selects the same item.
    static func winner(_ a: Item, _ b: Item) -> Item {
        if a.changed != b.changed { return a.changed > b.changed ? a : b }
        if a.isRemoved != b.isRemoved { return a.isRemoved ? a : b }
        if a.words.count != b.words.count { return a.words.count > b.words.count ? a : b }
        let aWords = a.words.joined(separator: "\n"), bWords = b.words.joined(separator: "\n")
        if aWords != bWords { return aWords > bWords ? a : b }
        return a.title >= b.title ? a : b
    }
}

/// A KLIPY GIF or meme that you used (D18 of YAZ-2919). It syncs in `library-<Mac name>.json`, so the panel
/// makes its tile at once, with no lookup call. The file itself stays on this Mac only (`KlipyFiles`).
public struct KlipyCard: Codable, Equatable, Sendable {
    /// The KLIPY slug, the ID of D7.
    public var slug: String
    public var kind: ItemKind
    /// KLIPY's title (D15).
    public var title: String
    /// The URLs of `OnlineItem`, as KLIPY gave them: the still, the moving preview (nil for a meme), the paste file.
    public var still: URL
    public var preview: URL?
    public var file: URL
    /// The UTType identifier of `file`, for example `com.compuserve.gif`, and its extension.
    public var fileType: String
    public var fileExtension: String
    /// The size of `file`: pixels, and bytes when KLIPY gave them.
    public var width: Int
    public var height: Int
    public var bytes: Int?
    /// The last pick on any Mac. The newest wins in the merge, and the oldest card goes first at the limit.
    public var lastUsed: Date

    /// The key of the card in `LibraryFile.cards` and in `you-<Mac>.json`: `klipy:<slug>`.
    public var key: String { KlipyCard.key(slug) }

    public static func key(_ slug: String) -> String { "klipy:\(slug)" }

    /// The card that wins for one key: the newest `lastUsed`. The same time: the larger title, then the larger
    /// file URL, so each Mac selects the same card.
    static func winner(_ a: KlipyCard, _ b: KlipyCard) -> KlipyCard {
        if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed ? a : b }
        if a.title != b.title { return a.title > b.title ? a : b }
        return a.file.absoluteString >= b.file.absoluteString ? a : b
    }
}

/// The contents of one list file, `library-<Mac name>.json` (D3 of YAZ-2919): the items that this Mac added
/// or changed, by `id`, and the cards of the KLIPY items that this Mac used (D18), by `klipy:<slug>`.
/// The keys are sorted in the file, so a change gives a small git diff.
public struct LibraryFile: Codable, Equatable, Sendable {
    public var items: [String: Item]
    public var cards: [String: KlipyCard]

    public init(items: [String: Item] = [:], cards: [String: KlipyCard] = [:]) {
        self.items = items
        self.cards = cards
    }

    /// A field that is missing gives an empty value: a file of an earlier build has no `cards`.
    /// A card that cannot be read is skipped, so it never makes the full file bad.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decodeIfPresent([String: Item].self, forKey: .items) ?? [:]
        let read = (try? values.decodeIfPresent([String: Lenient<KlipyCard>].self, forKey: .cards)) ?? [:]
        cards = read.compactMapValues(\.value)
    }

    /// The cards of all Macs: for each key, the card of `KlipyCard.winner` (D18 of YAZ-2919).
    public static func combineCards(own: LibraryFile, others: [LibraryFile]) -> [String: KlipyCard] {
        var combined = own.cards
        for file in others {
            for (key, card) in file.cards {
                combined[key] = combined[key].map { KlipyCard.winner($0, card) } ?? card
            }
        }
        return combined
    }

    /// The list of all Macs: for each `id`, the item of `Item.winner`. Removed items stay in the result,
    /// so a later add on any Mac can win over the remove.
    public static func combine(own: LibraryFile, others: [LibraryFile]) -> [String: Item] {
        var combined = own.items
        for file in others {
            for (id, item) in file.items {
                combined[id] = combined[id].map { Item.winner($0, item) } ?? item
            }
        }
        return combined
    }
}

/// The SHA-256 of a file, as hex text. The `id` of an item and the check of a folder move use it.
enum MediaHash {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The `id` of your own file: the first 16 hex characters of the SHA-256 of its bytes (D3).
    static func id(_ data: Data) -> String { String(hex(data).prefix(16)) }
}

/// A file that is ready to add (D5 of YAZ-2919): the final bytes, their extension, the `id`, and the kind
/// that the file has. `MediaImport.prepare` makes it.
public struct PreparedFile: Equatable, Sendable {
    public var bytes: Data
    /// `gif`, `png` or `jpg`.
    public var ext: String
    public var id: String
    public var kind: ItemKind

    public init(bytes: Data, ext: String, kind: ItemKind) {
        self.bytes = bytes
        self.ext = ext
        self.kind = kind
        id = MediaHash.id(bytes)
    }
}

/// What `LibraryStore.add` did.
public enum AddResult: Equatable, Sendable {
    /// A new item, or an item that comes back after a remove.
    case added(Item)
    /// "You have this one already." (D12): the item with the same `id`, with the new words added.
    case alreadyThere(Item)

    public var item: Item {
        switch self {
        case .added(let item), .alreadyThere(let item): return item
        }
    }
}

/// The GIFs and memes folder of D4 on YAZ-2919: the place of `gifs/` and `memes/`.
/// The list file stays in the preferences folder, also when the files move.
public enum MediaFolder {
    static let missingText = "Can't find the GIFs and memes folder."

    /// The GIFs and memes folder is gone. An add does not make a new folder in its place.
    public struct Missing: LocalizedError {
        public var errorDescription: String? { MediaFolder.missingText }
    }

    /// A file in the new folder has the same name as an old file, but different bytes. The move stops.
    public struct DifferentFile: LocalizedError {
        public let name: String
        public var errorDescription: String? { "A different file named \(name) is already in the new folder." }
    }

    /// A copy does not have the size or the SHA-256 of the old file. The move stops.
    public struct BadCopy: LocalizedError {
        public let name: String
        public var errorDescription: String? { "The copy of \(name) is not the same as the old file." }
    }

    /// The folder to use: the chosen folder, or the preferences folder when none is chosen ("").
    /// A chosen folder that is gone stays the folder, with `isMissing` true: the items show grey tiles,
    /// and Settings shows the red line. The app never writes the files into a different folder in silence.
    public static func resolve(chosen: String, preferencesFolder: URL) -> (folder: URL, isMissing: Bool) {
        guard !chosen.isEmpty else { return (preferencesFolder, false) }
        let folder = URL(fileURLWithPath: chosen, isDirectory: true)
        return (folder, !PreferencesFolder.isUsable(folder))
    }

    /// Copies `gifs/` and `memes/` from `old` to `new`, checks each copy (size and SHA-256), then removes the old files.
    /// On a failure, it removes only the copies that it made, keeps all the old files, and throws.
    /// An old folder that is missing (for example, an unmounted drive) has nothing to copy.
    public static func move(from old: URL, to new: URL) throws {
        guard old.standardizedFileURL.path != new.standardizedFileURL.path else { return }
        let fileManager = FileManager.default
        var made: [URL] = []
        var done: [URL] = []
        do {
            for kind in ItemKind.allCases {
                let oldFolder = old.appendingPathComponent(kind.folderName, isDirectory: true)
                let names = ((try? fileManager.contentsOfDirectory(atPath: oldFolder.path)) ?? []).sorted()
                let newFolder = new.appendingPathComponent(kind.folderName, isDirectory: true)
                for name in names where !name.hasPrefix(".") {
                    let source = oldFolder.appendingPathComponent(name)
                    var isFolder: ObjCBool = false
                    guard fileManager.fileExists(atPath: source.path, isDirectory: &isFolder), !isFolder.boolValue else { continue }
                    let bytes = try Data(contentsOf: source)
                    let target = newFolder.appendingPathComponent(name)
                    if fileManager.fileExists(atPath: target.path) {
                        // Git can have the same file there already. The same bytes: keep it, with no copy.
                        guard try Data(contentsOf: target) == bytes else { throw DifferentFile(name: name) }
                    } else {
                        try fileManager.createDirectory(at: newFolder, withIntermediateDirectories: true)
                        try fileManager.copyItem(at: source, to: target)
                        made.append(target)
                        let copy = try Data(contentsOf: target)
                        guard copy.count == bytes.count, MediaHash.hex(copy) == MediaHash.hex(bytes) else {
                            throw BadCopy(name: name)
                        }
                    }
                    done.append(source)
                }
            }
        } catch {
            for copy in made { try? fileManager.removeItem(at: copy) }
            throw error
        }
        // Each file is safe in the new folder. A file that cannot be removed only stays as an extra copy.
        for source in done { try? fileManager.removeItem(at: source) }
        for kind in ItemKind.allCases {
            let oldFolder = old.appendingPathComponent(kind.folderName, isDirectory: true)
            if let rest = try? fileManager.contentsOfDirectory(atPath: oldFolder.path), rest.allSatisfy({ $0 == ".DS_Store" }) {
                try? fileManager.removeItem(at: oldFolder)
            }
        }
    }
}

/// Keeps this Mac's list of GIFs and memes in `library-<Mac name>.json` (D3 of YAZ-2919), and reads the lists
/// of the other Macs in the same folder. It works like `YouStore`: each change saves this Mac's file at once,
/// with an atomic write, and the store never writes the file of a different Mac.
/// The paths are parameters, so a test gives temp folders.
/// The app never deletes a file of `gifs/` or `memes/`: you delete it in Finder (D13 update on YAZ-2926).
public final class LibraryStore {
    /// This Mac's list file, in the preferences folder.
    public private(set) var url: URL
    /// The GIFs and memes folder (D4): the place of `gifs/` and `memes/`.
    public private(set) var mediaFolder: URL
    /// The items of this Mac only: the contents of `url`.
    public private(set) var own = LibraryFile()
    /// The list of all Macs, by `id`, with the removed items (`LibraryFile.combine`).
    public private(set) var all: [String: Item] = [:]
    /// The items that are not removed, the newest add first. The panel reads this.
    public private(set) var items: [Item] = []
    /// The cards of the KLIPY items that you used, of all Macs, by `klipy:<slug>` (D18 of YAZ-2919).
    public private(set) var cards: [String: KlipyCard] = [:]
    /// The `id`s of the items whose file is not in the GIFs and memes folder: deleted in Finder, or before a `git pull`.
    /// The panel does not show them (D13 update on YAZ-2926).
    public private(set) var missing: Set<String> = []
    /// True when the GIFs and memes folder is gone, for example on an unmounted drive.
    public private(set) var mediaFolderIsMissing = false
    /// The last error of a save, or nil. The store keeps the data in memory and tries again at the next change.
    public private(set) var saveError: Error?
    /// The file that `load()` moved away because it was bad, or nil.
    public private(set) var movedBadFile: URL?

    private var others = OtherMacFiles<LibraryFile>()
    /// True when a bad file could not move away. Then the store never writes over it.
    private var saveIsBlocked = false
    private let now: () -> Date

    public init(url: URL, mediaFolder: URL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.mediaFolder = mediaFolder
        self.now = now
    }

    /// The folder of this Mac's list file: the preferences folder.
    public var folder: URL { url.deletingLastPathComponent() }

    /// Reads this Mac's list and the lists of the other Macs. No file gives an empty list.
    /// A list of this Mac that cannot be read becomes `library-<Mac name>.bad.json`, and the store starts empty.
    public func load() {
        others.removeAll()
        switch MacFiles.loadOwn(LibraryFile.self, at: url) {
        case .missing:
            own = LibraryFile()
        case .loaded(let file):
            own = file
        case .movedBad(let bad):
            movedBadFile = bad
            own = LibraryFile()
        case .blocked(let error):
            // The bad file stays in place. A save must not write over it.
            saveError = error
            saveIsBlocked = true
            own = LibraryFile()
        }
        _ = readOthers()
        combine()
        _ = checkFiles()
    }

    /// Reads the changed lists of the other Macs, and checks the files again (D3, D4). The panel calls it
    /// at each open, so a `git pull` shows at the next open. Returns true when the list or a file changed.
    @discardableResult
    public func reload() -> Bool {
        let listChanged = readOthers()
        if listChanged { combine() }
        let filesChanged = checkFiles()
        return listChanged || filesChanged
    }

    /// Writes this Mac's list into `newURL` (a new preferences folder), then uses it with the lists of
    /// the other Macs there. The old file stays, as for `YouStore.move(to:)`.
    public func move(to newURL: URL) throws {
        if saveIsBlocked, let saveError { throw saveError }
        try MacFiles.save(own, to: newURL)
        url = newURL
        saveError = nil
        movedBadFile = nil
        others.removeAll()
        _ = readOthers()
        combine()
    }

    /// "Set GIFs and memes folder…" (D4): copies `gifs/` and `memes/` into `newFolder`, checks them, removes
    /// the old copies, then uses `newFolder`. On a failure, the old files and the old folder stay, and it throws.
    /// The caller keeps the pref `yaseenEmoji.mediaFolder` only after a move with no error.
    public func useMediaFolder(_ newFolder: URL) throws {
        try MediaFolder.move(from: mediaFolder, to: newFolder)
        mediaFolder = newFolder
        _ = checkFiles()
    }

    // MARK: The items

    /// The item with this `id`, also when it is removed.
    public func item(_ id: String) -> Item? { all[id] }

    /// The file of your own item in the GIFs and memes folder, or nil for a KLIPY item.
    public func fileURL(of item: Item) -> URL? {
        item.file.map { mediaFolder.appendingPathComponent($0) }
    }

    /// The items of one tab that are not removed, the newest add first.
    public func items(_ kind: ItemKind) -> [Item] { items.filter { $0.kind == kind } }

    /// Adds your own file (D5, D12): writes it into `gifs/` or `memes/` with an atomic write, then adds the item.
    /// `kind` is the kind of the add window, so a GIF marked as a meme goes into `memes/`.
    /// The same `id` again adds only the new words, and says so (`alreadyThere`). It writes the file again
    /// when it is missing. An item that was removed comes back, with its old words and the new words.
    /// `title` (D15 of YAZ-2919): an empty title keeps the title that the item has.
    /// `klipyID` (D18 of YAZ-2919): the slug of the KLIPY item that "Save to your GIFs" copied. The `key` of the item
    /// stays `gif:<id>`, because it has a file. The card of that slug then does not show as a second tile.
    @discardableResult
    public func add(_ file: PreparedFile, as kind: ItemKind? = nil, words: [String], title: String = "",
                    klipyID: String? = nil) throws -> AddResult {
        let words = Item.clean(words)
        let title = Item.cleanTitle(title)
        if var item = all[file.id], !item.isRemoved {
            try write(file, at: item.file)
            let new = words.filter { !item.words.contains($0) }
            let newTitle = !title.isEmpty && title != item.title
            let newLink = item.klipyID == nil && klipyID != nil
            if !new.isEmpty || newTitle || newLink {
                item.words += new
                if newTitle { item.title = title }
                if newLink { item.klipyID = klipyID }
                item.changed = now()
                change(item)
            }
            _ = checkFiles()
            return .alreadyThere(item)
        }
        let kind = kind ?? file.kind
        let path = path(of: file, as: kind)
        try write(file, at: path)
        let time = now()
        let old = all[file.id]?.words ?? []
        let item = Item(id: file.id, kind: kind, file: path, klipyID: klipyID ?? all[file.id]?.klipyID,
                        words: old + words.filter { !old.contains($0) },
                        title: title.isEmpty ? all[file.id]?.title ?? "" : title, added: time, changed: time)
        change(item)
        _ = checkFiles()
        return .added(item)
    }

    /// "Add a word…" (D13): adds the words that the item does not have yet.
    public func addWords(_ words: [String], to id: String) {
        guard var item = all[id], !item.isRemoved else { return }
        let new = Item.clean(words).filter { !item.words.contains($0) }
        guard !new.isEmpty else { return }
        item.words += new
        item.changed = now()
        change(item)
    }

    /// "Rename…" (D15 of YAZ-2919): the new title of your own item. An empty text clears it. The file keeps its name.
    public func setTitle(_ text: String, of id: String) {
        let title = Item.cleanTitle(text)
        guard var item = all[id], !item.isRemoved, item.title != title else { return }
        item.title = title
        item.changed = now()
        change(item)
    }

    /// A saved KLIPY item of D7: only its ID goes into the list, never a file. A KLIPY item that is already saved stays
    /// as it is. Since D18 of YAZ-2919, "Save to your GIFs" copies the file instead (`add` with `klipyID`). The app still
    /// reads, shows and removes the items of this kind that an earlier build saved. The tests make them here.
    @discardableResult
    public func saveKlipy(_ klipyID: String, kind: ItemKind, words: [String] = []) -> Item {
        let id = Item.klipyItemID(klipyID)
        if let item = all[id], !item.isRemoved { return item }
        let time = now()
        let item = Item(id: id, kind: kind, file: nil, klipyID: klipyID, words: Item.clean(words), added: time, changed: time)
        change(item)
        return item
    }

    /// "Remove from your GIFs" (or memes) of a saved KLIPY item (D7, D13): the item gets `removed`, on all Macs.
    /// It touches no file.
    public func remove(_ id: String) {
        guard var item = all[id], !item.isRemoved else { return }
        let time = now()
        item.removed = time
        item.changed = time
        change(item)
        _ = checkFiles()
    }

    // MARK: The cards of KLIPY items (D18 of YAZ-2919)

    /// The most cards in this Mac's file. A write drops the least recently used card of this Mac's file.
    public static let cardLimit = 2_000

    /// The card of this slug, from any Mac, or nil.
    public func card(_ slug: String) -> KlipyCard? { cards[KlipyCard.key(slug)] }

    /// A pick of a KLIPY item: its card, with the new last use, goes into this Mac's file.
    public func useCard(_ card: KlipyCard) {
        var card = card
        card.lastUsed = now()
        keep(card)
    }

    /// The first lookup of a used or saved KLIPY item with no card (the items of an earlier build): its card, with the
    /// last use that the history has. A card that is there already stays as it is.
    public func addCard(_ card: KlipyCard) {
        guard cards[card.key] == nil else { return }
        keep(card)
    }

    private func keep(_ card: KlipyCard) {
        own.cards[card.key] = card
        if own.cards.count > LibraryStore.cardLimit {
            let oldest = own.cards.values.sorted { a, b in
                a.lastUsed != b.lastUsed ? a.lastUsed < b.lastUsed : a.key < b.key
            }
            for old in oldest.prefix(own.cards.count - LibraryStore.cardLimit) { own.cards[old.key] = nil }
        }
        save()
        // Only the cards changed: the items are not combined and sorted again.
        combineCards()
    }

    // MARK: The files

    /// The file that `add` uses for `file`: the file of the item with the same `id`, or `<kind folder>/<id>.<ext>`.
    /// Nil when the GIFs and memes folder is gone. The add window writes the bytes there off the main thread
    /// (`writeMediaFile`), then calls `add` on the main thread, which finds the file and only saves the list.
    public func place(of file: PreparedFile, as kind: ItemKind? = nil) -> URL? {
        guard !isMediaFolderMissing() else { return nil }
        if let item = all[file.id], !item.isRemoved { return item.file.map { mediaFolder.appendingPathComponent($0) } }
        return mediaFolder.appendingPathComponent(path(of: file, as: kind))
    }

    /// `gifs/<id>.<ext>` or `memes/<id>.<ext>`.
    private func path(of file: PreparedFile, as kind: ItemKind?) -> String {
        "\((kind ?? file.kind).folderName)/\(file.id).\(file.ext)"
    }

    /// Writes the bytes of a file of the list, with an atomic write, unless that file is already there.
    /// The name is the hash of the bytes, so a file with that name has the same bytes. Safe off the main thread.
    public static func writeMediaFile(_ bytes: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }

    /// Writes the bytes at `path` in the GIFs and memes folder, unless that file is already there.
    private func write(_ file: PreparedFile, at path: String?) throws {
        guard let path else { return }
        if isMediaFolderMissing() { throw MediaFolder.Missing() }
        try LibraryStore.writeMediaFile(file.bytes, to: mediaFolder.appendingPathComponent(path))
    }

    /// True when a chosen GIFs and memes folder is gone. The preferences folder itself is never missing:
    /// the app makes it at the first save.
    private func isMediaFolderMissing() -> Bool {
        mediaFolder.standardizedFileURL.path != folder.standardizedFileURL.path && !PreferencesFolder.isUsable(mediaFolder)
    }

    /// Keeps one changed item in this Mac's file, saves, and combines again.
    func change(_ item: Item) {
        own.items[item.id] = item
        save()
        combine()
    }

    private func combine() {
        all = LibraryFile.combine(own: own, others: others.values)
        combineCards()
        items = all.values.filter { !$0.isRemoved }.sorted { a, b in
            a.added != b.added ? a.added > b.added : a.id < b.id
        }
    }

    private func combineCards() {
        cards = LibraryFile.combineCards(own: own, others: others.values)
    }

    private func readOthers() -> Bool {
        others.read(folder: folder, ownName: url.lastPathComponent, isFile: PreferencesFolder.isLibraryFile)
    }

    /// Lists `gifs/` and `memes/` one time each, and finds the items with no file. Returns true on a change.
    private func checkFiles() -> Bool {
        let fileManager = FileManager.default
        var found: Set<String> = []
        for kind in ItemKind.allCases {
            let names = (try? fileManager.contentsOfDirectory(atPath: mediaFolder.appendingPathComponent(kind.folderName).path)) ?? []
            for name in names { found.insert("\(kind.folderName)/\(name)") }
        }
        let newMissing = Set(all.values.compactMap { item -> String? in
            guard let file = item.file, !item.isRemoved, !found.contains(file) else { return nil }
            return item.id
        })
        let folderIsMissing = isMediaFolderMissing()
        defer {
            missing = newMissing
            mediaFolderIsMissing = folderIsMissing
        }
        return newMissing != missing || folderIsMissing != mediaFolderIsMissing
    }

    @discardableResult
    func save() -> Bool {
        guard !saveIsBlocked else { return false }
        do {
            try MacFiles.save(own, to: url)
            saveError = nil
            return true
        } catch {
            saveError = error
            return false
        }
    }
}
