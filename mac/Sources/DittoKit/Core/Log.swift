import Foundation

/// Port of Ditto's `Log()` helper (Misc.cpp).
///
/// Windows Ditto writes to `Ditto.log` beside the database when
/// "Enable debug logging" is checked; this does the same, and also mirrors
/// to stderr so `Console.app` / a terminal launch shows the same lines.
enum Log {

    private static let queue = DispatchQueue(label: "io.ditto.log")
    private static var handle: FileHandle?
    private static var openedPath: String?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var logFileURL: URL {
        return Paths.appSupportDirectory.appendingPathComponent("Ditto.log")
    }

    static func write(_ message: @autoclosure () -> String,
                      function: String = #function) {
        guard Options.shared.enableDebugLogging else { return }
        let line = "\(formatter.string(from: Date())) [\(function)] \(message())\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
            appendToFile(line)
        }
    }

    /// Errors are always recorded, debug logging on or off.
    static func error(_ message: @autoclosure () -> String,
                      function: String = #function) {
        let line = "\(formatter.string(from: Date())) [ERROR \(function)] \(message())\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
            appendToFile(line)
        }
    }

    private static func appendToFile(_ line: String) {
        let path = logFileURL.path
        if openedPath != path {
            handle?.closeFile()
            handle = nil
            openedPath = path
        }
        if handle == nil {
            let fm = FileManager.default
            if !fm.fileExists(atPath: path) {
                fm.createFile(atPath: path, contents: nil)
            }
            handle = FileHandle(forWritingAtPath: path)
            handle?.seekToEndOfFile()
        }
        guard let handle = handle else { return }
        handle.write(Data(line.utf8))

        // Keep the log from growing without bound (Ditto rolls at 10 MB).
        if handle.offsetInFile > 10 * 1024 * 1024 {
            handle.closeFile()
            Self.handle = nil
            let rolled = logFileURL.deletingLastPathComponent()
                .appendingPathComponent("Ditto.log.1")
            try? FileManager.default.removeItem(at: rolled)
            try? FileManager.default.moveItem(at: logFileURL, to: rolled)
        }
    }
}
