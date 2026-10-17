import Foundation

/// The parts of one file for each Mac (D16 of YAZ-2894, D3 of YAZ-2919) that `YouStore` and `LibraryStore` share:
/// the load of this Mac's file with the bad-file move, the atomic save, and the JSON format.
enum MacFiles {
    /// What `loadOwn` found.
    enum Own<Value> {
        /// No file yet.
        case missing
        case loaded(Value)
        /// The file could not be read. It is now at this URL.
        case movedBad(URL)
        /// The file could not be read, and it could not move away. A save must not write over it.
        case blocked(Error)
    }

    /// Reads this Mac's file. A file that cannot be read becomes `<name>.bad.json` (or `.bad-2.json` and on).
    /// It never deletes a file in silence.
    static func loadOwn<Value: Decodable>(_ type: Value.Type, at url: URL) -> Own<Value> {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        do {
            return .loaded(try decoder.decode(Value.self, from: Data(contentsOf: url)))
        } catch {
            let bad = freeBadURL(next: url)
            do {
                try fileManager.moveItem(at: url, to: bad)
                return .movedBad(bad)
            } catch {
                return .blocked(error)
            }
        }
    }

    /// Writes the file atomically: a new file, then a swap. A crash never leaves half a file.
    static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// `<name>.bad.json` next to the file, or `<name>.bad-2.json` and on if that name is in use.
    /// The dot keeps the bad file out of the merge (`PreferencesFolder.isHistoryFile`, `isLibraryFile`).
    static func freeBadURL(next url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var number = 1
        while true {
            let name = number == 1 ? "\(base).bad.json" : "\(base).bad-\(number).json"
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    // MARK: The file format

    /// Dates are ISO 8601 text with milliseconds, so a person can read the file.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: dateStyle) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return decoder
    }()

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// The files of the other Macs in one folder, by file name, with the modification date of each read.
/// `read` reads only the files that are new or changed. A file that cannot be read keeps its last good data,
/// and the store never changes that file.
struct OtherMacFiles<Value: Decodable> {
    private struct File {
        var modified: Date
        var value: Value
    }

    private var files: [String: File] = [:]

    /// The data of the other Macs, in the order of the file names.
    var values: [Value] { files.keys.sorted().compactMap { files[$0]?.value } }

    mutating func removeAll() { files = [:] }

    /// Lists `folder`, reads the files that `isFile` takes (except `ownName`) and forgets the files that are gone.
    /// Returns true when something changed.
    mutating func read(folder: URL, ownName: String, isFile: (String) -> Bool) -> Bool {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        var seen: Set<String> = []
        var didChange = false
        for file in found {
            let name = file.lastPathComponent
            guard name != ownName, isFile(name) else { continue }
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            seen.insert(name)
            let modified = values?.contentModificationDate ?? .distantPast
            if let known = files[name], known.modified == modified { continue }
            guard let data = try? Data(contentsOf: file), let decoded = try? MacFiles.decoder.decode(Value.self, from: data) else {
                // A half-written or broken file of a different Mac: keep the last good data, if any.
                if var known = files[name] {
                    known.modified = modified
                    files[name] = known
                }
                continue
            }
            files[name] = File(modified: modified, value: decoded)
            didChange = true
        }
        for name in files.keys where !seen.contains(name) {
            files[name] = nil
            didChange = true
        }
        return didChange
    }
}
