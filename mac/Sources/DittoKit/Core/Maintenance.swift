import Foundation
import CoreGraphics

/// Port of `RemoveOldEntries` and friends (DatabaseUtilities.cpp).
///
/// Ditto trims the database in the background: too many clips, clips nobody has
/// pasted in a while, and the queue of data rows left behind by deletes. Clips
/// that are starred, in a group, stuck to the top, or carry a shortcut are
/// never touched - the same exemptions Windows Ditto applies.
enum Maintenance {

    /// Seconds the machine has been idle, for the "only delete while idle"
    /// rule. `IdleSeconds()` on Windows.
    static func idleSeconds() -> Double {
        let anyEvent = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyEvent)
    }

    /// Run one maintenance pass. Safe to call often; it does nothing when the
    /// relevant options are off.
    static func removeOldEntries(checkIdleTime: Bool = true) {
        let options = Options.shared
        Log.write("maintenance pass: max \(options.maxEntries), keep \(options.expiredEntries) days")

        do {
            let repository = ClipRepository.shared
            let db = try repository.open()

            if options.checkForMaxEntries && options.maxEntries >= 0 {
                var doomed: [Int] = []
                try db.query("""
                    SELECT lID, lShortCut, lParentID, lDontAutoDelete, stickyClipOrder,
                    stickyClipGroupOrder FROM Main WHERE bIsGroup = 0
                    ORDER BY clipOrder DESC LIMIT -1 OFFSET \(options.maxEntries)
                    """) { row in
                        if row.int("lShortCut") == 0,
                           row.int("lDontAutoDelete") == 0,
                           row.int("lParentID", -1) <= 0,
                           row.double("stickyClipOrder") == DatabaseSchema.invalidSticky,
                           row.double("stickyClipGroupOrder") == DatabaseSchema.invalidSticky {
                            doomed.append(row.int("lID"))
                        }
                    }
                if doomed.isEmpty == false {
                    Log.write("over the limit: deleting \(doomed.count) clips")
                    try repository.delete(ids: doomed)
                }
            }

            if options.checkForExpiredEntries && options.expiredEntries > 0 {
                let cutoff = Int(Date().timeIntervalSince1970) - options.expiredEntries * 24 * 60 * 60
                var doomed: [Int] = []
                try db.query("""
                    SELECT lID FROM Main WHERE lastPasteDate < ? AND bIsGroup = 0
                    AND lShortCut = 0 AND lParentID <= 0 AND lDontAutoDelete = 0
                    AND stickyClipOrder = \(DatabaseSchema.invalidSticky)
                    AND stickyClipGroupOrder = \(DatabaseSchema.invalidSticky)
                    """, [cutoff]) { row in
                        doomed.append(row.int("lID"))
                    }
                if doomed.isEmpty == false {
                    Log.write("expired: deleting \(doomed.count) clips")
                    try repository.delete(ids: doomed)
                }
            }

            try drainDeleteQueue(db, checkIdleTime: checkIdleTime)
        } catch {
            Log.error("maintenance failed: \(error)")
        }
    }

    /// Empty out `MainDeletes` a few rows at a time. The trigger on that table
    /// removes the clip's data rows, which is the slow part - hence doing it
    /// only while the machine is idle, and only in small batches.
    private static func drainDeleteQueue(_ db: SQLiteDatabase, checkIdleTime: Bool) throws {
        let options = Options.shared
        let idle = idleSeconds()
        if checkIdleTime && idle < Double(options.idleSecondsBeforeDelete) {
            Log.write("not idle long enough to drain deletes (\(Int(idle))s)")
            return
        }

        var pending: [Int] = []
        try db.query("SELECT clipID FROM MainDeletes LIMIT \(options.mainDeletesDeleteCount)") { row in
            pending.append(row.int("clipID"))
        }

        for clipID in pending {
            _ = try db.execute("DELETE FROM MainDeletes WHERE clipID = ?", [clipID])
        }

        if pending.isEmpty == false {
            let remaining = (try db.scalarInt("SELECT COUNT(clipID) FROM MainDeletes")) ?? 0
            Log.write("drained \(pending.count) deletes, \(remaining) left")
        }
    }

    /// `CompactDatabase` - offered on the options page.
    static func compact() throws {
        let db = try ClipRepository.shared.open()
        try DatabaseSchema.compact(db)
    }

    /// The timer that drives all of the above, started at launch.
    final class Scheduler {
        private var timer: Timer?

        func start() {
            stop()
            // Windows Ditto runs this on a one minute timer.
            let timer = Timer(timeInterval: 60, repeats: true) { _ in
                DispatchQueue.global(qos: .utility).async {
                    Maintenance.removeOldEntries(checkIdleTime: true)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer

            // One pass shortly after launch, so a database that grew while the
            // app was closed gets trimmed without waiting a minute.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                Maintenance.removeOldEntries(checkIdleTime: false)
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }
    }
}
