import Foundation

/// One emoji of the catalog, with its search words (D3 on YAZ-2894).
public struct Emoji: Sendable, Hashable {
    /// The emoji as the app pastes it: the fully-qualified form, with U+FE0F where Unicode puts it.
    public let text: String
    /// The Unicode name, for example "red heart".
    public let name: String
    /// The place of its group in `EmojiCatalog.groupNames`.
    public let group: Int
    /// The place in the Unicode order. Search uses it when all else is equal.
    public let order: Int
    /// The search words in lower case. The name is not in this list.
    public let words: [String]
    /// The five one-tone forms, light to dark. Empty if the emoji takes no skin tone.
    public let toneForms: [String]
    /// `You.key(text)`: the key of this emoji in `you.json`.
    public let key: String
    /// The name and the words in lower case as UTF-8 bytes. The search compares bytes,
    /// because that is about 3 times faster than a compare of `String` values.
    let nameBytes: [UInt8]
    let wordBytes: [[UInt8]]

    public var takesTone: Bool { !toneForms.isEmpty }

    public init(text: String, name: String, group: Int, order: Int, words: [String], toneForms: [String] = []) {
        self.text = text
        self.name = name
        self.group = group
        self.order = order
        self.words = words
        self.toneForms = toneForms
        key = You.key(text)
        nameBytes = Array(name.lowercased().utf8)
        wordBytes = words.map { Array($0.lowercased().utf8) }
    }
}

/// Loads `emoji.json`, the list that `scripts/make-emoji-data.swift` makes.
public enum EmojiCatalog {
    /// The group names, in order. `Emoji.group` is a place in this list.
    public static let groupNames = [
        "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink",
        "Travel & Places", "Activities", "Objects", "Symbols", "Flags",
    ]

    /// The name of the resource bundle that SwiftPM makes for this target.
    static let resourceBundleName = "YaseenEmoji_EmojiKit.bundle"

    /// The file is missing, or it is not a list of emoji rows.
    public struct LoadError: Error, CustomStringConvertible {
        public let description: String
    }

    /// One row of `emoji.json`. The short keys keep the file small.
    private struct Row: Decodable {
        let e: String
        let n: String
        let g: Int
        let t: Int
        let w: [String]
        let f: [String]?
    }

    /// The emojis of the file at `url`, in Unicode order.
    public static func load(from url: URL) throws -> [Emoji] {
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
        return rows.enumerated().map { order, row in
            Emoji(text: row.e, name: row.n, group: row.g, order: order, words: row.w,
                  toneForms: row.t == 1 ? row.f ?? [] : [])
        }
    }

    /// The emojis of the `emoji.json` that ships with the app.
    public static func bundled() throws -> [Emoji] {
        try load(from: bundledURL())
    }

    /// Where `emoji.json` is. The app first: `bundle.sh` copies the SwiftPM resource bundle
    /// into `Contents/Resources`. `Bundle(url:)` finds the file in a nested and in a flat bundle.
    /// Then the app itself. Then `Bundle.module`, for `swift test` and `swift run` only.
    static func bundledURL() throws -> URL {
        if let resources = Bundle.main.resourceURL,
           let inner = Bundle(url: resources.appendingPathComponent(resourceBundleName)),
           let url = inner.url(forResource: "emoji", withExtension: "json") {
            return url
        }
        if let url = Bundle.main.url(forResource: "emoji", withExtension: "json") {
            return url
        }
        // `Bundle.module` stops the process when it cannot find the bundle. In an app that bundle
        // is never in the place that `Bundle.module` looks, so the app throws an error instead.
        guard Bundle.main.bundleURL.pathExtension != "app" else {
            throw LoadError(description: "\(resourceBundleName) is not in the app")
        }
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json") else {
            throw LoadError(description: "emoji.json is not in \(resourceBundleName)")
        }
        return url
    }
}
