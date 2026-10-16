import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Everything that was on the clipboard: each item with each of its types, in order.
struct ClipboardContents: Equatable {
    /// One item: its types and their data, in the order of the item.
    struct Item: Equatable {
        var values: [(type: String, data: Data)]

        static func == (a: Item, b: Item) -> Bool {
            a.values.map(\.type) == b.values.map(\.type) && a.values.map(\.data) == b.values.map(\.data)
        }
    }

    var items: [Item]

    /// One text item, as the app writes an emoji.
    static func text(_ text: String) -> ClipboardContents {
        ClipboardContents(items: [Item(values: [(NSPasteboard.PasteboardType.string.rawValue, Data(text.utf8))])])
    }
}

/// The clipboard (D2). A test uses a fake one, so it never changes the real clipboard.
@MainActor
protocol Clipboard: AnyObject {
    /// macOS adds one to it at each change of the clipboard, by any app.
    var changeCount: Int { get }
    /// Each item with each of its types.
    func read() -> ClipboardContents
    /// Puts one text on the clipboard. Returns the new `changeCount`: the app's own.
    func write(_ text: String) -> Int
    /// Puts saved contents back.
    func restore(_ contents: ClipboardContents)
}

/// Posts a key press to the system. A test uses a fake one: no test posts a key event.
@MainActor
protocol KeySender: AnyObject {
    func post(_ combo: HotKeyCombo)
}

/// What the app may do with the keyboard of other apps.
@MainActor
protocol PasteAccess: AnyObject {
    /// True when the app has the Accessibility permission. Without it, macOS drops a posted ⌘V.
    var isTrusted: Bool { get }
    /// True when a password field has the keyboard. macOS can then block a posted ⌘V.
    var secureInputIsOn: Bool { get }
    /// Shows the macOS prompt for Accessibility.
    func ask()
}

/// Runs work later on the main thread. A test runs the work when it wants, with no wait.
@MainActor
protocol Later: AnyObject {
    func run(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void)
}

/// Puts a picked emoji where it must go (D2): on the clipboard, then ⌘V into the app in front,
/// then the old clipboard back.
@MainActor
final class Paster {
    /// ⌘V: key code 9 with Command. The event has only this flag, so a Shift that the user
    /// still holds does not make it ⌘⇧V.
    static let pasteKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: .command)
    /// From the write to the ⌘V. The panel is hidden by then, so the ⌘V goes to the app in front.
    static let postDelay: TimeInterval = 0.05
    /// From the ⌘V to the restore of the old clipboard (D2).
    static let restoreDelay: TimeInterval = 0.3
    /// From the ⌘V to `afterPaste`. The app in front must get the ⌘V before the panel takes the keyboard again.
    static let comeBackDelay: TimeInterval = 0.15

    private let clipboard: Clipboard
    private let keys: KeySender
    private let access: PasteAccess
    private let later: Later

    /// The clipboard of the user, saved before the last paste, and the `changeCount` of the emoji.
    /// Nil when no restore waits.
    private var pending: (saved: ClipboardContents, own: Int)?

    init(clipboard: Clipboard, keys: KeySender, access: PasteAccess, later: Later) {
        self.clipboard = clipboard
        self.keys = keys
        self.access = access
        self.later = later
    }

    /// True when a pick in this mode posts ⌘V. Copy only, no Accessibility, or secure input: copy only (D2).
    func willPaste(_ mode: PickMode) -> Bool {
        mode == .paste && access.isTrusted && !access.secureInputIsOn
    }

    /// Puts `text` on the clipboard. With `paste`, it also posts ⌘V and later puts the old clipboard back,
    /// but only if the clipboard is still the app's own. Then a new copy of the user in the wait stays.
    /// `afterPaste` runs when the panel can take the keyboard again. With no paste, it runs at once.
    func deliver(_ text: String, paste: Bool, afterPaste: @escaping @MainActor () -> Void = {}) {
        // A second pick in the wait: the clipboard of the user is the one that the first pick saved.
        let saved: ClipboardContents
        if let pending, clipboard.changeCount == pending.own {
            saved = pending.saved
        } else {
            saved = clipboard.read()
        }
        let own = clipboard.write(text)
        guard paste else {
            // Copy only: the emoji stays, and a restore that waits does nothing.
            pending = nil
            afterPaste()
            return
        }
        pending = (saved, own)
        later.run(after: Paster.postDelay) { [self] in
            keys.post(Paster.pasteKey)
            later.run(after: Paster.comeBackDelay, afterPaste)
            later.run(after: Paster.restoreDelay) { [self] in
                // A later pick owns the restore now.
                guard let pending, pending.own == own else { return }
                self.pending = nil
                if clipboard.changeCount == own { clipboard.restore(pending.saved) }
            }
        }
    }
}

// MARK: The real parts

/// The real clipboard: `NSPasteboard.general`.
@MainActor
final class SystemClipboard: Clipboard {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    func read() -> ClipboardContents {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            // A type with no data (a promise that the app does not keep) cannot come back.
            ClipboardContents.Item(values: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
        }
        return ClipboardContents(items: items)
    }

    func write(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    func restore(_ contents: ClipboardContents) {
        pasteboard.clearContents()
        let items = contents.items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for value in saved.values { item.setData(value.data, forType: NSPasteboard.PasteboardType(value.type)) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

/// Posts real key events with `CGEvent`. Only the app uses it, never a test.
@MainActor
final class SystemKeySender: KeySender {
    func post(_ combo: HotKeyCombo) {
        let source = CGEventSource(stateID: .combinedSessionState)
        var flags: CGEventFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(combo.keyCode), keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cgSessionEventTap)
        }
    }
}

/// The real Accessibility check and the secure input check.
@MainActor
final class SystemPasteAccess: PasteAccess {
    var isTrusted: Bool { AXIsProcessTrusted() }

    var secureInputIsOn: Bool { IsSecureEventInputEnabled() }

    func ask() {
        // The text of `kAXTrustedCheckOptionPrompt`. The constant is a global `var`, which Swift 6 refuses.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// `DispatchQueue.main.asyncAfter`.
@MainActor
final class MainQueueLater: Later {
    func run(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { work() }
        }
    }
}
