import Foundation
import AppKit
import Carbon.HIToolbox

/// Port of `CQPasteWnd` (QPasteWnd.cpp) - the window Ditto is really about.
///
/// Same shape as the Windows one: a search box at the top, the clip list under
/// it, a status line at the bottom, groups you can step into and back out of,
/// and a keyboard map that covers everything without ever reaching for the
/// mouse. The actions are the ones in `ActionEnums.h`.
final class QuickPasteWindowController: NSWindowController,
                                        NSWindowDelegate,
                                        NSTableViewDataSource,
                                        NSTableViewDelegate,
                                        NSSearchFieldDelegate {

    // MARK: - State

    private var items: [ClipListItem] = []
    private var groupID = -1
    private var groupStack: [Int] = []
    private var starredOnly = false
    private var searchText = ""
    private var loadedLimit = 300
    private var totalMatches = 0

    private var searchTimer: Timer?
    private var keyMonitor: Any?
    private var isLoadingMore = false

    // MARK: - Views

    private let searchField = NSSearchField()
    private let tableView = ClipTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let groupLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton()

    // MARK: - Construction

    /// Takes its repository rather than reaching for the singleton, and takes
    /// an argument at all so that it never collides with `NSWindowController`'s
    /// own no-argument initialiser.
    private let repository: ClipRepository

    init(repository: ClipRepository) {
        self.repository = repository

        let options = Options.shared
        let size = NSSize(width: options.quickPasteWidth, height: options.quickPasteHeight)
        let panel = QuickPastePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.title = "Ditto"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        super.init(window: panel)

        panel.delegate = self
        buildViews()
        applyOptions()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clipsChanged(_:)),
                                               name: .dittoClipsChanged,
                                               object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        removeKeyMonitor()
        NotificationCenter.default.removeObserver(self)
    }

    private func buildViews() {
        guard let content = window?.contentView else { return }

        searchField.delegate = self
        searchField.placeholderString = "Search clips  (try  /f text  to search contents)"
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true

        backButton.title = "‹ Back"
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(goBack(_:))
        backButton.isHidden = true

        groupLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        groupLabel.textColor = Theme.listText
        groupLabel.isHidden = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyDelegate = self
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.intercellSpacing = NSSize(width: 0, height: 1)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        statusLabel.font = Theme.listSecondaryFont
        statusLabel.textColor = Theme.secondaryText

        for view in [searchField, backButton, groupLabel, scrollView, statusLabel] as [NSView] {
            content.addSubview(view)
        }

        content.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(frameChanged(_:)),
                                               name: NSView.frameDidChangeNotification,
                                               object: content)
        layoutViews()
    }

    @objc private func frameChanged(_ notification: Notification) {
        layoutViews()
    }

    private func layoutViews() {
        guard let content = window?.contentView else { return }
        let bounds = content.bounds
        let margin: CGFloat = 8
        let searchHeight: CGFloat = 24
        let statusHeight: CGFloat = 16

        var top = bounds.height - margin - searchHeight
        searchField.frame = NSRect(x: margin, y: top,
                                   width: bounds.width - margin * 2, height: searchHeight)

        var listTop = top - margin

        if backButton.isHidden == false || groupLabel.isHidden == false {
            top -= searchHeight + 4
            backButton.frame = NSRect(x: margin, y: top, width: 64, height: searchHeight)
            groupLabel.frame = NSRect(x: margin + 70, y: top + 3,
                                      width: bounds.width - margin * 2 - 70,
                                      height: searchHeight - 4)
            listTop = top - margin
        }

        let listBottom = margin + statusHeight + 4
        scrollView.frame = NSRect(x: margin, y: listBottom,
                                  width: bounds.width - margin * 2,
                                  height: max(40, listTop - listBottom))

        statusLabel.frame = NSRect(x: margin, y: margin,
                                   width: bounds.width - margin * 2, height: statusHeight)
    }

    // MARK: - Options

    func applyOptions() {
        Theme.apply(to: window)
        let options = Options.shared

        tableView.rowHeight = Theme.rowHeight(lines: options.linesPerRow)
        tableView.backgroundColor = Theme.listBackground
        scrollView.backgroundColor = Theme.listBackground

        window?.level = options.showPersistent ? .floating : .normal
        window?.alphaValue = options.enableTransparency
            ? CGFloat(100 - options.transparencyPercent) / 100.0
            : 1.0

        tableView.reloadData()
        updateStatus()
    }

    // MARK: - Showing and hiding

    var isVisible: Bool {
        return window?.isVisible ?? false
    }

    func show() {
        guard let window = window else { return }

        // Whoever was in front is where a paste will go. Read it before we
        // take the focus.
        let target = FrontAppTracker.shared.targetName

        position(window)
        applyOptions()
        reload(resetSelection: true)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        installKeyMonitor()

        if items.isEmpty == false {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }

        statusLabel.stringValue = statusText(target: target)
    }

    /// `restoringFocus` is false when the window is going away because the
    /// user has already moved to another app - pulling the old target forward
    /// then would yank them out of whatever they just clicked on.
    func hide(restoringFocus: Bool = true) {
        removeKeyMonitor()
        saveFrame()
        window?.orderOut(nil)
        if restoringFocus {
            FrontAppTracker.shared.activateTarget()
        }
    }

    func showStarredOnly() {
        starredOnly = true
        groupID = -1
        groupStack.removeAll()
        searchText = ""
        searchField.stringValue = ""
        show()
    }

    /// `GetQuickPastePosition` - where the window turns up.
    private func position(_ window: NSWindow) {
        let options = Options.shared
        var frame = window.frame
        frame.size = NSSize(width: options.quickPasteWidth, height: options.quickPasteHeight)

        switch options.quickPastePosition {
        case .lastPosition:
            if options.quickPasteX >= 0 && options.quickPasteY >= 0 {
                frame.origin = NSPoint(x: options.quickPasteX, y: options.quickPasteY)
            }

        case .atCursor:
            let mouse = NSEvent.mouseLocation
            frame.origin = NSPoint(x: mouse.x - 20, y: mouse.y - frame.height + 20)

        case .screenCenter:
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                frame.origin = NSPoint(x: visible.midX - frame.width / 2,
                                       y: visible.midY - frame.height / 2)
            }

        case .activeWindowCenter:
            // Without Accessibility access we cannot measure another app's
            // window, so use the screen the pointer is on - close enough, and
            // it keeps the window near what the user is looking at.
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                frame.origin = NSPoint(x: visible.midX - frame.width / 2,
                                       y: visible.midY - frame.height / 2)
            }
        }

        window.setFrame(constrain(frame), display: true)
    }

    /// `GetEnsureEntireWindowCanBeSeen` - keep the window on a screen.
    private func constrain(_ frame: NSRect) -> NSRect {
        var frame = frame
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }

        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        let options = Options.shared
        options.quickPasteWidth = Double(frame.width)
        options.quickPasteHeight = Double(frame.height)
        options.quickPasteX = Double(frame.origin.x)
        options.quickPasteY = Double(frame.origin.y)
    }

    // MARK: - Loading

    @objc private func clipsChanged(_ notification: Notification) {
        guard isVisible else { return }
        reload(resetSelection: false)
    }

    private func currentRequest() -> ClipRepository.ListRequest {
        var request = ClipRepository.ListRequest()
        request.search = searchText
        request.groupID = groupID
        request.starredOnly = starredOnly
        request.limit = loadedLimit
        return request
    }

    private func reload(resetSelection: Bool) {
        let selectedIDs = Set(selectedItems().map { $0.id })

        do {
            let request = currentRequest()
            items = try repository.list(request)
            totalMatches = try repository.count(request)
        } catch {
            Log.error("could not load the clip list: \(error)")
            items = []
            totalMatches = 0
        }

        tableView.reloadData()
        updateGroupChrome()
        updateStatus()

        if resetSelection || selectedIDs.isEmpty {
            if items.isEmpty == false {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            return
        }

        var restored = IndexSet()
        for (index, item) in items.enumerated() where selectedIDs.contains(item.id) {
            restored.insert(index)
        }
        if restored.isEmpty {
            if items.isEmpty == false {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        } else {
            tableView.selectRowIndexes(restored, byExtendingSelection: false)
        }
    }

    private func updateGroupChrome() {
        if starredOnly {
            groupLabel.stringValue = "Starred clips"
            groupLabel.isHidden = false
            backButton.isHidden = false
        } else if groupID >= 0 {
            let name = (try? repository.groupName(id: groupID)) ?? nil
            groupLabel.stringValue = name ?? "Group"
            groupLabel.isHidden = false
            backButton.isHidden = false
        } else {
            groupLabel.isHidden = true
            backButton.isHidden = true
        }
        layoutViews()
    }

    private func statusText(target: String? = nil) -> String {
        let targetName = target ?? FrontAppTracker.shared.targetName
        var parts: [String] = []
        parts.append("\(items.count) of \(totalMatches)")
        parts.append("paste into: \(targetName)")
        if ClipboardMonitor.shared.isConnected == false {
            parts.append("clipboard disconnected")
        }
        if Options.shared.showPersistent {
            parts.append("always on top")
        }
        return parts.joined(separator: "   ·   ")
    }

    private func updateStatus() {
        statusLabel.stringValue = statusText()
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        scheduleSearch()
    }

    private func scheduleSearch() {
        searchTimer?.invalidate()
        guard Options.shared.findAsYouType else { return }
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.runSearch()
        }
    }

    private func runSearch() {
        searchText = searchField.stringValue
        loadedLimit = 300
        reload(resetSelection: true)
    }

    // MARK: - Table view

    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < items.count else { return nil }

        let cell: ClipRowCellView
        if let reused = tableView.makeView(withIdentifier: ClipRowCellView.identifier,
                                           owner: self) as? ClipRowCellView {
            cell = reused
        } else {
            cell = ClipRowCellView()
            cell.identifier = ClipRowCellView.identifier
        }

        let position = row < Options.firstTenCount ? row + 1 : nil
        cell.configure(with: items[row],
                       position: position,
                       isSelected: tableView.selectedRowIndexes.contains(row))

        loadMoreIfNeeded(row: row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Redraw so the selected row's text picks up the selection colour.
        tableView.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? ClipRowCellView,
                  row < items.count else { return }
            let position = row < Options.firstTenCount ? row + 1 : nil
            cell.configure(with: items[row],
                           position: position,
                           isSelected: tableView.selectedRowIndexes.contains(row))
        }
    }

    /// Pull in another page when the list is scrolled near the end, rather than
    /// loading thousands of rows up front. Ditto's list thread does the same.
    private func loadMoreIfNeeded(row: Int) {
        guard isLoadingMore == false else { return }
        guard row >= items.count - 20, items.count < totalMatches else { return }

        isLoadingMore = true
        loadedLimit += 300
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.reload(resetSelection: false)
            self.isLoadingMore = false
        }
    }

    private func selectedItems() -> [ClipListItem] {
        return tableView.selectedRowIndexes.compactMap { index in
            index < items.count ? items[index] : nil
        }
    }

    private var selectedIDs: [Int] {
        return selectedItems().map { $0.id }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        if items[row].isGroup {
            enterGroup(items[row].id)
        } else {
            pasteSelection()
        }
    }

    // MARK: - Keyboard (Accels.cpp / QuickPasteKeyboard.cpp)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
    }

    func escapePressed() {
        // Escape clears the search first (CANCELFILTER), then closes.
        if searchField.stringValue.isEmpty == false {
            searchField.stringValue = ""
            runSearch()
            return
        }
        if starredOnly || groupID >= 0 {
            goBack(nil)
            return
        }
        hide()
    }

    /// Returns true when the key has been dealt with.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = Int(event.keyCode)

        // Command+1..0 - PASTE_POSITION_1..10.
        if modifiers == .command || modifiers == [.command, .shift] {
            if let position = QuickPasteWindowController.numberKeyPosition(code) {
                guard Options.shared.useNumbersForFirstTenHotKeys else { return false }
                pasteClip(atRow: position - 1, plainText: modifiers.contains(.shift))
                return true
            }
        }

        switch code {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if modifiers.contains(.shift) {
                pasteSelection(plainText: true)             // PASTE_SELECTED_PLAIN_TEXT
            } else if modifiers.contains(.command) {
                pasteSelection(updateOrder: false)          // PASTE_DONT_MOVE_CLIP
            } else if let first = selectedItems().first, first.isGroup {
                enterGroup(first.id)
            } else {
                pasteSelection()                            // PASTE_SELECTED
            }
            return true

        case kVK_Escape:
            escapePressed()
            return true

        case kVK_UpArrow:
            moveSelection(by: -1, extend: modifiers.contains(.shift))
            return true

        case kVK_DownArrow:
            moveSelection(by: 1, extend: modifiers.contains(.shift))
            return true

        case kVK_PageUp:
            moveSelection(by: -visibleRowCount(), extend: modifiers.contains(.shift))
            return true

        case kVK_PageDown:
            moveSelection(by: visibleRowCount(), extend: modifiers.contains(.shift))
            return true

        case kVK_Home:
            if modifiers.contains(.command) { selectRow(0); return true }
            return false

        case kVK_End:
            if modifiers.contains(.command) { selectRow(items.count - 1); return true }
            return false

        case kVK_LeftArrow:
            // BACKGRROUP - out of the current group, if the caret is not busy.
            if searchField.stringValue.isEmpty && (groupID >= 0 || starredOnly) {
                goBack(nil)
                return true
            }
            return false

        case kVK_RightArrow:
            if searchField.stringValue.isEmpty,
               let first = selectedItems().first, first.isGroup {
                enterGroup(first.id)
                return true
            }
            return false

        case kVK_Delete:
            // DELETE_SELECTED, but only when the search box is empty so
            // backspace still edits the search text.
            if searchField.stringValue.isEmpty {
                deleteSelection()
                return true
            }
            return false

        case kVK_ForwardDelete:
            deleteSelection()
            return true

        default:
            break
        }

        guard modifiers.contains(.command) else { return false }

        switch code {
        case kVK_ANSI_E:                    // EDITCLIP
            editSelection()
            return true
        case kVK_ANSI_G:                    // MOVE_CLIP_TO_GROUP
            moveSelectionToGroup()
            return true
        case kVK_ANSI_D:                    // starred clips (lDontAutoDelete)
            toggleStarSelection()
            return true
        case kVK_ANSI_T:                    // MAKE_TOP_STICKY / REMOVE_STICKY
            if modifiers.contains(.shift) {
                setSticky(.none)
            } else {
                setSticky(.top)
            }
            return true
        case kVK_ANSI_B:                    // MAKE_LAST_STICKY
            setSticky(.last)
            return true
        case kVK_ANSI_N:                    // NEWGROUP
            promptForNewGroup()
            return true
        case kVK_ANSI_F:                    // focus the search box
            window?.makeFirstResponder(searchField)
            return true
        case kVK_ANSI_P:                    // TOGGLESHOWPERSISTANT
            Options.shared.showPersistent.toggle()
            applyOptions()
            return true
        case kVK_ANSI_R:                    // REFRESH_LIST
            reload(resetSelection: false)
            return true
        case kVK_ANSI_U:                    // MOVE_CLIP_TOP
            moveSelectionToTop()
            return true
        case kVK_ANSI_I:                    // CLIP_PROPERTIES
            showProperties()
            return true
        case kVK_ANSI_S:                    // SHOW_STARRED_CLIPS
            starredOnly.toggle()
            reload(resetSelection: true)
            return true
        case kVK_ANSI_C:                    // COPY_SELECTION
            // Shift as well, so plain Command-C still copies text out of the
            // search box.
            guard modifiers.contains(.shift) else { return false }
            copySelectionToClipboard()
            return true
        default:
            return false
        }
    }

    private static func numberKeyPosition(_ keyCode: Int) -> Int? {
        switch keyCode {
        case kVK_ANSI_1: return 1
        case kVK_ANSI_2: return 2
        case kVK_ANSI_3: return 3
        case kVK_ANSI_4: return 4
        case kVK_ANSI_5: return 5
        case kVK_ANSI_6: return 6
        case kVK_ANSI_7: return 7
        case kVK_ANSI_8: return 8
        case kVK_ANSI_9: return 9
        case kVK_ANSI_0: return 10
        default: return nil
        }
    }

    private func visibleRowCount() -> Int {
        let height = scrollView.contentView.bounds.height
        let rowHeight = max(1, tableView.rowHeight + tableView.intercellSpacing.height)
        return max(1, Int(height / rowHeight) - 1)
    }

    private func moveSelection(by delta: Int, extend: Bool) {
        guard items.isEmpty == false else { return }
        let current = tableView.selectedRow
        let next = max(0, min(items.count - 1, (current < 0 ? 0 : current) + delta))
        if extend {
            var set = tableView.selectedRowIndexes
            set.insert(next)
            tableView.selectRowIndexes(set, byExtendingSelection: false)
        } else {
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
        tableView.scrollRowToVisible(next)
    }

    private func selectRow(_ row: Int) {
        guard row >= 0, row < items.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    // MARK: - Actions

    private func pasteClip(atRow row: Int, plainText: Bool) {
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        if item.isGroup {
            enterGroup(item.id)
            return
        }
        performPaste(ids: [item.id], transform: .none, plainText: plainText, updateOrder: true)
    }

    private func pasteSelection(plainText: Bool = false,
                                transform: SpecialPaste.Transform = .none,
                                updateOrder: Bool = true) {
        let ids = selectedIDs
        guard ids.isEmpty == false else { return }
        performPaste(ids: ids, transform: transform, plainText: plainText, updateOrder: updateOrder)
    }

    private func performPaste(ids: [Int],
                              transform: SpecialPaste.Transform,
                              plainText: Bool,
                              updateOrder: Bool) {
        if Options.shared.hideDittoOnPaste {
            hide()
        }

        var request = PasteEngine.Request(clipIDs: ids)
        request.transform = transform
        request.plainTextOnly = plainText
        request.updateClipOrder = updateOrder
        request.fromGroup = groupID >= 0
        PasteEngine.paste(request)
    }

    /// COPY_SELECTION - put the clip back on the clipboard without pasting.
    private func copySelectionToClipboard() {
        let ids = selectedIDs
        guard ids.isEmpty == false else { return }
        var request = PasteEngine.Request(clipIDs: ids)
        request.sendPaste = false
        PasteEngine.paste(request)
        if Options.shared.hideDittoOnPaste { hide() }
    }

    private func enterGroup(_ id: Int) {
        groupStack.append(groupID)
        groupID = id
        starredOnly = false
        searchField.stringValue = ""
        searchText = ""
        loadedLimit = 300
        reload(resetSelection: true)
    }

    @objc private func goBack(_ sender: Any?) {
        if starredOnly {
            starredOnly = false
        } else if let previous = groupStack.popLast() {
            groupID = previous
        } else {
            groupID = -1
        }
        loadedLimit = 300
        reload(resetSelection: true)
    }

    private func deleteSelection() {
        let ids = selectedIDs
        guard ids.isEmpty == false else { return }

        if Options.shared.promptWhenDeletingClips {
            let alert = NSAlert()
            alert.messageText = ids.count == 1
                ? "Delete this clip?"
                : "Delete these \(ids.count) clips?"
            alert.informativeText = "Deleted clips cannot be brought back."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let row = tableView.selectedRow
        do {
            try repository.delete(ids: ids)
        } catch {
            presentError(error)
            return
        }
        reload(resetSelection: false)
        selectRow(min(row, items.count - 1))
    }

    private func editSelection() {
        guard let first = selectedItems().first, first.isGroup == false else { return }
        DittoController.shared.editClip(id: first.id)
    }

    private func toggleStarSelection() {
        let selected = selectedItems()
        guard selected.isEmpty == false else { return }
        let makeStarred = selected.contains { $0.isStarred == false }
        do {
            try repository.setStarred(ids: selected.map { $0.id }, starred: makeStarred)
        } catch {
            presentError(error)
        }
    }

    private func setSticky(_ position: ClipRepository.StickyPosition) {
        let ids = selectedIDs
        guard ids.isEmpty == false else { return }
        do {
            try repository.setSticky(ids: ids, position: position, inGroup: groupID)
        } catch {
            presentError(error)
        }
    }

    private func moveSelectionToTop() {
        let ids = selectedIDs
        guard ids.isEmpty == false else { return }
        do {
            try repository.moveToTop(ids: ids, inGroup: groupID)
        } catch {
            presentError(error)
        }
    }

    private func moveSelectionToLast() {
        let ids = selectedIDs
        guard ids.isEmpty == false else { return }
        do {
            try repository.moveToLast(ids: ids, inGroup: groupID)
        } catch {
            presentError(error)
        }
    }

    private func promptForNewGroup() {
        guard let name = TextPrompt.run(title: "New Group",
                                        message: "Name for the new group:",
                                        defaultValue: "",
                                        window: window) else { return }
        guard name.trimmingCharacters(in: .whitespaces).isEmpty == false else { return }
        do {
            _ = try repository.createGroup(named: name, parentID: groupID)
            reload(resetSelection: false)
        } catch {
            presentError(error)
        }
    }

    private func moveSelectionToGroup() {
        let ids = selectedIDs
        guard ids.isEmpty == false else { return }
        guard let target = GroupPicker.run(window: window,
                                           excluding: Set(ids)) else { return }
        do {
            try repository.move(ids: ids, toGroup: target)
            reload(resetSelection: false)
        } catch {
            presentError(error)
        }
    }

    private func showProperties() {
        guard let item = selectedItems().first else { return }
        ClipProperties.show(for: item, window: window)
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Ditto could not finish that"
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Context menu

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let selected = selectedItems()
        let isGroup = selected.first?.isGroup ?? false

        if isGroup {
            menu.addItem(withTitleAndAction("Open Group", #selector(contextOpenGroup(_:))))
        } else {
            menu.addItem(withTitleAndAction("Paste", #selector(contextPaste(_:))))
            menu.addItem(withTitleAndAction("Paste as Plain Text", #selector(contextPastePlain(_:))))
            menu.addItem(withTitleAndAction("Copy to Clipboard", #selector(contextCopy(_:))))

            let specialMenu = NSMenu()
            for transform in SpecialPaste.Transform.allCases where transform != .none {
                let item = NSMenuItem(title: transform.title,
                                      action: #selector(contextSpecialPaste(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = transform.rawValue
                specialMenu.addItem(item)
            }
            let specialItem = NSMenuItem(title: "Special Paste", action: nil, keyEquivalent: "")
            specialItem.submenu = specialMenu
            menu.addItem(specialItem)
        }

        menu.addItem(.separator())
        menu.addItem(withTitleAndAction("Edit Clip", #selector(contextEdit(_:))))
        menu.addItem(withTitleAndAction("Properties", #selector(contextProperties(_:))))
        menu.addItem(withTitleAndAction("Set Quick Paste Text", #selector(contextQuickPasteText(_:))))
        menu.addItem(withTitleAndAction("Set Shortcut", #selector(contextShortcut(_:))))

        menu.addItem(.separator())
        let starTitle = (selected.first?.isStarred ?? false) ? "Remove Star" : "Star Clip"
        menu.addItem(withTitleAndAction(starTitle, #selector(contextToggleStar(_:))))
        menu.addItem(withTitleAndAction("Stick to Top", #selector(contextStickTop(_:))))
        menu.addItem(withTitleAndAction("Stick to Bottom", #selector(contextStickLast(_:))))
        menu.addItem(withTitleAndAction("Remove Sticky", #selector(contextRemoveSticky(_:))))
        menu.addItem(withTitleAndAction("Move to Top", #selector(contextMoveTop(_:))))
        menu.addItem(withTitleAndAction("Move to Bottom", #selector(contextMoveLast(_:))))

        menu.addItem(.separator())
        menu.addItem(withTitleAndAction("Move to Group…", #selector(contextMoveToGroup(_:))))
        menu.addItem(withTitleAndAction("New Group…", #selector(contextNewGroup(_:))))

        menu.addItem(.separator())
        menu.addItem(withTitleAndAction("Save to File…", #selector(contextExport(_:))))
        menu.addItem(withTitleAndAction("Delete", #selector(contextDelete(_:))))

        return menu
    }

    private func withTitleAndAction(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func contextPaste(_ sender: Any?) { pasteSelection() }
    @objc private func contextPastePlain(_ sender: Any?) { pasteSelection(plainText: true) }
    @objc private func contextCopy(_ sender: Any?) { copySelectionToClipboard() }
    @objc private func contextOpenGroup(_ sender: Any?) {
        if let first = selectedItems().first, first.isGroup { enterGroup(first.id) }
    }
    @objc private func contextEdit(_ sender: Any?) { editSelection() }
    @objc private func contextProperties(_ sender: Any?) { showProperties() }
    @objc private func contextToggleStar(_ sender: Any?) { toggleStarSelection() }
    @objc private func contextStickTop(_ sender: Any?) { setSticky(.top) }
    @objc private func contextStickLast(_ sender: Any?) { setSticky(.last) }
    @objc private func contextRemoveSticky(_ sender: Any?) { setSticky(.none) }
    @objc private func contextMoveTop(_ sender: Any?) { moveSelectionToTop() }
    @objc private func contextMoveLast(_ sender: Any?) { moveSelectionToLast() }
    @objc private func contextMoveToGroup(_ sender: Any?) { moveSelectionToGroup() }
    @objc private func contextNewGroup(_ sender: Any?) { promptForNewGroup() }
    @objc private func contextDelete(_ sender: Any?) { deleteSelection() }

    @objc private func contextSpecialPaste(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let transform = SpecialPaste.Transform(rawValue: raw) else { return }
        pasteSelection(transform: transform)
    }

    @objc private func contextQuickPasteText(_ sender: Any?) {
        guard let item = selectedItems().first else { return }
        guard let text = TextPrompt.run(title: "Quick Paste Text",
                                        message: "A short name to search this clip by:",
                                        defaultValue: item.quickPasteText,
                                        window: window) else { return }
        do {
            try repository.setQuickPasteText(id: item.id, text: text)
        } catch {
            presentError(error)
        }
    }

    @objc private func contextShortcut(_ sender: Any?) {
        guard let item = selectedItems().first else { return }
        guard let result = HotKeyPrompt.run(window: window,
                                            current: HotKey(packed: item.shortcut)) else { return }
        do {
            switch result {
            case .set(let hotKey):
                try repository.setShortcut(id: item.id,
                                                      shortcut: hotKey.packed,
                                                      global: true)
            case .cleared:
                try repository.setShortcut(id: item.id, shortcut: 0, global: false)
            }
            HotKeyManager.shared.reload(controller: DittoController.shared)
        } catch {
            presentError(error)
        }
    }

    @objc private func contextExport(_ sender: Any?) {
        let ids = selectedIDs
        guard ids.isEmpty == false else { return }
        ImportExport.exportClips(ids: ids, window: window)
    }

    // MARK: - Window delegate

    func windowDidResize(_ notification: Notification) {
        layoutViews()
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        saveFrame()
    }

    func windowDidResignKey(_ notification: Notification) {
        // `GetAutoHide` - put the window away when it loses the keyboard,
        // unless the user pinned it.
        guard Options.shared.showPersistent == false else { return }
        // Wait a turn: a sheet or an alert also takes the key window away, and
        // NSApp stays active in that case, so this only fires when the user has
        // genuinely moved on to another application.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window else { return }
            guard NSApp.isActive == false else { return }
            if window.isKeyWindow == false && window.isVisible {
                self.hide(restoringFocus: false)
            }
        }
    }
}
