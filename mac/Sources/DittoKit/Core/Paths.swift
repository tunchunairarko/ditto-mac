import Foundation

/// Port of `CGetSetOptions::GetAppDataPath` / `GetDBPath` (Options.cpp).
///
/// Windows Ditto keeps `Ditto.db` in `%APPDATA%\Ditto`; the macOS equivalent
/// is `~/Library/Application Support/Ditto`.
enum Paths {

    static let appFolderName = "Ditto"
    static let databaseFileName = "Ditto.db"

    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(appFolderName, isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    static var defaultDatabaseURL: URL {
        return appSupportDirectory.appendingPathComponent(databaseFileName)
    }

    /// Where clips that carry files (CF_HDROP) are written out before a paste.
    static var tempDirectory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ditto", isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    static func ensureDirectory(_ url: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return
        }
        try? FileManager.default.createDirectory(at: url,
                                                 withIntermediateDirectories: true)
    }

    /// Resolve a user-entered database path, expanding `~` and treating a
    /// directory as "put Ditto.db inside it" the way the Windows options do.
    static func resolveDatabasePath(_ raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultDatabaseURL }

        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
           isDir.boolValue {
            return URL(fileURLWithPath: expanded)
                .appendingPathComponent(databaseFileName)
        }
        return URL(fileURLWithPath: expanded)
    }
}
