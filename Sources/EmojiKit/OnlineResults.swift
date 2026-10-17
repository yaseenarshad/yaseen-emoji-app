import AppKit

/// The "From KLIPY" section of one search: the items in KLIPY's order (KLIPY's rule 4), or one grey line (D2 of YAZ-2919).
struct OnlineSection: Equatable {
    var items: [OnlineItem]
    /// The grey line of `OnlineError.line`, or nil.
    var line: String?
}

/// The place of KLIPY in the GIFs and Memes tabs (D1 and D7 of YAZ-2919). Subissue 4 makes the real one on
/// `KlipyLibrary`. With no `OnlineResults`, the panel shows only your own files, and no "From KLIPY" section.
/// A test gives a fake one.
@MainActor
protocol OnlineResults: AnyObject {
    /// True when a KLIPY key is set. Then the placeholder of the GIFs and Memes tabs is "Search KLIPY" (D10 update).
    var isOn: Bool { get }
    /// The session sets it. It runs when new results, new items or new pictures came.
    var onChange: () -> Void { get set }
    /// A KLIPY item that this session knows by its slug: a result, or a saved or learned item that came by its ID (D7).
    /// Nil when it is not known (yet). The panel does not show a KLIPY item that it does not know.
    func item(_ slug: String) -> OnlineItem?
    /// The "From KLIPY" section for this search text (normalized, not empty) in the tab of `kind`.
    /// Nil when there is nothing to show yet. The provider starts its own search after the pause of D11.
    func section(for text: String, kind: ItemKind) -> OnlineSection?
    /// The downloaded paste file of `item` (D6), or nil when it is not ready.
    func pasteFile(for item: OnlineItem) -> URL?
    /// The still picture of a KLIPY tile, or nil while it loads.
    func still(for item: OnlineItem) -> NSImage?
    /// The moving picture of the tile with the blue box, or nil.
    func moving(for item: OnlineItem) -> NSImage?
}
