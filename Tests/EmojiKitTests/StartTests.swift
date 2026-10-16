import Testing
@testable import EmojiKit

@Suite struct StartTests {
    @Test func theLibraryLoads() {
        #expect(AppController.self is AnyObject.Type)
    }
}
