import Foundation
import AppKit
import ServiceManagement

/// Port of `CGetSetOptions::SetRunOnStartUp` (Options.cpp), which writes to the
/// Windows `Run` registry key. The macOS equivalents are `SMAppService` on
/// Ventura and later, and a launch agent before that.
enum LoginItem {

    private static let identifier = "io.ditto.DittoMac"

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                return true
            } catch {
                Log.error("could not change the login item: \(error)")
                return false
            }
        }
        return enabled ? writeAgent() : removeAgent()
    }

    // MARK: - Launch agent fallback

    private static var agentURL: URL {
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return base.appendingPathComponent("\(identifier).plist")
    }

    private static func writeAgent() -> Bool {
        let executable = Bundle.main.bundlePath
        let plist: [String: Any] = [
            "Label": identifier,
            "ProgramArguments": ["/usr/bin/open", "-a", executable],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        do {
            Paths.ensureDirectory(agentURL.deletingLastPathComponent())
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml,
                                                          options: 0)
            try data.write(to: agentURL)
            return true
        } catch {
            Log.error("could not write the launch agent: \(error)")
            return false
        }
    }

    private static func removeAgent() -> Bool {
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: agentURL)
            return true
        } catch {
            Log.error("could not remove the launch agent: \(error)")
            return false
        }
    }
}
