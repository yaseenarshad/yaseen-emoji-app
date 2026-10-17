import Foundation

/// The files of the KLIPY GIFs and memes that you used (D18 of YAZ-2919), on this Mac only:
/// `~/Library/Application Support/Yaseen Emoji/klipy/<slug>.<ext>`. Not in the preferences folder, because
/// 50 files that change often would grow the git history of a synced folder with no end.
///
/// A pick moves the paste file that it downloaded into the folder, so no file downloads two times.
/// The last use of a file on this Mac is its modification date. At most 50 files and 200 MB:
/// the file with the oldest last use goes first. The card of the item stays in the list (`KlipyCard`).
/// The folder, the limits and the clock are parameters, so a test gives a temp folder and small limits.
final class KlipyFiles {
    static let fileLimit = 50
    static let byteLimit = 200 * 1024 * 1024

    let folder: URL
    private let fileLimit: Int
    private let byteLimit: Int
    private let now: () -> Date
    /// The files of the folder, by file name with no extension (`PreferencesFolder.safeName` of the slug).
    private var index: [String: URL] = [:]

    init(folder: URL, fileLimit: Int = KlipyFiles.fileLimit, byteLimit: Int = KlipyFiles.byteLimit,
         now: @escaping () -> Date = Date.init) {
        self.folder = folder
        self.fileLimit = fileLimit
        self.byteLimit = byteLimit
        self.now = now
        reload()
    }

    /// Lists the folder one time (at each open of the panel), the same as `gifs/` and `memes/` (D13 update).
    func reload() {
        index = [:]
        for file in files() { index[file.deletingPathExtension().lastPathComponent] = file }
    }

    /// The kept file of this slug, from the last listing, or nil.
    func file(for slug: String) -> URL? {
        index[PreferencesFolder.safeName(slug)]
    }

    /// The names of the kept files, sorted. For a test.
    var names: [String] { files().map(\.lastPathComponent).sorted() }

    /// A pick: moves `source` (the downloaded paste file) to `<slug>.<ext>`, marks the use, and drops the files
    /// past the limits. The move goes to a hidden name in the folder first, then one rename puts it in place,
    /// so a different reader never sees half a file.
    func keep(_ source: URL, slug: String, ext: String) throws -> URL {
        let manager = FileManager.default
        let name = PreferencesFolder.safeName(slug)
        let target = folder.appendingPathComponent("\(name).\(ext)")
        if source.standardizedFileURL.path != target.standardizedFileURL.path {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let part = folder.appendingPathComponent(".\(UUID().uuidString).part")
            try manager.moveItem(at: source, to: part)
            do {
                if manager.fileExists(atPath: target.path) {
                    _ = try manager.replaceItemAt(target, withItemAt: part)
                } else {
                    try manager.moveItem(at: part, to: target)
                }
            } catch {
                try? manager.removeItem(at: part)
                throw error
            }
        }
        // The same slug with a different extension: the old file goes.
        if let old = index[name], old.lastPathComponent != target.lastPathComponent { try? manager.removeItem(at: old) }
        index[name] = target
        markUse(of: target)
        dropPastLimits(keeping: target)
        return target
    }

    /// A pick of an item whose file is kept: its last use is now.
    func markUse(of file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: file.path)
    }

    /// Drops the files with the oldest last use until at most `fileLimit` files and `byteLimit` bytes stay.
    /// The file of this pick always stays.
    private func dropPastLimits(keeping kept: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let keptName = kept.lastPathComponent
        let entries = files().map { file -> (url: URL, used: Date, bytes: Int) in
            let values = try? file.resourceValues(forKeys: keys)
            return (file, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }.sorted { a, b in
            let aKept = a.url.lastPathComponent == keptName, bKept = b.url.lastPathComponent == keptName
            if aKept != bKept { return aKept }
            return a.used != b.used ? a.used > b.used : a.url.lastPathComponent < b.url.lastPathComponent
        }
        var count = 0
        var bytes = 0
        for entry in entries {
            count += 1
            bytes += entry.bytes
            guard entry.url.lastPathComponent != keptName, count > fileLimit || bytes > byteLimit else { continue }
            try? FileManager.default.removeItem(at: entry.url)
            index[entry.url.deletingPathExtension().lastPathComponent] = nil
            count -= 1
            bytes -= entry.bytes
        }
    }

    /// The files of the folder, with no hidden file (a move that runs, `.DS_Store`). Each URL is `folder` and the name,
    /// so it is the same URL as the one that `keep` gives.
    private func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.map { folder.appendingPathComponent($0) }
    }
}
