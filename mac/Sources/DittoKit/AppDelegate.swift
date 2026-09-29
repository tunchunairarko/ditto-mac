import Foundation
import AppKit

/// Port of `CCP_MainApp::InitInstance` (CP_Main.cpp): open the database, start
/// watching the clipboard, claim the hot keys, put the icon in the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusItem = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon, no menu bar of its own. LSUIElement in
        // Info.plist says the same thing, and this covers running the binary
        // directly during development.
        NSApp.setActivationPolicy(.accessory)

        buildMainMenu()
        DittoController.shared.start()
        statusItem.install()

        Log.write("Ditto started")
    }

    /// A menu bar app has no menu bar of its own, but the Edit menu is what
    /// gives text fields their Command-C, Command-V and Command-A - the search
    /// box would be oddly crippled without it.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let about = NSMenuItem(title: "About Ditto",
                               action: #selector(DittoController.showAboutMenuAction(_:)),
                               keyEquivalent: "")
        about.target = DittoController.shared
        appMenu.addItem(about)

        appMenu.addItem(.separator())

        let options = NSMenuItem(title: "Options…",
                                 action: #selector(DittoController.showOptionsMenuAction(_:)),
                                 keyEquivalent: ",")
        options.target = DittoController.shared
        appMenu.addItem(options)

        appMenu.addItem(.separator())
        _ = appMenu.addItem(withTitle: "Hide Ditto",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        _ = appMenu.addItem(withTitle: "Quit Ditto",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        _ = editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")), keyEquivalent: "z")
        _ = editMenu.addItem(withTitle: "Redo",
                         action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        _ = editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        _ = editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        _ = editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        _ = editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        DittoController.shared.stop()
        statusItem.remove()
        Log.write("Ditto stopped")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Opening the app again (from the Dock or Finder) shows the clip list.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        DittoController.shared.showQuickPasteWindow()
        return true
    }

    /// Files dropped on the app become clips. IMPORT_CLIP on Windows.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for path in filenames {
            ImportExport.importClip(from: URL(fileURLWithPath: path))
        }
        ClipRepository.shared.notifyChanged()
        sender.reply(toOpenOrPrint: .success)
    }
}
