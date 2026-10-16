import Foundation
import SystemConfiguration

/// The preferences folder of D16 on YAZ-2894: the folder with one history file for each Mac.
///
/// The default is `~/Library/Application Support/Yaseen Emoji`. Settings → "Set preferences folder…"
/// can point it at a folder that git syncs, for example `yaseen-os/Sync/yaseen-emoji`. Each Mac writes
/// only `you-<Mac name>.json` there, so git never gets a conflict. The folder path stays on each Mac.
struct PreferencesFolder {
    static let missingText = "Can't find the preferences folder. This Mac uses its own history."

    /// `~/Library/Application Support/Yaseen Emoji` in the app. A temp folder in a test.
    let defaultFolder: URL
    /// The safe name of this Mac (`safeName`), made one time and kept in Prefs.
    let macName: String

    /// The name of this Mac's history file: `you-<Mac name>.json`.
    var fileName: String { "you-\(macName).json" }

    /// This Mac's history file in `folder`.
    func ownFile(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    /// The folder to use at the start: the chosen folder, or the default folder when none is chosen.
    /// A chosen folder that is gone or cannot be read gives the default folder, with `isMissing` true.
    func resolve(chosen: String) -> (folder: URL, isMissing: Bool) {
        guard !chosen.isEmpty else { return (defaultFolder, false) }
        let folder = URL(fileURLWithPath: chosen, isDirectory: true)
        return PreferencesFolder.isUsable(folder) ? (folder, false) : (defaultFolder, true)
    }

    /// Makes this Mac's file when it is missing, from the history that this Mac already has (D16):
    /// first this Mac's file in the default folder, then the old `you.json` there (before D16).
    /// The source stays as a backup. Returns the source, or nil when nothing was copied.
    /// It never copies when this Mac's file exists, so a pick never counts two times.
    @discardableResult
    func seedIfMissing(_ ownFile: URL) -> URL? {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: ownFile.path) else { return nil }
        let sources = [self.ownFile(in: defaultFolder), defaultFolder.appendingPathComponent("you.json")]
        for source in sources where source.standardizedFileURL != ownFile.standardizedFileURL {
            guard let data = try? Data(contentsOf: source) else { continue }
            do {
                try fileManager.createDirectory(at: ownFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: ownFile, options: .atomic)
                return source
            } catch {
                return nil
            }
        }
        return nil
    }

    // MARK: Names

    /// The name of a Mac, safe for a file name: A-Z, a-z, 0-9 and `-`. Each other character becomes `-`.
    /// Runs of `-` become one, and the ends have none. "Yasin's BIG Macbook Pro" gives "Yasin-s-BIG-Macbook-Pro".
    static func safeName(_ computerName: String) -> String {
        var result = ""
        for scalar in computerName.unicodeScalars {
            let safe = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
            if safe {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result += "-"
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "Mac" : trimmed
    }

    /// True for a history file that the merge reads: `you-<A-Z a-z 0-9 ->.json`.
    /// The old `you.json`, a bad file (`you-X.bad.json`) and a copy (`you-X 2.json`) never count.
    static func isHistoryFile(_ name: String) -> Bool {
        guard name.hasPrefix("you-"), name.hasSuffix(".json") else { return false }
        let middle = name.dropFirst(4).dropLast(5)
        return !middle.isEmpty && middle.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
        }
    }

    /// True when the folder has any history: `you.json`, or any `you-*.json` (also a bad one).
    /// The import of the EmojiFinder history runs only with no history at all (D6, D16).
    static func hasHistory(in folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0 == "you.json" || ($0.hasPrefix("you-") && $0.hasSuffix(".json")) }
    }

    /// True for a folder that exists and that the app can list.
    /// macOS can refuse a folder in Documents until you allow it.
    static func isUsable(_ folder: URL) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }

    /// The computer name of System Settings → General → Sharing, for example "Yasin's BIG Macbook Pro".
    static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}
