import AppKit

/// `YaseenEmoji --add-media <file> [<file> …] [--words "<words>"]`: adds many GIFs and memes at once from the Terminal
/// or a script (Yaseen added 15 memes with it on 16 Oct 2026). It uses the same steps and rules as the add window
/// (D5, D8, D12, D15 of YAZ-2919): `MediaImport.prepare`, the words, the title from the file name, then
/// `LibraryStore.add`. It prints one line for each file, and shows no window.
/// The new file gets the name of the title (D25 of YAZ-3018). A file that is already in `gifs/` or `memes/` is not
/// copied and not changed, of any size: only its words go into the list. This is how an agent adds keywords to the
/// files that Yaseen put in Finder.
public enum AddCommand {
    public static let usage = "Usage: YaseenEmoji --add-media <file> [<file> …] [--words \"<word> <word>\"]"
    public static let appRunsText = "Quit Yaseen Emoji first. The app keeps its own list and would write over the new items."

    /// The files and the words of the arguments after `--add-media`. Nil when no file is given.
    /// The words follow the rule of the words box of the add window (`Item.words(typed:)`).
    static func parse(_ arguments: [String]) -> (files: [URL], words: [String])? {
        var files: [URL] = []
        var words: [String] = []
        var rest = arguments[...]
        while let next = rest.popFirst() {
            if next == "--words" {
                words += Item.words(typed: rest.popFirst() ?? "")
            } else {
                files.append(URL(fileURLWithPath: (next as NSString).expandingTildeInPath))
            }
        }
        return files.isEmpty ? nil : (files, words)
    }

    /// The words of a file name: "Happy-Dance_2.gif" gives "happy", "dance".
    static func words(fromName url: URL) -> [String] {
        MediaImport.words(in: url.deletingPathExtension().lastPathComponent.lowercased()).filter { Int($0) == nil }
    }

    /// Runs the command and waits. The work runs off the main thread. Returns the exit code: 0 done,
    /// 1 a file failed, 2 bad arguments, 3 the app runs.
    public static func runAndWait(_ arguments: [String]) -> Int32 {
        if appIsRunning() {
            FileHandle.standardError.write(Data((appRunsText + "\n").utf8))
            return 3
        }
        let result = ExitCode()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result.value = await run(arguments, defaults: .standard, defaultFolder: YouStore.defaultFolder,
                                     computerName: PreferencesFolder.computerName, cacheURL: LibraryStore.defaultCacheURL) { print($0) }
            done.signal()
        }
        done.wait()
        return result.value
    }

    /// The command with its parts as parameters, so a test gives fake prefs and a temp folder.
    /// The folders are the same as the app's: the preferences folder and the GIFs and memes folder of the prefs.
    /// `cacheURL`: the hash cache of the app (D27 of YAZ-3018), or nil in a test.
    static func run(_ arguments: [String], defaults: UserDefaults, defaultFolder: URL, computerName: () -> String,
                    cacheURL: URL? = nil, say: (String) -> Void) async -> Int32 {
        guard let (files, given) = parse(arguments) else {
            say(usage)
            return 2
        }
        let library = AddCommand.library(defaults: defaults, defaultFolder: defaultFolder, computerName: computerName,
                                         cacheURL: cacheURL)
        library.load()
        var code: Int32 = 0
        for file in files {
            do {
                let prepared: PreparedFile
                if let inside = MediaScan.place(of: file, in: library.mediaFolder),
                   MediaScan.extensions.contains(file.pathExtension.lowercased()) {
                    // A GIF, PNG or JPEG that is already in the folder (D25 of YAZ-3018): no `prepare`, so no 10 MB limit.
                    // The bytes stay as they are, and only the words go into the list.
                    let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
                    prepared = PreparedFile(bytes: bytes, ext: file.pathExtension.lowercased(), kind: inside.kind)
                } else {
                    prepared = try await MediaImport.prepare(file)
                }
                var words = given
                if words.isEmpty, prepared.kind == .meme { words = await MediaImport.readText(in: prepared.bytes) }
                if words.isEmpty { words = AddCommand.words(fromName: file) }
                // The title of the add window (D15): the file name. It names a new file, so the file keeps its name
                // (D25 of YAZ-3018). A picture that is on disk already keeps its file and its name.
                let title = AddSource.title(fromName: file.deletingPathExtension().lastPathComponent)
                let written = try library.place(of: prepared, title: title).map {
                    try LibraryStore.fileToAdd(prepared.bytes, source: file, target: $0, mediaFolder: library.mediaFolder)
                }
                let result = try library.add(prepared, words: words, at: written)
                let kind = result.item.kind == .gif ? "GIF" : "meme"
                let verb: String
                if case .alreadyThere = result { verb = "Already there:" } else { verb = "Added" }
                say("\(verb) \(kind) \(result.item.id) from \(file.lastPathComponent), title: \(result.item.title), "
                    + "words: \(result.item.words.joined(separator: ", "))")
            } catch {
                say("\(file.lastPathComponent): \(error.localizedDescription)")
                code = 1
            }
        }
        return code
    }

    /// True when the app runs. `--add-media` and `--name-files` then stop: the app would write over the list.
    static func appIsRunning() -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: AddCommand.bundleIdentifier)
        return copies.contains { $0.processIdentifier != own }
    }

    /// This Mac's list, with the same folders as the app's: the preferences folder and the GIFs and memes folder of the
    /// prefs. Not loaded yet.
    static func library(defaults: UserDefaults, defaultFolder: URL, computerName: () -> String, cacheURL: URL?) -> LibraryStore {
        let prefs = Prefs(defaults: defaults)
        let folders = PreferencesFolder(defaultFolder: defaultFolder, macName: prefs.macName(computerName: computerName))
        let place = folders.resolve(chosen: prefs.preferencesFolder)
        let media = MediaFolder.resolve(chosen: prefs.mediaFolder, preferencesFolder: place.folder)
        return LibraryStore(url: place.folder.appendingPathComponent(folders.libraryFileName), mediaFolder: media.folder,
                            cacheURL: cacheURL)
    }

    /// The app, also when this binary runs outside the bundle.
    static let bundleIdentifier = "com.yaseenarshad.yaseenemoji"
}

/// The exit code that the detached work gives back to the waiting thread.
private final class ExitCode: @unchecked Sendable {
    var value: Int32 = 1
}
