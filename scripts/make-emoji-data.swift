// Makes `Sources/EmojiKit/Resources/emoji.json` from five free sources (D3 on YAZ-2894).
//
// USAGE (from the repository root):
//   swift scripts/make-emoji-data.swift
//
// Run it by hand. The repository keeps the made file, so a normal build never goes online,
// and the app never goes online.
//
// The script downloads each source at a fixed version into a new, empty temp folder.
// It checks the SHA-256 of each file, so a changed source stops the script.
// It reads the files only as JSON or as text. It never runs them.
//
// Each row of `emoji.json`:
//   e: the emoji (the fully-qualified form)    n: the name    g: the group number
//   t: 1 if it takes a skin tone, else 0       w: the search words
//   f: the five one-tone forms, light to dark (only when t is 1)
// The array order is the Unicode order.

import CryptoKit
import Foundation

/// One source: where it is, and the SHA-256 of the file at that version.
struct Source {
    let file: String
    let url: String
    let sha256: String
}

let sources = [
    Source(file: "emoji-test.txt",
           url: "https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt",
           sha256: "1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda"),
    Source(file: "unicode-emoji-json.json",
           url: "https://cdn.jsdelivr.net/npm/unicode-emoji-json@0.9.0/data-by-emoji.json",
           sha256: "2ebd44d5c66459b48aadbb34ad21161850da6c9b74036dce9097b2bfad9b2c23"),
    Source(file: "cldr-annotations.json",
           url: "https://cdn.jsdelivr.net/npm/cldr-annotations-full@48.2.0/annotations/en/annotations.json",
           sha256: "f22083cb86dffb63a643d5bacb5d9899f82d2fa5d388ad4f3aed72184acef505"),
    Source(file: "emojilib.json",
           url: "https://cdn.jsdelivr.net/npm/emojilib@4.0.3/dist/emoji-en-US.json",
           sha256: "7974e9162e1505aa1b02d07a04e4eefa5c51864d6c32e477121c635201e2eca2"),
    Source(file: "gemoji.json",
           url: "https://raw.githubusercontent.com/github/gemoji/v4.1.0/db/emoji.json",
           sha256: "b174ae2aeb321b52f64adb9ff412f966a7f338839d780784dd15dcad702c2dd6"),
]

/// The groups of `unicode-emoji-json`, in order. The group number in `emoji.json` is the place here.
/// `EmojiCatalog.groupNames` in the app has the same list.
let groups = [
    "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink",
    "Travel & Places", "Activities", "Objects", "Symbols", "Flags",
]

/// The five skin tones, light to dark, as `emoji-test.txt` names them.
let toneNames = [
    "light skin tone", "medium-light skin tone", "medium skin tone",
    "medium-dark skin tone", "dark skin tone",
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-emoji-data: \(message)\n".utf8))
    exit(1)
}

/// The same emoji with or without U+FE0F. The sources do not agree on U+FE0F.
func key(_ emoji: String) -> String {
    String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
}

// MARK: Download

let fileManager = FileManager.default
let folder = fileManager.temporaryDirectory
    .appendingPathComponent("make-emoji-data-\(UUID().uuidString)", isDirectory: true)
do {
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
} catch {
    fail("cannot make the temp folder \(folder.path): \(error)")
}
defer { try? fileManager.removeItem(at: folder) }

var downloaded: [String: Data] = [:]
for source in sources {
    guard let url = URL(string: source.url) else { fail("bad URL \(source.url)") }
    let data: Data
    do {
        let (body, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            fail("\(source.url) did not give HTTP 200")
        }
        data = body
    } catch {
        fail("cannot download \(source.url): \(error)")
    }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard hash == source.sha256 else {
        fail("\(source.file) changed. SHA-256 is \(hash), expected \(source.sha256)")
    }
    let file = folder.appendingPathComponent(source.file)
    try data.write(to: file)
    downloaded[source.file] = try Data(contentsOf: file)
    print("Downloaded \(source.file) (\(data.count) bytes)")
}

func json(_ file: String) -> Any {
    guard let data = downloaded[file], let value = try? JSONSerialization.jsonObject(with: data) else {
        fail("\(file) is not JSON")
    }
    return value
}

// MARK: emoji-test.txt: the fully-qualified forms and their names

guard let testText = String(data: downloaded["emoji-test.txt"]!, encoding: .utf8) else {
    fail("emoji-test.txt is not UTF-8")
}
/// Each fully-qualified form, in file order, with its name (for example "thumbs up: light skin tone").
var testForms: [(emoji: String, name: String)] = []
for line in testText.split(separator: "\n") where line.contains("; fully-qualified") {
    let parts = line.split(separator: ";", maxSplits: 1)
    var scalars = String.UnicodeScalarView()
    for hex in parts[0].split(separator: " ") {
        guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            fail("bad code point in emoji-test.txt: \(line)")
        }
        scalars.append(scalar)
    }
    // The comment is "# 👍🏻 E1.0 thumbs up: light skin tone". The name follows the version.
    guard let comment = parts[1].split(separator: "#", maxSplits: 1).last,
          let version = comment.range(of: #"E\d+\.\d+ "#, options: .regularExpression)
    else { fail("bad line in emoji-test.txt: \(line)") }
    testForms.append((String(scalars), String(comment[version.upperBound...]).trimmingCharacters(in: .whitespaces)))
}

/// The emoji for each name of the test file.
var emojiForTestName: [String: String] = [:]
for form in testForms { emojiForTestName[form.name] = form.emoji }

/// The five one-tone forms of each emoji. A form with two different tones is not kept.
/// The tone is not always the emoji plus one tone mark. Some emojis with two people have their own forms.
var toneForms: [String: [String?]] = [:]
for form in testForms {
    guard let colon = form.name.range(of: ": ") else { continue }
    let head = String(form.name[..<colon.lowerBound])
    let parts = form.name[colon.upperBound...].components(separatedBy: ", ")
    let tones = parts.filter { toneNames.contains($0) }
    guard tones.count == 1, let tone = toneNames.firstIndex(of: tones[0]) else { continue }
    let rest = parts.filter { !toneNames.contains($0) }
    let baseName = rest.isEmpty ? head : head + ": " + rest.joined(separator: ", ")
    guard let base = emojiForTestName[baseName] else { fail("no emoji named \"\(baseName)\"") }
    var forms = toneForms[base] ?? Array(repeating: nil, count: 5)
    guard forms[tone] == nil else { fail("two forms for \"\(form.name)\"") }
    forms[tone] = form.emoji
    toneForms[base] = forms
}

// MARK: The word lists

guard let byEmoji = json("unicode-emoji-json.json") as? [String: [String: Any]] else {
    fail("unicode-emoji-json has a different shape")
}
guard let cldrRoot = json("cldr-annotations.json") as? [String: Any],
      let cldrInner = cldrRoot["annotations"] as? [String: Any],
      let cldr = cldrInner["annotations"] as? [String: [String: Any]]
else { fail("cldr-annotations has a different shape") }
guard let emojilib = json("emojilib.json") as? [String: [String]] else {
    fail("emojilib has a different shape")
}
guard let gemoji = json("gemoji.json") as? [[String: Any]] else { fail("gemoji has a different shape") }

/// All the words of each emoji from CLDR, emojilib and gemoji, by `key`.
var rawWords: [String: [String]] = [:]
for (emoji, value) in cldr {
    rawWords[key(emoji), default: []] += value["default"] as? [String] ?? []
}
for (emoji, words) in emojilib {
    rawWords[key(emoji), default: []] += words
}
for row in gemoji {
    guard let emoji = row["emoji"] as? String else { continue }
    rawWords[key(emoji), default: []] += (row["aliases"] as? [String] ?? []) + (row["tags"] as? [String] ?? [])
}

// MARK: Merge

/// The emojis in Unicode order: the fully-qualified forms without a skin tone.
/// These are the same emojis as `unicode-emoji-json`, in the same order.
let order = testForms.map(\.emoji).filter { byEmoji[$0] != nil }
guard order.count == byEmoji.count else {
    fail("emoji-test.txt has \(order.count) of the \(byEmoji.count) emojis of unicode-emoji-json")
}

var rows: [[String: Any]] = []
var wordCount = 0
var toneCount = 0
for emoji in order {
    let info = byEmoji[emoji]!
    guard let name = info["name"] as? String,
          let groupName = info["group"] as? String,
          let group = groups.firstIndex(of: groupName),
          let takesTone = info["skin_tone_support"] as? Bool
    else { fail("unicode-emoji-json has a bad row for \(emoji)") }

    // Lower case, "_" to a space, no copies, and no copy of the name.
    let lowerName = name.lowercased()
    var words = Set<String>()
    for word in rawWords[key(emoji)] ?? [] {
        let clean = word.lowercased().replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if !clean.isEmpty && clean != lowerName { words.insert(clean) }
    }
    wordCount += words.count

    var row: [String: Any] = ["e": emoji, "n": name, "g": group, "t": takesTone ? 1 : 0, "w": words.sorted()]
    if takesTone {
        let forms = toneForms[emoji] ?? []
        guard forms.count == 5, forms.allSatisfy({ $0 != nil }) else {
            fail("\(emoji) \(name) takes a skin tone, but emoji-test.txt does not have its five forms")
        }
        row["f"] = forms.compactMap { $0 }
        toneCount += 1
    } else if toneForms[emoji] != nil {
        fail("\(emoji) \(name) has tone forms, but unicode-emoji-json says it takes no skin tone")
    }
    rows.append(row)
}

// One row on each line, so a change shows well in a git diff.
var lines: [String] = []
for row in rows {
    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
    lines.append(String(decoding: data, as: UTF8.self))
}
let output = "[\n" + lines.joined(separator: ",\n") + "\n]\n"
let target = URL(fileURLWithPath: "Sources/EmojiKit/Resources/emoji.json")
try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data(output.utf8).write(to: target, options: .atomic)

print("Wrote \(target.path): \(rows.count) emojis, \(wordCount) words, \(toneCount) take a skin tone, \(output.utf8.count) bytes")
