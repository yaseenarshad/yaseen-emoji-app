import AppKit
import Carbon.HIToolbox
import Testing
@testable import EmojiKit

/// The pages of Settings and "Show in Finder" (D19 of YAZ-2919). The model only: no window, and no Finder.
@MainActor
@Suite struct SettingsPagesTests {
    private func makeModel(_ rig: PickRig, prefs: Prefs? = nil, hotKeys: FakeHotKeyRegistrar = FakeHotKeyRegistrar()) -> SettingsModel {
        let model = SettingsModel(prefs: prefs ?? rig.prefs, hotKeys: hotKeys, loginItem: FakeLoginItem(), access: rig.access,
                                  store: rig.store, folders: rig.folders, library: rig.library, keyStore: rig.klipyKey, fileWork: rig.fileWork)
        model.registerHotKey()
        return model
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The five pages in the D19 order, and the rows of each page. Each row is on exactly one page,
    /// so a row that a later change adds can't get lost.
    @Test func eachPageListsItsRows() {
        #expect(SettingsPage.allCases.map(\.title) == ["General", "Enter and paste", "GIFs and memes", "Your history", "Sync folder"])
        #expect(SettingsPage.general.rows == [.hotKey, .defaultTone, .startAtLogin, .accessibility])
        #expect(SettingsPage.enterAndPaste.rows == [.enterEmojis, .enterGIFs, .enterMemes])
        #expect(SettingsPage.gifsAndMemes.rows == [.klipyKey, .klipyGIFs, .klipyMemes, .mediaFolder])
        #expect(SettingsPage.history.rows == [.hiddenFromMostUsed, .forgetLearnedWords])
        #expect(SettingsPage.syncFolder.rows == [.preferencesFolder])

        let placed = SettingsPage.allCases.flatMap(\.rows)
        #expect(placed.count == SettingsRow.allCases.count)
        #expect(Set(placed) == Set(SettingsRow.allCases))

        // The grey line of "When you press Enter" shows below its three rows only.
        let withText = SettingsPage.allCases.flatMap(\.sections).filter(\.showsEnterText)
        #expect(withText == [SettingsSection(title: "When you press Enter", rows: [.enterEmojis, .enterGIFs, .enterMemes],
                                             showsEnterText: true)])
        // Each page has an SF Symbol that this macOS has.
        #expect(SettingsPage.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil })
    }

    /// The window opens on General the first time. A page that you pick is the page of the next open,
    /// also after a new start. It stays on this Mac: the history file does not get it. A bad value gives General.
    @Test func theLastPageIsKeptOnThisMac() throws {
        let rig = try PickRig()
        let model = makeModel(rig)
        #expect(model.page == .general)

        model.select(.syncFolder)
        #expect(model.page == .syncFolder)
        #expect(makeModel(rig, prefs: Prefs(defaults: rig.defaults)).page == .syncFolder)
        model.select(.gifsAndMemes)
        #expect(makeModel(rig).page == .gifsAndMemes)
        #expect(rig.defaults.object(forKey: "yaseenEmoji.settingsPage") as? String == "gifsAndMemes")
        let history = (try? String(contentsOf: rig.store.url, encoding: .utf8)) ?? ""
        #expect(!history.contains("settingsPage") && !history.contains("gifsAndMemes"))

        rig.defaults.set("advanced", forKey: "yaseenEmoji.settingsPage")
        #expect(makeModel(rig).page == .general)
    }

    /// A page change stops the hotkey recorder (the hotkey works again), the type-to-confirm box,
    /// and "Change…" of the KLIPY key. The saved key stays.
    @Test func aPageChangeStopsTheRecorderAndTheBoxes() throws {
        let rig = try PickRig()
        try rig.klipyKey.write("abc123")
        let hotKeys = FakeHotKeyRegistrar()
        let model = makeModel(rig, hotKeys: hotKeys)
        let commandE = HotKeyCombo(keyCode: UInt32(kVK_ANSI_E), modifiers: .command)

        model.startRecording()
        #expect(hotKeys.registered.isEmpty)
        model.select(.history)
        #expect(!model.isRecording && hotKeys.registered == [.findEmoji: commandE])

        model.askToForget()
        model.typedConfirmation = "forg"
        model.select(.syncFolder)
        #expect(model.confirming == nil && model.typedConfirmation.isEmpty)

        model.select(.gifsAndMemes)
        model.startChangingKlipyKey()
        model.klipyKeyText = "half typed"
        model.select(.general)
        #expect(!model.isChangingKlipyKey && model.klipyKeyText.isEmpty)
        #expect(rig.klipyKey.read() == "abc123" && model.hasKlipyKey)

        // A click on the page that shows changes nothing.
        model.startRecording()
        model.select(.general)
        #expect(model.isRecording)
        model.cancelRecording()
    }

    /// "Show in Finder" opens the folder that the app uses now: the preferences folder, and the GIFs and memes
    /// folder (the same folder by default, or the folder that you set). A missing folder is made first.
    /// A file in the place of the folder gives the red line.
    @Test func showInFinderOpensBothFoldersAndMakesAMissingOne() throws {
        let rig = try PickRig()
        let model = makeModel(rig)
        var opened: [URL] = []
        model.openInFinder = { opened.append($0) }
        let home = rig.folder.defaultFolder
        let fileManager = FileManager.default

        // The first start: the default folder is not there yet. Each row makes it.
        if exists(home) { try fileManager.removeItem(at: home) }
        model.showMediaFolder()
        #expect(opened == [home] && exists(home) && model.mediaFolderProblem == nil)
        try fileManager.removeItem(at: home)
        model.showPreferencesFolder()
        #expect(opened == [home, home] && exists(home) && model.folderProblem == nil)

        // A file in the place of the folder: the red line, and nothing opens. With the file gone, it works again.
        try fileManager.removeItem(at: home)
        try Data("a file".utf8).write(to: home)
        model.showPreferencesFolder()
        #expect(opened.count == 2 && model.folderProblem == SettingsModel.folderNotMadeText)
        try fileManager.removeItem(at: home)
        model.showPreferencesFolder()
        #expect(opened == [home, home, home] && model.folderProblem == nil)

        // The GIFs and memes folder that you set.
        let media = rig.folder.url.appendingPathComponent("media", isDirectory: true)
        try fileManager.createDirectory(at: media, withIntermediateDirectories: true)
        model.useMediaFolder(media)
        #expect(!model.mediaFolderIsSame && !model.mediaFolderIsMissing)
        model.showMediaFolder()
        #expect(opened.last == media)

        // The preferences folder that you set.
        let sync = rig.folder.url.appendingPathComponent("yaseen-os/Sync/yaseen-emoji", isDirectory: true)
        model.usePreferencesFolder(sync)
        model.showPreferencesFolder()
        model.showMediaFolder()
        #expect(opened.suffix(2) == [sync, media] && opened.count == 6)
    }

    /// A folder that you chose and that is missing at the start (an unmounted drive): the row shows the red line,
    /// the button does nothing, and the app makes no empty folder in its place (D4).
    @Test func showInFinderDoesNotMakeAChosenFolderThatIsMissing() async throws {
        let rig = try PickRig()
        let gone = rig.folder.url.appendingPathComponent("Volumes/Drive/yaseen-emoji", isDirectory: true)
        let goneMedia = rig.folder.url.appendingPathComponent("Volumes/Drive/media", isDirectory: true)
        rig.prefs.preferencesFolder = gone.path
        rig.prefs.mediaFolder = goneMedia.path
        let app = AppController(hotKeys: FakeHotKeyRegistrar(), loginItem: FakeLoginItem(), parts: rig.parts(catalog: []))
        app.start()
        await app.ready?.value
        let settings = app.settings
        // The window reads the states again at each show.
        settings.refresh()
        var opened: [URL] = []
        settings.openInFinder = { opened.append($0) }

        #expect(settings.folderIsMissing && settings.folderProblem == PreferencesFolder.missingText)
        #expect(settings.mediaFolderIsMissing && settings.mediaFolderProblem == MediaFolder.missingText)
        settings.showPreferencesFolder()
        settings.showMediaFolder()
        #expect(opened.isEmpty)
        #expect(!exists(gone) && !exists(goneMedia))
        #expect(settings.folderProblem == PreferencesFolder.missingText && settings.mediaFolderProblem == MediaFolder.missingText)
    }
}
