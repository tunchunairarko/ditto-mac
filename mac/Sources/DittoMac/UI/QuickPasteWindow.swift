import Foundation
import AppKit

/// The window itself. A panel rather than a normal window so it can float over
/// other applications, and one that is allowed to take the keyboard - the whole
/// point of the quick paste window is that you type into it.
final class QuickPastePanel: NSPanel {

    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    /// Escape closes the window, as it does on Windows (CLOSEWINDOW).
    override func cancelOperation(_ sender: Any?) {
        (delegate as? QuickPasteWindowController)?.escapePressed()
    }
}

/// A table view that leaves the arrow keys and Return to the controller, so the
/// search field can keep the focus while the list is being driven from the
/// keyboard - the behaviour `GetFindAsYouType` describes on Windows.
final class ClipTableView: NSTableView {

    weak var keyDelegate: QuickPasteWindowController?

    override func keyDown(with event: NSEvent) {
        if keyDelegate?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 && selectedRowIndexes.contains(row) == false {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return keyDelegate?.buildContextMenu()
    }
}
