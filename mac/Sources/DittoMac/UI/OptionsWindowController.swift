import Foundation
import AppKit

/// Port of the options property sheet (`COptionsSheet` and its pages:
/// OptionsGeneral, OptionsQuickPaste, OptionsKeyBoard, OptionsTypes,
/// OptionsStats). Same pages, same settings, laid out with a tab view.
final class OptionsWindowController: NSWindowController, NSWindowDelegate {

    private let tabView = NSTabView()
    private var hotKeyButtons: [String: NSButton] = [:]

    /// Takes its options object rather than reaching for the singleton - and
    /// takes an argument at all so that it never collides with
    /// `NSWindowController`'s own no-argument initialiser.
    private let options: Options

    init(options: Options) {
        self.options = options

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Ditto Options"
        window.center()

        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func build() {
        guard let content = window?.contentView else { return }

        tabView.frame = content.bounds.insetBy(dx: 10, dy: 10)
        tabView.autoresizingMask = [.width, .height]
        content.addSubview(tabView)

        addTab("General", view: generalPage())
        addTab("Quick Paste", view: quickPastePage())
        addTab("Keyboard", view: keyboardPage())
        addTab("Types", view: typesPage())
        addTab("Database", view: databasePage())
    }

    private func addTab(_ label: String, view: NSView) {
        let item = NSTabViewItem(identifier: label)
        item.label = label

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = view
        scroll.autoresizingMask = [.width, .height]

        item.view = scroll
        tabView.addTabViewItem(item)
    }

    // MARK: - Form building

    private func makeForm() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = true
        return stack
    }

    /// Wrap a form so it sizes itself inside the scroll view.
    private func finish(_ stack: NSStackView) -> NSView {
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        stack.frame = NSRect(x: 0, y: 0, width: max(520, size.width), height: size.height)
        stack.autoresizingMask = [.width]
        return stack
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.listSecondaryFont
        label.textColor = Theme.secondaryText
        label.preferredMaxLayoutWidth = 480
        return label
    }

    private func checkbox(_ title: String,
                          value: Bool,
                          action: @escaping (Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = value ? .on : .off
        let handler = ActionHandler { sender in
            guard let sender = sender as? NSButton else { return }
            action(sender.state == .on)
            Options.shared.notifyChanged()
        }
        button.target = handler
        button.action = #selector(ActionHandler.invoke(_:))
        keepAlive(handler)
        return button
    }

    private func numberRow(_ title: String,
                           value: Int,
                           suffix: String = "",
                           action: @escaping (Int) -> Void) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let label = NSTextField(labelWithString: title)
        let field = NSTextField(string: String(value))
        field.alignment = .right
        field.formatter = integerFormatter()
        field.frame.size.width = 80

        let handler = ActionHandler { sender in
            guard let sender = sender as? NSTextField else { return }
            action(sender.integerValue)
            Options.shared.notifyChanged()
        }
        field.target = handler
        field.action = #selector(ActionHandler.invoke(_:))
        keepAlive(handler)

        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        if suffix.isEmpty == false {
            row.addArrangedSubview(NSTextField(labelWithString: suffix))
        }
        return row
    }

    private func textRow(_ title: String,
                         value: String,
                         width: CGFloat = 300,
                         action: @escaping (String) -> Void) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let label = NSTextField(labelWithString: title)
        let field = NSTextField(string: value)

        let handler = ActionHandler { sender in
            guard let sender = sender as? NSTextField else { return }
            action(sender.stringValue)
            Options.shared.notifyChanged()
        }
        field.target = handler
        field.action = #selector(ActionHandler.invoke(_:))
        keepAlive(handler)

        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private func popupRow(_ title: String,
                          titles: [String],
                          selected: Int,
                          action: @escaping (Int) -> Void) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let label = NSTextField(labelWithString: title)
        let popup = NSPopUpButton()
        popup.addItems(withTitles: titles)
        if selected >= 0 && selected < titles.count {
            popup.selectItem(at: selected)
        }

        let handler = ActionHandler { sender in
            guard let sender = sender as? NSPopUpButton else { return }
            action(sender.indexOfSelectedItem)
            Options.shared.notifyChanged()
        }
        popup.target = handler
        popup.action = #selector(ActionHandler.invoke(_:))
        keepAlive(handler)

        row.addArrangedSubview(label)
        row.addArrangedSubview(popup)
        return row
    }

    /// A row that captures a key combination, for every global hot key.
    private func hotKeyRow(_ title: String,
                           key: String,
                           get: @escaping () -> String,
                           set: @escaping (String) -> Void) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let button = NSButton()
        button.bezelStyle = .rounded
        button.title = HotKey(string: get())?.description ?? "None"
        hotKeyButtons[key] = button

        let handler = ActionHandler { [weak self] _ in
            guard let self = self else { return }
            let current = HotKey(string: get())
            guard let result = HotKeyPrompt.run(window: self.window, current: current) else { return }
            switch result {
            case .set(let hotKey):
                set(hotKey.stringValue)
                button.title = hotKey.description
            case .cleared:
                set("")
                button.title = "None"
            }
            Options.shared.notifyChanged()
        }
        button.target = handler
        button.action = #selector(ActionHandler.invoke(_:))
        keepAlive(handler)

        row.addArrangedSubview(label)
        row.addArrangedSubview(button)
        button.widthAnchor.constraint(equalToConstant: 160).isActive = true
        return row
    }

    private func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        let handler = ActionHandler { _ in action() }
        button.target = handler
        button.action = #selector(ActionHandler.invoke(_:))
        keepAlive(handler)
        return button
    }

    private func integerFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 0
        return formatter
    }

    /// Keep the small action objects alive for as long as the window is.
    private var handlers: [ActionHandler] = []
    private func keepAlive(_ handler: ActionHandler) {
        handlers.append(handler)
    }

    // MARK: - Pages

    private func generalPage() -> NSView {
        let options = self.options
        let form = makeForm()

        form.addArrangedSubview(heading("Ditto"))
        form.addArrangedSubview(checkbox("Show the icon in the menu bar",
                                         value: options.showIconInMenuBar) { value in
            options.showIconInMenuBar = value
        })
        form.addArrangedSubview(checkbox("Start Ditto when I log in",
                                         value: LoginItem.isEnabled) { value in
            options.runOnStartup = value
            LoginItem.setEnabled(value)
        })
        form.addArrangedSubview(checkbox("Play a sound when a clip is saved",
                                         value: options.playSoundOnCopy) { value in
            options.playSoundOnCopy = value
        })

        form.addArrangedSubview(heading("Capturing clips"))
        form.addArrangedSubview(checkbox("Watch the clipboard",
                                         value: options.captureEnabled) { value in
            ClipboardMonitor.shared.setConnected(value)
        })
        form.addArrangedSubview(checkbox("Keep duplicates as separate clips",
                                         value: options.allowDuplicates) { value in
            options.allowDuplicates = value
        })
        form.addArrangedSubview(checkbox("Ignore formatting noise when comparing clips",
                                         value: options.adjustClipsForCRC) { value in
            options.adjustClipsForCRC = value
        })
        form.addArrangedSubview(note("""
            Word and Outlook rewrite invisible values inside rich text on every \
            copy. With this on, Ditto ignores them, so copying the same text \
            twice is recognised as the same clip.
            """))

        form.addArrangedSubview(numberRow("Wait before reading the clipboard",
                                          value: options.saveClipDelay,
                                          suffix: "ms") { value in
            options.saveClipDelay = value
        })
        form.addArrangedSubview(numberRow("Minimum gap between clips",
                                          value: options.copyGap,
                                          suffix: "ms") { value in
            options.copyGap = value
        })
        form.addArrangedSubview(numberRow("Check the clipboard every",
                                          value: options.pollIntervalMilliseconds,
                                          suffix: "ms") { value in
            options.pollIntervalMilliseconds = value
        })
        form.addArrangedSubview(note("""
            macOS does not tell an app when the clipboard changes, so Ditto has \
            to look. A shorter interval notices copies sooner and costs a little \
            more power.
            """))
        form.addArrangedSubview(numberRow("Skip clips larger than",
                                          value: options.maxClipSizeInBytes,
                                          suffix: "bytes (0 for no limit)") { value in
            options.maxClipSizeInBytes = value
        })
        form.addArrangedSubview(numberRow("Keep this much text as the description",
                                          value: options.descriptionTextSize,
                                          suffix: "characters") { value in
            options.descriptionTextSize = value
        })

        form.addArrangedSubview(heading("Removing old clips"))
        form.addArrangedSubview(checkbox("Keep only the newest clips",
                                         value: options.checkForMaxEntries) { value in
            options.checkForMaxEntries = value
        })
        form.addArrangedSubview(numberRow("Number of clips to keep",
                                          value: options.maxEntries) { value in
            options.maxEntries = value
        })
        form.addArrangedSubview(checkbox("Remove clips nobody has pasted in a while",
                                         value: options.checkForExpiredEntries) { value in
            options.checkForExpiredEntries = value
        })
        form.addArrangedSubview(numberRow("Remove after",
                                          value: options.expiredEntries,
                                          suffix: "days") { value in
            options.expiredEntries = value
        })
        form.addArrangedSubview(note("""
            Starred clips, clips in groups, stuck clips and clips with their own \
            shortcut are never removed automatically.
            """))

        form.addArrangedSubview(heading("Troubleshooting"))
        form.addArrangedSubview(checkbox("Write a debug log",
                                         value: options.enableDebugLogging) { value in
            options.enableDebugLogging = value
        })
        form.addArrangedSubview(button("Show the Log File") {
            DittoController.shared.showLogFile()
        })

        return finish(form)
    }

    private func quickPastePage() -> NSView {
        let options = self.options
        let form = makeForm()

        form.addArrangedSubview(heading("The window"))
        form.addArrangedSubview(popupRow("Show the window",
                                         titles: Options.QuickPastePosition.allCases.map { $0.title },
                                         selected: options.quickPastePosition.rawValue) { index in
            if let position = Options.QuickPastePosition(rawValue: index) {
                options.quickPastePosition = position
            }
        })
        form.addArrangedSubview(popupRow("Appearance",
                                         titles: Options.AppearanceSetting.allCases.map { $0.title },
                                         selected: options.appearance.rawValue) { index in
            if let appearance = Options.AppearanceSetting(rawValue: index) {
                options.appearance = appearance
            }
        })
        form.addArrangedSubview(numberRow("Lines of text per clip",
                                          value: options.linesPerRow) { value in
            options.linesPerRow = value
        })
        form.addArrangedSubview(checkbox("Keep the window on top",
                                         value: options.showPersistent) { value in
            options.showPersistent = value
        })
        form.addArrangedSubview(checkbox("Close the window after pasting",
                                         value: options.hideDittoOnPaste) { value in
            options.hideDittoOnPaste = value
        })
        form.addArrangedSubview(checkbox("The hot key closes the window if it is already open",
                                         value: options.hideOnHotKeyIfAlreadyShown) { value in
            options.hideOnHotKeyIfAlreadyShown = value
        })
        form.addArrangedSubview(checkbox("Show a thumbnail for image clips",
                                         value: options.drawThumbnail) { value in
            options.drawThumbnail = value
            ThumbnailCache.shared.clear()
        })
        form.addArrangedSubview(checkbox("Number the first ten clips",
                                         value: options.showTextForFirstTenHotKeys) { value in
            options.showTextForFirstTenHotKeys = value
        })
        form.addArrangedSubview(checkbox("Command-1 to Command-0 paste the first ten clips",
                                         value: options.useNumbersForFirstTenHotKeys) { value in
            options.useNumbersForFirstTenHotKeys = value
        })
        form.addArrangedSubview(checkbox("Make the window see-through",
                                         value: options.enableTransparency) { value in
            options.enableTransparency = value
        })
        form.addArrangedSubview(numberRow("Transparency",
                                          value: options.transparencyPercent,
                                          suffix: "%") { value in
            options.transparencyPercent = value
        })

        form.addArrangedSubview(heading("The list"))
        form.addArrangedSubview(checkbox("Show clips that are inside groups in the main list",
                                         value: options.showAllClipsInMainList) { value in
            options.showAllClipsInMainList = value
        })
        form.addArrangedSubview(checkbox("Show groups in the main list",
                                         value: options.showGroupsInMainList) { value in
            options.showGroupsInMainList = value
        })

        form.addArrangedSubview(heading("Searching"))
        form.addArrangedSubview(checkbox("Search as you type",
                                         value: options.findAsYouType) { value in
            options.findAsYouType = value
        })
        form.addArrangedSubview(checkbox("Search the clip description",
                                         value: options.searchDescription) { value in
            options.searchDescription = value
        })
        form.addArrangedSubview(checkbox("Search the quick paste text",
                                         value: options.searchQuickPaste) { value in
            options.searchQuickPaste = value
        })
        form.addArrangedSubview(checkbox("Search inside the clips themselves",
                                         value: options.searchFullText) { value in
            options.searchFullText = value
        })
        form.addArrangedSubview(checkbox("Treat what I type as one phrase",
                                         value: options.simpleTextSearch) { value in
            options.simpleTextSearch = value
        })
        form.addArrangedSubview(checkbox("Treat what I type as a regular expression",
                                         value: options.regExTextSearch) { value in
            options.regExTextSearch = value
        })
        form.addArrangedSubview(checkbox("Match upper and lower case exactly",
                                         value: options.caseSensitiveSearch) { value in
            options.caseSensitiveSearch = value
        })
        form.addArrangedSubview(note("""
            Otherwise several words are ANDed together; OR, AND and NOT change \
            that, "quotes" keep a phrase together and * is a wildcard. Start the \
            search with /f to look inside the clips, or /q for the quick paste text.
            """))

        form.addArrangedSubview(heading("Pasting"))
        form.addArrangedSubview(checkbox("Press Command-V in the other app for me",
                                         value: options.sendPasteAfterSelection) { value in
            options.sendPasteAfterSelection = value
        })
        form.addArrangedSubview(numberRow("Wait before pressing Command-V",
                                          value: options.pasteDelayMilliseconds,
                                          suffix: "ms") { value in
            options.pasteDelayMilliseconds = value
        })
        form.addArrangedSubview(checkbox("Move a pasted clip back to the top of the list",
                                         value: options.updateTimeOnPaste) { value in
            options.updateTimeOnPaste = value
        })
        form.addArrangedSubview(checkbox("Put my own clipboard back after pasting",
                                         value: options.restoreClipboardAfterPaste) { value in
            options.restoreClipboardAfterPaste = value
        })
        form.addArrangedSubview(checkbox("Ask before deleting clips",
                                         value: options.promptWhenDeletingClips) { value in
            options.promptWhenDeletingClips = value
        })

        if Accessibility.isTrusted == false {
            form.addArrangedSubview(heading("Accessibility"))
            form.addArrangedSubview(note("""
                Ditto is not yet allowed to press Command-V in other apps. Until \
                it is, picking a clip puts it on the clipboard and leaves the \
                pasting to you.
                """))
            form.addArrangedSubview(button("Open System Settings") {
                Accessibility.requestTrust()
                Accessibility.openSettings()
            })
        }

        return finish(form)
    }

    private func keyboardPage() -> NSView {
        let options = self.options
        let form = makeForm()

        form.addArrangedSubview(heading("Opening Ditto"))
        form.addArrangedSubview(hotKeyRow("Show the clip list", key: "show",
                                          get: { options.showQuickPasteHotKey },
                                          set: { options.showQuickPasteHotKey = $0 }))
        form.addArrangedSubview(hotKeyRow("Show the clip list (second key)", key: "show2",
                                          get: { options.showQuickPasteHotKey2 },
                                          set: { options.showQuickPasteHotKey2 = $0 }))
        form.addArrangedSubview(hotKeyRow("Show starred clips", key: "starred",
                                          get: { options.showStarredClipsHotKey },
                                          set: { options.showStarredClipsHotKey = $0 }))

        form.addArrangedSubview(heading("Pasting without opening the window"))
        form.addArrangedSubview(hotKeyRow("Paste the newest clip as plain text", key: "plain",
                                          get: { options.textOnlyPasteHotKey },
                                          set: { options.textOnlyPasteHotKey = $0 }))
        form.addArrangedSubview(hotKeyRow("Save what is on the clipboard now", key: "save",
                                          get: { options.saveClipboardHotKey },
                                          set: { options.saveClipboardHotKey = $0 }))

        for position in 1...Options.firstTenCount {
            form.addArrangedSubview(hotKeyRow("Paste clip \(position)", key: "pos\(position)",
                                              get: { options.pastePositionHotKey(position) },
                                              set: { options.setPastePositionHotKey(position, $0) }))
        }

        form.addArrangedSubview(heading("Copy buffers"))
        form.addArrangedSubview(note("""
            A copy buffer is a numbered slot: one key puts what you just copied \
            into it, another pastes it back. Handy for shuffling several things \
            between two documents.
            """))
        for buffer in 1...Options.copyBufferCount {
            form.addArrangedSubview(hotKeyRow("Copy into buffer \(buffer)", key: "copy\(buffer)",
                                              get: { options.copyBufferHotKey(buffer) },
                                              set: { options.setCopyBufferHotKey(buffer, $0) }))
            form.addArrangedSubview(hotKeyRow("Paste buffer \(buffer)", key: "paste\(buffer)",
                                              get: { options.pasteBufferHotKey(buffer) },
                                              set: { options.setPasteBufferHotKey(buffer, $0) }))
        }

        form.addArrangedSubview(heading("Inside the clip list"))
        form.addArrangedSubview(note("""
            Return pastes, Shift-Return pastes as plain text, Command-Return \
            pastes without moving the clip. Command-1 to Command-0 paste the \
            first ten. Command-E edits, Command-D stars, Command-T sticks a clip \
            to the top, Command-G moves it to a group, Command-N makes a group, \
            Delete removes. Left and right step out of and into groups. Escape \
            clears the search, then closes the window.
            """))

        return finish(form)
    }

    private func typesPage() -> NSView {
        let options = self.options
        let form = makeForm()

        form.addArrangedSubview(heading("Formats to save"))
        form.addArrangedSubview(note("""
            Ditto stores each clip in the Windows format names, which is what \
            keeps the database readable by Ditto for Windows.
            """))

        for format in ClipFormat.allKnownFormats {
            let enabled = options.enabledFormats.contains(format)
            form.addArrangedSubview(checkbox(ClipFormat.displayName(format),
                                             value: enabled) { value in
                var formats = options.enabledFormats
                if value {
                    formats.insert(format)
                } else {
                    formats.remove(format)
                }
                options.enabledFormats = formats
            })
        }

        form.addArrangedSubview(heading("Applications to ignore"))
        form.addArrangedSubview(note("""
            One bundle identifier per line. Anything copied while one of these \
            is in front is not saved - password managers, mostly.
            """))

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 120))
        textView.string = options.ignoredBundleIdentifiers.joined(separator: "\n")
        textView.font = NSFont.userFixedPitchFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 120))
        scroll.documentView = textView
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 480).isActive = true
        form.addArrangedSubview(scroll)

        form.addArrangedSubview(button("Save the Ignore List") {
            let lines = textView.string
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.isEmpty == false }
            options.ignoredBundleIdentifiers = lines
            options.notifyChanged()
        })

        form.addArrangedSubview(checkbox("Skip clips an app marks as concealed",
                                         value: options.honourConcealedPasteboardTypes) { value in
            options.honourConcealedPasteboardTypes = value
        })
        form.addArrangedSubview(note("""
            Password managers mark what they put on the clipboard with \
            org.nspasteboard.ConcealedType. With this on, Ditto leaves those alone.
            """))

        return finish(form)
    }

    private func databasePage() -> NSView {
        let options = self.options
        let form = makeForm()

        form.addArrangedSubview(heading("Database"))
        form.addArrangedSubview(textRow("File", value: options.databasePath, width: 360) { value in
            options.databasePath = value
        })
        form.addArrangedSubview(note("""
            Changing this takes effect when Ditto next starts. The file uses the \
            same format as Ditto for Windows, so the two can share one database \
            over a synced folder - though not at the same moment.
            """))

        form.addArrangedSubview(button("Show in Finder") {
            DittoController.shared.showDatabaseInFinder()
        })
        form.addArrangedSubview(button("Choose a Database File…") { [weak self] in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.title = "Choose a Ditto database"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            options.databasePath = url.path
            options.notifyChanged()
            self?.restartNotice()
        })
        form.addArrangedSubview(button("Back Up Database…") { [weak self] in
            ImportExport.backupDatabase(window: self?.window)
        })
        form.addArrangedSubview(button("Compact Database") { [weak self] in
            do {
                try Maintenance.compact()
                self?.info("The database has been compacted.")
            } catch {
                self?.info("Compacting failed: \(error)")
            }
        })
        form.addArrangedSubview(button("Import Clips from Files…") { [weak self] in
            ImportExport.importClips(window: self?.window)
        })

        form.addArrangedSubview(heading("Statistics"))

        let clipCount = (try? ClipRepository.shared.clipCount()) ?? 0
        let sizeInBytes = ClipRepository.shared.databaseSizeInBytes()
        let size = ByteCountFormatter.string(fromByteCount: Int64(sizeInBytes),
                                             countStyle: .file)

        form.addArrangedSubview(note("""
            Clips stored: \(clipCount)
            Database size: \(size)
            Copies since Ditto was installed: \(options.totalCopyCount)
            Pastes since Ditto was installed: \(options.totalPasteCount)
            Copies this trip: \(options.tripCopyCount)
            Pastes this trip: \(options.tripPasteCount)
            """))

        form.addArrangedSubview(button("Reset Trip Counters") { [weak self] in
            options.resetTripStatistics()
            self?.info("The trip counters have been reset.")
        })

        form.addArrangedSubview(heading("Danger"))
        form.addArrangedSubview(button("Delete Every Unstarred, Ungrouped Clip") { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Delete those clips?"
            alert.informativeText = """
                Everything except starred clips, stuck clips, clips in groups and \
                clips with their own shortcut will be removed.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try ClipRepository.shared.deleteAllNonUsedClips()
                self?.info("Those clips have been deleted.")
            } catch {
                self?.info("Deleting failed: \(error)")
            }
        })

        return finish(form)
    }

    // MARK: - Small helpers

    private func info(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Ditto"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func restartNotice() {
        info("Ditto will use the new database the next time it starts.")
    }
}

/// A tiny target object, so the form above can be written with closures rather
/// than a selector per control.
final class ActionHandler: NSObject {

    private let handler: (Any?) -> Void

    init(_ handler: @escaping (Any?) -> Void) {
        self.handler = handler
    }

    @objc func invoke(_ sender: Any?) {
        handler(sender)
    }
}
