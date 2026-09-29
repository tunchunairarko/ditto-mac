import Foundation
import XCTest
@testable import DittoKit

/// The auto-delete rules, ported from `RemoveOldEntries`. The exemptions matter
/// more than the deletions: a clip the user has starred, stuck, filed in a group
/// or given a shortcut must never be removed behind their back.
final class MaintenanceTests: DittoTestCase {

    private var repository: ClipRepository { return ClipRepository.shared }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Start from neither rule on; each test turns on the one it is about.
        environment.options.checkForMaxEntries = false
        environment.options.checkForExpiredEntries = false
    }

    // MARK: - Too many clips

    func testKeepsOnlyTheNewestClipsWhenAskedTo() throws {
        environment.options.checkForMaxEntries = true
        environment.options.maxEntries = 2

        for text in ["one", "two", "three", "four", "five"] {
            _ = try environment.addTextClip(text)
        }

        Maintenance.removeOldEntries(checkIdleTime: false)

        let remaining = try repository.list(ClipRepository.ListRequest()).map { $0.desc }
        XCTAssertEqual(remaining, ["five", "four"])
    }

    func testAStarredClipSurvivesTheLimit() throws {
        environment.options.checkForMaxEntries = true
        environment.options.maxEntries = 2

        let starred = try environment.addTextClip("starred")
        for text in ["two", "three", "four", "five"] {
            _ = try environment.addTextClip(text)
        }
        try repository.setStarred(ids: [starred], starred: true)

        Maintenance.removeOldEntries(checkIdleTime: false)

        XCTAssertNotNil(try repository.loadClip(id: starred),
                        "a starred clip is never deleted automatically")
        XCTAssertEqual(try repository.clipCount(), 3, "the two newest, plus the starred one")
    }

    func testAStuckClipSurvivesTheLimit() throws {
        environment.options.checkForMaxEntries = true
        environment.options.maxEntries = 1

        let stuck = try environment.addTextClip("stuck")
        _ = try environment.addTextClip("two")
        _ = try environment.addTextClip("three")
        try repository.setSticky(ids: [stuck], position: .top, inGroup: -1)

        Maintenance.removeOldEntries(checkIdleTime: false)

        XCTAssertNotNil(try repository.loadClip(id: stuck))
    }

    func testAClipInAGroupSurvivesTheLimit() throws {
        environment.options.checkForMaxEntries = true
        environment.options.maxEntries = 1

        let group = try repository.createGroup(named: "Kept")
        let filed = try environment.addTextClip("filed away")
        _ = try environment.addTextClip("two")
        _ = try environment.addTextClip("three")
        try repository.move(ids: [filed], toGroup: group)

        Maintenance.removeOldEntries(checkIdleTime: false)

        XCTAssertNotNil(try repository.loadClip(id: filed))
    }

    func testAClipWithItsOwnShortcutSurvivesTheLimit() throws {
        environment.options.checkForMaxEntries = true
        environment.options.maxEntries = 1

        let shortcut = try environment.addTextClip("has a shortcut")
        _ = try environment.addTextClip("two")
        _ = try environment.addTextClip("three")

        let hotKey = try XCTUnwrap(HotKey(string: "ctrl+alt+9"))
        try repository.setShortcut(id: shortcut, shortcut: hotKey.packed, global: true)

        Maintenance.removeOldEntries(checkIdleTime: false)

        XCTAssertNotNil(try repository.loadClip(id: shortcut))
    }

    func testNothingIsDeletedWhenTheLimitIsOff() throws {
        environment.options.checkForMaxEntries = false
        environment.options.maxEntries = 1

        for text in ["one", "two", "three"] {
            _ = try environment.addTextClip(text)
        }

        Maintenance.removeOldEntries(checkIdleTime: false)

        XCTAssertEqual(try repository.clipCount(), 3)
    }

    // MARK: - Clips nobody has pasted

    func testRemovesClipsNobodyHasPastedInAWhile() throws {
        environment.options.checkForExpiredEntries = true
        environment.options.expiredEntries = 5

        let stale = try environment.addTextClip("stale")
        let starred = try environment.addTextClip("stale but starred")
        let fresh = try environment.addTextClip("pasted just now")

        try repository.setStarred(ids: [starred], starred: true)

        let longAgo = Int(Date().addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970)
        for id in [stale, starred] {
            _ = try environment.database.execute(
                "UPDATE Main SET lastPasteDate = ? WHERE lID = ?", [longAgo, id])
        }

        Maintenance.removeOldEntries(checkIdleTime: false)

        XCTAssertNil(try repository.loadClip(id: stale))
        XCTAssertNotNil(try repository.loadClip(id: starred),
                        "a starred clip never expires")
        XCTAssertNotNil(try repository.loadClip(id: fresh))
    }

    // MARK: - Draining the delete queue

    /// Deleting queues the payload; the maintenance pass is what finally clears
    /// it, and only once the machine has been idle - hence `checkIdleTime`.
    func testTheMaintenancePassDrainsTheDeleteQueue() throws {
        let id = try environment.addTextClip("to be removed")
        try repository.delete(ids: [id])

        XCTAssertEqual(try environment.count("SELECT COUNT(*) FROM MainDeletes"), 1)
        XCTAssertEqual(try environment.count("SELECT COUNT(*) FROM Data WHERE lParentID = \(id)"), 2)

        Maintenance.removeOldEntries(checkIdleTime: false)

        XCTAssertEqual(try environment.count("SELECT COUNT(*) FROM MainDeletes"), 0)
        XCTAssertEqual(try environment.count("SELECT COUNT(*) FROM Data WHERE lParentID = \(id)"), 0)
    }

    func testCompactingLeavesTheDatabaseUsable() throws {
        _ = try environment.addTextClip("still here afterwards")

        try Maintenance.compact()

        XCTAssertEqual(try repository.clipCount(), 1)
        XCTAssertEqual(try repository.list(ClipRepository.ListRequest()).first?.desc,
                       "still here afterwards")
    }
}
