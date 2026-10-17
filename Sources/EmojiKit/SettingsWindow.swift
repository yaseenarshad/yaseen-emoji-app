import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The settings window (D10): the list of pages on the left and the page on the right (D19 of YAZ-2919).
/// Each page draws its rows from `SettingsPage.sections`. A long page scrolls inside the window.
/// Each change saves at once.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    /// The fixed size of the window. It does not follow the height of a page.
    static let size = CGSize(width: 680, height: 480)

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<SettingsPage?>(
                get: { model.page },
                set: { if let page = $0 { model.select(page) } }
            )) {
                ForEach(SettingsPage.allCases, id: \.self) { page in
                    Label(page.title, systemImage: page.symbol).tag(page)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 180)
            Divider()
            pageView(model.page)
        }
        .frame(width: SettingsView.size.width, height: SettingsView.size.height)
    }

    /// The title of the page, then its sections in a grouped form that scrolls.
    private func pageView(_ page: SettingsPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(page.title)
                .font(.title2.bold())
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form {
                ForEach(page.sections, id: \.self) { section in
                    Section {
                        ForEach(section.rows, id: \.self) { row($0) }
                    } header: {
                        if let title = section.title { Text(title) }
                    } footer: {
                        if section.showsEnterText {
                            Text(model.enterText).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            // A new page starts at its top.
            .id(page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One `case` for each row, with no `default`: a new row does not build until it has a view.
    @ViewBuilder
    private func row(_ row: SettingsRow) -> some View {
        switch row {
        case .hotKey: hotKeyRow
        case .defaultTone: toneRow
        case .startAtLogin: startAtLoginRow
        case .accessibility: accessibilityRow
        case .enterEmojis: enterRow(.emoji)
        case .enterGIFs: enterRow(.gif)
        case .enterMemes: enterRow(.meme)
        case .klipyKey: klipyKeyRow
        case .klipyGIFs: klipySwitch("Search KLIPY in GIFs", kind: .gif)
        case .klipyMemes: klipySwitch("Search KLIPY in Memes", kind: .meme)
        case .mediaFolder: mediaFolderRow
        case .hiddenFromMostUsed: hiddenRow
        case .forgetLearnedWords: forgetRow
        case .preferencesFolder: folderRow
        }
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

    /// D16 of YAZ-2919: Paste | Copy only, and "Keep it on the clipboard after a paste", for one kind.
    /// Copy only always keeps the item, so the switch shows off and does not work there.
    private func enterRow(_ kind: PickKind) -> some View {
        let choice = model.choice(kind)
        return VStack(alignment: .leading, spacing: 6) {
            Picker(kind.title, selection: Binding(
                get: { model.choice(kind).mode },
                set: { model.setPickMode($0, for: kind) }
            )) {
                ForEach(PickMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Keep it on the clipboard after a paste", isOn: Binding(
                get: { model.choice(kind).mode == .paste && model.choice(kind).keep },
                set: { model.setKeepsOnClipboard($0, for: kind) }
            ))
            .toggleStyle(.switch)
            .disabled(choice.mode == .copyOnly)
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

    /// D16: the folder of the history files, "Show in Finder" (D19 of YAZ-2919), the folder picker,
    /// and the way back to the default folder.
    private var folderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Preferences folder") {
                HStack {
                    Text((model.folderPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.folderPath)
                    Button("Show in Finder") { model.showPreferencesFolder() }
                        .disabled(model.folderIsMissing || model.moving != nil)
                }
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
                if !model.folderIsDefault && model.confirming != .reset {
                    Button("Reset to Mac Default Folder…") { model.ask(.reset) }
                        .help("Go back to ~/Library/Application Support/Yaseen Emoji. This Mac stops sharing its history.")
                }
                Button("Set preferences folder…") { model.choosePreferencesFolder() }
            }
            .disabled(model.moving != nil)
            if model.confirming == .reset {
                confirmBox(SettingsModel.resetQuestion, button: "Reset")
            }
            if model.moving == .preferences { movingLine }
            if let problem = model.folderProblem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
        }
    }

    /// D14 of YAZ-2919: the folder of `gifs/` and `memes/`, "Show in Finder" (D19), the folder picker,
    /// and the way back to the preferences folder.
    private var mediaFolderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("GIFs and memes folder") {
                HStack {
                    Text((model.mediaFolderPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.mediaFolderPath)
                    Button("Show in Finder") { model.showMediaFolder() }
                        .disabled(model.mediaFolderIsMissing || model.moving != nil)
                }
            }
            Text(model.mediaFolderIsSame ? SettingsModel.mediaSameText : SettingsModel.mediaDifferentText)
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                // Shown only when a different folder is set.
                if !model.mediaFolderIsSame && model.confirming != .resetMedia {
                    Button("Reset to Same Folder…") { model.ask(.resetMedia) }
                        .help("Move your GIFs and memes back into the preferences folder.")
                }
                Button("Set GIFs and memes folder…") { model.chooseMediaFolder() }
            }
            .disabled(model.moving != nil)
            if model.confirming == .resetMedia {
                confirmBox(SettingsModel.mediaResetQuestion, button: "Reset")
            }
            if model.moving == .media { movingLine }
            if let problem = model.mediaFolderProblem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Item 16 of YAZ-2929: the line of a folder row while its files move off the main thread.
    private var movingLine: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(SettingsModel.movingText).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// D2 and D14 of YAZ-2919: the KLIPY key. A saved key is locked: "Change…" opens an empty box with
    /// "Save" and "Cancel", and "Remove…" asks you to type "remove". Nothing saves on a click outside.
    private var klipyKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("KLIPY key") {
                if model.hasKlipyKey && !model.isChangingKlipyKey {
                    HStack {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if model.confirming != .removeKey {
                            Button("Change…") { model.startChangingKlipyKey() }
                            Button("Remove…") { model.ask(.removeKey) }
                        }
                    }
                } else {
                    HStack {
                        // An empty title: in a Form, the title of a field shows as a second label.
                        SecureField("", text: $model.klipyKeyText, prompt: Text("Paste your KLIPY key"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.saveKlipyKey() }
                            .frame(maxWidth: 180)
                        Button("Save") { model.saveKlipyKey() }
                        if model.isChangingKlipyKey {
                            Button("Cancel") { model.cancelChangingKlipyKey() }
                        } else {
                            Button("Get a free key") { model.openKlipyKeyPage() }
                                .help(SettingsModel.klipyKeyURL.absoluteString)
                        }
                    }
                }
            }
            if model.confirming == .removeKey {
                confirmBox(SettingsModel.klipyKeyRemoveQuestion, button: "Remove")
            }
            Text(model.hasKlipyKey ? SettingsModel.klipyKeySavedNote : SettingsModel.klipyKeyNote)
                .font(.callout).foregroundStyle(.secondary)
            if let problem = model.klipyKeyProblem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
        }
    }

    /// D14 update of YAZ-2919: a tab with its switch off shows only your own GIFs or memes.
    /// The switches show with no key too. Then the tab with its switch on tells you to add a key.
    private func klipySwitch(_ title: String, kind: ItemKind) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.searchesKlipy(kind) },
            set: { model.setSearchesKlipy($0, for: kind) }
        ))
        .toggleStyle(.switch)
    }

    /// The first click asks in the same row. No alert: an alert takes the keyboard from the panel.
    private var forgetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isConfirmingForget {
                confirmBox(SettingsModel.forgetQuestion, button: "Forget")
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

    /// D19: a red box. The red button works only after you type the word, for example "forget".
    private func confirmBox(_ question: String, button: String) -> some View {
        let word = model.confirming?.word ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            Text(question).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Type \(word) to confirm", text: $model.typedConfirmation)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.confirm() }
                Button("Cancel") { model.cancelConfirm() }
                Button(button, role: .destructive) { model.confirm() }
                    .disabled(!model.canConfirm)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.red, lineWidth: 1.5))
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
            contentRect: NSRect(origin: .zero, size: SettingsView.size),
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
        // The window takes the fixed size of the view (D19 of YAZ-2919). A long page scrolls inside it.
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.center()
        model.pickFolder = { [weak self] done in
            guard let self else { return done(nil) }
            pickFolder(message: "Pick the preferences folder. Each Mac keeps its own history file in it.",
                       start: model.folderPath, done)
        }
        model.pickMediaFolder = { [weak self] done in
            guard let self else { return done(nil) }
            pickFolder(message: "Pick the GIFs and memes folder. The app moves gifs/ and memes/ into it.",
                       start: model.mediaFolderPath, done)
        }
    }

    /// "Set preferences folder…" and "Set GIFs and memes folder…": a folder picker on the settings window.
    /// You can make a new folder in it.
    private func pickFolder(message: String, start: String, _ done: @escaping (URL?) -> Void) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = "Use This Folder"
        picker.message = message
        picker.directoryURL = URL(fileURLWithPath: start, isDirectory: true)
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
        // The app has no main menu, so nothing else gives Command-W and the edit keys to the window.
        // ⌘V pastes the KLIPY key into its box (D14 of YAZ-2919).
        if combo.keyCode == UInt32(kVK_ANSI_W), combo.modifiers == .command {
            window.performClose(nil)
            return true
        }
        return EditKeys.send(combo, in: window) ?? false
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
        // A key that you typed and did not save is dropped. Only "Save" writes the key.
        model.cancelChangingKlipyKey()
        model.cancelRecording()
        model.cancelConfirm()
        stopKeyMonitor()
    }
}
