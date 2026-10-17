import AppKit
import ApplicationServices
import Carbon.HIToolbox
import UniformTypeIdentifiers

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

    /// The clipboard item of a GIF or meme (D6 of YAZ-2919): the file URL, then the file's own bytes in its own type
    /// (`com.compuserve.gif`, `public.png` or `public.jpeg`), then the transient mark for a paste. No TIFF, and no
    /// extra PNG for a GIF: Slack and Chrome then paste a still picture. Nil when the file cannot be read.
    @MainActor
    static func fileItem(_ url: URL, type: UTType, transient: Bool) -> Item? {
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        var values: [(type: String, data: Data)] = [
            (NSPasteboard.PasteboardType.fileURL.rawValue, Data(url.absoluteString.utf8)),
            (type.identifier, bytes),
        ]
        if transient { values.append((SystemClipboard.transientType.rawValue, Data())) }
        return Item(values: values)
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
    /// `transient`: the text stays only for a paste, so clipboard history apps must not keep it.
    func write(_ text: String, transient: Bool) -> Int
    /// Puts one file on the clipboard: the item of `ClipboardContents.fileItem` (D6 of YAZ-2919).
    /// Returns the new `changeCount`, or nil when the file cannot be read. Then the clipboard does not change.
    func write(file: URL, type: UTType, transient: Bool) -> Int?
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

/// Puts a picked emoji, GIF or meme where it must go (D2; D6 of YAZ-2919): on the clipboard, then ⌘V into
/// the app in front, then the old clipboard back.
@MainActor
final class Paster {
    /// What a pick puts on the clipboard.
    enum Clip: Equatable {
        case text(String)
        /// A GIF or meme file, with the type of its bytes.
        case file(URL, type: UTType)

        /// The file with the type of its extension: `com.compuserve.gif`, `public.png` or `public.jpeg`.
        static func file(at url: URL) -> Clip? {
            UTType(filenameExtension: url.pathExtension).map { .file(url, type: $0) }
        }
    }

    /// ⌘V: key code 9 with Command. The event has only this flag, so a Shift that the user
    /// still holds does not make it ⌘⇧V.
    static let pasteKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: .command)
    /// From the write to the ⌘V. The panel is hidden by then, so the ⌘V goes to the app in front.
    static let postDelay: TimeInterval = 0.05
    /// From the ⌘V to the restore of the old clipboard (D2).
    static let restoreDelay: TimeInterval = 0.3
    /// The same for a file (D6 of YAZ-2919): an app can read a file later than a text.
    static let fileRestoreDelay: TimeInterval = 1.0
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

    /// Puts `text` on the clipboard, as `deliver(_ clip:)`.
    func deliver(_ text: String, paste: Bool, afterPaste: @escaping @MainActor () -> Void = {}) {
        deliver(.text(text), paste: paste, afterPaste: afterPaste)
    }

    /// Puts `clip` on the clipboard. With `paste`, it also posts ⌘V and later puts the old clipboard back,
    /// but only if the clipboard is still the app's own. Then a new copy of the user in the wait stays.
    /// A file waits 1.0 s for the restore, a text 0.3 s. A file that cannot be read changes nothing.
    /// `afterPaste` runs when the panel can take the keyboard again. With no paste, it runs at once.
    func deliver(_ clip: Clip, paste: Bool, afterPaste: @escaping @MainActor () -> Void = {}) {
        // A second pick in the wait: the clipboard of the user is the one that the first pick saved.
        let saved: ClipboardContents
        if let pending, clipboard.changeCount == pending.own {
            saved = pending.saved
        } else {
            saved = clipboard.read()
        }
        let written: Int?
        let wait: TimeInterval
        switch clip {
        case .text(let text):
            written = clipboard.write(text, transient: paste)
            wait = Paster.restoreDelay
        case .file(let url, let type):
            written = clipboard.write(file: url, type: type, transient: paste)
            wait = Paster.fileRestoreDelay
        }
        guard let own = written else {
            afterPaste()
            return
        }
        guard paste else {
            // Copy only: the item stays, and a restore that waits does nothing.
            pending = nil
            afterPaste()
            return
        }
        pending = (saved, own)
        later.run(after: Paster.postDelay) { [self] in
            keys.post(Paster.pasteKey)
            later.run(after: Paster.comeBackDelay, afterPaste)
            later.run(after: wait) { [self] in
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
    /// The mark of nspasteboard.org for an item that is on the clipboard for a short time only.
    /// Clipboard history apps (Alfred, Raycast, Maccy) do not keep an item with this type.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    func read() -> ClipboardContents {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            // A type with no data (a promise that the app does not keep) cannot come back.
            ClipboardContents.Item(values: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
        }
        return ClipboardContents(items: items)
    }

    func write(_ text: String, transient: Bool) -> Int {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient { item.setData(Data(), forType: SystemClipboard.transientType) }
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    func write(file: URL, type: UTType, transient: Bool) -> Int? {
        guard let item = ClipboardContents.fileItem(file, type: type, transient: transient) else { return nil }
        restore(ClipboardContents(items: [item]))
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
