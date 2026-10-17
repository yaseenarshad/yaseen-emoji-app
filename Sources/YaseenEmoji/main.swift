import EmojiKit
import Foundation

// `YaseenEmoji --import-uses <folder>`: the import of the EmojiFinder history (D6) into this Mac's
// file in the folder (D16). A path that ends in `.json` is one file, as before D16.
// `install.sh` sends the rows on standard input. The app writes the file, prints one line,
// and exits. It shows no window.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--import-uses") {
    guard flag + 1 < arguments.count else {
        FileHandle.standardError.write(Data("Usage: YaseenEmoji --import-uses <folder> < rows.json\n".utf8))
        exit(2)
    }
    let path = arguments[flag + 1]
    do {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let summary = path.hasSuffix(".json")
            ? try YouImport.run(input, into: URL(fileURLWithPath: path))
            : try YouImport.run(input, intoFolder: URL(fileURLWithPath: path, isDirectory: true))
        print(summary.line)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("The import failed: \(error)\n".utf8))
        exit(1)
    }
}

// `YaseenEmoji --add-media <file> [<file> …] [--words "<words>"]`: adds GIFs and memes for the demo of the
// panel, before the add window (YAZ-2925). The app must not run. It prints one line for each file and exits.
if let flag = arguments.firstIndex(of: "--add-media") {
    exit(AddCommand.runAndWait(Array(arguments[(flag + 1)...])))
}

AppController.main()
