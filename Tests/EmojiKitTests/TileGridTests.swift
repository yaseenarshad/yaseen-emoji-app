import AppKit
import Darwin
import Testing
@testable import EmojiKit

/// The tile grid with no window (YAZ-2925; D5 and D11 of YAZ-2919): the places of the tiles, the cache of the
/// still pictures, and the delete of the still picture of a removed item. No test makes a window.
@MainActor
@Suite struct TileGridTests {
    /// D11: 3 tiles in a row, about 145 points each, in the 460 points panel. `index(at:)` finds a tile from a point.
    /// D15: each row is 16 points higher for the line of text below the tiles. The picture keeps its square.
    @Test func theGridPlacesThreeTilesInARow() {
        let lines: [PickSession.Line] = [.title("Your GIFs"), .cells(0..<3), .cells(3..<5)]
        let metrics = GridMetrics(lines: lines, columns: PickSession.tileColumns)
        let side = (460 - 2 * GridMetrics.inset) / 3
        let row = side + 16
        #expect(metrics.cellSize == side && side > 145 && side < 146)
        #expect(GridMetrics.labelHeight == 16 && metrics.rowHeight == row)
        #expect(metrics.rect(of: 0) == NSRect(x: 12, y: 4 + GridMetrics.titleHeight, width: side, height: row))
        #expect(metrics.rect(of: 4) == NSRect(x: 12 + side, y: 4 + GridMetrics.titleHeight + row, width: side, height: row))
        #expect(metrics.rect(of: 5) == nil)
        #expect(metrics.height == 4 + GridMetrics.titleHeight + 2 * row + 8)
        // The picture is the square at the top of the cell. The line of text is below it, inside the cell.
        let cell = metrics.rect(of: 0)!
        let picture = EmojiGridView.tileRect(cell)
        let label = EmojiGridView.labelRect(cell)
        #expect(picture == NSRect(x: 16, y: 34, width: side - 8, height: side - 8))
        #expect(label.minY >= picture.maxY && label.maxY <= cell.maxY && label.height == 16)
        // A point on the line of text finds its tile.
        #expect(metrics.index(at: NSPoint(x: label.midX, y: label.midY)) == 0)

        // The middle of each tile finds it. A title, the gap on the left and the empty end of a short row find nothing.
        for index in 0..<5 {
            let rect = metrics.rect(of: index)!
            #expect(metrics.index(at: NSPoint(x: rect.midX, y: rect.midY)) == index, "\(index)")
        }
        #expect(metrics.index(at: NSPoint(x: 100, y: 10)) == nil)
        #expect(metrics.index(at: NSPoint(x: 5, y: 100)) == nil)
        #expect(metrics.index(at: NSPoint(x: 12 + 2.5 * side, y: 30 + 1.5 * row)) == nil)
        #expect(metrics.items(in: NSRect(x: 0, y: 0, width: 460, height: 100)) == [0, 1, 2])
        #expect(metrics.items(in: NSRect(x: 0, y: 100, width: 460, height: 100)) == [0, 1, 2, 3, 4])
        #expect(metrics.items(in: NSRect(x: 0, y: 200, width: 460, height: 100)) == [3, 4])

        // The Emoji tab keeps 9 cells of about 48 points (v0.1).
        let emojis = GridMetrics(lines: [.cells(0..<9)], columns: PickSession.columns)
        #expect(emojis.cellSize == GridMetrics.cellSize(columns: 9) && emojis.cellSize > 48 && emojis.cellSize < 49)
        #expect(emojis.rowHeight == emojis.cellSize && emojis.rect(of: 0)?.height == emojis.cellSize)
        #expect(emojis.index(at: NSPoint(x: 12 + 8.5 * emojis.cellSize, y: 20)) == 8)
    }

    /// D11: the cache keeps at most 120 still pictures, and the newest stay.
    @Test func theCacheKeepsAtMost120StillPictures() throws {
        let folder = try TempFolder()
        let thumbnails = Thumbnails(folder: folder.url)
        for place in 0..<300 { thumbnails.keep(NSImage(size: NSSize(width: 4, height: 4)), for: "id\(place)") }
        let kept = (0..<300).filter { thumbnails.image("id\($0)") != nil }
        #expect(kept.count == Thumbnails.countLimit)
        #expect(kept.contains(299) && !kept.contains(0))
    }

    /// A still picture loads off the main thread into the cache. The remove of an item on a different Mac
    /// (or in an earlier build) deletes it at the next open (D5, owner note on YAZ-2925).
    @Test func theStillPictureLoadsAndGoesWithItsItem() async throws {
        let rig = try PickRig()
        let gif = try rig.addOwn(words: ["dance"])
        let other = try rig.addOwn(words: ["wave"], seed: 1)
        rig.session.willOpen = { rig.library.reload() }
        var loaded: [String] = []
        rig.thumbnails.onLoad = { loaded.append($0) }
        for item in [gif, other] {
            rig.thumbnails.want([Thumbnails.Want(id: item.id, file: try #require(rig.library.fileURL(of: item)))])
            await waitUntil { loaded.contains(item.id) }
            #expect(loaded.contains(item.id))
        }
        let still = rig.thumbnails.folder.appendingPathComponent("\(gif.id).png")
        #expect(FileManager.default.fileExists(atPath: still.path))
        #expect(rig.thumbnails.image(gif.id)?.size == NSSize(width: 145, height: 145))

        rig.session.open()
        rig.session.select(tab: .gifs)

        // Mac B removes the other GIF. This Mac sees it at the next open, and deletes its still picture.
        let otherStill = rig.thumbnails.folder.appendingPathComponent("\(other.id).png")
        #expect(FileManager.default.fileExists(atPath: otherStill.path))
        let macB = LibraryStore(url: rig.folder.defaultFolder.appendingPathComponent("library-B.json"),
                                mediaFolder: rig.folder.defaultFolder, now: { Date(timeIntervalSince1970: 1_900_000_000) })
        macB.load()
        macB.remove(other.id)
        rig.session.close()
        rig.session.open()
        rig.session.select(tab: .gifs)
        #expect(!rig.session.items.contains { $0.key == other.key })
        #expect(rig.thumbnails.image(other.id) == nil)
        await waitUntil { !FileManager.default.fileExists(atPath: otherStill.path) }
        #expect(!FileManager.default.fileExists(atPath: otherStill.path))
    }

    /// The memory of 120 still pictures in the cache. The number goes into the Result comment.
    /// Each one is 290 × 290 pixels, decoded: about 336 KB, so 120 are about 40 MB.
    @Test func theMemoryOf120StillPictures() async throws {
        let folder = try TempFolder()
        // 120 different files: ImageIO can share the decoded picture of one file.
        var sources: [URL] = []
        for place in 0..<Thumbnails.countLimit {
            let source = folder.url.appendingPathComponent("\(place).png")
            try makeTestImage(width: 290, height: 290, type: .png, text: "\(place)", noise: true).write(to: source)
            sources.append(source)
        }
        let thumbnails = Thumbnails(folder: folder.url)
        let before = memoryFootprint()
        var pixels = 0
        for (place, source) in sources.enumerated() {
            let image = try #require(Thumbnails.decode(source))
            pixels += image.bytesPerRow * image.height
            thumbnails.keep(NSImage(cgImage: image, size: NSSize(width: 145, height: 145)), for: "id\(place)")
        }
        let after = memoryFootprint()
        let megabytes = (Double(after) - Double(before)) / 1_000_000
        print("MEMORY 120 still pictures of 290 x 290 in the cache: pixels \(String(format: "%.1f", Double(pixels) / 1_000_000)) MB,"
              + " footprint \(String(format: "%.1f", megabytes)) MB more")
        // Other tests run at the same time, so the number is only a measure, not a check.
        #expect((0..<Thumbnails.countLimit).allSatisfy { thumbnails.image("id\($0)") != nil })
    }
}

/// The memory of this process as Activity Monitor shows it (`phys_footprint`), in bytes.
func memoryFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}
