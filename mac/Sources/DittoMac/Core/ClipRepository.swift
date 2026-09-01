import Foundation
import AppKit

extension Notification.Name {
    /// Posted after anything changes the clip list, so open windows refresh.
    /// Windows Ditto broadcasts WM_UPDATE_LIST for the same reason.
    static let dittoClipsChanged = Notification.Name("io.ditto.clipsChanged")
}

/// Every database operation Ditto performs on clips, gathered in one place.
/// This is the port of `Clip.cpp`'s static helpers, `ClipIds.cpp`,
/// `MainTableFunctions.cpp` and the query building in `QPasteWnd.cpp`.
final class ClipRepository {

    static let shared = ClipRepository()

    private(set) var database: SQLiteDatabase?
    private let openLock = NSLock()

    /// Ditto's `m_LastAddedCRC` short-circuit: the same copy arriving twice in
    /// a row is very common and does not need a query.
    private var lastAddedCRC: UInt32 = 0
    private var lastAddedID: Int = 0

    private init() {}

    // MARK: - Opening

    @discardableResult
    func open(at url: URL? = nil) throws -> SQLiteDatabase {
        openLock.lock()
        defer { openLock.unlock() }

        let target = url ?? Options.shared.databaseURL
        if let existing = database, existing.url == target { return existing }

        database?.close()
        Paths.ensureDirectory(target.deletingLastPathComponent())

        let db = try SQLiteDatabase(url: target)
        try DatabaseSchema.createOrUpgrade(db)
        db.registerSearchFunctions()
        database = db
        Log.write("opened database at \(target.path)")
        return db
    }

    private func requireDatabase() throws -> SQLiteDatabase {
        if let db = database { return db }
        return try open()
    }

    func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .dittoClipsChanged, object: nil)
        }
    }

    // MARK: - Ordering (Clip.cpp: GetNewOrder / GetNewLastOrder)

    /// The order value that puts a clip at the top of the list.
    private func newTopOrder(parentID: Int) throws -> Double {
        let db = try requireDatabase()
        if parentID < 0 {
            let max = try db.scalarDouble(
                "SELECT clipOrder FROM Main ORDER BY clipOrder DESC LIMIT 1")
            return (max ?? 0) + 1
        }
        let max = try db.scalarDouble(
            "SELECT clipGroupOrder FROM Main WHERE lParentID = ? ORDER BY clipGroupOrder DESC LIMIT 1",
            [parentID])
        return (max ?? 0) + 1
    }

    /// The order value that puts a clip at the bottom of the list.
    private func newLastOrder(parentID: Int) throws -> Double {
        let db = try requireDatabase()
        if parentID < 0 {
            let min = try db.scalarDouble(
                "SELECT clipOrder FROM Main WHERE clipOrder NOT NULL ORDER BY clipOrder ASC LIMIT 1")
            return (min ?? 0) - 1
        }
        let min = try db.scalarDouble(
            "SELECT clipGroupOrder FROM Main WHERE lParentID = ? AND clipGroupOrder NOT NULL ORDER BY clipGroupOrder ASC LIMIT 1",
            [parentID])
        return (min ?? 0) - 1
    }

    private func newTopStickyOrder(parentID: Int) throws -> Double {
        let db = try requireDatabase()
        let column = parentID < 0 ? "stickyClipOrder" : "stickyClipGroupOrder"
        let sql = parentID < 0
            ? "SELECT \(column) FROM Main ORDER BY \(column) DESC LIMIT 1"
            : "SELECT \(column) FROM Main WHERE lParentID = \(parentID) ORDER BY \(column) DESC LIMIT 1"
        let max = try db.scalarDouble(sql)
        guard let value = max, value != DatabaseSchema.invalidSticky else { return 1 }
        return value + 1
    }

    private func newLastStickyOrder(parentID: Int) throws -> Double {
        let db = try requireDatabase()
        let column = parentID < 0 ? "stickyClipOrder" : "stickyClipGroupOrder"
        let sql = parentID < 0
            ? "SELECT \(column) FROM Main WHERE \(column) != \(DatabaseSchema.invalidSticky) ORDER BY \(column) ASC LIMIT 1"
            : "SELECT \(column) FROM Main WHERE lParentID = \(parentID) AND \(column) != \(DatabaseSchema.invalidSticky) ORDER BY \(column) ASC LIMIT 1"
        let min = try db.scalarDouble(sql)
        guard let value = min else { return 1 }
        return value - 1
    }

    // MARK: - Adding (Clip.cpp: AddToDB)

    enum AddResult {
        case added(Int)
        /// The copy matched an existing clip, which was moved back to the top.
        case duplicate(Int)
        case skipped
    }

    @discardableResult
    func add(_ clip: Clip, checkDuplicates: Bool = true) throws -> AddResult {
        guard clip.formats.isEmpty == false || clip.isGroup else { return .skipped }

        let db = try requireDatabase()
        clip.crc = clip.computeCRC()

        if checkDuplicates && Options.shared.allowDuplicates == false && clip.isGroup == false {
            if let existing = try findDuplicate(crc: clip.crc) {
                let order = try newTopOrder(parentID: -1)
                _ = try db.execute(
                    "UPDATE Main SET clipOrder = ?, lDate = ? WHERE lID = ?",
                    [order, Int(Date().timeIntervalSince1970), existing])
                Log.write("copy matched existing clip \(existing); moved it to the top")
                lastAddedCRC = clip.crc
                lastAddedID = existing
                notifyChanged()
                return .duplicate(existing)
            }
        }

        if clip.desc.isEmpty { clip.generateDescription() }

        clip.clipOrder = try newTopOrder(parentID: -1)
        clip.clipGroupOrder = clip.parentID >= 0
            ? try newTopOrder(parentID: clip.parentID)
            : 0

        let id: Int = try db.transaction {
            _ = try db.execute("""
                INSERT INTO Main (lDate, mText, lShortCut, lDontAutoDelete, CRC, bIsGroup,
                lParentID, QuickPasteText, clipOrder, clipGroupOrder, globalShortCut,
                lastPasteDate, stickyClipOrder, stickyClipGroupOrder, MoveToGroupShortCut,
                GlobalMoveToGroupShortCut)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                [Int(clip.date.timeIntervalSince1970),
                 clip.desc,
                 clip.shortcut,
                 clip.dontAutoDelete,
                 Int(clip.crc),
                 clip.isGroup ? 1 : 0,
                 clip.parentID,
                 clip.quickPasteText,
                 clip.clipOrder,
                 clip.clipGroupOrder,
                 clip.globalShortcut ? 1 : 0,
                 Int(clip.lastPasteDate.timeIntervalSince1970),
                 clip.stickyClipOrder,
                 clip.stickyClipGroupOrder,
                 clip.moveToGroupShortcut,
                 clip.globalMoveToGroupShortcut ? 1 : 0])

            let newID = db.lastInsertRowID
            for format in clip.formats {
                _ = try db.execute(
                    "INSERT INTO Data (lParentID, strClipBoardFormat, ooData) VALUES (?,?,?)",
                    [newID, format.format, format.bytes])
            }
            return newID
        }

        clip.id = id
        lastAddedCRC = clip.crc
        lastAddedID = id
        Log.write("added clip \(id): \(clip.desc.prefix(60))")
        notifyChanged()
        return .added(id)
    }

    /// Port of `CClip::FindDuplicate`.
    private func findDuplicate(crc: UInt32) throws -> Int? {
        if crc == lastAddedCRC && lastAddedID > 0 {
            // Confirm the row is still there before trusting the cache.
            let db = try requireDatabase()
            if let found = try db.scalarInt("SELECT lID FROM Main WHERE lID = ?", [lastAddedID]),
               found == lastAddedID {
                return lastAddedID
            }
        }
        let db = try requireDatabase()
        return try db.scalarInt("SELECT lID FROM Main WHERE CRC = ? LIMIT 1", [Int(crc)])
    }

    // MARK: - Listing (QPasteWnd.cpp: FillList)

    struct ListRequest {
        var search: String = ""
        /// -1 is the main list; anything else is that group's contents.
        var groupID: Int = -1
        /// The SHOW_STARRED_CLIPS view.
        var starredOnly: Bool = false
        var limit: Int = 400
        var offset: Int = 0
    }

    /// Build the same filter and sort Windows Ditto builds.
    private func filterAndSort(_ request: ListRequest) -> (filter: String,
                                                           sort: String,
                                                           join: String,
                                                           distinct: String) {
        let starredFilter = "Main.bIsGroup = 0 AND Main.lDontAutoDelete > 0"
        var filter: String
        let sort: String

        if request.starredOnly {
            sort = "Main.stickyClipOrder DESC, Main.bIsGroup ASC, Main.clipOrder DESC"
            filter = "(\(starredFilter))"
        } else if request.groupID < 0 {
            sort = "Main.stickyClipOrder DESC, Main.bIsGroup ASC, Main.clipOrder DESC"
            if Options.shared.showAllClipsInMainList {
                if Options.shared.showGroupsInMainList {
                    filter = "((Main.bIsGroup = 1 AND Main.lParentID = -1) OR Main.bIsGroup = 0)"
                } else {
                    filter = "(Main.bIsGroup = 0)"
                }
            } else {
                filter = "((Main.bIsGroup = 1 AND Main.lParentID = -1) OR (Main.bIsGroup = 0 AND Main.lParentID = -1))"
            }
        } else {
            sort = "Main.stickyClipGroupOrder DESC, Main.bIsGroup ASC, Main.clipGroupOrder DESC"
            filter = "(Main.lParentID = \(request.groupID))"
        }

        var join = ""
        var distinct = ""

        let query = SearchQuery(request.search)
        if let searchClause = query.whereClause() {
            filter = "\(filter) AND \(searchClause)"
            if query.needsDataJoin {
                join = "INNER JOIN Data on Data.lParentID = Main.lID"
                distinct = "DISTINCT"
            }
        }

        return (filter, sort, join, distinct)
    }

    func list(_ request: ListRequest) throws -> [ClipListItem] {
        let db = try requireDatabase()
        let parts = filterAndSort(request)

        let sql = """
            SELECT \(parts.distinct) Main.lID, Main.mText, Main.lParentID, Main.lDontAutoDelete,
            Main.lShortCut, Main.bIsGroup, Main.QuickPasteText, Main.clipOrder,
            Main.clipGroupOrder, Main.stickyClipOrder, Main.stickyClipGroupOrder,
            Main.lDate, Main.lastPasteDate
            FROM Main \(parts.join)
            WHERE \(parts.filter)
            ORDER BY \(parts.sort)
            LIMIT \(request.limit) OFFSET \(request.offset)
            """

        var items: [ClipListItem] = []
        items.reserveCapacity(min(request.limit, 512))
        try db.query(sql) { row in
            items.append(ClipListItem(row: row))
        }
        return items
    }

    func count(_ request: ListRequest) throws -> Int {
        let db = try requireDatabase()
        let parts = filterAndSort(request)
        let sql = "SELECT COUNT(\(parts.distinct) Main.lID) FROM Main \(parts.join) WHERE \(parts.filter)"
        return (try db.scalarInt(sql)) ?? 0
    }

    // MARK: - Loading one clip

    func loadFormats(clipID: Int) throws -> [ClipFormatData] {
        let db = try requireDatabase()
        var formats: [ClipFormatData] = []
        try db.query(
            "SELECT strClipBoardFormat, ooData FROM Data WHERE lParentID = ?",
            [clipID]) { row in
                formats.append(ClipFormatData(row.string("strClipBoardFormat"),
                                              row.data("ooData")))
            }
        return formats
    }

    func formatNames(clipID: Int) throws -> [String] {
        let db = try requireDatabase()
        var names: [String] = []
        try db.query(
            "SELECT strClipBoardFormat FROM Data WHERE lParentID = ?",
            [clipID]) { row in
                names.append(row.string("strClipBoardFormat"))
            }
        return names
    }

    /// Read a single format without pulling the whole clip into memory - what
    /// the list needs for a thumbnail or a tooltip.
    func loadFormat(clipID: Int, format: String) throws -> Data? {
        let db = try requireDatabase()
        var bytes: Data?
        try db.query(
            "SELECT ooData FROM Data WHERE lParentID = ? AND strClipBoardFormat = ? LIMIT 1",
            [clipID, format]) { row in
                bytes = row.data("ooData")
            }
        return bytes
    }

    func loadClip(id: Int) throws -> Clip? {
        let db = try requireDatabase()
        var clip: Clip?

        try db.query("SELECT * FROM Main WHERE lID = ?", [id]) { row in
            let loaded = Clip()
            loaded.id = row.int("lID")
            loaded.date = Date(timeIntervalSince1970: TimeInterval(row.int("lDate")))
            loaded.lastPasteDate = Date(timeIntervalSince1970: TimeInterval(row.int("lastPasteDate")))
            loaded.desc = row.string("mText")
            loaded.shortcut = row.int("lShortCut")
            loaded.globalShortcut = row.int("globalShortCut") != 0
            loaded.dontAutoDelete = row.int("lDontAutoDelete")
            loaded.crc = UInt32(truncatingIfNeeded: row.int("CRC"))
            loaded.isGroup = row.int("bIsGroup") != 0
            loaded.parentID = row.int("lParentID", -1)
            loaded.quickPasteText = row.string("QuickPasteText")
            loaded.clipOrder = row.double("clipOrder")
            loaded.clipGroupOrder = row.double("clipGroupOrder")
            loaded.stickyClipOrder = row.double("stickyClipOrder", DatabaseSchema.invalidSticky)
            loaded.stickyClipGroupOrder = row.double("stickyClipGroupOrder", DatabaseSchema.invalidSticky)
            loaded.moveToGroupShortcut = row.int("MoveToGroupShortCut")
            loaded.globalMoveToGroupShortcut = row.int("GlobalMoveToGroupShortCut") != 0
            clip = loaded
        }

        guard let clip = clip else { return nil }
        clip.formats = try loadFormats(clipID: clip.id)
        return clip
    }

    /// The clip sitting at 1-based `position` in the main list, for the global
    /// "paste position N" hot keys.
    func clip(atPosition position: Int, groupID: Int = -1) throws -> Int? {
        guard position >= 1 else { return nil }
        var request = ListRequest()
        request.groupID = groupID
        request.limit = 1
        request.offset = position - 1
        return try list(request).first?.id
    }

    // MARK: - Paste bookkeeping (Clip.cpp: MarkAsPasted)

    func markAsPasted(ids: [Int], updateClipOrder: Bool, fromGroup: Bool) {
        guard ids.isEmpty == false else { return }
        do {
            let db = try requireDatabase()
            let now = Int(Date().timeIntervalSince1970)

            for id in ids {
                _ = try db.execute("UPDATE Main SET lastPasteDate = ? WHERE lID = ?", [now, id])

                guard updateClipOrder, Options.shared.updateTimeOnPaste else { continue }

                // Pasting moves a clip back to the top of whichever list it
                // was pasted from, unless it is stuck in place.
                if fromGroup {
                    let parentID = try db.scalarInt(
                        "SELECT lParentID FROM Main WHERE lID = ?", [id]) ?? -1
                    if parentID >= 0 {
                        let order = try newTopOrder(parentID: parentID)
                        _ = try db.execute(
                            "UPDATE Main SET clipGroupOrder = ? WHERE lID = ? AND stickyClipGroupOrder = ?",
                            [order, id, DatabaseSchema.invalidSticky])
                    }
                }

                let order = try newTopOrder(parentID: -1)
                _ = try db.execute(
                    "UPDATE Main SET clipOrder = ? WHERE lID = ? AND stickyClipOrder = ?",
                    [order, id, DatabaseSchema.invalidSticky])
            }

            Options.shared.recordPaste()
            notifyChanged()
        } catch {
            Log.error("markAsPasted failed: \(error)")
        }
    }

    // MARK: - Editing

    func setDescription(id: Int, text: String) throws {
        let db = try requireDatabase()
        _ = try db.execute("UPDATE Main SET mText = ? WHERE lID = ?", [text, id])
        notifyChanged()
    }

    func setQuickPasteText(id: Int, text: String) throws {
        let db = try requireDatabase()
        _ = try db.execute("UPDATE Main SET QuickPasteText = ? WHERE lID = ?", [text, id])
        notifyChanged()
    }

    /// Replace a clip's text, as the clip editor does. Everything else the
    /// clip carried (RTF, HTML, images) is dropped, because it no longer
    /// matches - the same thing Windows Ditto's editor does.
    func replaceText(id: Int, text: String) throws {
        let db = try requireDatabase()
        try db.transaction {
            _ = try db.execute("DELETE FROM Data WHERE lParentID = ?", [id])
            _ = try db.execute(
                "INSERT INTO Data (lParentID, strClipBoardFormat, ooData) VALUES (?,?,?)",
                [id, ClipFormat.unicodeText, ClipFormat.encodeUnicodeText(text)])
            _ = try db.execute(
                "INSERT INTO Data (lParentID, strClipBoardFormat, ooData) VALUES (?,?,?)",
                [id, ClipFormat.text, ClipFormat.encodeText(text)])
        }

        let clip = Clip()
        clip.formats = try loadFormats(clipID: id)
        clip.generateDescription()
        _ = try db.execute("UPDATE Main SET mText = ?, CRC = ? WHERE lID = ?",
                           [clip.desc, Int(clip.computeCRC()), id])
        notifyChanged()
    }

    func setStarred(ids: [Int], starred: Bool) throws {
        guard ids.isEmpty == false else { return }
        let db = try requireDatabase()
        for id in ids {
            _ = try db.execute("UPDATE Main SET lDontAutoDelete = ? WHERE lID = ?",
                               [starred ? 1 : 0, id])
        }
        notifyChanged()
    }

    func setShortcut(id: Int, shortcut: Int, global: Bool) throws {
        let db = try requireDatabase()
        _ = try db.execute("UPDATE Main SET lShortCut = ?, globalShortCut = ? WHERE lID = ?",
                           [shortcut, global ? 1 : 0, id])
        notifyChanged()
    }

    /// Every clip that carries a global accelerator, for `HotKeyManager`.
    func clipsWithGlobalShortcuts() throws -> [(id: Int, shortcut: Int, desc: String)] {
        let db = try requireDatabase()
        var result: [(id: Int, shortcut: Int, desc: String)] = []
        try db.query(
            "SELECT lID, lShortCut, mText FROM Main WHERE lShortCut > 0 AND globalShortCut > 0") { row in
                result.append((row.int("lID"), row.int("lShortCut"), row.string("mText")))
            }
        return result
    }

    // MARK: - Ordering actions

    func moveToTop(ids: [Int], inGroup groupID: Int) throws {
        let db = try requireDatabase()
        for id in ids {
            if groupID < 0 {
                let order = try newTopOrder(parentID: -1)
                _ = try db.execute("UPDATE Main SET clipOrder = ? WHERE lID = ?", [order, id])
            } else {
                let order = try newTopOrder(parentID: groupID)
                _ = try db.execute("UPDATE Main SET clipGroupOrder = ? WHERE lID = ?", [order, id])
            }
        }
        notifyChanged()
    }

    func moveToLast(ids: [Int], inGroup groupID: Int) throws {
        let db = try requireDatabase()
        for id in ids {
            if groupID < 0 {
                let order = try newLastOrder(parentID: -1)
                _ = try db.execute("UPDATE Main SET clipOrder = ? WHERE lID = ?", [order, id])
            } else {
                let order = try newLastOrder(parentID: groupID)
                _ = try db.execute("UPDATE Main SET clipGroupOrder = ? WHERE lID = ?", [order, id])
            }
        }
        notifyChanged()
    }

    /// MAKE_TOP_STICKY / MAKE_LAST_STICKY / REMOVE_STICKY.
    func setSticky(ids: [Int], position: StickyPosition, inGroup groupID: Int) throws {
        let db = try requireDatabase()
        let column = groupID < 0 ? "stickyClipOrder" : "stickyClipGroupOrder"

        for id in ids {
            let value: Double
            switch position {
            case .top:
                value = try newTopStickyOrder(parentID: groupID)
            case .last:
                value = try newLastStickyOrder(parentID: groupID)
            case .none:
                value = DatabaseSchema.invalidSticky
            }
            _ = try db.execute("UPDATE Main SET \(column) = ? WHERE lID = ?", [value, id])
        }
        notifyChanged()
    }

    enum StickyPosition {
        case top
        case last
        case none
    }

    // MARK: - Groups

    /// Create a group. Groups are ordinary `Main` rows with `bIsGroup = 1`.
    @discardableResult
    func createGroup(named name: String, parentID: Int = -1) throws -> Int {
        let clip = Clip()
        clip.isGroup = true
        clip.desc = name
        clip.parentID = parentID
        clip.date = Date()
        clip.lastPasteDate = Date()
        switch try add(clip, checkDuplicates: false) {
        case .added(let id): return id
        case .duplicate(let id): return id
        case .skipped: return 0
        }
    }

    func groups() throws -> [ClipListItem] {
        let db = try requireDatabase()
        var items: [ClipListItem] = []
        try db.query("""
            SELECT lID, mText, lParentID, lDontAutoDelete, lShortCut, bIsGroup,
            QuickPasteText, clipOrder, clipGroupOrder, stickyClipOrder,
            stickyClipGroupOrder, lDate, lastPasteDate
            FROM Main WHERE bIsGroup = 1 ORDER BY mText COLLATE NOCASE ASC
            """) { row in
                items.append(ClipListItem(row: row))
            }
        return items
    }

    func groupName(id: Int) throws -> String? {
        guard id >= 0 else { return nil }
        let db = try requireDatabase()
        return try db.scalarString("SELECT mText FROM Main WHERE lID = ? AND bIsGroup = 1", [id])
    }

    func parentGroup(of groupID: Int) throws -> Int {
        guard groupID >= 0 else { return -1 }
        let db = try requireDatabase()
        return try db.scalarInt("SELECT lParentID FROM Main WHERE lID = ?", [groupID]) ?? -1
    }

    func move(ids: [Int], toGroup groupID: Int) throws {
        guard ids.isEmpty == false else { return }
        let db = try requireDatabase()
        for id in ids {
            guard id != groupID else { continue }
            let order = try newTopOrder(parentID: groupID)
            _ = try db.execute(
                "UPDATE Main SET lParentID = ?, clipGroupOrder = ? WHERE lID = ?",
                [groupID, order, id])
        }
        notifyChanged()
    }

    // MARK: - Deleting (ClipIds.cpp: DeleteIDs)

    /// Deleting only removes the `Main` row; the trigger queues the data for
    /// removal later, which is what keeps deleting a big selection quick.
    func delete(ids: [Int]) throws {
        guard ids.isEmpty == false else { return }
        let db = try requireDatabase()
        try db.transaction {
            for id in ids {
                // A group takes its children with it.
                _ = try db.execute("DELETE FROM Main WHERE lID = ? OR lParentID = ?", [id, id])
            }
        }
        Log.write("deleted clips \(ids)")
        notifyChanged()
    }

    /// DELETE_CLIP_DATA - keep the row, throw away the payload.
    func deleteData(ids: [Int]) throws {
        guard ids.isEmpty == false else { return }
        let db = try requireDatabase()
        try db.transaction {
            for id in ids {
                _ = try db.execute("DELETE FROM Data WHERE lParentID = ?", [id])
            }
        }
        notifyChanged()
    }

    func deleteAllNonUsedClips() throws {
        let db = try requireDatabase()
        _ = try db.execute("""
            DELETE FROM Main WHERE bIsGroup = 0 AND lShortCut = 0 AND lDontAutoDelete = 0
            AND lParentID <= 0 AND stickyClipOrder = \(DatabaseSchema.invalidSticky)
            AND stickyClipGroupOrder = \(DatabaseSchema.invalidSticky)
            """)
        notifyChanged()
    }

    // MARK: - Copy buffers (OptionsCopyBuffers.cpp)

    func setCopyBuffer(_ buffer: Int, clipID: Int) throws {
        let db = try requireDatabase()
        try db.transaction {
            _ = try db.execute("DELETE FROM CopyBuffers WHERE lCopyBuffer = ?", [buffer])
            _ = try db.execute(
                "INSERT INTO CopyBuffers (lClipID, lCopyBuffer) VALUES (?, ?)",
                [clipID, buffer])
        }
    }

    func copyBufferClipID(_ buffer: Int) throws -> Int? {
        let db = try requireDatabase()
        return try db.scalarInt(
            "SELECT lClipID FROM CopyBuffers WHERE lCopyBuffer = ? ORDER BY lID DESC LIMIT 1",
            [buffer])
    }

    // MARK: - Statistics

    func clipCount() throws -> Int {
        let db = try requireDatabase()
        return (try db.scalarInt("SELECT COUNT(*) FROM Main WHERE bIsGroup = 0")) ?? 0
    }

    func databaseSizeInBytes() -> Int {
        guard let url = database?.url else { return 0 }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int) ?? 0
    }
}
