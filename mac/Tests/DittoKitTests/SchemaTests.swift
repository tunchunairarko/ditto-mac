import Foundation
import XCTest
@testable import DittoKit

/// The database is the port's compatibility contract: a `Ditto.db` written here
/// has to be one Windows Ditto can open, and vice versa. These assertions are
/// taken from `DatabaseUtilities.cpp`'s `CreateDB` and are the reason this test
/// target exists - they used to be a shell script that launched the app.
final class SchemaTests: DittoTestCase {

    func testCreatesEveryTable() throws {
        for table in ["Main", "Data", "Types", "CopyBuffers", "MainDeletes"] {
            XCTAssertTrue(try environment.objectExists(type: "table", name: table),
                          "the \(table) table is missing")
        }
    }

    func testCreatesBothTriggers() throws {
        for trigger in ["delete_data_trigger", "MainDeletes_delete_data_trigger"] {
            XCTAssertTrue(try environment.objectExists(type: "trigger", name: trigger),
                          "the \(trigger) trigger is missing")
        }
    }

    /// Every column Windows Ditto's Main table has, and no invented ones.
    func testMainColumnsMatchWindowsDitto() throws {
        let expected: Set<String> = [
            "lID", "lDate", "mText", "lShortCut", "lDontAutoDelete", "CRC",
            "bIsGroup", "lParentID", "QuickPasteText", "clipOrder",
            "clipGroupOrder", "globalShortCut", "lastPasteDate",
            "stickyClipOrder", "stickyClipGroupOrder", "MoveToGroupShortCut",
            "GlobalMoveToGroupShortCut"
        ]
        XCTAssertEqual(try environment.columnNames(ofTable: "Main"), expected)
    }

    func testDataColumnsMatchWindowsDitto() throws {
        XCTAssertEqual(try environment.columnNames(ofTable: "Data"),
                       ["lID", "lParentID", "strClipBoardFormat", "ooData"])
    }

    func testTypesAndCopyBuffersColumnsMatchWindowsDitto() throws {
        XCTAssertEqual(try environment.columnNames(ofTable: "Types"),
                       ["lID", "TypeText"])
        XCTAssertEqual(try environment.columnNames(ofTable: "CopyBuffers"),
                       ["lID", "lClipID", "lCopyBuffer"])
    }

    func testCreatesTheIndexesTheListQueriesSortOn() throws {
        for index in ["Main_TopLevel", "Main_TopLevelParentID", "Main_InGroup2",
                      "Main_CRC", "Data_ParentId_Format"] {
            XCTAssertTrue(try environment.objectExists(type: "index", name: index),
                          "the \(index) index is missing")
        }
    }

    /// Deleting a clip must only remove the Main row and queue the rest, which
    /// is what keeps deleting a large selection quick on both platforms.
    func testDeletingAClipQueuesItsDataRatherThanRemovingIt() throws {
        let id = try environment.addTextClip("something to delete")
        XCTAssertEqual(try environment.count("SELECT COUNT(*) FROM Data WHERE lParentID = \(id)"), 2)

        try ClipRepository.shared.delete(ids: [id])

        XCTAssertEqual(try environment.count("SELECT COUNT(*) FROM Main WHERE lID = \(id)"), 0,
                       "the clip should be gone from Main")
        XCTAssertEqual(try environment.count("SELECT COUNT(*) FROM MainDeletes WHERE clipID = \(id)"), 1,
                       "the delete trigger should have queued the clip")
        XCTAssertEqual(try environment.count("SELECT COUNT(*) FROM Data WHERE lParentID = \(id)"), 2,
                       "the data should still be there until the queue is drained")

        // Draining the queue is what finally removes the payload.
        _ = try environment.database.execute("DELETE FROM MainDeletes WHERE clipID = ?", [id])

        XCTAssertEqual(try environment.count("SELECT COUNT(*) FROM Data WHERE lParentID = \(id)"), 0,
                       "draining MainDeletes should have removed the data rows")
    }

    /// A database from an older Ditto is missing columns added over the years;
    /// opening it has to add them rather than fail.
    func testUpgradesADatabaseMissingLaterColumns() throws {
        let older = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests", isDirectory: true)
            .appendingPathComponent("older-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: older) }

        // The Main table as it was before the ordering and sticky columns.
        let legacy = try SQLiteDatabase(url: older)
        _ = try legacy.execute("""
            CREATE TABLE Main(
            lID INTEGER PRIMARY KEY AUTOINCREMENT, lDate INTEGER, mText TEXT,
            lShortCut INTEGER, lDontAutoDelete INTEGER, CRC INTEGER,
            bIsGroup INTEGER, lParentID INTEGER);
            """)
        _ = try legacy.execute(
            "INSERT INTO Main (lDate, mText, lParentID) VALUES (1, 'an old clip', -1)")
        legacy.close()

        let upgrading = try SQLiteDatabase(url: older)
        try DatabaseSchema.createOrUpgrade(upgrading)
        upgrading.close()

        let upgraded = try SQLiteDatabase(url: older)
        var columns: Set<String> = []
        try upgraded.query("PRAGMA table_info(Main)") { row in
            columns.insert(row.string("name"))
        }
        XCTAssertTrue(columns.contains("stickyClipOrder"))
        XCTAssertTrue(columns.contains("clipOrder"))
        XCTAssertTrue(columns.contains("lastPasteDate"))

        // The upgrade also has to give the old row usable ordering values,
        // because the list query sorts on them.
        let sticky = try upgraded.scalarDouble("SELECT stickyClipOrder FROM Main LIMIT 1")
        XCTAssertEqual(sticky, DatabaseSchema.invalidSticky)
        XCTAssertNotNil(try upgraded.scalarDouble("SELECT clipOrder FROM Main LIMIT 1"))
        upgraded.close()
    }
}
