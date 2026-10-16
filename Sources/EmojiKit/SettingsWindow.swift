import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The rows of the settings window (D10): the hotkey, "When you pick", "Default skin tone",
/// "Start at login", the Accessibility line, "Hidden from Your most used", "Forget learned words",
/// and the preferences folder (D16).
/// Each change saves at once.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                hotKeyRow
                pickModeRow
                toneRow
                startAtLoginRow
            }
            Section("Accessibility") {
                accessibilityRow
            }
            Section("Your most used") {
                hiddenRow
            }
            Section("Learned words") {
                forgetRow
            }
            Section("Preferences folder") {
                folderRow
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The recorder: "Change…" starts it, and the same button stops it.
    /// The window controller gives the keys to the model while the row records.
    private var hotKeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Find an emoji") {
                HStack {
                    Text(model.isRecording ? "Type a hotkey" : model.hotKey.text)
                        .foregroundStyle(model.isRecording ? .secondary : .primary)
                    Button(model.isRecording ? "Cancel" : "Change…") {
                        if model.isRecording {
                            model.cancelRecording()
                        } else {
                            model.startRecording()
                        }
                    }
                }
            }
            if let problem = model.hotKeyProblem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private var pickModeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("When you pick", selection: Binding(
                get: { model.pickMode },
                set: { model.setPickMode($0) }
            )) {
                ForEach(PickMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(model.pickMode == .paste
                 ? "The emoji goes where your cursor is. Your clipboard comes back."
                 : "The emoji goes on the clipboard. You paste it.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The six tones as thumbs up, so the row shows the tone and not a name.
    private var toneRow: some View {
        Picker("Default skin tone", selection: Binding(
            get: { model.defaultTone },
            set: { model.setDefaultTone($0) }
        )) {
            ForEach(SkinTone.all, id: \.self) { tone in
                Text(SkinTone.sample(tone)).tag(tone)
            }
        }
        .pickerStyle(.segmented)
    }

    private var startAtLoginRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Start at login", isOn: Binding(
                get: { model.startAtLogin },
                set: { model.setStartAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!model.loginItemIsAvailable)

            if let note = model.loginItemNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            if let problem = model.loginItemProblem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private var accessibilityRow: some View {
        HStack {
            Image(systemName: model.accessibilityIsOn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.accessibilityIsOn ? .green : .orange)
            Text(model.accessibilityText)
            Spacer()
            Button("Open System Settings") { model.openAccessibilitySettings() }
        }
    }

    /// D15: the count of hidden emojis, and the button that brings them back. No button with none.
    private var hiddenRow: some View {
        LabeledContent("Hidden from Your most used") {
            if model.hiddenCount == 0 {
                Text("None")
            } else {
                HStack {
                    Text("\(model.hiddenCount)")
                    Button("Show them again") { model.showHidden() }
                }
            }
        }
    }

    /// D16: the folder of the history files, the folder picker, and the way back to the default folder.
    private var folderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Preferences folder") {
                Text((model.folderPath as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.folderPath)
            }
            HStack {
                Text(model.folderIsDefault
                     ? "This is the Mac default folder. Only this Mac uses it. To share your history with your other Macs, set a folder that syncs."
                     : "Each Mac saves its own file here. The app combines them, so your Macs share one history.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            HStack {
                Spacer()
                // Shown only when a different folder is set: it goes back to the private folder of this Mac (no sync).
                if !model.folderIsDefault {
                    Button("Reset to Mac Default Folder") { model.useThisMacOnly() }
                        .help("Go back to ~/Library/Application Support/Yaseen Emoji. This Mac stops sharing its history.")
                }
                Button("Set preferences folder…") { model.choosePreferencesFolder() }
            }
            if let problem = model.folderProblem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
        }
    }

    /// The first click asks in the same row. No alert: an alert takes the keyboard from the panel.
    private var forgetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isConfirmingForget {
                Text(SettingsModel.forgetQuestion)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelForget() }
                    Button("Forget", role: .destructive) { model.forgetWords() }
                }
            } else {
                HStack {
                    Text("Clears the words you taught. Your most used stays.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget learned words…") { model.askToForget() }
                }
            }
            if let note = model.forgetNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// The one settings window of the app.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: SettingsModel
    let window: NSPanel
    /// Exists only while the settings window has the keyboard.
    private(set) var keyMonitor: Any?

    init(model: SettingsModel) {
        self.model = model
        // A panel that does not activate the app. The app is an accessory app, and macOS can refuse
        // to make it the active app. A normal window then opens with no keyboard, and it goes behind
        // the windows of the active app (Screendraw, YAZ-2823). This panel takes the keyboard without the active app.
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        // It stays above the other windows until the user closes it, so it cannot get lost.
        window.isFloatingPanel = true
        window.title = "Yaseen Emoji settings"
        // The controller keeps the window, so "Settings…" shows the same window again.
        window.isReleasedWhenClosed = false
        window.delegate = self

        let host = NSHostingController(rootView: SettingsView(model: model))
        // The window follows the height of the form: a red line adds a row.
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.center()
        model.pickFolder = { [weak self] done in self?.pickFolder(done) }
    }

    /// "Set preferences folder…": a folder picker on the settings window. You can make a new folder in it.
    private func pickFolder(_ done: @escaping (URL?) -> Void) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = "Use This Folder"
        picker.message = "Pick the preferences folder. Each Mac keeps its own history file in it."
        picker.directoryURL = URL(fileURLWithPath: model.folderPath, isDirectory: true)
        // A sheet on this window: the window does not activate the app, and a sheet does not need that.
        picker.beginSheetModal(for: window) { response in
            done(response == .OK ? picker.url : nil)
        }
    }

    deinit {
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// Shows the window in front of other apps and gives it the keyboard. A second call shows the same window.
    func show() {
        model.refresh()
        // `orderFrontRegardless` does not need the active app, and a panel that does not activate
        // the app can take the keyboard without it.
        window.orderFrontRegardless()
        window.makeKey()
    }

    // MARK: The keys

    /// A monitor sees a key before the window does. Thus the recorder also gets a combination with Command,
    /// which the window would handle as a key equivalent.
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only plain values cross into the main actor: `NSEvent` is not `Sendable`.
            guard let combo = HotKeyCombo(keyDown: event) else { return event }
            let windowNumber = event.windowNumber
            let used = MainActor.assumeIsolated {
                self?.keyDown(combo, windowNumber: windowNumber) ?? false
            }
            // `nil` tells AppKit that the key is used.
            return used ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns `true` when the key is used.
    private func keyDown(_ combo: HotKeyCombo, windowNumber: Int) -> Bool {
        guard windowNumber == window.windowNumber else { return false }
        if model.keyDown(combo) { return true }
        // The app has no main menu, so nothing else gives Command-W to the window.
        if combo == HotKeyCombo(keyCode: UInt32(kVK_ANSI_W), modifiers: .command) {
            window.performClose(nil)
            return true
        }
        return false
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        // The user can come back from System Settings (Accessibility, Login Items).
        model.refresh()
        startKeyMonitor()
    }

    // A recorder must not stay open with the global hotkey off.
    func windowDidResignKey(_ notification: Notification) {
        model.cancelRecording()
        stopKeyMonitor()
    }

    func windowWillClose(_ notification: Notification) {
        model.cancelRecording()
        model.cancelForget()
        stopKeyMonitor()
    }
}
