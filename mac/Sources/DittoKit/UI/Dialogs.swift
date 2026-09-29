import Foundation
import AppKit
import Carbon.HIToolbox

/// A one-line text prompt. Windows Ditto uses a resource dialog for the same
/// job (`CGroupName`, `CCopyProperties`); an NSAlert with an accessory field is
/// the macOS shape of it.
enum TextPrompt {

    static func run(title: String,
                    message: String,
                    defaultValue: String,
                    window: NSWindow?,
                    multiline: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        if multiline {
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
            textView.string = defaultValue
            textView.font = NSFont.userFixedPitchFont(ofSize: NSFont.systemFontSize)
            textView.isRichText = false

            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            alert.accessoryView = scroll
            alert.window.initialFirstResponder = textView

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return textView.string
        }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

/// Pick a group to move clips into - `CMoveToGroupDlg` on Windows.
enum GroupPicker {

    /// Returns the chosen group id, or -1 for "no group". Nil when cancelled.
    static func run(window: NSWindow?, excluding: Set<Int> = []) -> Int? {
        let groups = ((try? ClipRepository.shared.groups()) ?? [])
            .filter { excluding.contains($0.id) == false }

        let alert = NSAlert()
        alert.messageText = "Move to Group"
        alert.informativeText = "Choose where these clips should live."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "New Group…")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        popup.addItem(withTitle: "No group (main list)")
        popup.lastItem?.tag = -1
        for group in groups {
            popup.addItem(withTitle: group.desc.isEmpty ? "Group \(group.id)" : group.desc)
            popup.lastItem?.tag = group.id
        }
        alert.accessoryView = popup

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return popup.selectedItem?.tag ?? -1

        case .alertSecondButtonReturn:
            guard let name = TextPrompt.run(title: "New Group",
                                            message: "Name for the new group:",
                                            defaultValue: "",
                                            window: window),
                  name.trimmingCharacters(in: .whitespaces).isEmpty == false else { return nil }
            return try? ClipRepository.shared.createGroup(named: name)

        default:
            return nil
        }
    }
}

/// Capture a key combination. `CHotKeyCtrl` on Windows; here a small panel that
/// listens for one key press.
enum HotKeyPrompt {

    enum Result {
        case set(HotKey)
        case cleared
    }

    static func run(window: NSWindow?, current: HotKey?) -> Result? {
        let alert = NSAlert()
        alert.messageText = "Set Shortcut"
        alert.informativeText = """
            Press the keys you want to use, with at least one of \
            Command, Option, Control or Shift.
            """
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        let field = HotKeyCaptureField(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        field.hotKey = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let hotKey = field.hotKey else { return .cleared }
            return .set(hotKey)
        case .alertSecondButtonReturn:
            return .cleared
        default:
            return nil
        }
    }
}

/// The field the prompt above puts in front of the user: it shows the current
/// combination and replaces it with whatever is pressed next.
final class HotKeyCaptureField: NSTextField {

    var hotKey: HotKey? {
        didSet { refresh() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        alignment = .center
        font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        refresh()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isEditable = false
        isSelectable = false
        refresh()
    }

    private func refresh() {
        stringValue = hotKey?.description ?? "Press a key combination"
        textColor = hotKey == nil ? .secondaryLabelColor : .labelColor
    }

    override var acceptsFirstResponder: Bool { return true }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            super.keyDown(with: event)
            return
        }
        if let captured = HotKey(event: event) {
            hotKey = captured
        } else {
            NSSound.beep()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Take Command combinations too, rather than letting the menu eat them.
        if let captured = HotKey(event: event) {
            hotKey = captured
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// CLIP_PROPERTIES - what Ditto knows about one clip.
enum ClipProperties {

    static func show(for item: ClipListItem, window: NSWindow?) {
        let formats = (try? ClipRepository.shared.formatNames(clipID: item.id)) ?? []

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        var lines: [String] = []
        lines.append("Id: \(item.id)")
        lines.append("Copied: \(formatter.string(from: item.date))")
        lines.append("Last pasted: \(formatter.string(from: item.lastPasteDate))")
        lines.append("Group: \(item.parentID >= 0 ? String(item.parentID) : "none")")
        lines.append("Starred: \(item.isStarred ? "yes" : "no")")
        lines.append("Stuck: \(item.isSticky ? "yes" : "no")")
        if let hotKey = HotKey(packed: item.shortcut) {
            lines.append("Shortcut: \(hotKey.description)")
        }
        if item.quickPasteText.isEmpty == false {
            lines.append("Quick paste text: \(item.quickPasteText)")
        }
        lines.append("Formats: \(formats.map { ClipFormat.displayName($0) }.joined(separator: ", "))")

        let alert = NSAlert()
        alert.messageText = "Clip Properties"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
