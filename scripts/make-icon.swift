// Draws the app icon and writes `Support/AppIcon.icns`.
//
// USAGE (from the repository root):
//   swift scripts/make-icon.swift
//
// The script draws each size of the icon into `build/AppIcon.iconset`, then
// `iconutil` packs the sizes into `Support/AppIcon.icns`. It also writes three
// preview pictures: `build/icon-preview-512.png`, `build/icon-preview-32.png`
// and `build/icon-preview-16.png`. It uses only AppKit and tools that come with
// Xcode. Run it again after a change to the drawing.
//
// The drawing is icon A of D11: a yellow smiley in a white search glass, on a
// dark rounded square.

import AppKit

/// Icon A (D11): a yellow smiley in a white search glass, on a dark rounded square.
/// All the numbers are for a 1024 canvas, with y up (as in AppKit).
/// The ring of the glass. The handle goes from the ring to the lower right.
let ringCenter = CGPoint(x: 452, y: 572)
let ringRadius: CGFloat = 248
let handleAngle: CGFloat = -45
/// The handle starts in the ring line and ends this far from the middle of the ring.
let handleEnd: CGFloat = 476
/// The smiley fills the inside of the ring, with a small dark gap.
let faceRadius: CGFloat = 196

/// The small sizes get thicker lines. Without this the ring is 1 pixel wide at 16 pixels,
/// and the eyes and the smile are a blur.
/// - `ring`: the width of the ring line.
/// - `handle`: the width of the handle.
/// - `features`: the size of the eyes and the width of the smile, where 1 is the large size.
func tuning(pixels: Int) -> (ring: CGFloat, handle: CGFloat, features: CGFloat) {
    switch pixels {
    case ...16: return (80, 128, 1.45)
    case ...32: return (70, 112, 1.25)
    case ...64: return (62, 100, 1.1)
    default: return (54, 92, 1.0)
    }
}

/// Draws the icon into a square of `pixels` x `pixels`.
func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // `u` scales the numbers of the 1024 canvas.
    let u = CGFloat(pixels) / 1024.0
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * u, y: y * u) }
    let tune = tuning(pixels: pixels)

    // The background: a dark rounded square on the icon grid of macOS (824 of 1024).
    // It is a little lighter at the top.
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let square = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)
    NSGradient(
        starting: NSColor(srgbRed: 0.20, green: 0.21, blue: 0.27, alpha: 1),
        ending: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.14, alpha: 1)
    )!.draw(in: square, angle: -90)

    // The smiley: a yellow disc, lighter at the top.
    let face = NSBezierPath(ovalIn: NSRect(
        x: (ringCenter.x - faceRadius) * u, y: (ringCenter.y - faceRadius) * u,
        width: 2 * faceRadius * u, height: 2 * faceRadius * u
    ))
    NSGradient(
        starting: NSColor(srgbRed: 1.00, green: 0.86, blue: 0.32, alpha: 1),
        ending: NSColor(srgbRed: 0.98, green: 0.71, blue: 0.08, alpha: 1)
    )!.draw(in: face, angle: -90)

    // The eyes and the smile, in a dark brown.
    let brown = NSColor(srgbRed: 0.33, green: 0.20, blue: 0.08, alpha: 1)
    brown.setFill()
    let eyeWidth = 46 * tune.features
    let eyeHeight = 74 * tune.features
    for side: CGFloat in [-1, 1] {
        let eyeX = ringCenter.x + side * 70 - eyeWidth / 2
        let eyeY = ringCenter.y + 52 - eyeHeight / 2
        NSBezierPath(ovalIn: NSRect(x: eyeX * u, y: eyeY * u, width: eyeWidth * u, height: eyeHeight * u)).fill()
    }
    let smile = NSBezierPath()
    smile.appendArc(
        withCenter: point(ringCenter.x, ringCenter.y + 18),
        radius: 118 * u,
        startAngle: 205,
        endAngle: 335
    )
    smile.lineWidth = 30 * tune.features * u
    smile.lineCapStyle = .round
    brown.setStroke()
    smile.stroke()

    // The search glass: a white ring and a white handle.
    NSColor.white.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(
        x: (ringCenter.x - ringRadius) * u, y: (ringCenter.y - ringRadius) * u,
        width: 2 * ringRadius * u, height: 2 * ringRadius * u
    ))
    ring.lineWidth = tune.ring * u
    ring.stroke()

    // The handle has a flat end in the ring line and a round end outside.
    // A round end in the ring would show as a bump inside the ring.
    let angle = handleAngle * .pi / 180
    let end = point(ringCenter.x + cos(angle) * handleEnd, ringCenter.y + sin(angle) * handleEnd)
    let handle = NSBezierPath()
    handle.move(to: point(ringCenter.x + cos(angle) * ringRadius, ringCenter.y + sin(angle) * ringRadius))
    handle.line(to: end)
    handle.lineWidth = tune.handle * u
    handle.lineCapStyle = .butt
    handle.stroke()
    let capRadius = tune.handle / 2 * u
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: end.x - capRadius, y: end.y - capRadius, width: 2 * capRadius, height: 2 * capRadius)).fill()

    return rep
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fail("cannot make the PNG data for \(url.lastPathComponent)")
    }
    do {
        try png.write(to: url)
    } catch {
        fail("cannot write \(url.lastPathComponent): \(error)")
    }
}

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
guard fileManager.fileExists(atPath: root.appendingPathComponent("Support/Info.plist").path) else {
    fail("run this script from the repository root: swift scripts/make-icon.swift")
}

let buildDir = root.appendingPathComponent("build")
let iconset = buildDir.appendingPathComponent("AppIcon.iconset")
let output = root.appendingPathComponent("Support/AppIcon.icns")

try? fileManager.removeItem(at: iconset)
do {
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    fail("cannot make \(iconset.path): \(error)")
}

// The file names and pixel sizes that `iconutil` expects.
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for entry in entries {
    writePNG(drawIcon(pixels: entry.pixels), to: iconset.appendingPathComponent(entry.name))
}

// The previews are the same drawings as the sizes in the .icns file.
for pixels in [512, 32, 16] {
    writePNG(drawIcon(pixels: pixels), to: buildDir.appendingPathComponent("icon-preview-\(pixels).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
do {
    try iconutil.run()
} catch {
    fail("cannot start iconutil: \(error)")
}
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fail("iconutil failed with status \(iconutil.terminationStatus)")
}

try? fileManager.removeItem(at: iconset)
print("Wrote \(output.path)")
print("Wrote the previews: build/icon-preview-512.png, build/icon-preview-32.png, build/icon-preview-16.png")
