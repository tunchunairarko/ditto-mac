import Foundation
import AppKit

/// Port of `CExternalWindowTracker` (ExternalWindowTracker.cpp).
///
/// Ditto has to know where a paste is going: the window that was in front
/// before its own window appeared. Windows Ditto watches the foreground window
/// handle; here the equivalent is the frontmost application, which macOS tells
/// us about through a workspace notification.
final class FrontAppTracker {

    static let shared = FrontAppTracker()

    /// The app that was in front before Ditto took over.
    private(set) var targetApplication: NSRunningApplication?

    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        targetApplication = currentOther()

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main) { [weak self] notification in
                guard let self = self else { return }
                let key = NSWorkspace.applicationUserInfoKey
                guard let app = notification.userInfo?[key] as? NSRunningApplication else { return }
                // Ignore ourselves: the point is to remember what we replaced.
                guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.targetApplication = app
            }
    }

    func stop() {
        if let observer = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    private func currentOther() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return nil
        }
        return front
    }

    /// The name shown in the quick paste window's title, so the user can see
    /// where the paste will land. Ditto shows the same thing.
    var targetName: String {
        return targetApplication?.localizedName ?? "No target"
    }

    /// Bring the target back to the front and wait for it to get there.
    @discardableResult
    func activateTarget() -> Bool {
        guard let app = targetApplication else { return false }
        if app.isTerminated { return false }
        return app.activate(options: [])
    }
}
