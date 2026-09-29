import Foundation
import AppKit

/// Port of `CCopyThread` / `CClipboardViewer` (CopyThread.cpp,
/// ClipboardViewer.cpp).
///
/// Windows hands Ditto a message when the clipboard changes. macOS has no such
/// notification, so the only way to notice a copy is to watch
/// `NSPasteboard.changeCount`. Everything else - the copy gap, the delay before
/// reading, the ignore rules, the size limit - is Ditto's logic unchanged.
final class ClipboardMonitor {

    static let shared = ClipboardMonitor()

    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var lastSaveTime: Date = .distantPast
    /// Set while Ditto itself is writing the pasteboard, so a paste is not
    /// recorded as a fresh copy. Windows Ditto uses the same trick.
    private var suppressUntilChangeCount: Int = -1

    private(set) var isConnected = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        lastChangeCount = pasteboard.changeCount
        isConnected = Options.shared.captureEnabled
        restartTimer()
        Log.write("clipboard monitor started (connected: \(isConnected))")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = Double(Options.shared.pollIntervalMilliseconds) / 1000.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// TOGGLE_CLIPBOARD_CONNECTION - the tray menu's "connect to clipboard".
    func setConnected(_ connected: Bool) {
        isConnected = connected
        Options.shared.captureEnabled = connected
        lastChangeCount = pasteboard.changeCount
        Log.write("clipboard monitor \(connected ? "connected" : "disconnected")")
        NotificationCenter.default.post(name: .dittoOptionsChanged, object: nil)
    }

    func toggleConnected() {
        setConnected(isConnected == false)
    }

    /// Called by the paste path so Ditto does not re-record its own writes.
    func suppressNextChange() {
        suppressUntilChangeCount = pasteboard.changeCount + 1
    }

    func optionsChanged() {
        restartTimer()
        if isConnected != Options.shared.captureEnabled {
            isConnected = Options.shared.captureEnabled
        }
    }

    // MARK: - Polling

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if changeCount <= suppressUntilChangeCount {
            Log.write("ignoring our own pasteboard write")
            return
        }

        guard isConnected else { return }

        // `GetSaveClipDelay` - some apps write the pasteboard in stages, so let
        // them finish before reading it.
        let delay = Double(Options.shared.saveClipDelay) / 1000.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            // If something changed again while waiting, that poll will handle it.
            guard self.pasteboard.changeCount == changeCount else { return }
            self.capture(reason: .copy)
        }
    }

    enum CaptureReason {
        case copy
        /// SAVE_CURRENT_CLIPBOARD - the user asked for this one explicitly, so
        /// the gap and the connection state do not apply.
        case explicit
    }

    /// Read the pasteboard and store it. Returns the new clip's id, if any.
    @discardableResult
    func capture(reason: CaptureReason) -> Int? {
        let options = Options.shared

        if reason == .copy {
            // `GetCopyGap` - ignore a second copy that lands right after one we
            // just saved; some apps write the clipboard several times per copy.
            let elapsed = Date().timeIntervalSince(lastSaveTime) * 1000
            if elapsed < Double(options.copyGap) {
                Log.write("inside the copy gap (\(Int(elapsed))ms), skipping")
                return nil
            }

            if PasteboardBridge.shouldIgnore(pasteboard) { return nil }

            if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               options.ignoredBundleIdentifiers.contains(bundleID) {
                Log.write("ignoring a copy from \(bundleID)")
                return nil
            }
        }

        let formats = PasteboardBridge.read(from: pasteboard,
                                            enabledFormats: options.enabledFormats)
        guard formats.isEmpty == false else { return nil }

        let total = formats.reduce(0) { $0 + $1.bytes.count }
        if options.maxClipSizeInBytes > 0 && total > options.maxClipSizeInBytes {
            Log.write("clip of \(total) bytes is over the limit, skipping")
            return nil
        }

        let clip = Clip()
        clip.formats = formats
        clip.date = Date()
        clip.lastPasteDate = Date()
        clip.sourceApplication = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        clip.generateDescription()

        do {
            let result = try ClipRepository.shared.add(clip)
            lastSaveTime = Date()

            switch result {
            case .added(let id):
                options.recordCopy()
                if options.playSoundOnCopy { NSSound.beep() }
                return id
            case .duplicate(let id):
                return id
            case .skipped:
                return nil
            }
        } catch {
            Log.error("could not save clip: \(error)")
            return nil
        }
    }
}
