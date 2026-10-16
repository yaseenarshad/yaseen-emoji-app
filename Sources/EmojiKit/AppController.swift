import AppKit
import os

/// The app shell: it starts the app and puts the menu bar icon on the screen.
///
/// The panel and the settings window come in later subissues. They connect to `start()`.
/// `main()` is the one call that the executable makes for the app.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate {
    let statusMenu = StatusMenu()

    /// The global hotkey. The skeleton registers no hotkey: the panel does not exist yet.
    let hotKeys: HotKeyRegistering
    /// "Start at login". The skeleton does not change it.
    let loginItem: LoginItem

    private let log = Logger(subsystem: "com.yaseenarshad.yaseenemoji", category: "shell")

    init(hotKeys: HotKeyRegistering, loginItem: LoginItem) {
        self.hotKeys = hotKeys
        self.loginItem = loginItem
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

    /// Connects the menu. It shows nothing on the screen, so a test can call it.
    func start() {
        statusMenu.onQuit = { NSApp.terminate(nil) }
    }
}
