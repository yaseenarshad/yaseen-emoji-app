import Foundation
@testable import EmojiKit

/// The full catalog of `emoji.json`, loaded one time for all the tests.
enum Catalog {
    static let all: [Emoji] = (try? EmojiCatalog.bundled()) ?? []

    /// The emoji with this text. The tests use it for an emoji that must be in the catalog.
    static func emoji(_ text: String) -> Emoji? {
        all.first { $0.text == text }
    }
}

/// A new, empty folder in the temp folder. The tests write only here,
/// never to `~/Library/Application Support/Yaseen Emoji`.
final class TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YaseenEmojiTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// `you.json` in a subfolder that does not exist yet, as on the first start of the app.
    var youFile: URL { url.appendingPathComponent("Yaseen Emoji/you.json") }

    func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A clock for the store: each call is one second after the call before it.
/// Whole seconds come back the same from the ISO 8601 text of `you.json`.
final class StepClock {
    private var seconds: TimeInterval = 1_800_000_000

    func now() -> Date {
        seconds += 1
        return Date(timeIntervalSince1970: seconds)
    }
}

/// The median time of `body` in milliseconds, over `runs` runs.
func medianMilliseconds(runs: Int, _ body: () throws -> Void) rethrows -> Double {
    var times: [Double] = []
    let clock = ContinuousClock()
    for _ in 0..<runs {
        let start = clock.now
        try body()
        let elapsed = clock.now - start
        times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
    }
    return times.sorted()[times.count / 2]
}

/// Debug or release, for the printed timings.
#if DEBUG
let buildKind = "debug"
#else
let buildKind = "release"
#endif
