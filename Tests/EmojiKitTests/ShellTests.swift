import AppKit
import Testing
@testable import EmojiKit

/// The shell with fakes. No test here makes a status item or a window.
@MainActor
@Suite struct ShellTests {
    @Test func theQuitRow() throws {
        let menu = StatusMenu()
        let quit = try #require(menu.menu.item(withTitle: "Quit Yaseen Emoji"))
        #expect(quit.keyEquivalent == "q")
        #expect(quit.keyEquivalentModifierMask == .command)
        #expect(quit.isEnabled)
    }

    @Test func aClickOnQuitCallsOnQuit() throws {
        let menu = StatusMenu()
        var quits = 0
        menu.onQuit = { quits += 1 }
        click(try #require(menu.menu.item(withTitle: "Quit Yaseen Emoji")))
        #expect(quits == 1)
    }

    /// D11: an outline smiley as a template image. The menu exists with no status item.
    @Test func theMenuBarIconIsATemplateSmiley() throws {
        #expect(StatusMenu.symbolName == "face.smiling")
        #expect(StatusMenu.autosaveName == "YaseenEmoji")
        let icon = try #require(StatusMenu.icon())
        #expect(icon.isTemplate)
        #expect(StatusMenu().statusItem == nil)
    }

    @Test func aSecondCopyOfTheAppQuits() {
        #expect(!AppController.isSecondCopy(own: 10, running: []))
        #expect(!AppController.isSecondCopy(own: 10, running: [10]))
        #expect(AppController.isSecondCopy(own: 10, running: [10, 11]))
        #expect(AppController.isSecondCopy(own: 10, running: [11]))
    }

    /// The fake works as macOS does: only a registered hotkey tells the app.
    @Test func theFakeHotKeyCenterTellsOnlyARegisteredHotKey() {
        let hotKeys = FakeHotKeyRegistrar()
        var presses: [HotKeyKind] = []
        hotKeys.onHotKey = { presses.append($0) }
        let commandE = HotKeyKind.findEmoji.startValue
        hotKeys.press(commandE)
        #expect(presses.isEmpty)
        #expect(hotKeys.register(commandE, for: .findEmoji))
        hotKeys.press(commandE)
        #expect(presses == [.findEmoji])
        hotKeys.refused = [commandE]
        #expect(!hotKeys.register(commandE, for: .findEmoji))
        #expect(hotKeys.registered.isEmpty)
    }
}
