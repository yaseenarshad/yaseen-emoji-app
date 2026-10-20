import Foundation

/// One file of `gifs/` or `memes/` that the scan found (D22, D27 of YAZ-3018).
struct ScannedFile: Equatable, Sendable {
    /// The path in the GIFs and memes folder, for example `memes/Infinite game/circle.png`.
    var path: String
    /// The top folder gives the tab (D22 of YAZ-3018): a file below `memes/` is a meme, also a GIF file.
    var kind: ItemKind
    var size: Int
    /// The modification date, in seconds since 2001. The hash cache compares it.
    var modified: Double
    /// The order of a file with no record (D27 of YAZ-3018).
    var created: Date
}

/// The hash cache of D27 on YAZ-3018: for each path of the last scan, the size, the modification date and the `id`.
/// A file with the same path, size and date uses the saved `id`, with no hash. The app keeps it in
/// `~/Library/Caches/Yaseen Emoji/files.json`, on this Mac only. The paths are relative to the GIFs and memes folder:
/// after "Set GIFs and memes folder…", the copies keep their size and date, and need no hash.
struct FileCache: Codable, Equatable {
    struct Entry: Codable, Equatable, Sendable {
        var size: Int
        var modified: Double
        var id: String
    }

    /// The entries, by the path in the GIFs and memes folder.
    var files: [String: Entry] = [:]

    /// The saved `id` of the file, or nil when the file is new or changed.
    func id(of file: ScannedFile) -> String? {
        guard let entry = files[file.path], entry.size == file.size, entry.modified == file.modified else { return nil }
        return entry.id
    }

    /// The cache in `url`. No file, or a bad file, gives an empty cache.
    static func load(from url: URL) -> FileCache {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(FileCache.self, from: $0) } ?? FileCache()
    }

    /// Writes the cache with an atomic write. A failure only costs the hashes at the next start.
    func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// The scan of the GIFs and memes folder (D22, D27 of YAZ-3018): the full tree of `gifs/` and `memes/`.
enum MediaScan {
    /// The types that the scan takes. The add window changes the other types (D5 of YAZ-2919).
    static let extensions: Set<String> = ["gif", "png", "jpg", "jpeg"]

    private static let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                 .contentModificationDateKey, .creationDateKey]
    private static let keySet = Set(keys)

    /// The GIF, PNG and JPEG files of `gifs/` and `memes/`, at any depth, in the order of the listing. It skips hidden
    /// files, hidden folders, packages and symbolic links. It reads only the listing: no file is opened.
    static func list(_ mediaFolder: URL) -> [ScannedFile] {
        var found: [ScannedFile] = []
        for kind in ItemKind.allCases {
            let top = mediaFolder.appendingPathComponent(kind.folderName, isDirectory: true)
            guard let walk = FileManager.default.enumerator(at: top, includingPropertiesForKeys: keys,
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            // The enumerator gives the real path (`/private/var/…` for `/var/…`). Made one time, not for each file.
            let prefixes = [top.path + "/", realPath(top) + "/"]
            for case let url as URL in walk {
                let full = url.path
                guard let prefix = prefixes.first(where: { full.hasPrefix($0) }),
                      let file = file(at: url, path: kind.folderName + "/" + full.dropFirst(prefix.count), kind: kind)
                else { continue }
                found.append(file)
            }
        }
        return found
    }

    /// One file of the tree, or nil for a folder, a symbolic link or a different type.
    static func file(at url: URL, path: String, kind: ItemKind) -> ScannedFile? {
        guard extensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: keySet),
              values.isRegularFile == true, values.isSymbolicLink != true
        else { return nil }
        return ScannedFile(path: path, kind: kind, size: values.fileSize ?? 0,
                           modified: values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0,
                           created: values.creationDate ?? values.contentModificationDate ?? Date(timeIntervalSince1970: 0))
    }

    /// `a/x.png` for the file `<top>/a/x.png`, or nil for a file outside `top`. The enumerator gives the real path
    /// (`/private/var/…` for `/var/…`), so the real path of `top` counts too.
    static func relativePath(of url: URL, in top: URL) -> String? {
        for base in [top.path, realPath(top)] {
            let prefix = base + "/"
            if url.path.hasPrefix(prefix) { return String(url.path.dropFirst(prefix.count)) }
        }
        return nil
    }

    /// The path with each symbolic link resolved, `/private` included (`realpath`). `resolvingSymlinksInPath()`
    /// removes `/private` again. A path that is not there stays as it is.
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The path in the GIFs and memes folder of a file below `gifs/` or `memes/`, and its kind, or nil.
    /// The add uses it for a source that is already in the folder (D25 of YAZ-3018).
    static func place(of url: URL, in mediaFolder: URL) -> (path: String, kind: ItemKind)? {
        for kind in ItemKind.allCases {
            let top = mediaFolder.appendingPathComponent(kind.folderName, isDirectory: true)
            if let inside = relativePath(of: url, in: top) ?? relativePath(of: URL(fileURLWithPath: realPath(url)), in: top) {
                return ("\(kind.folderName)/\(inside)", kind)
            }
        }
        return nil
    }

    /// The hashes of `files`, by path. Safe off the main thread. A file that cannot be read gets none.
    static func hash(_ files: [ScannedFile], in mediaFolder: URL) -> [String: FileCache.Entry] {
        var result: [String: FileCache.Entry] = [:]
        for file in files {
            let url = mediaFolder.appendingPathComponent(file.path)
            guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            result[file.path] = FileCache.Entry(size: file.size, modified: file.modified, id: MediaHash.id(bytes))
        }
        return result
    }
}

/// The names of the files (D23 of YAZ-3018): the title of a file name, and the folder words of a path.
enum MediaName {
    /// The title of a file name with no extension (D23 of YAZ-3018): `-` and `_` as spaces, one space between words,
    /// no copy mark (` (1)`) at the end. A code name of 16 or more hex characters gives "". Camera names stay:
    /// `IMG_2231` gives "IMG 2231". No regular expression: the scan makes a title for each file.
    static func title(ofName name: String) -> String {
        var text = Item.cleanTitle(String(name.map { $0 == "-" || $0 == "_" ? " " : $0 }))
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let number = text[text.index(after: open)..<text.index(before: text.endIndex)]
            if !number.isEmpty, number.allSatisfy(\.isASCII), number.allSatisfy(\.isNumber) {
                text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return isCodeName(text) ? "" : text
    }

    /// The title of the file at a path of the GIFs and memes folder.
    static func title(ofPath path: String) -> String {
        title(ofName: ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
    }

    /// 16 or more hex characters, for example `01bb8611accdad57`: the code name of D4 on YAZ-2919.
    static func isCodeName(_ name: String) -> Bool {
        name.count >= 16 && name.allSatisfy(\.isHexDigit)
    }

    /// The longest file name with no extension (D24 of YAZ-3018).
    static let longestName = 120
    /// The most UTF-8 bytes of a file name with no extension. With " 9999" and ".jpeg", a name stays under the 255
    /// bytes of APFS, also in Arabic, Chinese or emoji.
    static let longestNameBytes = 240

    /// The name rule of "Rename…" and of an add (D24, D25 of YAZ-3018): the text as a file name with no extension.
    /// Trimmed, one space between words, `/` and `:` as `-`, no dot at the start (the file never becomes hidden),
    /// 120 characters and 240 UTF-8 bytes at most, cut between two characters. "" when nothing is left.
    static func fileName(_ text: String) -> String {
        var name = Item.cleanTitle(String(text.map { $0 == "/" || $0 == ":" ? "-" : $0 }))
        while name.hasPrefix(".") { name = Item.cleanTitle(String(name.dropFirst())) }
        if name.count > longestName { name = Item.cleanTitle(String(name.prefix(longestName))) }
        if name.utf8.count > longestNameBytes {
            var bytes = 0
            let kept = name.prefix { character in
                bytes += character.utf8.count
                return bytes <= longestNameBytes
            }
            name = Item.cleanTitle(String(kept))
        }
        return name
    }

    /// `<name>.<ext>` for the first try, then `<name> 2.<ext>`, `<name> 3.<ext>` and so on (D24, D25 of YAZ-3018).
    static func numbered(_ name: String, _ number: Int, ext: String) -> String {
        let base = number == 1 ? name : "\(name) \(number)"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// The first name of `numbered` in `folder` that is free, or whose file `isSame` says is the same file.
    static func freeURL(in folder: URL, name: String, ext: String, isSame: (URL) -> Bool) -> URL {
        var number = 1
        while true {
            let url = folder.appendingPathComponent(numbered(name, number, ext: ext))
            if !FileManager.default.fileExists(atPath: url.path) || isSame(url) { return url }
            number += 1
        }
    }

    /// The search words of the folders between `gifs/` or `memes/` and the file (D23 of YAZ-3018), with `-` and `_`
    /// as spaces. `memes/Infinite game/circle.png` gives "Infinite game". They are not saved in the list.
    static func folderWords(ofPath path: String) -> [String] {
        let parts = path.split(separator: "/")
        guard parts.count > 2 else { return [] }
        return parts.dropFirst().dropLast().map { Item.cleanTitle(String($0.map { $0 == "-" || $0 == "_" ? " " : $0 })) }
    }
}
