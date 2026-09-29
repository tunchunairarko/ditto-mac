import Foundation
import AppKit

/// Port of `CEditWnd` / `CEditFrameWnd` (EditWnd.cpp) - EDITCLIP.
///
/// Editing a clip replaces its text. The other formats it carried (RTF, HTML,
/// an image) no longer match the new text, so they are dropped - the same
/// choice the Windows editor makes.
final class ClipEditorWindowController: NSWindowController, NSWindowDelegate {

    private let clipID: Int
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let saveButton = NSButton()
    private let cancelButton = NSButton()
    private let noticeLabel = NSTextField(labelWithString: "")

    var onClose: (() -> Void)?

    init(clipID: Int) {
        self.clipID = clipID

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Edit Clip"
        window.center()

        super.init(window: window)
        window.delegate = self
        buildViews()
        load()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func buildViews() {
        guard let content = window?.contentView else { return }

        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.userFixedPitchFont(ofSize: NSFont.systemFontSize)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autoresizingMask = [.width, .height]

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.autoresizingMask = [.minXMargin, .maxYMargin]

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.autoresizingMask = [.minXMargin, .maxYMargin]

        noticeLabel.font = Theme.listSecondaryFont
        noticeLabel.textColor = Theme.secondaryText
        noticeLabel.autoresizingMask = [.width, .maxYMargin]

        for view in [scrollView, saveButton, cancelButton, noticeLabel] as [NSView] {
            content.addSubview(view)
        }

        layoutViews()
        content.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(frameChanged(_:)),
                                               name: NSView.frameDidChangeNotification,
                                               object: content)
    }

    @objc private func frameChanged(_ notification: Notification) {
        layoutViews()
    }

    private func layoutViews() {
        guard let content = window?.contentView else { return }
        let bounds = content.bounds
        let margin: CGFloat = 12
        let buttonHeight: CGFloat = 24
        let buttonWidth: CGFloat = 84

        cancelButton.frame = NSRect(x: bounds.width - margin - buttonWidth,
                                    y: margin, width: buttonWidth, height: buttonHeight)
        saveButton.frame = NSRect(x: bounds.width - margin * 2 - buttonWidth * 2,
                                  y: margin, width: buttonWidth, height: buttonHeight)
        noticeLabel.frame = NSRect(x: margin, y: margin + 3,
                                   width: bounds.width - margin * 3 - buttonWidth * 2,
                                   height: buttonHeight - 4)

        let top = margin + buttonHeight + margin
        scrollView.frame = NSRect(x: margin, y: top,
                                  width: bounds.width - margin * 2,
                                  height: max(60, bounds.height - top - margin))
    }

    private func load() {
        guard let clip = try? ClipRepository.shared.loadClip(id: clipID) else {
            textView.string = ""
            return
        }

        textView.string = clip.text ?? ""

        var extras = clip.formats.map { $0.format }
            .filter { ClipFormat.isTextFormat($0) == false }
        extras = Array(Set(extras)).sorted()

        if extras.isEmpty {
            noticeLabel.stringValue = ""
        } else {
            let names = extras.map { ClipFormat.displayName($0) }.joined(separator: ", ")
            noticeLabel.stringValue = "Saving will drop: \(names)"
        }
    }

    @objc private func save(_ sender: Any?) {
        do {
            try ClipRepository.shared.replaceText(id: clipID, text: textView.string)
            ThumbnailCache.shared.clear()
            close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Ditto could not save the clip"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }
}
