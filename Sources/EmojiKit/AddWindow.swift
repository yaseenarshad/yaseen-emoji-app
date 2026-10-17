import AppKit
import Carbon.HIToolbox
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: Where a row comes from

/// Where one row of the add window comes from (D12 of YAZ-2919): a file, or the bytes of a paste or a drop.
enum AddSource: Equatable {
    case file(URL)
    /// The bytes of one clipboard item, with the type that `PasteReader` selected.
    case bytes(Data, type: UTType)

    /// True for a still picture from the clipboard. The source app can have copied only one frame of a GIF.
    var isStillPicture: Bool {
        guard case .bytes(_, let type) = self else { return false }
        return PasteReader.stillTypes.contains(type)
    }

    /// The name on the row.
    var name: String {
        switch self {
        case .file(let url): return url.lastPathComponent
        case .bytes(_, let type):
            if type == .gif { return "Pasted GIF" }
            return PasteReader.videoTypes.contains(type) ? "Pasted video" : "Pasted picture"
        }
    }

    /// The first text of the Title box (D15 of YAZ-2919): the file name with no extension, `-` and `_` as spaces,
    /// and no copy mark (` (1)`) at the end. `midwit-mba.png` gives `midwit mba`. A paste of bytes has no name: "".
    var suggestedTitle: String {
        guard case .file(let url) = self else { return "" }
        return AddSource.title(fromName: url.deletingPathExtension().lastPathComponent)
    }

    /// The camera and system names (`IMG_2231`, `Screenshot 2026-…`) start with one of these, then a digit, a space or the end.
    static let machinePrefixes = ["img", "dsc", "dscn", "dscf", "pxl", "mvimg", "vid", "mvi", "gopr", "dji", "screenshot",
                                  "screen shot", "screen recording", "cleanshot", "whatsapp image", "whatsapp video",
                                  "photo", "image", "video", "untitled", "pasted", "clipboard", "download", "giphy", "tenor"]

    /// The title of a file name, or "" for a name that a camera or the system gave.
    static func title(fromName name: String) -> String {
        var text = Item.cleanTitle(name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))
        if let mark = text.range(of: #" ?\(\d+\)$"#, options: .regularExpression) { text.removeSubrange(mark) }
        let lower = text.lowercased()
        // Only digits and marks, a UUID, or a code name of the list (16 or more hex characters).
        if !lower.contains(where: \.isLetter) { return "" }
        if lower.range(of: #"^[0-9a-f]{8} ?[0-9a-f]{4} ?[0-9a-f]{4} ?[0-9a-f]{4} ?[0-9a-f]{12}$"#, options: .regularExpression) != nil
            || lower.range(of: #"^[0-9a-f]{16,}$"#, options: .regularExpression) != nil {
            return ""
        }
        // A camera word with digits after it, or with nothing after it. `photo booth fail` stays.
        for prefix in machinePrefixes.sorted(by: { $0.count > $1.count }) where lower.hasPrefix(prefix) {
            let rest = lower.dropFirst(prefix.count)
            guard rest.first.map({ $0 == " " || $0.isNumber }) ?? true else { continue }
            if rest.contains(where: \.isNumber) || !rest.contains(where: \.isLetter) { return "" }
        }
        return text
    }
}

/// The items of a clipboard or of a drag, with their types. A protocol, so a test gives a fake clipboard
/// and never reads the real one.
protocol PasteboardSource {
    /// The types of each item, in the order of the item.
    var itemTypes: [[String]] { get }
    /// The data of one type of one item. Only the selected type is read, not each type of the item.
    func data(item: Int, type: String) -> Data?
}

extension NSPasteboard: PasteboardSource {
    var itemTypes: [[String]] { (pasteboardItems ?? []).map { $0.types.map(\.rawValue) } }

    func data(item: Int, type: String) -> Data? {
        guard let items = pasteboardItems, items.indices.contains(item) else { return nil }
        return items[item].data(forType: NSPasteboard.PasteboardType(type))
    }
}

/// The saved clipboard of `Paster` and the fake clipboard of the tests.
extension ClipboardContents: PasteboardSource {
    var itemTypes: [[String]] { items.map { $0.values.map(\.type) } }

    func data(item: Int, type: String) -> Data? {
        guard items.indices.contains(item) else { return nil }
        return items[item].values.first { $0.type == type }?.data
    }
}

/// Finds the best form on the clipboard ("D12 update: paste from the clipboard" of YAZ-2919), in this order:
/// 1. A file URL: the file itself, full quality. One row for each file.
/// 2. GIF bytes: an animated GIF, full quality.
/// 3. Video bytes (MP4, MOV): `MediaImport` changes them to a GIF (D5).
/// 4. Still image bytes (PNG, JPEG, HEIC, HEIF, TIFF): a meme. `MediaImport` saves TIFF as PNG.
/// The first form that any item has wins. Each item with that form gives one row.
enum PasteReader {
    static let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue
    static let gifTypes: [UTType] = [.gif]
    static let videoTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie]
    static let stillTypes: [UTType] = [.png, .jpeg, .heic, .heif, .tiff]
    /// The byte forms, best first.
    static let byteTiers = [gifTypes, videoTypes, stillTypes]

    /// The rows of a paste. None when the clipboard has no form of the list.
    static func sources(in board: PasteboardSource) -> [AddSource] {
        let types = board.itemTypes
        let files = types.indices.compactMap { place -> URL? in
            guard types[place].contains(fileURLType), let data = board.data(item: place, type: fileURLType),
                  let text = String(data: data, encoding: .utf8), let url = URL(string: text), url.isFileURL else { return nil }
            // Finder writes a file reference URL (`file:///.file/id=…`). The path URL is the real file.
            return (url as NSURL).filePathURL ?? url
        }
        if !files.isEmpty { return files.map(AddSource.file) }
        for tier in byteTiers {
            let found = types.indices.compactMap { place -> AddSource? in
                guard let type = tier.first(where: { types[place].contains($0.identifier) }),
                      let data = board.data(item: place, type: type.identifier) else { return nil }
                return .bytes(data, type: type)
            }
            if !found.isEmpty { return found }
        }
        return []
    }

    /// True when the clipboard has a form of the list. It reads only the types, not the data.
    static func canRead(_ board: PasteboardSource) -> Bool {
        let wanted = Set([fileURLType] + byteTiers.joined().map(\.identifier))
        return board.itemTypes.contains { !wanted.isDisjoint(with: $0) }
    }
}

// MARK: The rules of the window

/// One file that waits in the add window (D12 of YAZ-2919): a preview, GIF or Meme, the words box, "Add" and "Remove".
struct AddRow: Identifiable, Equatable {
    enum State: Equatable {
        /// `MediaImport.prepare` runs: "Getting it ready…".
        case preparing
        case ready
        /// `MediaImport.prepare` refused the file. `problem` has the reason.
        case failed
    }

    let id: Int
    let source: AddSource
    var state = State.preparing
    /// The final bytes, when the row is ready.
    var file: PreparedFile?
    /// A small still picture of the file.
    var preview: NSImage?
    var kind = ItemKind.gif
    /// The text of the Title box (D15 of YAZ-2919). It starts with `AddSource.suggestedTitle`.
    var title: String
    /// True after you typed in the Title box. Then a duplicate does not put the title of its item in the box.
    var titleWasTyped = false
    /// The text of the words box.
    var words = ""
    /// The red line: the reason of a refused file, "Type one word first.", or an error of the add.
    var problem: String?
    /// The item of the list with the same `id`: "You have this one already."
    var existing: Item?
    /// True while the add runs.
    var isAdding = false
    /// True after the text reader read this file one time (D8).
    var wasRead = false

    init(id: Int, source: AddSource) {
        self.id = id
        self.source = source
        title = source.suggestedTitle
    }

    var name: String { source.name }
    /// The grey line of a still picture from the clipboard.
    var note: String? { source.isStillPicture ? AddModel.stillPictureText : nil }
}

/// The rules of the add window (D5, D8, D12 of YAZ-2919), with no view, so a test checks them.
/// `prepare` and `readText` are parameters: a test gives a fake text reader.
@MainActor
final class AddModel: ObservableObject {
    nonisolated static let title = "Add a GIF or meme"
    nonisolated static let gettingReadyText = "Getting it ready…"
    nonisolated static let needsWordText = "Type one word first."
    nonisolated static let duplicateText = "You have this one already."
    nonisolated static let stillPictureText = "This came in as a still picture. To keep it moving, save the file and drag it in."
    nonisolated static let emptyClipboardText = "The clipboard has no GIF, video or picture."

    @Published private(set) var rows: [AddRow] = []
    /// The grey line at the top of the window, for example after a paste of an empty clipboard.
    @Published private(set) var notice: String?
    /// True while the window asks "Close and drop N files?".
    @Published private(set) var isAskingToClose = false
    /// True while a drag with files is over the window.
    @Published var isDropTargeted = false

    let library: LibraryStore
    /// Runs on the main thread after each add, with the result.
    var onAdded: (AddResult) -> Void = { _ in }

    private let prepare: (AddSource) async throws -> PreparedFile
    private let readText: (Data) async -> [String]
    private var nextID = 0
    /// The work that runs: the prepares, the text reads and the adds. A test waits for it with `settle()`.
    private var work: [Task<Void, Never>] = []

    init(library: LibraryStore,
         prepare: @escaping (AddSource) async throws -> PreparedFile = AddModel.prepare,
         readText: @escaping (Data) async -> [String] = MediaImport.readText) {
        self.library = library
        self.prepare = prepare
        self.readText = readText
    }

    /// `MediaImport.prepare` of a file or of the bytes of a paste, off the main thread (D5).
    nonisolated static func prepare(_ source: AddSource) async throws -> PreparedFile {
        switch source {
        case .file(let url): return try await MediaImport.prepare(url)
        case .bytes(let data, let type): return try await MediaImport.prepare(data: data, type: type)
        }
    }

    // MARK: New rows

    /// A drop, "Choose files…" or a paste: one row for each source. Each row shows "Getting it ready…" until
    /// `MediaImport.prepare` is done.
    func add(_ sources: [AddSource]) {
        guard !sources.isEmpty else { return }
        notice = nil
        for source in sources {
            let id = nextID
            nextID += 1
            rows.append(AddRow(id: id, source: source))
            work.append(Task { [weak self] in await self?.prepareRow(id, source) })
        }
    }

    /// "Paste" and ⌘V: the best form on the clipboard (D12 update). An empty clipboard gives the grey line.
    func paste(from board: PasteboardSource) {
        let sources = PasteReader.sources(in: board)
        if sources.isEmpty {
            notice = AddModel.emptyClipboardText
        } else {
            add(sources)
        }
    }

    private func prepareRow(_ id: Int, _ source: AddSource) async {
        do {
            let file = try await prepare(source)
            let preview = await AddModel.preview(of: file.bytes)
            change(id) { row in
                row.state = .ready
                row.file = file
                row.kind = file.kind
                row.preview = preview
            }
            markDuplicates()
            // D8: a meme has its read words at once. A duplicate has its words already.
            if file.kind == .meme, let row = row(id), row.existing == nil { await read(id, file.bytes) }
        } catch {
            change(id) { row in
                row.state = .failed
                row.problem = error.localizedDescription
            }
        }
    }

    /// Reads the words of a meme into the empty words box, one time for each row (D8).
    private func read(_ id: Int, _ bytes: Data) async {
        change(id) { $0.wasRead = true }
        let words = await readText(bytes)
        change(id) { row in
            if row.words.trimmingCharacters(in: .whitespaces).isEmpty { row.words = words.joined(separator: " ") }
        }
    }

    // MARK: The row actions

    /// GIF or Meme. A GIF marked as a meme goes into `memes/`. The first change to Meme reads its words (D8).
    /// A duplicate keeps the kind of its item.
    func setKind(_ kind: ItemKind, of id: Int) {
        guard let row = row(id), row.state == .ready, row.existing == nil else { return }
        change(id) { $0.kind = kind }
        if kind == .meme, !row.wasRead, let bytes = row.file?.bytes {
            work.append(Task { [weak self] in await self?.read(id, bytes) })
        }
    }

    func setTitle(_ text: String, of id: Int) {
        change(id) { row in
            row.title = text
            row.titleWasTyped = true
        }
    }

    func setWords(_ text: String, of id: Int) {
        change(id) { row in
            row.words = text
            if row.problem == AddModel.needsWordText { row.problem = nil }
        }
    }

    /// "Remove": the row goes away. Nothing goes into the list.
    func remove(_ id: Int) {
        rows.removeAll { $0.id == id }
        if rows.isEmpty { isAskingToClose = false }
    }

    /// "Add" (D12): needs one word. The file goes into `gifs/` or `memes/` off the main thread (owner note on
    /// YAZ-2927), then `LibraryStore.add` saves the list on the main thread. The row goes away, and the item is
    /// first in "Your GIFs" or "Your memes". A duplicate adds only its new words, and a new title that is not empty.
    func add(row id: Int) {
        guard let row = row(id), row.state == .ready, !row.isAdding, let file = row.file else { return }
        let words = Item.words(typed: row.words)
        guard !words.isEmpty else {
            change(id) { $0.problem = AddModel.needsWordText }
            return
        }
        change(id) { row in
            row.isAdding = true
            row.problem = nil
        }
        let kind = row.kind
        let title = row.title
        // `LibraryStore` is not safe for two threads, and the panel reads it on the main thread.
        // Thus only the write of the file runs off the main thread.
        let target = library.place(of: file, as: kind)
        work.append(Task { [weak self] in
            do {
                if let target {
                    try await Task.detached(priority: .userInitiated) {
                        try LibraryStore.writeMediaFile(file.bytes, to: target)
                    }.value
                }
                self?.finishAdd(id, file, kind: kind, words: words, title: title)
            } catch {
                self?.failAdd(id, error)
            }
        })
    }

    private func finishAdd(_ id: Int, _ file: PreparedFile, kind: ItemKind, words: [String], title: String) {
        do {
            let result = try library.add(file, as: kind, words: words, title: title)
            rows.removeAll { $0.id == id }
            if rows.isEmpty { isAskingToClose = false }
            markDuplicates()
            onAdded(result)
        } catch {
            failAdd(id, error)
        }
    }

    private func failAdd(_ id: Int, _ error: Error) {
        change(id) { row in
            row.isAdding = false
            row.problem = error.localizedDescription
        }
    }

    /// Finds the rows whose file is in the list already: two pastes of the same GIF, or a GIF of the list.
    /// A duplicate keeps the kind of its item, and shows its title until you type a different one.
    private func markDuplicates() {
        for place in rows.indices {
            guard let file = rows[place].file else { continue }
            let existing = library.item(file.id).flatMap { $0.isRemoved ? nil : $0 }
            if rows[place].existing != existing {
                rows[place].existing = existing
                if let existing {
                    rows[place].kind = existing.kind
                    if !rows[place].titleWasTyped { rows[place].title = existing.title }
                }
            }
        }
    }

    // MARK: Close (D12)

    /// The rows that a close would drop: each row that is not refused and not in its add.
    var waitingCount: Int { rows.filter { $0.state != .failed && !$0.isAdding }.count }

    /// "Close and drop N files?"
    var closeQuestion: String {
        "Close and drop \(waitingCount) \(waitingCount == 1 ? "file" : "files")?"
    }

    /// The close button or ⌘W. True: the window closes now, and the refused rows go. False: the window asks
    /// "Close and drop N files?" inside the window, with no alert.
    func requestClose() -> Bool {
        guard waitingCount > 0 else {
            dropAll()
            return true
        }
        isAskingToClose = true
        return false
    }

    /// "Close" in the question: the rows go. The window closes.
    func dropAll() {
        rows.removeAll { !$0.isAdding }
        notice = nil
        isAskingToClose = false
    }

    func cancelClose() {
        isAskingToClose = false
    }

    // MARK: Helpers

    func row(_ id: Int) -> AddRow? { rows.first { $0.id == id } }

    /// Changes the row with this `id`. A row that is gone (for example after "Remove") changes nothing.
    private func change(_ id: Int, _ body: (inout AddRow) -> Void) {
        guard let place = rows.firstIndex(where: { $0.id == id }) else { return }
        body(&rows[place])
    }

    /// Waits for the work that runs, also the work that it starts. For the tests.
    func settle() async {
        while !work.isEmpty {
            let running = work
            work = []
            for task in running { await task.value }
        }
    }

    /// A small still picture of the bytes, made off the main thread.
    nonisolated static func preview(of bytes: Data) async -> NSImage? {
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
            ] as CFDictionary)
        }.value
        return image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width / 2, height: $0.height / 2)) }
    }
}

// MARK: Drops

/// The drop of files on the add window and on the search panel (D12 of YAZ-2919). It takes files, file promises
/// (a drag from a browser or from Telegram) and the byte forms of `PasteReader`, in this order.
@MainActor
enum FileDrop {
    static var types: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            + PasteReader.byteTiers.joined().map { NSPasteboard.PasteboardType($0.identifier) }
    }

    /// True when the drag has a form to add.
    static func accepts(_ info: NSDraggingInfo) -> Bool {
        let board = info.draggingPasteboard
        return PasteReader.canRead(board) || board.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    /// Reads the drop. Files and bytes come at once. The files of promises come later, one at a time, into a new temp folder.
    static func receive(_ info: NSDraggingInfo, done: @escaping @MainActor ([AddSource]) -> Void) {
        let board = info.draggingPasteboard
        let found = PasteReader.sources(in: board)
        if case .file = found.first { return done(found) }
        let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        guard !promises.isEmpty else { return done(found) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YaseenEmoji-drop-\(UUID().uuidString)",
                                                                                   isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return done(found)
        }
        let queue = OperationQueue()
        for promise in promises {
            // The reader runs one time for each file, on `queue`. Each file gives its row when it is there.
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                guard error == nil else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { done([.file(url)]) }
                }
            }
        }
    }
}

/// The part of a view that takes the drops of `FileDrop`. The add window, the search panel and the field editor
/// of the search box give their drag calls to it.
@MainActor
final class FileDropTarget {
    var onDrop: ([AddSource]) -> Void = { _ in }
    /// True while a drag that the target takes is over the view.
    var onHover: (Bool) -> Void = { _ in }

    func entered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard FileDrop.accepts(info) else { return [] }
        onHover(true)
        return .copy
    }

    func exited() { onHover(false) }

    func perform(_ info: NSDraggingInfo) -> Bool {
        onHover(false)
        guard FileDrop.accepts(info) else { return false }
        FileDrop.receive(info) { [weak self] sources in
            if !sources.isEmpty { self?.onDrop(sources) }
        }
        return true
    }
}

/// The content of the add window: the SwiftUI view, in a view that takes the drops.
final class FileDropView: NSView {
    let fileDrop = FileDropTarget()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(FileDrop.types)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileDrop.entered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { fileDrop.exited() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { fileDrop.perform(sender) }
}

// MARK: The view

/// The add window (D12 of YAZ-2919): the drop area with "Choose files…" and "Paste", the question of a close,
/// and one row for each file that waits.
struct AddView: View {
    @ObservedObject var model: AddModel
    var chooseFiles: () -> Void
    var paste: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropArea
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
            if model.isAskingToClose { closeBox }
            if !model.rows.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            AddRowView(model: model, row: row)
                            Divider()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 300)
    }

    private var dropArea: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("Drop GIFs, videos and memes here").foregroundStyle(.secondary)
            HStack {
                Button("Choose files…", action: chooseFiles)
                Button("Paste", action: paste).help("Adds the file, GIF, video or picture on the clipboard. ⌘V does the same.")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(model.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                              style: StrokeStyle(lineWidth: model.isDropTargeted ? 3 : 1.5, dash: [6, 4]))
        )
    }

    /// The question of a close with rows that wait. No alert: an alert takes the keyboard from the panel.
    private var closeBox: some View {
        HStack {
            Text(model.closeQuestion).foregroundStyle(.red)
            Spacer()
            Button("Cancel") { model.cancelClose() }
            Button("Close", role: .destructive) {
                model.dropAll()
                close()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.red, lineWidth: 1.5))
    }
}

/// One row: the preview, GIF / Meme, the words box, "Add" and "Remove", and the lines below.
struct AddRowView: View {
    @ObservedObject var model: AddModel
    let row: AddRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 6) {
                Text(row.name).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if row.state == .preparing {
                    Text(AddModel.gettingReadyText).foregroundStyle(.secondary)
                }
                if row.state == .ready {
                    TextField("Title", text: Binding(get: { row.title }, set: { model.setTitle($0, of: row.id) }),
                              prompt: Text("Title, for example: midwit mba"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.add(row: row.id) }
                    HStack {
                        Picker("Kind", selection: Binding(get: { row.kind }, set: { model.setKind($0, of: row.id) })) {
                            Text("GIF").tag(ItemKind.gif)
                            Text("Meme").tag(ItemKind.meme)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(row.existing != nil)
                        TextField("Words, for example: dance party", text: Binding(
                            get: { row.words }, set: { model.setWords($0, of: row.id) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.add(row: row.id) }
                        Button("Add") { model.add(row: row.id) }
                            .disabled(row.isAdding)
                    }
                    if row.existing != nil {
                        Text(AddModel.duplicateText).font(.callout).foregroundStyle(.secondary)
                    }
                    if let note = row.note {
                        Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let problem = row.problem {
                    Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Remove") { model.remove(row.id) }
                .disabled(row.isAdding)
        }
        .padding(.vertical, 10)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.2))
            if let image = row.preview {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if row.state == .preparing {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: The window

/// The panel of the add window. The app has no main menu, so the panel gives the edit keys to the words box,
/// and ⌘W closes it.
final class AddPanel: NSPanel {
    /// ⌘V. True when the add window used it. False: the words box pastes the text.
    var onPaste: () -> Bool = { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let combo = HotKeyCombo(keyDown: event) else { return super.performKeyEquivalent(with: event) }
        let command = NSEvent.ModifierFlags.command
        switch (Int(combo.keyCode), combo.modifiers) {
        case (kVK_ANSI_V, command):
            return onPaste() || EditKeys.send(combo, in: self) == true
        case (kVK_ANSI_W, command):
            performClose(nil)
            return true
        default:
            return EditKeys.send(combo, in: self) ?? super.performKeyEquivalent(with: event)
        }
    }
}

/// The add window "Add a GIF or meme" (D12 of YAZ-2919). A non-activating panel, like Settings. It stays open until
/// you close it, also when the search panel closes. One window for the life of the app.
@MainActor
final class AddWindowController: NSObject, NSWindowDelegate {
    private let model: AddModel
    let window: AddPanel

    init(model: AddModel) {
        self.model = model
        // The same panel as Settings: it takes the keyboard without the active app (Screendraw, YAZ-2823).
        window = AddPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        // It stays above the other windows until the user closes it, so it cannot get lost (D12).
        window.isFloatingPanel = true
        window.title = AddModel.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 300)
        window.delegate = self
        window.onPaste = { [weak self] in self?.commandV() ?? false }

        let content = FileDropView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
        content.fileDrop.onDrop = { [weak model] in model?.add($0) }
        content.fileDrop.onHover = { [weak model] in model?.isDropTargeted = $0 }
        let host = NSHostingView(rootView: AddView(
            model: model,
            chooseFiles: { [weak self] in self?.chooseFiles() },
            paste: { [weak self] in self?.paste() },
            close: { [weak self] in self?.window.close() }
        ))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        window.contentView = content
        window.center()
    }

    /// Shows the window in front of other apps and gives it the keyboard. A second call shows the same window.
    func show() {
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// "Choose files…": a file picker on the window, for more than one file.
    private func chooseFiles() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.allowedContentTypes = [.gif, .mpeg4Movie, .quickTimeMovie, .png, .jpeg, .heic, .heif]
        picker.prompt = "Add"
        picker.message = "Pick GIFs, MP4 or MOV videos, and memes."
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.model.add(picker.urls.map(AddSource.file)) }
        }
    }

    private func paste() {
        model.paste(from: NSPasteboard.general)
    }

    /// ⌘V adds the clipboard when it has a form of the list. Else, in the words box, it pastes the text.
    private func commandV() -> Bool {
        let board = NSPasteboard.general
        guard PasteReader.canRead(board) || !(window.firstResponder is NSTextView) else { return false }
        model.paste(from: board)
        return true
    }

    // MARK: NSWindowDelegate

    /// A close with rows that wait asks first, inside the window (D12).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.requestClose()
    }
}
