import Foundation
import Testing
@testable import EmojiKit

/// The Settings section "GIFs and memes" (YAZ-2928 part 2; D4 and D14 of YAZ-2919), and the move of the list and
/// the files with the preferences folder (the owner note on YAZ-2928). Temp folders, fake prefs, a fake key store.
@MainActor
@Suite struct MediaSettingsTests {
    /// A key store that refuses each write, as the Keychain can.
    final class RefusingKeyStore: KeyStore, @unchecked Sendable {
        func read() -> String? { nil }
        func write(_ key: String) throws { throw KeychainError(status: -25293) }
    }

    /// The app on the temp folders of `rig`, with one GIF of your own in the preferences folder.
    private func app(_ rig: PickRig) throws -> (AppController, Item) {
        let app = AppController(hotKeys: FakeHotKeyRegistrar(), loginItem: FakeLoginItem(), parts: rig.parts(catalog: []))
        app.start()
        let bytes = makeTestImage(width: 40, height: 30, type: .gif, frames: 2)
        let item = try app.library.add(PreparedFile(bytes: bytes, ext: "gif", kind: .gif), words: ["dance"]).item
        return (app, item)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// "Set preferences folder…" and "Reset to Mac Default Folder…" also move `library-<Mac>.json`, and the files
    /// of `gifs/` and `memes/` when the GIFs and memes folder is the preferences folder.
    @Test func thePreferencesFolderMovesTheListAndTheFiles() throws {
        let rig = try PickRig()
        let (app, item) = try app(rig)
        let settings = app.settings
        let home = rig.folder.defaultFolder
        let file = try #require(item.file)
        #expect(exists(home.appendingPathComponent(file)))
        #expect(settings.mediaFolderIsSame && settings.mediaFolderPath == home.path && settings.mediaFolderProblem == nil)

        let sync = rig.folder.url.appendingPathComponent("yaseen-os/Sync/yaseen-emoji", isDirectory: true)
        settings.pickFolder = { $0(sync) }
        settings.choosePreferencesFolder()
        #expect(rig.prefs.preferencesFolder == sync.path && settings.folderProblem == nil)
        #expect(app.store.url == sync.appendingPathComponent("you-Test-Mac.json"))
        #expect(app.library.url == sync.appendingPathComponent("library-Test-Mac.json") && exists(app.library.url))
        #expect(exists(sync.appendingPathComponent(file)) && !exists(home.appendingPathComponent(file)))
        #expect(app.library.mediaFolder.path == sync.path && app.library.missing.isEmpty)
        #expect(rig.prefs.mediaFolder.isEmpty && settings.mediaFolderIsSame && settings.mediaFolderPath == sync.path)
        #expect(app.library.items.map(\.id) == [item.id])

        // "Reset to Mac Default Folder…" after you type "reset" (D19): the list and the file come back.
        settings.ask(.reset)
        settings.typedConfirmation = "reset"
        settings.confirm()
        #expect(rig.prefs.preferencesFolder.isEmpty)
        #expect(app.library.url == home.appendingPathComponent("library-Test-Mac.json"))
        #expect(exists(home.appendingPathComponent(file)) && !exists(sync.appendingPathComponent(file)))
        #expect(app.library.missing.isEmpty && app.library.items.map(\.id) == [item.id])
    }

    /// "Set GIFs and memes folder…" and "Reset to Same Folder…" call `useMediaFolder(_:)`. A change of the preferences
    /// folder then leaves the files in their own folder. A failed move keeps the files and the pref, with the red line.
    @Test func theGIFsAndMemesFolderMovesAndComesBack() throws {
        let rig = try PickRig()
        let (app, item) = try app(rig)
        let settings = app.settings
        let home = rig.folder.defaultFolder
        let file = try #require(item.file)

        let media = rig.folder.url.appendingPathComponent("media", isDirectory: true)
        settings.pickMediaFolder = { $0(media) }
        settings.chooseMediaFolder()
        #expect(rig.prefs.mediaFolder == media.path && !settings.mediaFolderIsSame)
        #expect(settings.mediaFolderPath == media.path && settings.mediaFolderProblem == nil)
        #expect(exists(media.appendingPathComponent(file)) && !exists(home.appendingPathComponent(file)))
        // The list stays in the preferences folder (D4).
        #expect(app.library.url == home.appendingPathComponent("library-Test-Mac.json"))

        // A new preferences folder: the list moves, the files stay in the GIFs and memes folder.
        let sync = rig.folder.url.appendingPathComponent("sync", isDirectory: true)
        settings.usePreferencesFolder(sync)
        #expect(app.library.url == sync.appendingPathComponent("library-Test-Mac.json"))
        #expect(app.library.mediaFolder.path == media.path && exists(media.appendingPathComponent(file)))
        #expect(rig.prefs.mediaFolder == media.path && app.library.missing.isEmpty)

        // "Reset to Same Folder…" asks you to type "reset" (D19), then the files go into the preferences folder.
        settings.ask(.resetMedia)
        #expect(settings.confirming?.word == "reset")
        settings.confirm()
        #expect(rig.prefs.mediaFolder == media.path)
        settings.typedConfirmation = "Reset"
        settings.confirm()
        #expect(rig.prefs.mediaFolder.isEmpty && settings.mediaFolderIsSame)
        #expect(exists(sync.appendingPathComponent(file)) && !exists(media.appendingPathComponent(file)))
        #expect(app.library.missing.isEmpty)

        // A different file with the same name in the new folder: the move stops, the files and the pref stay.
        let other = rig.folder.url.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("gifs"), withIntermediateDirectories: true)
        try Data("not the same".utf8).write(to: other.appendingPathComponent(file))
        settings.pickMediaFolder = { $0(other) }
        settings.chooseMediaFolder()
        #expect(rig.prefs.mediaFolder.isEmpty && settings.mediaFolderIsSame)
        #expect(settings.mediaFolderProblem?.hasPrefix(SettingsModel.mediaNotMovedText) == true)
        #expect(settings.mediaFolderProblem?.contains("A different file named") == true)
        #expect(exists(sync.appendingPathComponent(file)) && app.library.mediaFolder.path == sync.path)

        // The same fault in a new preferences folder: the history and the list move, the files stay in the old
        // folder, and the GIFs and memes folder becomes that folder. No file is lost.
        settings.usePreferencesFolder(other)
        #expect(rig.prefs.preferencesFolder == other.path)
        #expect(app.library.url == other.appendingPathComponent("library-Test-Mac.json"))
        #expect(rig.prefs.mediaFolder == sync.path && !settings.mediaFolderIsSame)
        #expect(settings.mediaFolderProblem?.hasPrefix(SettingsModel.mediaNotMovedText) == true)
        #expect(exists(sync.appendingPathComponent(file)) && app.library.missing.isEmpty)
        // A good folder next clears the red line.
        settings.useSameMediaFolder()
        #expect(settings.mediaFolderProblem != nil && rig.prefs.mediaFolder == sync.path)
        try FileManager.default.removeItem(at: other.appendingPathComponent(file))
        settings.useSameMediaFolder()
        #expect(settings.mediaFolderProblem == nil && rig.prefs.mediaFolder.isEmpty)
        #expect(exists(other.appendingPathComponent(file)) && !exists(sync.appendingPathComponent(file)))
    }

    /// D14: "Save" puts the key into the key store (the Keychain in the app). A saved key is locked: only "Change…" then
    /// "Save" replaces it, and only "Remove…" with the typed word "remove" deletes it. An empty box saves nothing.
    /// The GIFs and Memes tabs use the new key at once. "Get a free key" opens the Partner Panel of KLIPY.
    @Test func theKeyRowSavesAndRemovesTheKey() throws {
        let rig = try PickRig()
        let (app, _) = try app(rig)
        let settings = app.settings
        var opened: [URL] = []
        settings.openURL = { opened.append($0) }
        #expect(!settings.hasKlipyKey && settings.klipyKeyText.isEmpty && !app.klipy.isOn)
        #expect(SettingsModel.klipyKeyNote == "Without a key, you see only your own GIFs and memes.")

        // An empty box saves nothing and says why.
        settings.klipyKeyText = " "
        settings.saveKlipyKey()
        #expect(rig.klipyKey.read() == nil && settings.klipyKeyProblem == SettingsModel.klipyKeyEmptyText)

        settings.klipyKeyText = "  abc123\n"
        settings.saveKlipyKey()
        #expect(rig.klipyKey.read() == "abc123" && settings.klipyKeyText.isEmpty)
        #expect(settings.hasKlipyKey && !settings.isChangingKlipyKey && settings.klipyKeyProblem == nil && app.klipy.isOn)

        // The next start: the key is saved, and the box never holds it.
        let again = AppController(hotKeys: FakeHotKeyRegistrar(), loginItem: FakeLoginItem(), parts: rig.parts(catalog: []))
        #expect(again.settings.klipyKeyText.isEmpty && again.settings.hasKlipyKey && again.klipy.isOn)

        // "Change…" then "Cancel": no change. "Change…" with an empty box and "Save": no change.
        settings.startChangingKlipyKey()
        #expect(settings.isChangingKlipyKey && settings.klipyKeyText.isEmpty)
        settings.klipyKeyText = "half typed"
        settings.cancelChangingKlipyKey()
        #expect(rig.klipyKey.read() == "abc123" && !settings.isChangingKlipyKey && settings.klipyKeyText.isEmpty)
        settings.startChangingKlipyKey()
        settings.saveKlipyKey()
        #expect(rig.klipyKey.read() == "abc123" && settings.isChangingKlipyKey)
        settings.klipyKeyText = "def456"
        settings.saveKlipyKey()
        #expect(rig.klipyKey.read() == "def456" && !settings.isChangingKlipyKey)

        // "Remove…" works only after you type "remove".
        settings.ask(.removeKey)
        settings.typedConfirmation = "reset"
        settings.confirm()
        #expect(rig.klipyKey.read() == "def456" && settings.confirming == .removeKey)
        settings.typedConfirmation = "Remove "
        settings.confirm()
        #expect(rig.klipyKey.read() == nil && !settings.hasKlipyKey && !app.klipy.isOn && settings.confirming == nil)

        settings.openKlipyKeyPage()
        #expect(opened == [URL(string: "https://partner.klipy.com/")!])

        // A Keychain that refuses: the red line, and no key.
        let refusing = SettingsModel(prefs: rig.prefs, hotKeys: FakeHotKeyRegistrar(), loginItem: FakeLoginItem(), access: rig.access,
                                     store: rig.store, folders: rig.folders, library: rig.library, keyStore: RefusingKeyStore())
        refusing.klipyKeyText = "abc"
        refusing.saveKlipyKey()
        #expect(refusing.klipyKeyProblem == SettingsModel.klipyKeyNotSavedText && !refusing.hasKlipyKey)
    }
}
