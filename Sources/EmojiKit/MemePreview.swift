import AppKit
import ImageIO

/// The big preview of the meme with the blue box (D15 of YAZ-2919): when it shows, which item, and on which side
/// of the search panel. Pure functions, so a test checks them with no window and no screen.
enum MemePreview {
    /// About 360 points wide, the height of the search panel.
    static let width: CGFloat = 360
    /// The space between the search panel and the preview.
    static let gap: CGFloat = 8

    enum Side: Equatable {
        case left, right
    }

    /// The meme that the preview shows, or nil: the preview hides. Only on the Memes tab, while the panel shows
    /// and does not step aside, and only for a meme with the blue box.
    static func item(isOpen: Bool, isSteppingAside: Bool, tab: PickSession.Tab, selected: PickItem?) -> PickItem? {
        guard isOpen, !isSteppingAside, tab == .memes, let selected, selected.kind == .meme else { return nil }
        return selected
    }

    /// Right of the search panel when the preview fits on the visible screen there. Else left when it fits there.
    /// Else the side with more room.
    static func side(panel: CGRect, visibleFrame: CGRect) -> Side {
        let right = visibleFrame.maxX - panel.maxX
        let left = panel.minX - visibleFrame.minX
        let needed = gap + width
        if right >= needed { return .right }
        if left >= needed { return .left }
        return right >= left ? .right : .left
    }

    /// The frame of the preview: beside the search panel, with the same top and the same height.
    static func frame(panel: CGRect, visibleFrame: CGRect) -> CGRect {
        let x = side(panel: panel, visibleFrame: visibleFrame) == .right ? panel.maxX + gap : panel.minX - gap - width
        return CGRect(x: x, y: panel.minY, width: width, height: panel.height)
    }
}

/// The window of the big preview: a thin view of `MemePreview` (D15 of YAZ-2919). It never takes the keyboard or
/// the mouse, so the search panel keeps the keyboard, and the close of the panel at a lost key never runs because
/// of it. No test opens it.
final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the meme with the blue box beside the search panel: the picture aspect-fit (no crop), the tile text below.
/// It is a child window of the search panel while it shows, so it moves with a drag of the panel.
@MainActor
final class MemePreviewController {
    static let titleHeight: CGFloat = 30
    static let inset: CGFloat = 12
    /// The long side of a picture in memory, in pixels: enough for 360 points on a Retina screen.
    nonisolated static let largestPixels = 1_200

    private let window: PreviewPanel
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let online: OnlineResults?
    /// The file of your own meme in `memes/`. The search panel sets it.
    var fileURL: (PickItem) -> URL? = { _ in nil }
    /// The item that shows, or nil when the preview is hidden.
    private var shown: PickItem?
    /// The last pictures, by file URL.
    private let pictures = NSCache<NSString, NSImage>()
    private var load: Task<Void, Never>?

    init(online: OnlineResults?, mask: NSImage) {
        self.online = online
        pictures.countLimit = 20
        window = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: MemePreview.width, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.ignoresMouseEvents = true
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        // The same material and the same round corners as the search panel.
        let background = NSVisualEffectView(frame: window.contentLayoutRect)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = mask
        background.autoresizingMask = [.width, .height]
        window.contentView = background

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        background.addSubview(imageView)
        titleField.alignment = .center
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.autoresizingMask = [.width, .maxYMargin]
        background.addSubview(titleField)
    }

    /// Shows `item` beside `panel`, or hides the preview when `item` is nil (`MemePreview.item`).
    func show(_ item: PickItem?, beside panel: NSWindow) {
        guard let item else { return hide() }
        let screen = panel.screen ?? NSScreen.main
        let frame = MemePreview.frame(panel: panel.frame, visibleFrame: screen?.visibleFrame ?? panel.frame)
        if window.frame != frame {
            window.setFrame(frame, display: false)
            layOut()
        }
        if shown != item {
            shown = item
            titleField.stringValue = PickSession.label(of: item)
            showPicture(of: item)
        }
        if window.parent !== panel {
            window.parent?.removeChildWindow(window)
            panel.addChildWindow(window, ordered: .above)
        }
        // The app is never the active app, as for the search panel (Screendraw).
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        guard shown != nil || window.isVisible else { return }
        shown = nil
        load?.cancel()
        load = nil
        imageView.image = nil
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    private func layOut() {
        let bounds = window.contentLayoutRect
        let inset = MemePreviewController.inset
        titleField.frame = NSRect(x: inset, y: inset, width: bounds.width - 2 * inset, height: MemePreviewController.titleHeight - inset)
        imageView.frame = NSRect(x: inset, y: MemePreviewController.titleHeight,
                                 width: bounds.width - 2 * inset, height: bounds.height - MemePreviewController.titleHeight - inset)
    }

    /// Your meme: its file. A KLIPY meme: its paste file, once the blue box stays 350 ms on it (the same file as a pick).
    private func showPicture(of item: PickItem) {
        load?.cancel()
        load = nil
        imageView.image = nil
        switch item {
        case .own:
            guard let url = fileURL(item) else { return }
            showPicture(at: url, for: item)
        case .online(let found):
            if let url = online?.pasteFile(for: found) { return showPicture(at: url, for: item) }
            load = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self, !Task.isCancelled, self.shown == item else { return }
                self.online?.getPasteFile(for: found) { [weak self] url in
                    guard let self, let url, self.shown == item else { return }
                    self.showPicture(at: url, for: item)
                }
            }
        case .emoji:
            break
        }
    }

    /// Loads the picture off the main thread, at most `largestPixels` on the long side, and keeps the last 20.
    private func showPicture(at url: URL, for item: PickItem) {
        let key = url.absoluteString as NSString
        if let image = pictures.object(forKey: key) {
            imageView.image = image
            return
        }
        load = Task { [weak self] in
            let picture = await MemePreviewController.decode(url)
            guard let self, !Task.isCancelled, self.shown == item, let picture else { return }
            let image = NSImage(cgImage: picture.image, size: NSSize(width: picture.image.width / 2, height: picture.image.height / 2))
            self.pictures.setObject(image, forKey: key)
            self.imageView.image = image
        }
    }

    /// A `CGImage` that crosses from the decode thread to the main thread.
    struct Decoded: @unchecked Sendable {
        let image: CGImage
    }

    nonisolated static func decode(_ url: URL) async -> Decoded? {
        await Task.detached(priority: .userInitiated) { () -> Decoded? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: largestPixels,
                  ] as CFDictionary)
            else { return nil }
            return Decoded(image: image)
        }.value
    }
}
