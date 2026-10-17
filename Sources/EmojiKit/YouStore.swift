import Foundation

/// What the app knows about you (D4 on YAZ-2894): the contents of one history file.
/// Each Mac writes its own file, `you-<Mac name>.json`, and the app adds up the files of all Macs (D16).
/// Each emoji key is `You.key(emoji)`, so "❤" and "❤️" are one emoji, and 👍🏽 counts as 👍 (D9).
public struct You: Codable, Equatable, Sendable {
    /// How many times you picked one emoji, and the last time.
    public struct Use: Codable, Equatable, Sendable {
        public var count: Int
        public var last: Date
        public init(count: Int, last: Date) {
            self.count = count
            self.last = last
        }
    }

    /// One emoji hidden from "Your most used" (D15), or shown again. `at` is the time of the change,
    /// so a later sync can keep the newest change of each emoji.
    public struct Hide: Codable, Equatable, Sendable {
        public var on: Bool
        public var at: Date
        public init(on: Bool, at: Date) {
            self.on = on
            self.at = at
        }
    }

    /// One setting that syncs (D16), with the time of the change. The newest change of all Macs wins.
    public struct Dated<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        public var value: Value
        public var at: Date
        public init(_ value: Value, at: Date) {
            self.value = value
            self.at = at
        }
    }

    /// A hotkey in the file: the virtual key code and the raw value of `NSEvent.ModifierFlags`.
    public struct Key: Codable, Equatable, Sendable {
        public var keyCode: Int
        public var modifiers: Int
        public init(keyCode: Int, modifiers: Int) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
    }

    /// The settings that sync through the preferences folder (D16). Each is nil until you change it
    /// in Settings, so a new Mac with the start values never wins over a choice on the other Mac.
    /// "Start at login", Accessibility and the folder path stay on each Mac.
    public struct Settings: Codable, Equatable, Sendable {
        public var hotKey: Dated<Key>?
        /// `PickMode.rawValue`.
        public var pickMode: Dated<String>?
        /// "" (yellow) or one tone mark of `SkinTone.all`.
        public var defaultTone: Dated<String>?
        /// "Search KLIPY in GIFs" and "Search KLIPY in Memes" (D14 update of YAZ-2919). An older file has none.
        public var klipyGIFs: Dated<Bool>?
        public var klipyMemes: Dated<Bool>?
        public init() {}

        /// The KLIPY switch of the tab of `kind`.
        static func klipy(_ kind: ItemKind) -> WritableKeyPath<Settings, Dated<Bool>?> {
            kind == .gif ? \.klipyGIFs : \.klipyMemes
        }
    }

    /// The emojis for each search text: search text → emoji key → how many times, and the last time.
    public typealias Learned = [String: [String: Use]]

    /// Emoji key → your picks. "Your most used" comes from this.
    public var uses: [String: Use]
    /// The search text you typed → the emoji you picked. The search text is `Search.normalize(query)`.
    public var learned: Learned
    /// Emoji key → the words you added by hand.
    public var added: [String: [String]]
    /// Emoji key → hidden from "Your most used" or not (D15). The search does not read it.
    public var hidden: [String: Hide]
    /// The time of the import from EmojiFinder (D6). An import happens one time only.
    public var imported: Date?
    /// The settings that you changed on this Mac, with the time of each change (D16).
    public var settings: Settings
    /// The time of "Forget learned words" on this Mac (D16).
    public var forgotAt: Date?
    /// The newest `forgotAt` of all the files that this Mac applied to its own words (D16).
    public var forgetApplied: Date?

    public init(uses: [String: Use] = [:], learned: Learned = [:], added: [String: [String]] = [:],
                hidden: [String: Hide] = [:], imported: Date? = nil, settings: Settings = Settings(),
                forgotAt: Date? = nil, forgetApplied: Date? = nil) {
        self.uses = uses
        self.learned = learned
        self.added = added
        self.hidden = hidden
        self.imported = imported
        self.settings = settings
        self.forgotAt = forgotAt
        self.forgetApplied = forgetApplied
    }

    /// A field that is missing gives an empty value, so an older file still loads.
    /// An unknown field is ignored: an older file with `tones` (D9, removed by D17) still loads.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uses = try values.decodeIfPresent([String: Use].self, forKey: .uses) ?? [:]
        learned = try values.decodeIfPresent(Learned.self, forKey: .learned) ?? [:]
        added = try values.decodeIfPresent([String: [String]].self, forKey: .added) ?? [:]
        hidden = try values.decodeIfPresent([String: Hide].self, forKey: .hidden) ?? [:]
        imported = try values.decodeIfPresent(Date.self, forKey: .imported)
        settings = try values.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        forgotAt = try values.decodeIfPresent(Date.self, forKey: .forgotAt)
        forgetApplied = try values.decodeIfPresent(Date.self, forKey: .forgetApplied)
    }

    /// The number of learned pairs (one search text and one emoji).
    public var learnedPairs: Int { learned.values.reduce(0) { $0 + $1.count } }

    /// True if the emoji with this key is hidden from "Your most used" now.
    public func isHidden(_ key: String) -> Bool { hidden[key]?.on == true }

    /// The key of an emoji in `you.json`: the emoji without U+FE0F and without a skin tone mark.
    /// The sources and EmojiFinder do not agree on U+FE0F. The store, the search and the import
    /// all use this one helper.
    public static func key(_ emoji: String) -> String {
        String(String.UnicodeScalarView(emoji.unicodeScalars.filter { scalar in
            scalar.value != 0xFE0F && !(0x1F3FB...0x1F3FF).contains(scalar.value)
        }))
    }

    /// The history of all Macs (D16): this Mac's file and the files of the other Macs.
    /// * `uses`: the counts add up, and `last` is the newest.
    /// * `learned`: the counts add up for each search text and emoji.
    /// * `added`: all the words of all the files.
    /// * `hidden` and each setting: the newest change wins.
    /// * A file that did not apply the newest "Forget learned words" gives no learned and no added words.
    ///   Without this, a Forget on one Mac shows the words of the other Mac again until that Mac applies it.
    /// `imported` and `forgetApplied` are this Mac's own.
    public static func merge(own: You, others: [You]) -> You {
        guard !others.isEmpty else { return own }
        let files = [own] + others
        let newestForget = files.compactMap(\.forgotAt).max()
        var merged = You(imported: own.imported, forgotAt: newestForget, forgetApplied: own.forgetApplied)
        for file in files {
            for (key, use) in file.uses {
                merged.uses[key] = merged.uses[key].map { Use(count: $0.count + use.count, last: max($0.last, use.last)) } ?? use
            }
            if let newestForget, (file.forgetApplied ?? .distantPast) < newestForget {
                // This file still has the words of before the Forget.
            } else {
                for (text, emojis) in file.learned {
                    for (key, use) in emojis {
                        merged.learned[text, default: [:]][key] = merged.learned[text]?[key]
                            .map { Use(count: $0.count + use.count, last: max($0.last, use.last)) } ?? use
                    }
                }
                for (key, words) in file.added {
                    var list = merged.added[key] ?? []
                    for word in words where !list.contains(word) { list.append(word) }
                    merged.added[key] = list
                }
            }
            for (key, hide) in file.hidden {
                // The same time on two Macs: the hide wins.
                if let old = merged.hidden[key], old.at > hide.at || (old.at == hide.at && old.on) { continue }
                merged.hidden[key] = hide
            }
            merged.settings.hotKey = newest(merged.settings.hotKey, file.settings.hotKey)
            merged.settings.pickMode = newest(merged.settings.pickMode, file.settings.pickMode)
            merged.settings.defaultTone = newest(merged.settings.defaultTone, file.settings.defaultTone)
            merged.settings.klipyGIFs = newest(merged.settings.klipyGIFs, file.settings.klipyGIFs)
            merged.settings.klipyMemes = newest(merged.settings.klipyMemes, file.settings.klipyMemes)
        }
        return merged
    }

    private static func newest<Value>(_ a: Dated<Value>?, _ b: Dated<Value>?) -> Dated<Value>? {
        guard let a else { return b }
        guard let b else { return a }
        return b.at > a.at ? b : a
    }
}

/// Keeps this Mac's `You` in its own file (D4, D16), and reads the files of the other Macs in the same folder.
/// Each change saves this Mac's file at once. The store never writes the file of a different Mac.
/// The path is a parameter, so a test gives a temp folder and never touches the real file.
public final class YouStore {
    /// At most this many learned pairs in this Mac's file. A pick past it drops the pair with the
    /// lowest count, then the oldest.
    public static let learnedLimit = 5_000

    /// `~/Library/Application Support/Yaseen Emoji`. Tests never use it.
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yaseen Emoji", isDirectory: true)
    }

    /// This Mac's own file. The other history files of its folder count in `you`.
    public private(set) var url: URL
    /// The data of this Mac only: the contents of `url`.
    public private(set) var own = You()
    /// The history of all Macs (`You.merge`). The search, "Your most used" and the panel read this.
    public private(set) var you = You()
    /// The last error of a save, or nil. The app keeps the data in memory and tries again at the next change.
    public private(set) var saveError: Error?
    /// The file that `load()` moved away because it was bad, or nil.
    public private(set) var movedBadFile: URL?

    /// The history files of the other Macs.
    private var others = OtherMacFiles<You>()
    /// True when a bad file could not move away. Then the store never writes over it.
    private var saveIsBlocked = false
    private let now: () -> Date

    /// `now` is a parameter, so a test can give each change its own time.
    public init(url: URL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    /// The folder of this Mac's file: the preferences folder.
    public var folder: URL { url.deletingLastPathComponent() }

    /// Reads this Mac's file and the files of the other Macs. No file gives an empty `You`.
    /// A file of this Mac that cannot be read becomes `you-<Mac name>.bad.json` (or `.bad-2.json` and on),
    /// and the store starts empty. It never deletes your history in silence.
    public func load() {
        others.removeAll()
        switch MacFiles.loadOwn(You.self, at: url) {
        case .missing:
            own = You()
        case .loaded(let you):
            own = you
        case .movedBad(let bad):
            movedBadFile = bad
            own = You()
        case .blocked(let error):
            // The bad file stays in place. A save must not write over it.
            saveError = error
            saveIsBlocked = true
            own = You()
        }
        _ = readOthers()
        applyForget()
        merge()
    }

    /// Reads the files of the other Macs again, but only the files that changed (D16). The panel calls it
    /// each time it opens, so a `git pull` shows at the next open. It lists one folder: this is cheap.
    /// Returns true when the history changed.
    @discardableResult
    public func reload() -> Bool {
        guard readOthers() else { return false }
        applyForget()
        merge()
        return true
    }

    /// Writes this Mac's data into `newURL`, then uses it, with the files of the other Macs in that folder (D16).
    /// The old file stays. A file of this Mac that is already at `newURL` gets the data of now:
    /// the data in memory is always the newest data of this Mac.
    public func move(to newURL: URL) throws {
        // The data in memory is empty after a bad file that could not move. It must not replace a good file.
        if saveIsBlocked, let saveError { throw saveError }
        try MacFiles.save(own, to: newURL)
        url = newURL
        saveError = nil
        movedBadFile = nil
        others.removeAll()
        _ = readOthers()
        applyForget()
        merge()
    }

    /// One pick: one more use of the emoji, and the search text learns the emoji.
    /// An empty search learns no word. It still counts a use.
    public func recordPick(_ emoji: String, query: String) {
        let key = You.key(emoji)
        guard !key.isEmpty else { return }
        let time = now()
        own.uses[key, default: You.Use(count: 0, last: time)].count += 1
        own.uses[key]?.last = time

        let text = Search.normalize(query)
        // A pasted emoji is not a word.
        if !text.isEmpty && You.key(text) != key {
            own.learned[text, default: [:]][key, default: You.Use(count: 0, last: time)].count += 1
            own.learned[text]?[key]?.last = time
            YouStore.dropPastLimit(&own, limit: YouStore.learnedLimit, keeping: (text, key))
        }
        changed()
    }

    /// Adds a word by hand. The search finds it at once.
    public func addWord(_ word: String, to emoji: String) {
        let clean = Search.normalize(word)
        let key = You.key(emoji)
        guard !clean.isEmpty, !key.isEmpty else { return }
        var words = own.added[key] ?? []
        guard !words.contains(clean) else { return }
        words.append(clean)
        own.added[key] = words
        changed()
    }

    /// The right-click "Hide from Your most used" (D15). The uses and the learned words stay,
    /// so the search ranks the emoji the same as before.
    public func hide(_ emoji: String) {
        let key = You.key(emoji)
        guard !key.isEmpty else { return }
        own.hidden[key] = You.Hide(on: true, at: now())
        changed()
    }

    /// Settings → "Show them again" (D15). Each hidden emoji of all Macs gets an entry with `on` false
    /// and the time of now in this Mac's file. This change is newer than each hide, so it wins on each Mac.
    public func showHidden() {
        let keys = Set(own.hidden.keys).union(you.hidden.filter(\.value.on).keys)
        guard !keys.isEmpty else { return }
        let time = now()
        for key in keys { own.hidden[key] = You.Hide(on: false, at: time) }
        changed()
    }

    /// The number of emojis hidden from "Your most used" now, on all Macs.
    public var hiddenCount: Int { you.hidden.values.filter(\.on).count }

    /// Settings → "Forget learned words": clears `learned` and `added` of this Mac, and writes the time,
    /// so each other Mac clears its own words too (D16). It keeps `uses` and `hidden`.
    public func forgetWords() {
        let time = now()
        own.learned = [:]
        own.added = [:]
        own.forgotAt = time
        own.forgetApplied = time
        changed()
    }

    // MARK: The settings that sync (D16)

    /// A new hotkey in Settings. Returns the time of the change.
    @discardableResult
    public func setHotKey(_ key: You.Key) -> Date {
        let time = now()
        own.settings.hotKey = You.Dated(key, at: time)
        changed()
        return time
    }

    /// A new "When you pick" in Settings. Returns the time of the change.
    @discardableResult
    public func setPickMode(_ mode: String) -> Date {
        let time = now()
        own.settings.pickMode = You.Dated(mode, at: time)
        changed()
        return time
    }

    /// A new "Default skin tone" in Settings. Returns the time of the change.
    @discardableResult
    public func setDefaultTone(_ tone: String) -> Date {
        let time = now()
        own.settings.defaultTone = You.Dated(tone, at: time)
        changed()
        return time
    }

    /// A new "Search KLIPY in GIFs" or "Search KLIPY in Memes" in Settings (D14 update of YAZ-2919).
    /// Returns the time of the change.
    @discardableResult
    public func setSearchesKlipy(_ on: Bool, for kind: ItemKind) -> Date {
        let time = now()
        own.settings[keyPath: You.Settings.klipy(kind)] = You.Dated(on, at: time)
        changed()
        return time
    }

    /// Puts a new `You` in place of this Mac's data and saves it. The import uses it.
    func replace(with new: You) {
        own = new
        changed()
    }

    // MARK: The files

    /// Saves this Mac's file, and adds up the files again.
    private func changed() {
        save()
        merge()
    }

    private func merge() {
        you = You.merge(own: own, others: others.values)
    }

    /// A newer "Forget learned words" from any file clears the learned and added words of this Mac (D16).
    /// The store writes the time that it applied, so it clears them one time only.
    private func applyForget() {
        let newest = ([own.forgotAt] + others.values.map(\.forgotAt)).compactMap { $0 }.max()
        guard let newest, (own.forgetApplied ?? .distantPast) < newest else { return }
        own.learned = [:]
        own.added = [:]
        own.forgetApplied = newest
        save()
    }

    /// Reads the history files of the other Macs that are new or changed since the last read,
    /// and forgets the files that are gone. Returns true when something changed.
    private func readOthers() -> Bool {
        others.read(folder: folder, ownName: url.lastPathComponent, isFile: PreferencesFolder.isHistoryFile)
    }

    /// Writes the file atomically: a new file, then a swap. A crash never leaves half a file.
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

    /// Drops pairs until at most `limit` are left: the lowest count first, then the oldest (D4).
    /// It never drops `keeping`, the pair of the pick that happens now. A new pair has the count 1.
    /// Without this, a full list of pairs with a count of 2 or more would drop each new word at once.
    static func dropPastLimit(_ you: inout You, limit: Int, keeping: (text: String, key: String)) {
        var extra = you.learnedPairs - limit
        guard extra > 0 else { return }
        let pairs = you.learned.flatMap { text, emojis in emojis.map { (text: text, key: $0.key, use: $0.value) } }
            .sorted { a, b in
                if a.use.count != b.use.count { return a.use.count < b.use.count }
                if a.use.last != b.use.last { return a.use.last < b.use.last }
                return (a.text, a.key) < (b.text, b.key)
            }
        for pair in pairs where extra > 0 && (pair.text, pair.key) != keeping {
            you.learned[pair.text]?[pair.key] = nil
            if you.learned[pair.text]?.isEmpty == true { you.learned[pair.text] = nil }
            extra -= 1
        }
    }

    // MARK: The file format

    /// Dates are ISO 8601 text with milliseconds, so a person can read the file.
    static var encoder: JSONEncoder { MacFiles.encoder }
    static var decoder: JSONDecoder { MacFiles.decoder }
}
