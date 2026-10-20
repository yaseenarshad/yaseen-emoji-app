import Foundation

/// `YaseenEmoji --name-files` (D26 of YAZ-3018): gives each file with a code name (`01bb8611accdad57.png`) at the top of
/// `gifs/` and `memes/` a real name, one time, on one Mac. Git syncs the renames to the other Mac. The new name is the
/// title in the list, else the first 4 words (`LibraryStore.nameCodeFiles`). It prints one line for each file, and shows
/// no window. A second run changes nothing.
public enum NameCommand {
    public static let noCodeNamesText = "No file has a code name."

    /// Runs the command. Returns the exit code: 0 done, 1 a rename failed or the GIFs and memes folder is missing,
    /// 3 the app runs.
    public static func runAndWait() -> Int32 {
        if AddCommand.appIsRunning() {
            FileHandle.standardError.write(Data((AddCommand.appRunsText + "\n").utf8))
            return 3
        }
        return run(defaults: .standard, defaultFolder: YouStore.defaultFolder, computerName: PreferencesFolder.computerName,
                   cacheURL: LibraryStore.defaultCacheURL) { print($0) }
    }

    /// The command with its parts as parameters, so a test gives fake prefs and a temp folder.
    /// `cacheURL`: the hash cache of the app (D27 of YAZ-3018), or nil in a test.
    static func run(defaults: UserDefaults, defaultFolder: URL, computerName: () -> String, cacheURL: URL? = nil,
                    say: (String) -> Void) -> Int32 {
        let library = AddCommand.library(defaults: defaults, defaultFolder: defaultFolder, computerName: computerName,
                                         cacheURL: cacheURL)
        library.load()
        if library.mediaFolderIsMissing {
            say(MediaFolder.missingText)
            return 1
        }
        let result = library.nameCodeFiles()
        result.lines.forEach(say)
        if result.lines.isEmpty { say(noCodeNamesText) }
        return result.failed ? 1 : 0
    }
}
