import AppKit
import os

/// How a pick that stays open gives the keyboard to the app in front for its ⌘V (D21 of YAZ-2919).
/// The hidden pref `yaseenEmoji.pasteStrategy` selects it. Settings has no row for it.
enum PasteStrategy: String, CaseIterable {
    /// The panel stays on the screen. It refuses the keyboard and activates the app in front again, so the window of
    /// that app takes the keyboard. If the panel still has it right before the ⌘V, this pick uses `hide` (the fallback).
    case handBack
    /// The v0.2.0 way: the panel hides for the ⌘V and shows again. This is the flash.
    case hide
    /// The panel stays and keeps the keyboard. The ⌘V goes to the process of the app in front (`CGEvent.postToPid`).
    case pid

    /// The value of the pref. A missing or unknown value gives `handBack`.
    init(pref: String?) {
        self = pref.flatMap(PasteStrategy.init(rawValue:)) ?? .handBack
    }
}

/// Where the ⌘V of a paste goes (D21 of YAZ-2919).
enum PasteTarget: Equatable {
    /// The window with the keyboard (the session event tap), at once.
    case keyWindow
    /// The panel hid just now. The ⌘V waits `Paster.postDelay` more, then goes to the window with the keyboard.
    case keyWindowAfterHide
    /// The process of the app in front (`CGEvent.postToPid`).
    case process(pid_t)
}

/// The check that runs right before the ⌘V. It tells where the ⌘V goes.
typealias PasteHandOff = @MainActor () -> PasteTarget

/// What `PanelPaste` needs from the panel window. A test uses a fake one, so no test makes a window.
@MainActor
protocol PasteWindow: AnyObject {
    /// `isKeyWindow`: the panel gets the keys.
    var hasKeyboard: Bool { get }
    /// The panel is on the screen.
    var isShown: Bool { get }
    /// While true, the panel refuses the keyboard (`canBecomeKey` is false).
    var refusesKeyboard: Bool { get set }
    /// Hides the panel for the ⌘V (`orderOut`). The session stays open.
    func hideForPaste()
    /// Shows the panel and gives it the keyboard. `selectAll`: all the search text is selected (D20 of YAZ-2919).
    func showWithKeyboard(selectAll: Bool)
}

/// The app that was in front when the panel opened. A test uses a fake one.
@MainActor
protocol FrontApp: AnyObject {
    var processID: pid_t { get }
    /// Asks macOS to make the app active again. Then its own window takes the keyboard.
    func activate()
}

/// The real app in front.
@MainActor
final class RunningFrontApp: FrontApp {
    private let app: NSRunningApplication

    /// Nil for no app, or for this app.
    init?(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        self.app = app
    }

    var processID: pid_t { app.processIdentifier }

    /// No `.activateIgnoringOtherApps`: macOS 14 ignores it. macOS 14 can refuse the call (cooperative activation).
    /// Then the check before the ⌘V uses the fallback.
    func activate() {
        _ = app.activate(options: [])
    }
}

/// The part of the search panel in a paste that keeps it open (D21 of YAZ-2919). It gives the keyboard to the app in
/// front for the ⌘V by the strategy, and takes it back after. A test gives a fake window and a fake app.
@MainActor
final class PanelPaste {
    /// From the come back to the check that the panel really has the keyboard again.
    static let keyboardCheckDelay: TimeInterval = 0.15

    /// The app in front when the panel opened. Nil: no other app. Then `handBack` and `pid` use `hide`.
    var frontApp: FrontApp?
    /// True from `makeWay()` to the end of `comeBack(selectQuery:)`. The panel loses the keyboard then, but the session
    /// stays open, so the panel must not close on `windowDidResignKey`.
    private(set) var isMakingWay = false
    /// True while the panel is hidden for the ⌘V (`hide`, or the fallback of `handBack`).
    private(set) var isHidden = false

    private unowned let window: PasteWindow
    private let later: Later
    private let strategy: () -> PasteStrategy
    /// Changes at each pick, each show and each hide, so an old check does nothing.
    private var count = 0
    /// The fallback and the second try go to the log, so a guided test can see them:
    /// `log stream --predicate 'subsystem == "com.yaseenarshad.yaseenemoji"'`.
    private let log = Logger(subsystem: "com.yaseenarshad.yaseenemoji", category: "paste")

    /// `strategy` is read at each pick, so a `defaults write` works with no new build.
    init(window: PasteWindow, later: Later, strategy: @escaping () -> PasteStrategy) {
        self.window = window
        self.later = later
        self.strategy = strategy
    }

    /// The panel shows or hides: a paste that waits does nothing more, and the panel accepts the keyboard.
    func reset() {
        count += 1
        isMakingWay = false
        isHidden = false
        window.refusesKeyboard = false
    }

    /// Gives the keyboard to the app in front. Returns the check that runs right before the ⌘V.
    func makeWay() -> PasteHandOff {
        count += 1
        isMakingWay = true
        switch strategy() {
        case .handBack:
            guard let frontApp else { return hideNow() }
            window.refusesKeyboard = true
            frontApp.activate()
            return { [self] in
                guard window.hasKeyboard else { return .keyWindow }
                // The D21 fallback: the panel still has the keyboard. The old way, for this pick only.
                log.notice("handBack: the panel kept the keyboard. This pick hides the panel (the fallback).")
                hide()
                return .keyWindowAfterHide
            }
        case .hide:
            return hideNow()
        case .pid:
            guard let pid = frontApp?.processID else { return hideNow() }
            return { .process(pid) }
        }
    }

    /// Takes the keyboard back after the ⌘V, and shows the panel again if it hid. The search text is selected
    /// (D20 of YAZ-2919). If the panel still has no keyboard a moment later, it hides and shows one time to take it.
    /// So the panel never stays open with no keyboard, with the keys going to the app behind.
    func comeBack(selectQuery: Bool) {
        takeKeyboard(selectAll: selectQuery)
        let current = count
        later.run(after: PanelPaste.keyboardCheckDelay) { [self] in
            guard count == current, window.isShown, !window.hasKeyboard else { return }
            log.notice("The panel came back with no keyboard. It hides and shows one time to take it.")
            isMakingWay = true
            hide()
            takeKeyboard(selectAll: selectQuery)
        }
    }

    private func takeKeyboard(selectAll: Bool) {
        window.refusesKeyboard = false
        isHidden = false
        window.showWithKeyboard(selectAll: selectAll)
        isMakingWay = false
    }

    private func hideNow() -> PasteHandOff {
        hide()
        return { .keyWindow }
    }

    /// The panel refuses the keyboard before `orderOut`. On macOS 26, `orderOut` of a key panel of an app that is not
    /// active can wait about 0.4 s for the window server (PasteMemo, `orderOutAvoidingKeyProposal`).
    private func hide() {
        window.refusesKeyboard = true
        isHidden = true
        window.hideForPaste()
    }
}
