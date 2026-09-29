import Foundation
import AppKit
import ApplicationServices

/// Pasting means synthesising a Command+V into another application, which macOS
/// only allows once the user has granted Accessibility permission. Windows has
/// no equivalent (Ditto just calls `SendInput`), so this whole file is new -
/// but without it the port would put clips on the clipboard and stop there.
enum Accessibility {

    /// Is Ditto allowed to post events to other applications?
    static var isTrusted: Bool {
        return AXIsProcessTrusted()
    }

    /// Ask, showing the system's own prompt. Returns the state before the
    /// prompt - macOS grants the right asynchronously, after the user acts.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings at the right pane, for the "grant access" button.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url = url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Explain the situation once, when the user first tries to paste without
    /// the permission.
    static func promptIfNeeded(from window: NSWindow?) -> Bool {
        if isTrusted { return true }

        let alert = NSAlert()
        alert.messageText = "Ditto needs Accessibility access to paste"
        alert.informativeText = """
            Ditto puts the clip you pick on the clipboard, then presses \
            Command-V in the app you were using. macOS only allows that for \
            apps you have allowed under Privacy & Security > Accessibility.

            Without it, Ditto still copies the clip to the clipboard - you \
            just have to press Command-V yourself.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            requestTrust()
            openSettings()
        }
        return false
    }
}
