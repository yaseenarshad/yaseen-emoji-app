import AppKit
import os

/// The parts that the app shell connects. `real()` is for the app. A test gives fakes,
/// so no test shows a window, posts a key, reads the real clipboard or the real `you.json`.
@MainActor
struct AppParts {
    var defaults: UserDefaults
    var youURL: URL
    /// The catalog after the draw check. It runs off the main thread.
    var loadCatalog: () async -> [Emoji]
    var clipboard: Clipboard
    var keys: KeySender
    var access: PasteAccess
    var later: Later
    /// Makes the search panel on the screen for the session.
    var makePanel: (PickSession) -> PickPanel

    static func real() -> AppParts {
        AppParts(
            defaults: .standard,
            youURL: YouStore.defaultURL,
            loadCatalog: AppController.loadCatalog,
            clipboard: SystemClipboard(),
            keys: SystemKeySender(),
            access: SystemPasteAccess(),
            later: MainQueueLater(),
            makePanel: { SearchPanelController(session: $0) }
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

    let statusMenu = StatusMenu()
    let settings: SettingsModel
    let prefs: Prefs
    let store: YouStore

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
    private var settingsWindow: SettingsWindowController?
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
        store = YouStore(url: parts.youURL)
        paster = Paster(clipboard: parts.clipboard, keys: parts.keys, access: parts.access, later: parts.later)
        settings = SettingsModel(prefs: prefs, hotKeys: hotKeys, loginItem: loginItem, access: parts.access, store: store)
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
        hotKeys.onHotKey = { [weak self] kind in
            // macOS calls this on the main thread.
            MainActor.assumeIsolated {
                switch kind {
                case .findEmoji: self?.toggleFinder()
                }
            }
        }
        // The app continues to run when macOS refuses the hotkey. The menu still opens the panel,
        // and Settings shows the red line.
        settings.registerHotKey()
        if settings.hotKeyProblem != nil {
            log.error("macOS refused the hotkey \(self.settings.hotKey.text, privacy: .public). A different app can have it.")
        }

        store.load()
        if let bad = store.movedBadFile {
            log.error("you.json could not be read. It is now \(bad.lastPathComponent, privacy: .public).")
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
        let session = PickSession(catalog: catalog, store: store, prefs: prefs, paster: paster)
        let panel = parts.makePanel(session)
        session.panel = panel
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

    // MARK: The settings window

    private func showSettingsWindow() {
        session?.close()
        // One window for the life of the app. A second "Settings…" shows the same window.
        let window = settingsWindow ?? SettingsWindowController(model: settings)
        settingsWindow = window
        window.show()
    }
}
