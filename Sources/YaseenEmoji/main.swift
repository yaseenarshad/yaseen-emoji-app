import EmojiKit
import Foundation

// `YaseenEmoji --import-uses <path to you.json>`: the import of the EmojiFinder history (D6).
// `install.sh` sends the rows on standard input. The app writes the file, prints one line,
// and exits. It shows no window.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--import-uses") {
    guard flag + 1 < arguments.count else {
        FileHandle.standardError.write(Data("Usage: YaseenEmoji --import-uses <path to you.json> < rows.json\n".utf8))
        exit(2)
    }
    let url = URL(fileURLWithPath: arguments[flag + 1])
    do {
        let summary = try YouImport.run(FileHandle.standardInput.readDataToEndOfFile(), into: url)
        print(summary.line)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("The import failed: \(error)\n".utf8))
        exit(1)
    }
}

AppController.main()
