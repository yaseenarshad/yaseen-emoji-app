import AppKit

/// The menu bar icon and its rows (D10).
///
/// The menu exists with no status item, so a test reads the rows and nothing shows on the screen.
/// `showInMenuBar()` makes the status item.
@MainActor
final class StatusMenu: NSObject {
    /// A fixed name: the key of the position does not depend on the order in which macOS makes the items.
    static let autosaveName = "YaseenEmoji"
    /// An outline smiley (D11). As a template image, it works in a light and in a dark menu bar.
    static let symbolName = "face.smiling"

    var onQuit: () -> Void = {}

    let menu = NSMenu()

    private(set) var statusItem: NSStatusItem?

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.addItem(row("Quit Yaseen Emoji", #selector(quit), key: "q"))
    }

    /// Puts the icon in the menu bar.
    func showInMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = StatusMenu.autosaveName
        item.menu = menu
        item.button?.image = StatusMenu.icon()
        statusItem = item
    }

    /// The menu bar icon. A template image: macOS colours it for a light and for a dark menu bar.
    static func icon() -> NSImage? {
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Yaseen Emoji")
        icon?.isTemplate = true
        return icon
    }

    private func row(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func quit() { onQuit() }
}
