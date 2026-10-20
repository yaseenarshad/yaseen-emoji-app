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
    /// The path in the GIFs and memes folder at the add, for example `memes/circle.png`. Nil for a KLIPY item.
    /// Old builds find the file with it. This build finds the file by the scan, by the hash (D22 of YAZ-3018).
    /// In `LibraryStore.items`, it is the path of the scan.
    public var file: String?
    /// The ID of a saved KLIPY item. Nil for your own file.
    public var klipyID: String?
    /// The words of the item: typed at add, or read from a meme (D8). "Forget learned words" keeps them.
    public var words: [String]
    /// The title of the tile (D15 of YAZ-2919), or "". Your own file takes its title from its file name (D23 of
    /// YAZ-3018): the field stays for old builds. In `LibraryStore.items`, it is the title of the file name.
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

    /// The key of the same file in the other tab: `meme:<id>` for `gif:<id>`, and back. Nil for a KLIPY item.
    /// A move between `gifs/` and `memes/` changes the key, so the search reads the uses and the learned words of
    /// both keys (decision of YAZ-3019: a move between gifs/ and memes/ keeps the uses).
    public var otherKey: String? {
        if klipyID != nil, file == nil { return nil }
        return "\(kind == .gif ? ItemKind.meme.rawValue : ItemKind.gif.rawValue):\(id)"
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
    /// A chosen folder that is gone stays the folder, with `isMissing` true: your items do not show (D13 update on
    /// YAZ-2926), the panel and Settings show the red line. The app never writes the files into a different folder in silence.
    public static func resolve(chosen: String, preferencesFolder: URL) -> (folder: URL, isMissing: Bool) {
        guard !chosen.isEmpty else { return (preferencesFolder, false) }
        let folder = URL(fileURLWithPath: chosen, isDirectory: true)
        return (folder, !PreferencesFolder.isUsable(folder))
    }

    /// Copies the full tree of `gifs/` and `memes/` from `old` to `new`, with the subfolders (D27 of YAZ-3018), checks
    /// each copy (size and SHA-256), then removes the old files. Hidden files, hidden folders and symbolic links stay.
    /// On a failure, it removes only the copies that it made, keeps all the old files, and throws.
    /// An old folder that is missing (for example, an unmounted drive) has nothing to copy.
    public static func move(from old: URL, to new: URL) throws {
        guard old.standardizedFileURL.path != new.standardizedFileURL.path else { return }
        let fileManager = FileManager.default
        var made: [URL] = []
        var done: [URL] = []
        do {
            for kind in ItemKind.allCases {
                for name in files(in: old.appendingPathComponent(kind.folderName, isDirectory: true)) {
                    let path = "\(kind.folderName)/\(name)"
                    let source = old.appendingPathComponent(path)
                    let bytes = try Data(contentsOf: source)
                    let target = new.appendingPathComponent(path)
                    if fileManager.fileExists(atPath: target.path) {
                        // Git can have the same file there already. The same bytes: keep it, with no copy.
                        guard try Data(contentsOf: target) == bytes else { throw DifferentFile(name: path) }
                    } else {
                        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fileManager.copyItem(at: source, to: target)
                        made.append(target)
                        let copy = try Data(contentsOf: target)
                        guard copy.count == bytes.count, MediaHash.hex(copy) == MediaHash.hex(bytes) else {
                            throw BadCopy(name: path)
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
        // The old folders with only `.DS_Store` left go, the deepest first.
        for kind in ItemKind.allCases {
            let top = old.appendingPathComponent(kind.folderName, isDirectory: true)
            let inside = (fileManager.subpaths(atPath: top.path) ?? []).map { top.appendingPathComponent($0) }
            for folder in inside.sorted(by: { $0.path.count > $1.path.count }) + [top] {
                if let rest = try? fileManager.contentsOfDirectory(atPath: folder.path), rest.allSatisfy({ $0 == ".DS_Store" }) {
                    try? fileManager.removeItem(at: folder)
                }
            }
        }
    }

    /// The paths of the files below `folder`, at any depth, sorted. No hidden file, no file in a hidden folder,
    /// no symbolic link.
    private static func files(in folder: URL) -> [String] {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var names: [String] = []
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let name = MediaScan.relativePath(of: url, in: folder)
            else { continue }
            names.append(name)
        }
        return names.sorted()
    }
}

/// Keeps this Mac's list of GIFs and memes in `library-<Mac name>.json` (D3 of YAZ-2919), and reads the lists
/// of the other Macs in the same folder. It works like `YouStore`: each change saves this Mac's file at once,
/// with an atomic write, and the store never writes the file of a different Mac.
/// The files on disk are the collection (D22 of YAZ-3018): each GIF, PNG or JPEG file in `gifs/` or `memes/`, at any
/// depth, is an item. The list keeps the words of each file, by its hash. The store reads the tree at each open (D27).
/// The paths are parameters, so a test gives temp folders.
/// The app never deletes a file of `gifs/` or `memes/`: you delete it in Finder (D13 update on YAZ-2926).
public final class LibraryStore {
    /// This Mac's list file, in the preferences folder.
    public private(set) var url: URL
    /// The GIFs and memes folder (D4): the place of `gifs/` and `memes/`.
    public private(set) var mediaFolder: URL
    /// The items of this Mac only: the contents of `url`.
    public private(set) var own = LibraryFile()
    /// The records of all Macs, by `id`, with the removed items (`LibraryFile.combine`).
    public private(set) var all: [String: Item] = [:]
    /// The items that show, the newest first (D27 of YAZ-3018): each file of the scan, and each saved KLIPY item of D7.
    /// The panel reads this. The item of a file has the path of the scan and the title of its file name.
    public private(set) var items: [Item] = []
    /// The cards of the KLIPY items that you used, of all Macs, by `klipy:<slug>` (D18 of YAZ-2919).
    public private(set) var cards: [String: KlipyCard] = [:]
    /// The `id`s of the records of your files whose file is not on disk: deleted in Finder, changed, or before a
    /// `git pull`. They do not show (D13 update on YAZ-2926). The record stays, and the file can come back.
    public private(set) var missing: Set<String> = []
    /// True when the GIFs and memes folder is gone, for example on an unmounted drive.
    public private(set) var mediaFolderIsMissing = false
    /// The last error of a save, or nil. The store keeps the data in memory and tries again at the next change.
    public private(set) var saveError: Error?
    /// The file that `load()` moved away because it was bad, or nil.
    public private(set) var movedBadFile: URL?
    /// Runs on the main thread when the hashes of new files are ready (D27 of YAZ-3018). With it, the hashes run off
    /// the main thread, and the panel shows the known files at once. Nil (the commands and the tests): `load()` and
    /// `reload()` make the hashes at once, on the thread of the caller.
    public var onHashed: (() -> Void)?

    /// The files of the last scan, by `id`. The same picture in two places: the first path in sorted order.
    private(set) var files: [String: ScannedFile] = [:]
    /// The items that show, by `id`.
    private var shown: [String: Item] = [:]
    /// The hash cache of D27 on YAZ-3018, and its file. Nil: the cache stays in memory (the tests).
    private var cache = FileCache()
    /// The entries of the cache file as it is on disk, so the store writes it only after a change.
    private var savedCache: [String: FileCache.Entry] = [:]
    private let cacheURL: URL?
    private var isHashing = false
    private var others = OtherMacFiles<LibraryFile>()
    /// True when a bad file could not move away. Then the store never writes over it.
    private var saveIsBlocked = false
    private let now: () -> Date

    public init(url: URL, mediaFolder: URL, cacheURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.mediaFolder = mediaFolder
        self.cacheURL = cacheURL
        self.now = now
    }

    /// The folder of this Mac's list file: the preferences folder.
    public var folder: URL { url.deletingLastPathComponent() }

    /// `~/Library/Caches/Yaseen Emoji/files.json`: the hash cache of D27 on YAZ-3018. It is not synced. Tests never use it.
    public static var defaultCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yaseen Emoji/files.json")
    }

    /// Reads this Mac's list, the lists of the other Macs, the hash cache, and the files. No file gives an empty list.
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
        if let cacheURL {
            cache = FileCache.load(from: cacheURL)
            savedCache = cache.files
        }
        _ = readOthers()
        _ = scanFiles()
        combine()
    }

    /// Reads the changed lists of the other Macs, and reads the files again (D3; D27 of YAZ-3018). The panel calls it
    /// at each open, so a `git pull` or a change in Finder shows at the next open. Returns true on a change.
    @discardableResult
    public func reload() -> Bool {
        let listChanged = readOthers()
        let filesChanged = scanFiles()
        if listChanged || filesChanged { combine() }
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
        mediaFolderMoved(to: newFolder)
    }

    /// The files are in `newFolder` now (`MediaFolder.move`, which Settings runs off the main thread): the list uses it.
    public func mediaFolderMoved(to newFolder: URL) {
        mediaFolder = newFolder
        _ = scanFiles()
        combine()
    }

    // MARK: The items

    /// The item with this `id`: the item that shows, else its record, also when it is removed.
    public func item(_ id: String) -> Item? { shown[id] ?? all[id] }

    /// The file of your own item: the path of the scan (D27 of YAZ-3018). Nil for a KLIPY item and a missing file.
    public func fileURL(of item: Item) -> URL? {
        files[item.id].map { mediaFolder.appendingPathComponent($0.path) }
    }

    /// The items of one tab that show, the newest first.
    public func items(_ kind: ItemKind) -> [Item] { items.filter { $0.kind == kind } }

    /// Adds your own file (D5, D12): writes it as `<title>.<ext>` at the top of `gifs/` or `memes/`, with an atomic
    /// write, then adds the item (D25 of YAZ-3018). An empty title gives the code name `<id>.<ext>`.
    /// `kind` is the kind of the add window, so a GIF marked as a meme goes into `memes/`.
    /// The same picture on disk (any name, any subfolder) adds only the new words, and says so (`alreadyThere`). It
    /// writes no file, and the title changes nothing. A record whose file is missing comes back with a new file.
    /// `at`: the file that the caller wrote off the main thread (`writeMediaFile`), or the source when it is already in
    /// the folder (`fileToAdd`). Nil: `add` writes the file itself.
    /// `klipyID` (D18 of YAZ-2919): the slug of the KLIPY item that "Save to your GIFs" copied. The `key` of the item
    /// stays `gif:<id>`, because it has a file. The card of that slug then does not show as a second tile.
    @discardableResult
    public func add(_ file: PreparedFile, as kind: ItemKind? = nil, words: [String], title: String = "",
                    klipyID: String? = nil, at written: URL? = nil) throws -> AddResult {
        let words = Item.clean(words)
        if files[file.id] != nil, var item = record(for: file.id) {
            let new = words.filter { !item.words.contains($0) }
            let newLink = item.klipyID == nil && klipyID != nil
            if !new.isEmpty || newLink {
                item.words += new
                if newLink { item.klipyID = klipyID }
                item.changed = now()
                change(item)
            }
            return .alreadyThere(self.item(file.id) ?? item)
        }
        let url: URL
        if let written {
            url = written
        } else {
            guard let target = place(of: file, as: kind, title: title) else { throw MediaFolder.Missing() }
            url = try LibraryStore.writeMediaFile(file.bytes, to: target)
        }
        guard let place = MediaScan.place(of: url, in: mediaFolder) else { throw MediaFolder.Missing() }
        remember(place.path, id: file.id)
        let time = now()
        let old = all[file.id]?.words ?? []
        // `file` and `title` are for old builds: this build finds the file by the scan (D25 of YAZ-3018).
        let item = Item(id: file.id, kind: place.kind, file: place.path, klipyID: klipyID ?? all[file.id]?.klipyID,
                        words: old + words.filter { !old.contains($0) }, title: MediaName.title(ofPath: place.path),
                        added: time, changed: time)
        change(item)
        return .added(self.item(file.id) ?? item)
    }

    /// "Add a word…" (D13): adds the words that the item does not have yet. A file with no record gets its record
    /// here (D22 of YAZ-3018).
    public func addWords(_ words: [String], to id: String) {
        guard var item = record(for: id) else { return }
        let new = Item.clean(words).filter { !item.words.contains($0) }
        guard !new.isEmpty else { return }
        item.words += new
        item.changed = now()
        change(item)
    }

    /// The record to change for this `id`: the record, else a new record for a file on disk (D22 of YAZ-3018), with
    /// the path and the title of the file for old builds. A removed record of a file on disk comes back. Nil for an
    /// item that is not there or is removed.
    private func record(for id: String) -> Item? {
        if let file = files[id] {
            var item = all[id] ?? Item(id: id, kind: file.kind, file: file.path, klipyID: nil, words: [],
                                       title: MediaName.title(ofPath: file.path), added: file.created, changed: file.created)
            item.removed = nil
            return item
        }
        guard let item = all[id], !item.isRemoved else { return nil }
        return item
    }

    /// The first part of the line of a failed "Rename…" (D24 of YAZ-3018).
    public static let cantRenameText = "Can't rename the file."

    /// Why "Rename…" did not rename the file. The panel shows the text, with the reason of macOS.
    public struct RenameFailure: LocalizedError {
        public let reason: String
        public var errorDescription: String? { "\(LibraryStore.cantRenameText) \(reason)" }
    }

    /// "Rename…" (D24 of YAZ-3018): moves the file of your own item to the new name in its folder, with
    /// `FileManager.moveItem`. The name rule of `MediaName.fileName` applies, and the extension stays. A different file
    /// with that name gives " 2". The hash stays, so the words and the uses stay, and the list file does not change.
    /// An empty text, the same name, or the title of the file name (the text that "Rename…" starts with: `A-B-C.png`
    /// shows "A B C") changes nothing: false. The file is gone, or the move fails: it throws
    /// `RenameFailure`, and the file keeps its name.
    @discardableResult
    public func rename(_ id: String, to text: String) throws -> Bool {
        guard let file = files[id] else { throw RenameFailure(reason: "The file is not in the GIFs and memes folder.") }
        let source = mediaFolder.appendingPathComponent(file.path)
        let name = MediaName.fileName(text)
        guard !name.isEmpty, name != source.deletingPathExtension().lastPathComponent,
              name != MediaName.fileName(MediaName.title(ofPath: file.path)) else { return false }
        // A change of the case only is the same file on the disk of a Mac, not a clash.
        let target = MediaName.freeURL(in: source.deletingLastPathComponent(), name: name, ext: source.pathExtension) {
            $0.lastPathComponent.lowercased() == source.lastPathComponent.lowercased()
        }
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            throw RenameFailure(reason: error.localizedDescription)
        }
        let path = ((file.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target.lastPathComponent)
        // A move keeps the size and the date: the cache entry moves to the new path, with no hash.
        if let entry = cache.files.removeValue(forKey: file.path) { cache.files[path] = entry }
        saveCache()
        files[id]?.path = path
        combine()
        return true
    }

    /// `--name-files` (D26 of YAZ-3018): gives each file with a code name at the top of `gifs/` or `memes/` a real name:
    /// the title of its record, else its first 4 words. With neither, the file keeps its code name. Each rename is the
    /// "Rename…" of `rename(_:to:)`, with its name rule. A file with a real name stays as it is, so a second run changes
    /// nothing. Returns one line for each file with a code name, in the order of the paths, and true when a rename failed.
    public func nameCodeFiles() -> (lines: [String], failed: Bool) {
        let coded = files.filter { _, file in
            let parts = file.path.split(separator: "/")
            return parts.count == 2 && MediaName.isCodeName((String(parts[1]) as NSString).deletingPathExtension)
        }
        var lines: [String] = []
        var failed = false
        for (id, file) in coded.sorted(by: { $0.value.path < $1.value.path }) {
            let record = all[id]
            let title = MediaName.fileName(record?.title ?? "")
            let name = title.isEmpty ? MediaName.fileName((record?.words ?? []).prefix(4).joined(separator: " ")) : title
            guard !name.isEmpty else {
                lines.append("\(file.path): no change, no title and no words")
                continue
            }
            do {
                try rename(id, to: name)
                lines.append("\(file.path) → \(files[id]?.path ?? name)")
            } catch {
                lines.append("\(file.path): \(error.localizedDescription)")
                failed = true
            }
        }
        return (lines, failed)
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
    /// It touches no file. A file on disk still shows: the disk is the collection (D22 of YAZ-3018).
    public func remove(_ id: String) {
        guard var item = all[id], !item.isRemoved else { return }
        let time = now()
        item.removed = time
        item.changed = time
        change(item)
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

    /// The file that `add` wants for `file` (D25 of YAZ-3018): the file of the same picture on disk, else
    /// `<kind folder>/<title>.<ext>` with the name rule (`MediaName.fileName`), or `<kind folder>/<id>.<ext>` with no
    /// title. Nil when the GIFs and memes folder is gone. The add window writes the bytes off the main thread
    /// (`writeMediaFile`, which picks a free name), then calls `add` on the main thread with the file.
    public func place(of file: PreparedFile, as kind: ItemKind? = nil, title: String = "") -> URL? {
        guard !isMediaFolderMissing() else { return nil }
        if let found = files[file.id] { return mediaFolder.appendingPathComponent(found.path) }
        let name = MediaName.fileName(title)
        return mediaFolder.appendingPathComponent((kind ?? file.kind).folderName, isDirectory: true)
            .appendingPathComponent("\(name.isEmpty ? file.id : name).\(file.ext)")
    }

    /// Writes the bytes as a new file (D25 of YAZ-3018). A file with the same bytes at that name is used, with no write.
    /// A different file with that name gives " 2", " 3" and so on. Returns the file. Safe off the main thread.
    /// The bytes go into a hidden temp file in the folder first, then one rename with `RENAME_EXCL` to the name. That
    /// rename never writes over a file, also when two adds want one name at the same time: the second gets `EEXIST` and
    /// takes the next number. (`FileManager.moveItem` checks the name first, then renames: two adds can pass the check.)
    @discardableResult
    public static func writeMediaFile(_ bytes: Data, to url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".\(UUID().uuidString).part")
        try bytes.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        var number = 1
        while true {
            let target = folder.appendingPathComponent(MediaName.numbered(name, number, ext: ext))
            if (try? Data(contentsOf: target, options: .mappedIfSafe)) == bytes { return target }
            if renamex_np(temp.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path]) }
            number += 1
        }
    }

    /// The file to give to `add` (D25 of YAZ-3018): `source` itself when it is already below `gifs/` or `memes/` with
    /// the same bytes, so the add makes no copy and saves only the words. Else `writeMediaFile` at `target`.
    /// Safe off the main thread.
    public static func fileToAdd(_ bytes: Data, source: URL?, target: URL, mediaFolder: URL) throws -> URL {
        if let source, MediaScan.place(of: source, in: mediaFolder) != nil,
           (try? Data(contentsOf: source, options: .mappedIfSafe)) == bytes {
            return source
        }
        return try writeMediaFile(bytes, to: target)
    }

    /// True when a chosen GIFs and memes folder is gone. The preferences folder itself is never missing:
    /// the app makes it at the first save.
    private func isMediaFolderMissing() -> Bool {
        mediaFolder.standardizedFileURL.path != folder.standardizedFileURL.path && !PreferencesFolder.isUsable(mediaFolder)
    }

    /// Reads the tree of `gifs/` and `memes/` (D27 of YAZ-3018). A file with the same path, size and date as in the
    /// cache uses the saved `id`. A new or changed file needs a hash: at once with no `onHashed`, else off the main
    /// thread (`startHashes`). The cache keeps only the files of this scan, but a missing folder does not change it.
    /// Returns true when the files changed.
    private func scanFiles(startHashes: Bool = true) -> Bool {
        let folderIsMissing = isMediaFolderMissing()
        let listed = folderIsMissing ? [] : MediaScan.list(mediaFolder)
        var unknown = listed.filter { cache.id(of: $0) == nil }
        if !unknown.isEmpty, onHashed == nil {
            cache.files.merge(MediaScan.hash(unknown, in: mediaFolder)) { $1 }
            unknown = []
        }
        var found: [String: ScannedFile] = [:]
        var kept: [String: FileCache.Entry] = [:]
        for file in listed {
            guard let id = cache.id(of: file) else { continue }
            kept[file.path] = cache.files[file.path]
            // The same picture twice: the first path in sorted order (D27 of YAZ-3018).
            if found[id].map({ file.path < $0.path }) ?? true { found[id] = file }
        }
        // A missing folder (an unmounted drive) keeps the cache: the files need no hash when the drive comes back.
        if !folderIsMissing {
            cache.files = kept
            saveCache()
        }
        if !unknown.isEmpty, startHashes { hashInBackground(unknown) }
        let changed = found != files || folderIsMissing != mediaFolderIsMissing
        files = found
        mediaFolderIsMissing = folderIsMissing
        return changed
    }

    /// The hashes of new files, off the main thread (D27 of YAZ-3018). Then the store scans again from the cache, and
    /// calls `onHashed`. That scan starts no new hash: a file that came later gets its hash at the next open.
    private func hashInBackground(_ wanted: [ScannedFile]) {
        guard !isHashing else { return }
        isHashing = true
        let folder = mediaFolder
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) { MediaScan.hash(wanted, in: folder) }.value
            guard let self else { return }
            self.isHashing = false
            self.cache.files.merge(found) { $1 }
            if self.scanFiles(startHashes: false) { self.combine() }
            self.onHashed?()
        }
    }

    /// Puts a file that the store wrote or moved into the scan and the cache, with its `id`, so it needs no hash.
    private func remember(_ path: String, id: String) {
        let url = mediaFolder.appendingPathComponent(path)
        guard let kind = ItemKind.allCases.first(where: { path.hasPrefix($0.folderName + "/") }),
              let file = MediaScan.file(at: url, path: path, kind: kind) else { return }
        cache.files[path] = FileCache.Entry(size: file.size, modified: file.modified, id: id)
        if files[id].map({ path < $0.path }) ?? true { files[id] = file }
        saveCache()
    }

    /// Writes the cache file when its entries changed.
    private func saveCache() {
        guard let cacheURL, cache.files != savedCache else { return }
        cache.save(to: cacheURL)
        savedCache = cache.files
    }

    /// Keeps one changed record in this Mac's file, saves, and combines again.
    func change(_ item: Item) {
        own.items[item.id] = item
        save()
        combine()
    }

    /// The records of all Macs, and the items that show: each file of the scan with the words of its record (D22 of
    /// YAZ-3018), and each saved KLIPY item of D7.
    private func combine() {
        all = LibraryFile.combine(own: own, others: others.values)
        combineCards()
        var shown: [String: Item] = [:]
        for (id, file) in files {
            let record = all[id]
            // The tab comes from the top folder, and the title from the file name (D22, D23 of YAZ-3018).
            shown[id] = Item(id: id, kind: file.kind, file: file.path, klipyID: record?.klipyID, words: record?.words ?? [],
                             title: MediaName.title(ofPath: file.path), added: record?.added ?? file.created,
                             changed: record?.changed ?? file.created)
        }
        for record in all.values where record.file == nil && record.klipyID != nil && !record.isRemoved {
            shown[record.id] = record
        }
        self.shown = shown
        items = shown.values.sorted { a, b in
            a.added != b.added ? a.added > b.added : a.id < b.id
        }
        missing = Set(all.values.compactMap { item in
            item.file != nil && !item.isRemoved && files[item.id] == nil ? item.id : nil
        })
    }

    private func combineCards() {
        cards = LibraryFile.combineCards(own: own, others: others.values)
    }

    private func readOthers() -> Bool {
        others.read(folder: folder, ownName: url.lastPathComponent, isFile: PreferencesFolder.isLibraryFile)
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
