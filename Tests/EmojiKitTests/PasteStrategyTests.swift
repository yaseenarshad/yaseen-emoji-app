import Foundation
import Testing
@testable import EmojiKit

/// D21 of YAZ-2919: a pick that stays open pastes with no flash. The panel stays on the screen, gives the keyboard to
/// the app in front for the ⌘V, and takes it back. If the panel still has the keyboard right before the ⌘V, that pick
/// uses the old way (hide, ⌘V, show). The window and the app in front are fakes: no test opens a window or posts a key.
@MainActor
@Suite struct PasteStrategyTests {
    /// A rig with "After Enter: Stay open", Keep on, and 👎 in the blue box, with the panel open.
    private func openRig(strategy: String? = nil) throws -> PickRig {
        let rig = try PickRig(afterEnter: nil)
        if let strategy { rig.defaults.set(strategy, forKey: "yaseenEmoji.pasteStrategy") }
        rig.setEnter(keep: true)
        rig.session.open()
        rig.session.setQuery("thumb")
        try rig.select("👎")
        return rig
    }

    /// The hidden pref `yaseenEmoji.pasteStrategy`: no value gives `handBack`. `hide` and `pid` work. An unknown text
    /// or a value that is not a text gives `handBack`.
    @Test func theStrategyPrefIsHandBackByDefault() throws {
        let defaults = MemoryDefaults()
        let prefs = Prefs(defaults: defaults)
        #expect(prefs.pasteStrategy == .handBack)
        for (value, strategy) in [("handBack", PasteStrategy.handBack), ("hide", .hide), ("pid", .pid), ("flash", .handBack),
                                  ("", .handBack), ("Hide", .handBack)] {
            defaults.set(value, forKey: "yaseenEmoji.pasteStrategy")
            #expect(prefs.pasteStrategy == strategy, "\(value)")
        }
        defaults.set(3, forKey: "yaseenEmoji.pasteStrategy")
        #expect(prefs.pasteStrategy == .handBack)
        #expect(PasteStrategy(pref: nil) == .handBack)
        // The session gives the panel the value of the pref at each pick.
        let rig = try PickRig()
        rig.defaults.set("pid", forKey: "yaseenEmoji.pasteStrategy")
        #expect(rig.session.pasteStrategy == .pid)
    }

    /// `handBack`, and the app in front takes the keyboard: nothing hides or shows. The ⌘V goes once to the window with
    /// the keyboard, after `postDelay` as before. The panel takes the keyboard back with the search text selected.
    /// The panel does not close while it makes way.
    @Test func handBackPastesWithNoHide() throws {
        let rig = try openRig()
        let window = rig.panel.window
        rig.session.enter(shift: false)
        #expect(rig.panel.calls == ["show", "makeWay"] && rig.panel.frontApp.activations == 1)
        #expect(window.refusesKeyboard && !window.hasKeyboard && window.isShown && rig.panel.paste.isMakingWay)
        #expect(window.calls.isEmpty && rig.keys.sent.isEmpty)

        rig.later.advance(by: Paster.postDelay)
        #expect(rig.keys.sent == [Paster.pasteKey] && rig.keys.targets == [nil] && rig.clipboard.contents == .text("👎"))
        rig.later.advance(by: Paster.comeBackDelay)
        #expect(rig.panel.calls == ["show", "makeWay", "comeBack"] && rig.panel.comeBackSelects == [true])
        #expect(window.calls == ["show+select"] && window.hasKeyboard && !window.refusesKeyboard)
        #expect(!rig.panel.paste.isMakingWay && !rig.panel.paste.isHidden)
        rig.later.runAll()
        #expect(rig.keys.sent.count == 1 && window.calls == ["show+select"] && rig.session.isOpen)
        #expect(rig.session.query == "thumb" && rig.session.selectedEmoji?.text == "👎")
    }

    /// `handBack`, but macOS refuses the activation: the panel still has the keyboard right before the ⌘V. The fallback
    /// hides the panel then, the ⌘V waits `postDelay` one more time, and the panel shows again. The next pick tries
    /// the hand-back again.
    @Test func theFallbackHidesWhenThePanelKeepsTheKeyboard() throws {
        let rig = try openRig()
        let window = rig.panel.window
        rig.panel.frontApp.takesKeyboard = false
        rig.session.enter(shift: false)
        #expect(window.hasKeyboard && window.calls.isEmpty && rig.panel.frontApp.activations == 1)

        rig.later.advance(by: Paster.postDelay)
        #expect(window.calls == ["hide"] && !window.isShown && rig.keys.sent.isEmpty && rig.panel.paste.isHidden)
        rig.later.advance(by: Paster.postDelay)
        #expect(rig.keys.sent == [Paster.pasteKey] && rig.keys.targets == [nil])
        rig.later.advance(by: Paster.comeBackDelay)
        #expect(window.calls == ["hide", "show+select"] && window.hasKeyboard && rig.panel.comeBackSelects == [true])
        #expect(!rig.panel.paste.isHidden && !rig.panel.paste.isMakingWay)

        // The fallback is for one pick only.
        rig.panel.frontApp.takesKeyboard = true
        rig.session.enter(shift: false)
        rig.later.runAll()
        #expect(rig.panel.frontApp.activations == 2 && rig.keys.sent.count == 2)
        #expect(window.calls == ["hide", "show+select", "show+select"])
    }

    /// `hide` is the v0.2.0 way: the panel hides at once, the ⌘V goes after `postDelay`, and the panel shows again.
    /// No app is activated. With no app in front, `handBack` and `pid` use the same way.
    @Test func theHideWayIsTheOldWay() throws {
        let rig = try openRig(strategy: "hide")
        let window = rig.panel.window
        rig.session.enter(shift: false)
        #expect(window.calls == ["hide"] && rig.panel.frontApp.activations == 0)
        rig.later.advance(by: Paster.postDelay)
        #expect(rig.keys.sent == [Paster.pasteKey] && rig.keys.targets == [nil])
        rig.later.advance(by: Paster.comeBackDelay)
        #expect(window.calls == ["hide", "show+select"] && window.hasKeyboard)

        for strategy in ["handBack", "pid"] {
            let rig = try PickRig(afterEnter: nil)
            rig.defaults.set(strategy, forKey: "yaseenEmoji.pasteStrategy")
            rig.panel.hasFrontApp = false
            rig.session.open()
            rig.session.setQuery("thumb")
            rig.session.enter(shift: false)
            #expect(rig.panel.window.calls == ["hide"], "\(strategy)")
            rig.later.runAll()
            #expect(rig.keys.targets == [nil] && rig.panel.window.calls == ["hide", "show+select"], "\(strategy)")
        }
    }

    /// `pid`: the panel stays and keeps the keyboard. The ⌘V goes to the process of the app in front, one time.
    @Test func thePidWayPostsToTheAppInFront() throws {
        let rig = try openRig(strategy: "pid")
        let window = rig.panel.window
        rig.session.enter(shift: false)
        #expect(window.calls.isEmpty && window.hasKeyboard && rig.panel.frontApp.activations == 0)
        rig.later.runAll()
        #expect(rig.keys.sent == [Paster.pasteKey] && rig.keys.targets == [4242])
        #expect(window.calls == ["show+select"] && rig.panel.comeBackSelects == [true] && rig.session.isOpen)
    }

    /// The panel came back, but macOS did not give it the keyboard. A moment later it hides and shows one time to take
    /// it. A panel that closed stops that check.
    @Test func aComeBackWithNoKeyboardTriesOneMoreTime() throws {
        let rig = try openRig()
        let window = rig.panel.window
        window.showTakesKeyboard = false
        rig.session.enter(shift: false)
        rig.later.advance(by: Paster.postDelay + Paster.comeBackDelay)
        #expect(window.calls == ["show+select"] && !window.hasKeyboard)
        window.showTakesKeyboard = true
        rig.later.advance(by: PanelPaste.keyboardCheckDelay)
        #expect(window.calls == ["show+select", "hide", "show+select"] && window.hasKeyboard)
        #expect(!rig.panel.paste.isMakingWay && rig.keys.sent.count == 1)

        // The hotkey closes the panel before the check: the check does nothing.
        window.showTakesKeyboard = false
        rig.session.enter(shift: false)
        rig.later.advance(by: Paster.postDelay + Paster.comeBackDelay)
        rig.session.toggle()
        rig.later.runAll()
        #expect(window.calls == ["show+select", "hide", "show+select", "show+select"] && !rig.session.isOpen)
    }

    /// Shift+Enter (paste and close), Copy only and ⌘C do not make way: no activation, no hide for a paste. They close
    /// the panel as before.
    @Test func shiftEnterAndCopyOnlyDoNotMakeWay() throws {
        let rig = try openRig()
        rig.session.enter(shift: true)
        #expect(!rig.session.isOpen && rig.panel.calls == ["show", "hide"])
        rig.later.runAll()
        #expect(rig.keys.sent == [Paster.pasteKey] && rig.keys.targets == [nil])

        rig.session.open()
        rig.session.setQuery("thumb")
        rig.session.copyOnly()
        rig.setEnter(.copyOnly, keep: true)
        rig.session.open()
        rig.session.setQuery("thumb")
        rig.session.enter(shift: false)
        rig.later.runAll()
        #expect(!rig.session.isOpen && !rig.panel.calls.contains("makeWay") && rig.keys.sent.count == 1)
        #expect(rig.panel.frontApp.activations == 0 && rig.panel.window.calls.isEmpty)
    }
}
