import CoreText
import Foundation

/// Hides each emoji that the Apple Color Emoji font of this Mac cannot draw as one picture (D3).
/// The app supports macOS 14, and older macOS versions cannot draw Emoji 16 and 17.
/// Without the check, such an emoji shows as two pictures or as a box.
public enum DrawCheck {
    /// The PostScript name of the Apple Color Emoji font.
    static let fontName = "AppleColorEmoji"

    /// True if the Apple Color Emoji font draws `text` as one picture.
    /// CoreText shapes the text, so a ZWJ form is one picture only if the font has it.
    /// A font that CoreText uses in its place (for a missing glyph) also means "no".
    /// Some forms with two people give two glyphs, where the first one has no width (YAZ-2896).
    /// Thus the check counts only the glyphs with a width.
    public static func canDraw(_ text: String, font: CTFont) -> Bool {
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1 else { return false }
        let run = runs[0]
        let runAttributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = runAttributes[kCTFontAttributeName],
              CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID(),
              CTFontCopyPostScriptName(value as! CTFont) as String == fontName
        else { return false }

        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { return false }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
        return !glyphs.contains(0) && advances.filter { $0.width > 0 }.count == 1
    }

    /// The emojis of `emojis` that this Mac can draw, in the same order. A pure function, so a test
    /// can give it a list. It takes about 20 ms for the full catalog on the Mac of Yaseen, so the app
    /// calls it off the main thread, in `AppController.loadCatalog`.
    public static func drawable(_ emojis: [Emoji]) -> [Emoji] {
        let font = CTFontCreateWithName(fontName as CFString, 32, nil)
        return emojis.filter { canDraw($0.text, font: font) }
    }
}
