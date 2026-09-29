import Foundation
import AppKit

/// Port of `CSystemTray` / `CNTray` (SystemTray.cpp, NTray.cpp) - Ditto's tray
/// icon and its menu, which on macOS is a menu bar status item.
final class StatusItemController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem?

    func install() {
        guard Options.shared.showIconInMenuBar else {
            remove()
            return
        }
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                   accessibilityDescription: "Ditto")
            button.image?.isTemplate = true
            button.toolTip = "Ditto"
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(optionsChanged(_:)),
                                               name: .dittoOptionsChanged,
                                               object: nil)
    }

    func remove() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    @objc private func optionsChanged(_ notification: Notification) {
        if Options.shared.showIconInMenuBar {
            install()
        } else {
            remove()
        }
    }

    // MARK: - Menu

    /// Rebuilt every time it opens, so the recent clips and the connection
    /// state are current - the same thing Ditto's tray menu does.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: "Open Ditto",
                              action: #selector(openDitto(_:)),
                              keyEquivalent: "")
        open.target = self
        if let hotKey = HotKey(string: Options.shared.showQuickPasteHotKey) {
            open.keyEquivalent = hotKey.menuKeyEquivalent
            open.keyEquivalentModifierMask = hotKey.modifiers
        }
        menu.addItem(open)

        let starred = NSMenuItem(title: "Starred Clips",
                                 action: #selector(showStarred(_:)),
                                 keyEquivalent: "")
        starred.target = self
        menu.addItem(starred)

        menu.addItem(.separator())
        addRecentClips(to: menu)

        menu.addItem(.separator())

        let connected = ClipboardMonitor.shared.isConnected
        let toggle = NSMenuItem(title: connected ? "Stop Watching the Clipboard"
                                                 : "Watch the Clipboard",
                                action: #selector(toggleConnection(_:)),
                                keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let save = NSMenuItem(title: "Save the Clipboard Now",
                              action: #selector(saveClipboard(_:)),
                              keyEquivalent: "")
        save.target = self
        menu.addItem(save)

        menu.addItem(.separator())

        let options = NSMenuItem(title: "Options…",
                                 action: #selector(showOptions(_:)),
                                 keyEquivalent: ",")
        options.target = self
        menu.addItem(options)

        let about = NSMenuItem(title: "About Ditto", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        if Accessibility.isTrusted == false {
            let grant = NSMenuItem(title: "Allow Ditto to Paste…",
                                   action: #selector(grantAccessibility(_:)),
                                   keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Ditto", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// The first few clips, so the common case never needs the window at all.
    private func addRecentClips(to menu: NSMenu) {
        var request = ClipRepository.ListRequest()
        request.limit = 10

        let items = (try? ClipRepository.shared.list(request)) ?? []
        guard items.isEmpty == false else {
            let empty = NSMenuItem(title: "No clips yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for (index, item) in items.enumerated() where item.isGroup == false {
            let title = ClipRowCellView.displayText(item.desc, lines: 1)
            let trimmed = title.count > 60 ? String(title.prefix(60)) + "…" : title

            let menuItem = NSMenuItem(title: trimmed.isEmpty ? "(empty clip)" : trimmed,
                                      action: #selector(pasteRecent(_:)),
                                      keyEquivalent: index < 9 ? "\(index + 1)" : "")
            menuItem.keyEquivalentModifierMask = []
            menuItem.target = self
            menuItem.tag = item.id
            if item.isStarred { menuItem.state = .on }
            menu.addItem(menuItem)
        }
    }

    // MARK: - Actions

    @objc private func openDitto(_ sender: Any?) {
        DittoController.shared.showQuickPasteWindow()
    }

    @objc private func showStarred(_ sender: Any?) {
        DittoController.shared.showStarredClips()
    }

    @objc private func pasteRecent(_ sender: NSMenuItem) {
        DittoController.shared.pasteClip(id: sender.tag)
    }

    @objc private func toggleConnection(_ sender: Any?) {
        DittoController.shared.toggleClipboardConnection()
    }

    @objc private func saveClipboard(_ sender: Any?) {
        ClipboardMonitor.shared.capture(reason: .explicit)
    }

    @objc private func showOptions(_ sender: Any?) {
        DittoController.shared.showOptions()
    }

    @objc private func showAbout(_ sender: Any?) {
        DittoController.shared.showAbout()
    }

    @objc private func grantAccessibility(_ sender: Any?) {
        Accessibility.requestTrust()
        Accessibility.openSettings()
    }

    @objc private func quit(_ sender: Any?) {
        DittoController.shared.quit()
    }
}
