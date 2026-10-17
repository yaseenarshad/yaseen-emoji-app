import AppKit

/// The "From KLIPY" section of one search: the items in KLIPY's order (KLIPY's rule 4), or one grey line (D2 of YAZ-2919).
struct OnlineSection: Equatable {
    var items: [OnlineItem]
    /// The grey line of `OnlineError.line`, "Searching KLIPY…", or nil.
    var line: String?
    /// True while the first page or the next page comes. Then the grid does not say "No match".
    var isLoading = false
}

/// The place of KLIPY in the GIFs and Memes tabs (D1 and D7 of YAZ-2919). `KlipyResults` is the real one.
/// With no `OnlineResults`, the panel shows only your own files, and no "From KLIPY" section.
/// A test gives a fake one, or `KlipyResults` on a stub network.
@MainActor
protocol OnlineResults: AnyObject {
    /// True when a KLIPY key is set. Then the placeholder of the GIFs and Memes tabs is "Search KLIPY" (D10 update).
    var isOn: Bool { get }
    /// The session sets it. It runs when new results or new items came. The session builds the grid again.
    var onChange: () -> Void { get set }
    /// The grid sets it. It runs when a still or moving picture came. The grid only draws again.
    var onPicture: () -> Void { get set }
    /// A KLIPY item of this kind that this session knows by its slug: a result, or a saved or learned item that came
    /// by its ID (D7). Nil when it is not known (yet): then the provider asks KLIPY for it, with the other unknown
    /// slugs of the same kind in one call, and calls `onChange`. An item that KLIPY deleted stays nil, with no line.
    func item(_ slug: String, kind: ItemKind) -> OnlineItem?
    /// The "From KLIPY" section for this search text (normalized, not empty) in the tab of `kind`.
    /// The provider starts its own search after the pause of D11, and calls `onChange` with the answer.
    func section(for text: String, kind: ItemKind) -> OnlineSection?
    /// The grid is near its end: the next page of this search, if KLIPY has one (at most 96 items, D11).
    func loadMore(for text: String, kind: ItemKind)
    /// The blue box is on this KLIPY item now, or on no KLIPY item. After 300 ms on one item, the provider downloads
    /// its paste file. A move to a different item stops that download.
    func selectionChanged(to item: OnlineItem?)
    /// The downloaded paste file of `item` (D6), or nil when it is not ready.
    func pasteFile(for item: OnlineItem) -> URL?
    /// Gives the paste file of `item` when it is ready, or nil after 3 s or on a failure.
    func getPasteFile(for item: OnlineItem, done: @escaping @MainActor (URL?) -> Void)
    /// The still picture of a KLIPY tile, or nil while it loads.
    func still(for item: OnlineItem) -> NSImage?
    /// The moving picture of the tile with the blue box, or nil.
    func moving(for item: OnlineItem) -> NSImage?
    /// Each open of the panel: tries again what failed.
    func refresh()
    /// Each close of the panel: stops the search that waits, and the downloads.
    func stop()
}
