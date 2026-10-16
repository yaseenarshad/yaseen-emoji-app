import AppKit

/// Starts the app. The menu bar item and the panel come in later subissues.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate {
    /// `main.swift` is not on the main actor, so this entry point is nonisolated.
    public nonisolated static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let controller = AppController()
            app.delegate = controller
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}
