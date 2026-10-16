import Foundation

/// The import of the EmojiFinder history (D6 on YAZ-2894).
/// `install.sh` reads the old database with `sqlite3 -json` and runs
/// `YaseenEmoji --import-uses <default folder>` with the rows on standard input:
/// `[{"emoji": "🤣", "count": 358}, ...]`. The rows go into `uses` of this Mac's file (D16).
/// The import runs only when the folder has no history at all, so it never runs again for a Mac with history.
public enum YouImport {
    /// The input is not a list of `{"emoji": text, "count": number}` rows.
    public struct BadInput: Error, CustomStringConvertible {
        public let description: String
    }

    /// What one run did, for the one line that the app prints.
    public struct Summary: Equatable, Sendable {
        /// The number of different emojis in the input, after `You.key`.
        public let emojis: Int
        /// The sum of the counts in the input.
        public let picks: Int
        /// False if the input had no rows, or if `you.json` already had an import. Then nothing changed.
        public let changed: Bool

        public var line: String {
            if changed { return "Imported \(picks) picks of \(emojis) emojis from EmojiFinder." }
            if emojis == 0 { return "Nothing changed: the EmojiFinder history is empty." }
            return "Nothing changed: Yaseen Emoji already has a history here."
        }
    }

    private struct Row: Decodable {
        let emoji: String
        let count: Int
    }

    /// The counts of the input by emoji key. "❤" and "❤️" become one emoji.
    /// Empty input is a list with no rows: `sqlite3 -json` prints nothing for an empty table.
    public static func parse(_ data: Data) throws -> [String: Int] {
        let rows: [Row]
        if String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) { return [:] }
        do {
            rows = try JSONDecoder().decode([Row].self, from: data)
        } catch {
            throw BadInput(description: "The input is not JSON like [{\"emoji\": \"🤣\", \"count\": 358}].")
        }
        var counts: [String: Int] = [:]
        for row in rows {
            let key = You.key(row.emoji)
            guard !key.isEmpty else { throw BadInput(description: "A row has no emoji.") }
            guard row.count >= 0 else { throw BadInput(description: "The count of \(row.emoji) is less than 0.") }
            counts[key, default: 0] += row.count
        }
        return counts
    }

    /// The import into this Mac's file in `folder` (D16). It does nothing when the folder has any history:
    /// `you.json`, or any `you-*.json`. The Mac name comes from Prefs, the same name as the app uses.
    public static func run(_ data: Data, intoFolder folder: URL, defaults: UserDefaults = .standard) throws -> Summary {
        let counts = try parse(data)
        if PreferencesFolder.hasHistory(in: folder) {
            return Summary(emojis: counts.count, picks: counts.values.reduce(0, +), changed: false)
        }
        let name = Prefs(defaults: defaults).macName(computerName: PreferencesFolder.computerName)
        return try run(data, into: PreferencesFolder(defaultFolder: folder, macName: name).ownFile(in: folder))
    }

    /// Adds the counts of `data` to the uses of the history file at `url`, and saves the file atomically.
    /// It runs one time only: a second run changes nothing, so a repeat never counts a pick twice.
    /// Bad input throws before the file changes.
    public static func run(_ data: Data, into url: URL, now: Date = Date()) throws -> Summary {
        let counts = try parse(data)
        // No rows: the file does not change, and a later import can still run.
        guard !counts.isEmpty else { return Summary(emojis: 0, picks: 0, changed: false) }
        let store = YouStore(url: url, now: { now })
        store.load()
        let picks = counts.values.reduce(0, +)
        guard store.you.imported == nil else {
            return Summary(emojis: counts.count, picks: picks, changed: false)
        }
        var you = store.you
        for (key, count) in counts where count > 0 {
            you.uses[key, default: You.Use(count: 0, last: now)].count += count
        }
        you.imported = now
        store.replace(with: you)
        if let error = store.saveError { throw error }
        return Summary(emojis: counts.count, picks: picks, changed: true)
    }
}
