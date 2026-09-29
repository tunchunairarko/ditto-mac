import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// Port of `CProcessPaste` (ProcessPaste.cpp) and `CSendKeys` (SendKeys.cpp).
///
/// The sequence is Ditto's: put the clip on the clipboard, hide our own window,
/// bring the target application back to the front, then send the paste
/// keystroke and record that the clip was pasted. What differs is the last two
/// steps - macOS needs the app activated explicitly, and the keystroke goes
/// through `CGEvent` rather than `SendInput`.
enum PasteEngine {

    struct Request {
        var clipIDs: [Int]
        var transform: SpecialPaste.Transform = .none
        var plainTextOnly: Bool = false
        /// Actually send Command+V, rather than only loading the clipboard.
        var sendPaste: Bool = true
        /// Move the pasted clips back to the top of the list.
        var updateClipOrder: Bool = true
        /// The clips came from inside a group, so the group order moves too.
        var fromGroup: Bool = false
        /// Separator between clips when several are pasted at once.
        var separator: String = "\r\n"
    }

    /// Load the clipboard and, unless asked not to, paste.
    @discardableResult
    static func paste(_ request: Request) -> Bool {
        guard request.clipIDs.isEmpty == false else { return false }

        var clips: [Clip] = []
        do {
            for id in request.clipIDs {
                if let clip = try ClipRepository.shared.loadClip(id: id) {
                    clips.append(clip)
                }
            }
        } catch {
            Log.error("could not load clips to paste: \(error)")
            return false
        }
        guard clips.isEmpty == false else { return false }

        let formats = buildFormats(clips: clips, request: request)
        guard formats.isEmpty == false else { return false }

        // Optionally put the user's own clipboard back afterwards.
        let snapshot = Options.shared.restoreClipboardAfterPaste
            ? PasteboardBridge.snapshot()
            : nil

        ClipboardMonitor.shared.suppressNextChange()
        let plainTextOnly = request.plainTextOnly || request.transform.forcesPlainText
        let wrote = PasteboardBridge.write(formats,
                                           to: .general,
                                           plainTextOnly: plainTextOnly)
        guard wrote else {
            Log.error("nothing could be put on the clipboard")
            return false
        }

        ClipRepository.shared.markAsPasted(ids: request.clipIDs,
                                           updateClipOrder: request.updateClipOrder,
                                           fromGroup: request.fromGroup)

        guard request.sendPaste && Options.shared.sendPasteAfterSelection else {
            return true
        }

        sendPasteKeystroke(restoring: snapshot)
        return true
    }

    /// Put a plain string on the clipboard and paste it. Used by the copy
    /// buffers and the "paste as ..." actions that do not start from a clip.
    static func paste(text: String, sendPaste: Bool = true) {
        ClipboardMonitor.shared.suppressNextChange()
        PasteboardBridge.write(text: text, to: .general)
        if sendPaste && Options.shared.sendPasteAfterSelection {
            sendPasteKeystroke(restoring: nil)
        }
    }

    // MARK: - Building the payload

    private static func buildFormats(clips: [Clip], request: Request) -> [ClipFormatData] {
        if clips.count == 1 {
            return SpecialPaste.formats(for: clips[0],
                                        transform: request.transform,
                                        plainTextOnly: request.plainTextOnly)
        }

        // Several clips at once: Ditto concatenates the text and keeps the
        // files. See `CClipIDs::AggregateData`.
        var text = SpecialPaste.aggregateText(clips,
                                              separator: request.separator,
                                              reverse: false)
        if request.transform != .none {
            text = SpecialPaste.apply(request.transform, to: text)
        }

        var formats = [
            ClipFormatData(ClipFormat.unicodeText, ClipFormat.encodeUnicodeText(text)),
            ClipFormatData(ClipFormat.text, ClipFormat.encodeText(text))
        ]

        if request.plainTextOnly == false {
            var paths: [String] = []
            for clip in clips {
                paths.append(contentsOf: clip.filePaths)
            }
            if paths.isEmpty == false {
                formats.append(ClipFormatData(ClipFormat.fileDrop,
                                              ClipFormat.encodeFileDrop(paths)))
            }
        }

        return formats
    }

    // MARK: - The keystroke

    /// Bring the target app forward and send Command+V to it.
    static func sendPasteKeystroke(restoring snapshot: PasteboardBridge.Snapshot?) {
        guard Accessibility.isTrusted else {
            Log.write("no Accessibility permission - the clip is on the clipboard, not pasted")
            NotificationCenter.default.post(name: .dittoNeedsAccessibility, object: nil)
            return
        }

        let activated = FrontAppTracker.shared.activateTarget()
        if activated == false {
            Log.write("no target application to paste into")
        }

        let delay = Double(Options.shared.pasteDelayMilliseconds) / 1000.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            postCommandV()

            if let snapshot = snapshot {
                // Give the target a moment to read the clipboard before it is
                // put back the way the user had it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    ClipboardMonitor.shared.suppressNextChange()
                    PasteboardBridge.restore(snapshot)
                }
            }
        }
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        // Let the user's own input through while the synthetic event goes out;
        // without this, a key they are still holding can be swallowed.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            return
        }

        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        Log.write("sent Command+V")
    }
}

extension Notification.Name {
    /// Raised when a paste could not be sent for want of Accessibility access.
    static let dittoNeedsAccessibility = Notification.Name("io.ditto.needsAccessibility")
}
