import AppKit

/// The menu bar icon and its rows (D10): "Find an emoji", "Settings…", "Start at login", "Quit Yaseen Emoji".
///
/// The menu exists with no status item, so a test reads the rows and nothing shows on the screen.
/// `showInMenuBar()` makes the status item.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    /// A fixed name: the key of the position does not depend on the order in which macOS makes the items.
    static let autosaveName = "YaseenEmoji"
    /// An outline smiley (D11). As a template image, it works in a light and in a dark menu bar.
    static let symbolName = "face.smiling"

    var onFindEmoji: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onToggleStartAtLogin: () -> Void = {}
    /// Runs before the menu opens, so the check mark of "Start at login" is the real state.
    var onMenuWillOpen: () -> Void = {}
    var onQuit: () -> Void = {}

    let menu = NSMenu()

    private(set) var statusItem: NSStatusItem?
    private let findRow = NSMenuItem(title: "Find an emoji", action: #selector(findEmoji), keyEquivalent: "")
    private let loginRow = NSMenuItem(title: "Start at login", action: #selector(toggleStartAtLogin), keyEquivalent: "")

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        for row in [findRow, loginRow] { row.target = self }
        menu.addItem(findRow)
        menu.addItem(.separator())
        menu.addItem(row("Settings…", #selector(openSettings), key: ","))
        menu.addItem(loginRow)
        menu.addItem(.separator())
        menu.addItem(row("Quit Yaseen Emoji", #selector(quit), key: "q"))
        showHotKey(HotKeyKind.findEmoji.startValue)
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

    /// "Find an emoji" shows the hotkey on its right side, as a menu shows a key equivalent.
    func showHotKey(_ hotKey: HotKeyCombo) {
        findRow.keyEquivalent = hotKey.menuKeyEquivalent
        findRow.keyEquivalentModifierMask = hotKey.modifiers
    }

    /// The check mark of "Start at login". The row is off when the app does not run from its bundle.
    func showStartAtLogin(_ isOn: Bool, isAvailable: Bool) {
        loginRow.state = isOn ? .on : .off
        loginRow.isEnabled = isAvailable
    }

    func menuWillOpen(_ menu: NSMenu) { onMenuWillOpen() }

    private func row(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func findEmoji() { onFindEmoji() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func toggleStartAtLogin() { onToggleStartAtLogin() }
    @objc private func quit() { onQuit() }
}
