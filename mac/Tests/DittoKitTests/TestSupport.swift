import Foundation
import XCTest
@testable import DittoKit

/// A database and an options store that belong to one test and nothing else.
///
/// The options go to a throwaway suite rather than the real user defaults, and
/// `Options.shared.databasePath` points at the temporary file so that code which
/// reopens the database by itself - `Maintenance`, for one - lands in the same
/// place.
final class TestEnvironment {

    let databaseURL: URL
    private let suiteName: String
    private let previousOptions: Options

    init(function: String = #function) {
        // XCTestCase.name looks like "-[SchemaTests testFoo]", which is no use
        // in a file name or a defaults suite name.
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let safeFunction = String(function.filter { allowed.contains($0) })
        let identifier = "\(safeFunction)-\(UUID().uuidString)"

        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests", isDirectory: true)
            .appendingPathComponent("\(identifier).db")

        suiteName = "io.ditto.tests.\(identifier)"
        previousOptions = Options.shared

        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let options = Options(defaults: defaults)
        options.databasePath = databaseURL.path
        Options.shared = options
    }

    var options: Options {
        return Options.shared
    }

    /// The repository, opened on this test's own database.
    @discardableResult
    func openRepository() throws -> ClipRepository {
        try ClipRepository.shared.open(at: databaseURL)
        return ClipRepository.shared
    }

    var database: SQLiteDatabase {
        return ClipRepository.shared.database!
    }

    func tearDown() {
        ClipRepository.shared.database?.close()
        Options.shared = previousOptions
        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Building clips

    /// A text clip, the way `ClipboardMonitor` would have built one.
    func textClip(_ text: String) -> Clip {
        let clip = Clip()
        clip.formats = [
            ClipFormatData(ClipFormat.unicodeText, ClipFormat.encodeUnicodeText(text)),
            ClipFormatData(ClipFormat.text, ClipFormat.encodeText(text))
        ]
        clip.date = Date()
        clip.lastPasteDate = Date()
        clip.generateDescription()
        return clip
    }

    @discardableResult
    func addTextClip(_ text: String) throws -> Int {
        switch try ClipRepository.shared.add(textClip(text)) {
        case .added(let id): return id
        case .duplicate(let id): return id
        case .skipped: return 0
        }
    }

    // MARK: - Reading the database back

    func count(_ sql: String) throws -> Int {
        return try database.scalarInt(sql) ?? 0
    }

    func objectExists(type: String, name: String) throws -> Bool {
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type = ? AND name = ?"
        return (try database.scalarInt(sql, [type, name]) ?? 0) == 1
    }

    func columnNames(ofTable table: String) throws -> Set<String> {
        var names: Set<String> = []
        try database.query("PRAGMA table_info(\(table))") { row in
            names.insert(row.string("name"))
        }
        return names
    }
}

/// A base class that wires the environment up and tears it down again.
class DittoTestCase: XCTestCase {

    var environment: TestEnvironment!

    override func setUpWithError() throws {
        try super.setUpWithError()
        environment = TestEnvironment(function: name)
        try environment.openRepository()
    }

    override func tearDownWithError() throws {
        environment.tearDown()
        environment = nil
        try super.tearDownWithError()
    }
}
