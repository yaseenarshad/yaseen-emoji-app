import AppKit
import os

/// The parts that the app shell connects. `real()` is for the app. A test gives fakes,
/// so no test shows a window, posts a key, reads the real clipboard or the real history files.
@MainActor
struct AppParts {
    var defaults: UserDefaults
    /// The default preferences folder (D16): `~/Library/Application Support/Yaseen Emoji` in the app.
    var defaultFolder: URL
    /// The computer name, for the name of this Mac's history file. Read one time only.
    var computerName: () -> String
    /// The catalog after the draw check. It runs off the main thread.
    var loadCatalog: () async -> [Emoji]
    var clipboard: Clipboard
    var keys: KeySender
    var access: PasteAccess
    var later: Later
    /// The still pictures of the tiles (D5 of YAZ-2919): `~/Library/Caches/Yaseen Emoji/thumbs` in the app.
    var thumbnailFolder: URL
    /// "Show in Finder" of a GIF or meme (D13 of YAZ-2919).
    var showInFinder: (URL) -> Void
    /// The KLIPY key (D2 of YAZ-2919): this Mac's Keychain in the app, a fake in a test.
    var klipyKey: KeyStore
    /// The network of KLIPY, with the 5 s time-out. A stub in a test, so no test goes online.
    var onlineSession: URLSession
    /// `~/Library/Caches/Yaseen Emoji` in the app. The paste files of KLIPY items go into `paste/` (D6 of YAZ-2919),
    /// and the hash cache of the files is `files.json` (D27 of YAZ-3018).
    var cacheFolder: URL
    /// The files of the KLIPY items that you used (D18 of YAZ-2919): `~/Library/Application Support/Yaseen Emoji/klipy`
    /// in the app, on this Mac only. A temp folder in a test.
    var klipyFolder: URL
    /// Makes the search panel on the screen for the session.
    var makePanel: (PickSession) -> PickPanel
    /// The copy and check of a folder move in Settings: off the main thread in the app, at once in a test.
    var fileWork: FileWork

    static func real() -> AppParts {
        AppParts(
            defaults: .standard,
            defaultFolder: YouStore.defaultFolder,
            computerName: PreferencesFolder.computerName,
            loadCatalog: AppController.loadCatalog,
            clipboard: SystemClipboard(),
            keys: SystemKeySender(),
            access: SystemPasteAccess(),
            later: MainQueueLater(),
            thumbnailFolder: MediaImport.defaultThumbnailFolder,
            showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            klipyKey: KeychainKeyStore(),
            onlineSession: KlipyLibrary.makeSession(),
            cacheFolder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Yaseen Emoji", isDirectory: true),
            klipyFolder: YouStore.defaultFolder.appendingPathComponent("klipy", isDirectory: true),
            makePanel: { SearchPanelController(session: $0) },
            fileWork: BackgroundFileWork()
        )
    }
}

/// The app shell: it starts the app and connects the hotkey and the menu to the search panel and to Settings.
///
/// `main()` is the one call that the executable makes for the app.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate {
    /// What "Settings…" does. The default opens the settings window.
    lazy var openSettings: () -> Void = { [weak self] in self?.showSettingsWindow() }
    /// What "Add a GIF or meme…" and a drop on the panel do (D12 of YAZ-2919). The default opens the add window
    /// with one row for each file. A test gives a fake, so no test opens a window.
    lazy var openAddWindow: ([AddSource]) -> Void = { [weak self] in self?.showAddWindow(adding: $0) }

    let statusMenu = StatusMenu()
    let settings: SettingsModel
    let prefs: Prefs
    let store: YouStore
    /// The list of GIFs and memes of all Macs (D3 of YAZ-2919).
    let library: LibraryStore
    /// The rows of the add window (D12 of YAZ-2919). They stay while the window is open.
    let addModel: AddModel
    /// The preferences folder and the name of this Mac's history file (D16).
    let folders: PreferencesFolder

    /// The global hotkey (D8).
    let hotKeys: HotKeyRegistering
    /// "Start at login".
    let loginItem: LoginItem

    /// Nil until the catalog is ready.
    private(set) var session: PickSession?
    /// The load of the catalog. A test waits for it.
    private(set) var ready: Task<Void, Never>?
    /// The hotkey came before the catalog was ready. The panel opens when the catalog is ready.
    private(set) var opensWhenReady = false

    private let parts: AppParts
    private let paster: Paster
    private var panel: PickPanel?
    /// The still pictures of the tiles, for the life of the app (D11 of YAZ-2919).
    let thumbnails: Thumbnails
    /// The temp files of KLIPY pastes (D6 of YAZ-2919). They go after 5 minutes and at quit.
    let pasteFiles: PasteFiles
    /// KLIPY in the GIFs and Memes tabs (D1 of YAZ-2919).
    let klipy: KlipyResults
    /// Deletes the old paste files each minute.
    private var cleanUpTimer: Timer?
    private var settingsWindow: SettingsWindowController?
    private var addWindow: AddWindowController?
    private let log = Logger(subsystem: "com.yaseenarshad.yaseenemoji", category: "shell")

    /// The app: the real hotkey center, the real login item, and the real parts.
    convenience init(hotKeys: HotKeyRegistering, loginItem: LoginItem) {
        self.init(hotKeys: hotKeys, loginItem: loginItem, parts: .real())
    }

    init(hotKeys: HotKeyRegistering, loginItem: LoginItem, parts: AppParts) {
        self.hotKeys = hotKeys
        self.loginItem = loginItem
        self.parts = parts
        prefs = Prefs(defaults: parts.defaults)
        folders = PreferencesFolder(defaultFolder: parts.defaultFolder, macName: prefs.macName(computerName: parts.computerName))
        // A chosen folder that is missing gives the default folder. Settings shows why (D16).
        let place = folders.resolve(chosen: prefs.preferencesFolder)
        store = YouStore(url: folders.ownFile(in: place.folder))
        // The list stays in the preferences folder. The files are in the GIFs and memes folder (D4 of YAZ-2919).
        let media = MediaFolder.resolve(chosen: prefs.mediaFolder, preferencesFolder: place.folder)
        // The hash cache of D27 on YAZ-3018: `~/Library/Caches/Yaseen Emoji/files.json` in the app.
        library = LibraryStore(url: place.folder.appendingPathComponent(folders.libraryFileName), mediaFolder: media.folder,
                               cacheURL: parts.cacheFolder.appendingPathComponent("files.json"))
        addModel = AddModel(library: library)
        paster = Paster(clipboard: parts.clipboard, keys: parts.keys, access: parts.access, later: parts.later)
        thumbnails = Thumbnails(folder: parts.thumbnailFolder)
        pasteFiles = PasteFiles(cache: parts.cacheFolder, session: parts.onlineSession)
        klipy = KlipyResults(keys: parts.klipyKey, session: parts.onlineSession, pasteFiles: pasteFiles,
                             keptFiles: KlipyFiles(folder: parts.klipyFolder), stills: thumbnails.cache, later: parts.later)
        settings = SettingsModel(prefs: prefs, hotKeys: hotKeys, loginItem: loginItem, access: parts.access, store: store,
                                 folders: folders, library: library, keyStore: parts.klipyKey, fileWork: parts.fileWork)
    }

    /// Starts the app with the real hotkey center and the real login item. It does not return.
    public nonisolated static func main() {
        // `main.swift` runs on the main thread, but the compiler does not know that in Swift 5 mode.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let controller = AppController(hotKeys: HotKeyCenter(), loginItem: SystemLoginItem())
            app.delegate = controller
            // The same as `LSUIElement`: no Dock icon, also when the binary runs outside the bundle.
            app.setActivationPolicy(.accessory)
            // The delegate of the app is a weak reference.
            withExtendedLifetime(controller) { app.run() }
        }
    }

    // MARK: The life of the app

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // The binary has no bundle identifier when it runs outside the bundle. Then there is no check.
        if let identifier = Bundle.main.bundleIdentifier {
            let copies = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            let own = ProcessInfo.processInfo.processIdentifier
            if AppController.isSecondCopy(own: own, running: copies.map(\.processIdentifier)) {
                log.info("A different copy of the app runs. This copy quits.")
                NSApp.terminate(nil)
                return
            }
        }
        start()
        statusMenu.showInMenuBar()
        // D6 of YAZ-2919: a paste file goes 5 minutes after its download, also when the panel stays closed.
        cleanUpTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanUpPasteFiles() }
        }
    }

    /// At quit, all the paste files go (D6 of YAZ-2919), and the temp files of a drop from a browser or Telegram.
    public func applicationWillTerminate(_ notification: Notification) {
        pasteFiles.cleanUp(all: true)
        FileDrop.cleanUp()
    }

    /// Deletes the paste files that are older than 5 minutes, off the main thread.
    func cleanUpPasteFiles() {
        let files = pasteFiles
        Task.detached(priority: .utility) { files.cleanUp() }
    }

    /// The app lives in the menu bar. To close a window does not quit it.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// True when a different process of this app runs. Then this copy quits at once.
    static func isSecondCopy(own: pid_t, running: [pid_t]) -> Bool {
        running.contains { $0 != own }
    }

    /// Connects the hotkey, the menu, Settings and the panel, and starts the load of the catalog.
    /// It shows nothing on the screen, so a test can call it.
    func start() {
        statusMenu.onQuit = { NSApp.terminate(nil) }
        statusMenu.onFindEmoji = { [weak self] in self?.showFinder() }
        statusMenu.onOpenSettings = { [weak self] in self?.openSettings() }
        statusMenu.onAddMedia = { [weak self] in self?.addNew() }
        statusMenu.onToggleStartAtLogin = { [weak self] in
            guard let self else { return }
            settings.setStartAtLogin(!settings.startAtLogin)
            showStartAtLogin()
        }
        statusMenu.onMenuWillOpen = { [weak self] in
            self?.settings.refresh()
            self?.showStartAtLogin()
        }
        showStartAtLogin()

        statusMenu.showHotKey(settings.hotKey)
        settings.onHotKeyChanged = { [weak self] hotKey in self?.statusMenu.showHotKey(hotKey) }
        settings.onTonesChanged = { [weak self] in self?.panel?.reload() }
        // A new or removed KLIPY key: the GIFs and Memes tabs search KLIPY, or stop (D2 of YAZ-2919).
        settings.onKlipyKeyChanged = { [weak self] in self?.klipy.keyChanged() }
        // A KLIPY switch changed (D14 update of YAZ-2919): the GIFs and Memes tabs use it at once.
        settings.onKlipySwitchChanged = { [weak self] in self?.session?.klipySwitchChanged() }
        hotKeys.onHotKey = { [weak self] kind in
            // macOS calls this on the main thread.
            MainActor.assumeIsolated {
                switch kind {
                case .findEmoji: self?.toggleFinder()
                }
            }
        }
        // This Mac's file, the first time: a copy of the history that this Mac has (D16). The source stays.
        if let source = folders.seedIfMissing(store.url) {
            log.info("\(self.store.url.lastPathComponent, privacy: .public) is a copy of \(source.path, privacy: .public).")
        }
        store.load()
        if let bad = store.movedBadFile {
            log.error("\(self.store.url.lastPathComponent, privacy: .public) could not be read. It is now \(bad.lastPathComponent, privacy: .public).")
        } else if let error = store.saveError {
            // The bad file could not move away. The app keeps it and saves no change.
            log.error("The history file could not be read or moved. No change is saved: \(String(describing: error), privacy: .public)")
        }
        // D27 of YAZ-3018: the hashes of new files run off the main thread. The panel shows them when they are ready.
        library.onHashed = { [weak self] in self?.session?.filesChanged() }
        library.load()
        if let bad = library.movedBadFile {
            log.error("\(self.library.url.lastPathComponent, privacy: .public) could not be read. It is now \(bad.lastPathComponent, privacy: .public).")
        } else if let error = library.saveError {
            log.error("The list of GIFs and memes could not be read or moved. No change is saved: \(String(describing: error), privacy: .public)")
        }
        if library.mediaFolderIsMissing {
            log.error("Can't find the GIFs and memes folder \(self.library.mediaFolder.path, privacy: .public).")
        }

        // The app continues to run when macOS refuses the hotkey. The menu still opens the panel,
        // and Settings shows the red line.
        settings.registerHotKey()
        // A newer hotkey, pick mode or tone from a different Mac replaces the stored one (D16).
        settings.applySynced()
        if settings.hotKeyProblem != nil {
            log.error("macOS refused the hotkey \(self.settings.hotKey.text, privacy: .public). A different app can have it.")
        }
        askForAccessibilityAtFirstLaunch()

        ready = Task { [weak self, parts] in
            let catalog = await parts.loadCatalog()
            self?.catalogIsReady(catalog)
        }
    }

    /// The first launch asks for Accessibility one time, with the macOS prompt (D2).
    private func askForAccessibilityAtFirstLaunch() {
        guard !prefs.askedForAccessibility else { return }
        prefs.askedForAccessibility = true
        if !parts.access.isTrusted { parts.access.ask() }
    }

    private func catalogIsReady(_ catalog: [Emoji]) {
        if catalog.isEmpty { log.error("The emoji catalog is empty. emoji.json is missing or bad.") }
        let session = PickSession(catalog: catalog, store: store, library: library, prefs: prefs, paster: paster,
                                  online: klipy, thumbnails: thumbnails)
        let panel = parts.makePanel(session)
        session.panel = panel
        session.willOpen = { [weak self] in
            self?.reloadHistory()
            self?.cleanUpPasteFiles()
        }
        session.showInFinder = parts.showInFinder
        session.onAddNew = { [weak self] in self?.addNew() }
        session.onAddFiles = { [weak self] in self?.openAddWindow($0) }
        self.session = session
        self.panel = panel
        if opensWhenReady {
            opensWhenReady = false
            session.open()
        }
    }

    /// The hotkey and "Find an emoji": open the panel, or close it (D8).
    /// Before the catalog is ready, the panel opens when it is ready. A second press stops that.
    func toggleFinder() {
        guard let session else {
            opensWhenReady.toggle()
            return
        }
        session.toggle()
    }

    /// "Find an emoji" in the menu: it always opens the panel. The panel can still be open behind the menu.
    func showFinder() {
        guard let session else {
            opensWhenReady = true
            return
        }
        session.open()
    }

    /// Reads the changed history files and lists of the other Macs (D16, D3 of YAZ-2919), and applies their
    /// newer settings. The panel calls it each time it opens. With no change, it only lists the folders.
    func reloadHistory() {
        library.reload()
        guard store.reload() else { return }
        settings.applySynced()
        settings.refresh()
    }

    private func showStartAtLogin() {
        statusMenu.showStartAtLogin(settings.startAtLogin, isAvailable: settings.loginItemIsAvailable)
    }

    /// The emojis of `emoji.json` that this Mac can draw. The load (about 12 ms) and the
    /// draw check (about 20 ms) run off the main thread.
    nonisolated static func loadCatalog() async -> [Emoji] {
        await Task.detached(priority: .userInitiated) {
            do {
                return DrawCheck.drawable(try EmojiCatalog.bundled())
            } catch {
                Logger(subsystem: "com.yaseenarshad.yaseenemoji", category: "shell")
                    .error("emoji.json did not load: \(String(describing: error), privacy: .public)")
                return []
            }
        }.value
    }

    /// "Add a GIF or meme…" in the menu bar and in the right-click menu: the panel closes, and the add window opens.
    func addNew() {
        session?.close()
        openAddWindow([])
    }

    // MARK: The add window and the settings window

    /// One add window for the life of the app (D12 of YAZ-2919). It keeps its rows while it is open.
    private func showAddWindow(adding sources: [AddSource]) {
        let window = addWindow ?? AddWindowController(model: addModel)
        addWindow = window
        window.show()
        addModel.add(sources)
    }

    private func showSettingsWindow() {
        session?.close()
        reloadHistory()
        // One window for the life of the app. A second "Settings…" shows the same window.
        let window = settingsWindow ?? SettingsWindowController(model: settings)
        settingsWindow = window
        window.show()
    }
}
