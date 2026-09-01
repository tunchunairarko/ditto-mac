import Foundation
import AppKit

/// The coordinator: the macOS counterpart of `CCP_MainApp` and `CMainFrame`
/// (CP_Main.cpp, MainFrm.cpp). It owns the windows, wires the hot keys to
/// actions, and is the single place the rest of the app asks to do something.
final class DittoController: NSObject {

    static let shared = DittoController()

    private(set) var quickPasteWindow: QuickPasteWindowController?
    private var optionsWindow: OptionsWindowController?
    private var editorWindows: [Int: ClipEditorWindowController] = [:]
    private let maintenance = Maintenance.Scheduler()

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        do {
            try ClipRepository.shared.open()
        } catch {
            presentDatabaseFailure(error)
            return
        }

        FrontAppTracker.shared.start()
        ClipboardMonitor.shared.start()
        HotKeyManager.shared.reload(controller: self)
        maintenance.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(optionsChanged(_:)),
            name: .dittoOptionsChanged,
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityNeeded(_:)),
            name: .dittoNeedsAccessibility,
            object: nil)

        if Options.shared.hasCompletedFirstRun == false {
            presentFirstRun()
        }
    }

    func stop() {
        maintenance.stop()
        ClipboardMonitor.shared.stop()
        FrontAppTracker.shared.stop()
        HotKeyManager.shared.unregisterAll()
        ClipRepository.shared.database?.close()
    }

    @objc private func optionsChanged(_ notification: Notification) {
        ClipboardMonitor.shared.optionsChanged()
        HotKeyManager.shared.reload(controller: self)
        quickPasteWindow?.applyOptions()
    }

    private var hasWarnedAboutAccessibility = false

    @objc private func accessibilityNeeded(_ notification: Notification) {
        guard hasWarnedAboutAccessibility == false else { return }
        hasWarnedAboutAccessibility = true
        DispatchQueue.main.async {
            _ = Accessibility.promptIfNeeded(from: self.quickPasteWindow?.window)
        }
    }

    // MARK: - The quick paste window

    private func ensureQuickPasteWindow() -> QuickPasteWindowController {
        if let existing = quickPasteWindow { return existing }
        let controller = QuickPasteWindowController(repository: ClipRepository.shared)
        quickPasteWindow = controller
        return controller
    }

    func showQuickPasteWindow() {
        ensureQuickPasteWindow().show()
    }

    /// The main hot key. `GetHideDittoOnHotKeyIfAlreadyShown` decides whether
    /// pressing it again puts the window away.
    func toggleQuickPasteWindow() {
        let controller = ensureQuickPasteWindow()
        if controller.isVisible && Options.shared.hideOnHotKeyIfAlreadyShown {
            controller.hide()
        } else {
            controller.show()
        }
    }

    func showStarredClips() {
        let controller = ensureQuickPasteWindow()
        controller.showStarredOnly()
    }

    func hideQuickPasteWindow() {
        quickPasteWindow?.hide()
    }

    // MARK: - Options

    /// Menu-item wrappers: AppKit sends the sender along, so the selector it
    /// targets has to take one.
    @objc func showOptionsMenuAction(_ sender: Any?) {
        showOptions()
    }

    @objc func showAboutMenuAction(_ sender: Any?) {
        showAbout()
    }

    func showOptions() {
        if optionsWindow == nil {
            optionsWindow = OptionsWindowController(options: Options.shared)
        }
        NSApp.activate(ignoringOtherApps: true)
        optionsWindow?.showWindow(nil)
        optionsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Editing

    func editClip(id: Int) {
        if let existing = editorWindows[id] {
            NSApp.activate(ignoringOtherApps: true)
            existing.showWindow(nil)
            return
        }
        let controller = ClipEditorWindowController(clipID: id)
        controller.onClose = { [weak self] in
            self?.editorWindows.removeValue(forKey: id)
        }
        editorWindows[id] = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    // MARK: - Hot key actions

    /// PASTE_POSITION_1..10 - paste the Nth clip in the main list without
    /// opening the window at all.
    func pasteClip(atPosition position: Int) {
        do {
            guard let id = try ClipRepository.shared.clip(atPosition: position) else { return }
            pasteClip(id: id)
        } catch {
            Log.error("paste position \(position) failed: \(error)")
        }
    }

    func pasteClip(id: Int, transform: SpecialPaste.Transform = .none, plainText: Bool = false) {
        var request = PasteEngine.Request(clipIDs: [id])
        request.transform = transform
        request.plainTextOnly = plainText
        PasteEngine.paste(request)
    }

    /// The global "paste as plain text" hot key: the newest clip, text only.
    func pasteTopClipAsPlainText() {
        do {
            guard let id = try ClipRepository.shared.clip(atPosition: 1) else { return }
            pasteClip(id: id, plainText: true)
        } catch {
            Log.error("plain text paste failed: \(error)")
        }
    }

    /// Copy buffers: `Ctrl+Shift+N` stores, `Ctrl+N` pastes, on Windows.
    func copyToBuffer(_ buffer: Int) {
        guard let id = ClipboardMonitor.shared.capture(reason: .explicit) else {
            Log.write("nothing on the clipboard to put in buffer \(buffer)")
            return
        }
        do {
            try ClipRepository.shared.setCopyBuffer(buffer, clipID: id)
            Log.write("clip \(id) stored in buffer \(buffer)")
        } catch {
            Log.error("could not set buffer \(buffer): \(error)")
        }
    }

    func pasteBuffer(_ buffer: Int) {
        do {
            guard let id = try ClipRepository.shared.copyBufferClipID(buffer) else {
                Log.write("buffer \(buffer) is empty")
                return
            }
            pasteClip(id: id)
        } catch {
            Log.error("could not paste buffer \(buffer): \(error)")
        }
    }

    // MARK: - Menu actions

    func toggleClipboardConnection() {
        ClipboardMonitor.shared.toggleConnected()
    }

    func showLogFile() {
        NSWorkspace.shared.selectFile(Log.logFileURL.path,
                                      inFileViewerRootedAtPath: Paths.appSupportDirectory.path)
    }

    func showDatabaseInFinder() {
        let url = Options.shared.databaseURL
        NSWorkspace.shared.selectFile(url.path,
                                      inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(string: """
            An extension to the macOS clipboard. Every clip you copy is kept, \
            so you can get back to any of them later.

            A port of Ditto for Windows by Scott Brogden and contributors, \
            released under the GNU General Public License. The database format \
            is the same, so a Ditto.db file works on either platform.
            """)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private func presentDatabaseFailure(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Ditto could not open its database"
        alert.informativeText = """
            \(error)

            The database lives at \(Options.shared.databaseURL.path). \
            Check that the folder exists and is writable, then start Ditto again.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func presentFirstRun() {
        Options.shared.hasCompletedFirstRun = true

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Ditto is running in the menu bar"
        let hotKey = HotKey(string: Options.shared.showQuickPasteHotKey)?.description ?? "the hot key"
        alert.informativeText = """
            Copy things as you normally would; Ditto keeps every clip.

            Press \(hotKey) to open the list, then press Return on a clip to \
            paste it into whatever you were using.

            To paste for you, Ditto needs Accessibility access. You can grant \
            it now or the first time you paste.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            Accessibility.requestTrust()
            Accessibility.openSettings()
        }
    }
}
