// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YaseenEmoji",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "YaseenEmoji", targets: ["YaseenEmoji"]),
    ],
    targets: [
        // All the code lives in the library, so the tests can import it.
        // `emoji.json` is the catalog that `scripts/make-emoji-data.swift` makes (D3).
        .target(name: "EmojiKit", resources: [.copy("Resources/emoji.json")]),
        .executableTarget(name: "YaseenEmoji", dependencies: ["EmojiKit"]),
        .testTarget(name: "EmojiKitTests", dependencies: ["EmojiKit"]),
    ],
    // Swift 5 mode: CI uses an older compiler than the Mac of Yaseen.
    swiftLanguageModes: [.v5]
)
