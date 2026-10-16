import AppKit
import Testing
@testable import EmojiKit

/// The shell with fakes. No test here makes a status item or a window.
@MainActor
@Suite struct ShellTests {
    /// D10 and D11: "Quit Yaseen Emoji" with ⌘Q, and an outline smiley as a template image.
    /// The menu exists with no status item. `SettingsTests` checks the other rows.
    @Test func theQuitRowAndTheIcon() throws {
        let menu = StatusMenu()
        #expect(menu.statusItem == nil)
        #expect(StatusMenu.symbolName == "face.smiling")
        #expect(try #require(StatusMenu.icon()).isTemplate)

        var quits = 0
        menu.onQuit = { quits += 1 }
        let quit = try #require(menu.menu.item(withTitle: "Quit Yaseen Emoji"))
        #expect(quit.keyEquivalent == "q" && quit.keyEquivalentModifierMask == .command)
        click(quit)
        #expect(quits == 1)
    }

    @Test func aSecondCopyOfTheAppQuits() {
        #expect(!AppController.isSecondCopy(own: 10, running: []))
        #expect(!AppController.isSecondCopy(own: 10, running: [10]))
        #expect(AppController.isSecondCopy(own: 10, running: [10, 11]))
        #expect(AppController.isSecondCopy(own: 10, running: [11]))
    }
}
