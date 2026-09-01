import Foundation

/// Port of `DatabaseUtilities.cpp` - creating and upgrading `Ditto.db`.
///
/// The schema is copied verbatim from Windows Ditto (`CreateDB`), including the
/// triggers and the index names, so a database written here can be opened by
/// Windows Ditto and vice versa. That is the whole point: the same file can
/// live in a synced folder and be used from either side.
enum DatabaseSchema {

    /// Ditto's marker for "this clip is not stuck to the top of the list".
    /// `#define INVALID_STICKY -(2147483647)` in Misc.h.
    static let invalidSticky: Double = -2_147_483_647

    static let createStatements: [String] = [
        "PRAGMA auto_vacuum = 1",

        """
        CREATE TABLE IF NOT EXISTS Main(
        lID INTEGER PRIMARY KEY AUTOINCREMENT,
        lDate INTEGER,
        mText TEXT,
        lShortCut INTEGER,
        lDontAutoDelete INTEGER,
        CRC INTEGER,
        bIsGroup INTEGER,
        lParentID INTEGER,
        QuickPasteText TEXT,
        clipOrder REAL,
        clipGroupOrder REAL,
        globalShortCut INTEGER,
        lastPasteDate INTEGER,
        stickyClipOrder REAL,
        stickyClipGroupOrder REAL,
        MoveToGroupShortCut INTEGER,
        GlobalMoveToGroupShortCut INTEGER);
        """,

        """
        CREATE TABLE IF NOT EXISTS Data(
        lID INTEGER PRIMARY KEY AUTOINCREMENT,
        lParentID INTEGER,
        strClipBoardFormat TEXT,
        ooData BLOB);
        """,

        """
        CREATE TABLE IF NOT EXISTS Types(
        lID INTEGER PRIMARY KEY AUTOINCREMENT,
        TypeText TEXT);
        """,

        """
        CREATE TABLE IF NOT EXISTS CopyBuffers(
        lID INTEGER PRIMARY KEY AUTOINCREMENT,
        lClipID INTEGER,
        lCopyBuffer INTEGER);
        """,

        """
        CREATE TABLE IF NOT EXISTS MainDeletes(
        clipID INTEGER,
        modifiedDate);
        """,

        // Deleting a clip only queues its data for removal; draining the queue
        // happens later, while the machine is idle. Copied from Ditto so both
        // implementations agree on what a half-deleted clip looks like.
        """
        CREATE TRIGGER IF NOT EXISTS delete_data_trigger BEFORE DELETE ON Main FOR EACH ROW
        BEGIN
        INSERT INTO MainDeletes VALUES(old.lID, datetime('now'));
        END
        """,

        """
        CREATE TRIGGER IF NOT EXISTS MainDeletes_delete_data_trigger BEFORE DELETE ON MainDeletes FOR EACH ROW
        BEGIN
        DELETE FROM CopyBuffers WHERE lClipID = old.clipID;
        DELETE FROM Data WHERE lParentID = old.clipID;
        END
        """,

        "CREATE UNIQUE INDEX IF NOT EXISTS Main_ID on Main(lID ASC)",
        "CREATE UNIQUE INDEX IF NOT EXISTS Data_ID on Data(lID ASC)",
        "CREATE INDEX IF NOT EXISTS Main_ClipOrder on Main(clipOrder DESC)",
        "CREATE INDEX IF NOT EXISTS Main_ClipGroupOrder on Main(clipGroupOrder DESC)",
        "CREATE INDEX IF NOT EXISTS Main_ParentId on Main(lParentID DESC)",
        "CREATE INDEX IF NOT EXISTS Main_IsGroup on Main(bIsGroup DESC)",
        "CREATE INDEX IF NOT EXISTS Data_ParentId_Format ON Data(lParentID COLLATE BINARY ASC, strClipBoardFormat COLLATE NOCASE ASC);",
        "CREATE INDEX IF NOT EXISTS Main_TopLevelParentID ON Main(lParentId ASC, stickyClipOrder DESC, bIsGroup ASC, clipOrder DESC);",
        "CREATE INDEX IF NOT EXISTS Main_TopLevel ON Main(stickyClipOrder DESC, bIsGroup ASC, clipOrder DESC);",
        "CREATE INDEX IF NOT EXISTS Main_InGroup2 ON Main(lParentId ASC, stickyClipGroupOrder DESC, bIsGroup ASC, clipGroupOrder DESC);",
        "CREATE INDEX IF NOT EXISTS Main_ShortCut2 on Main(lShortCut DESC, globalShortCut DESC)",
        "CREATE INDEX IF NOT EXISTS Main_MoveToGroup on Main(MoveToGroupShortCut DESC, GlobalMoveToGroupShortCut DESC)",
        "CREATE INDEX IF NOT EXISTS Main_CRC on Main(CRC ASC)"
    ]

    /// Columns Windows Ditto added over the years. A database created by an
    /// older Ditto is missing some of them, so add anything absent - this is
    /// the equivalent of `ValidateDB`'s version ladder.
    private static let expectedMainColumns: [(String, String)] = [
        ("QuickPasteText", "TEXT"),
        ("clipOrder", "REAL"),
        ("clipGroupOrder", "REAL"),
        ("globalShortCut", "INTEGER"),
        ("lastPasteDate", "INTEGER"),
        ("stickyClipOrder", "REAL"),
        ("stickyClipGroupOrder", "REAL"),
        ("MoveToGroupShortCut", "INTEGER"),
        ("GlobalMoveToGroupShortCut", "INTEGER")
    ]

    static func createOrUpgrade(_ db: SQLiteDatabase) throws {
        try db.executeScript(createStatements)

        for (column, type) in expectedMainColumns
        where db.columnExists(table: "Main", column: column) == false {
            Log.write("adding missing Main column \(column)")
            _ = try db.execute("ALTER TABLE Main ADD COLUMN \(column) \(type)")
        }

        // Rows written by very old versions have NULL ordering columns; the
        // list query sorts on them, so give them concrete values.
        _ = try db.execute("UPDATE Main SET clipOrder = lID WHERE clipOrder IS NULL")
        _ = try db.execute("UPDATE Main SET clipGroupOrder = lID WHERE clipGroupOrder IS NULL")
        _ = try db.execute(
            "UPDATE Main SET stickyClipOrder = \(invalidSticky) WHERE stickyClipOrder IS NULL")
        _ = try db.execute(
            "UPDATE Main SET stickyClipGroupOrder = \(invalidSticky) WHERE stickyClipGroupOrder IS NULL")
        _ = try db.execute("UPDATE Main SET lastPasteDate = lDate WHERE lastPasteDate IS NULL")
        _ = try db.execute("UPDATE Main SET lDontAutoDelete = 0 WHERE lDontAutoDelete IS NULL")
        _ = try db.execute("UPDATE Main SET lShortCut = 0 WHERE lShortCut IS NULL")
        _ = try db.execute("UPDATE Main SET bIsGroup = 0 WHERE bIsGroup IS NULL")
        _ = try db.execute("UPDATE Main SET lParentID = -1 WHERE lParentID IS NULL")
    }

    /// `CompactDatabase` - VACUUM, which auto_vacuum alone does not fully do.
    static func compact(_ db: SQLiteDatabase) throws {
        _ = try db.execute("VACUUM")
    }
}
