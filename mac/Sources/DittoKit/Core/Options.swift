import Foundation
import AppKit

extension Notification.Name {
    /// Posted whenever any option changes, so open windows can re-read them.
    /// Equivalent to Windows Ditto broadcasting WM_LOAD_SETTINGS.
    static let dittoOptionsChanged = Notification.Name("io.ditto.optionsChanged")
}

/// Port of `CGetSetOptions` (Options.cpp/.h).
///
/// Windows Ditto stores these in the registry or in `Ditto.ini`; on macOS the
/// natural home is `NSUserDefaults`. The keys deliberately keep Ditto's own
/// names ("MaxEntries", "CopyGap", ...) so the two stay easy to compare, and
/// so a user who knows the Windows options can find the same knob here.
final class Options {

    /// A `var`, and the initialiser takes its store, so a test can install an
    /// instance backed by a throwaway suite instead of the real user defaults.
    /// Nothing in the app reassigns it.
    static var shared = Options()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Backing store

    private func long(_ key: String, _ fallback: Int) -> Int {
        if defaults.object(forKey: key) == nil { return fallback }
        return defaults.integer(forKey: key)
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        if defaults.object(forKey: key) == nil { return fallback }
        return defaults.bool(forKey: key)
    }

    private func double(_ key: String, _ fallback: Double) -> Double {
        if defaults.object(forKey: key) == nil { return fallback }
        return defaults.double(forKey: key)
    }

    private func string(_ key: String, _ fallback: String) -> String {
        return defaults.string(forKey: key) ?? fallback
    }

    private func set(_ key: String, _ value: Any?) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Let anything that caches option values know they are stale.
    func notifyChanged() {
        NotificationCenter.default.post(name: .dittoOptionsChanged, object: nil)
    }

    // MARK: - Database

    var databasePath: String {
        get { string("DBPath", Paths.defaultDatabaseURL.path) }
        set { set("DBPath", newValue) }
    }

    var databaseURL: URL {
        return Paths.resolveDatabasePath(databasePath)
    }

    // MARK: - Capture

    /// `GetCopyOnChange` - whether the clipboard monitor is connected.
    var captureEnabled: Bool {
        get { bool("CopyOnChange", true) }
        set { set("CopyOnChange", newValue) }
    }

    /// `GetCopyGap` - minimum ms between two saved clips.
    var copyGap: Int {
        get { long("CopyGap", 150) }
        set { set("CopyGap", newValue) }
    }

    /// `GetSaveClipDelay` - how long to let a slow app finish writing the
    /// pasteboard before reading it.
    var saveClipDelay: Int {
        get { long("SaveClipDelay", 500) }
        set { set("SaveClipDelay", newValue) }
    }

    /// macOS has no clipboard-change notification, so the monitor polls
    /// `NSPasteboard.changeCount`. This is that interval, in milliseconds.
    var pollIntervalMilliseconds: Int {
        get { max(50, long("PollInterval", 250)) }
        set { set("PollInterval", newValue) }
    }

    /// `GetAllowDuplicates` - when false a copy that matches an existing clip's
    /// CRC just moves that clip to the top instead of adding a new row.
    var allowDuplicates: Bool {
        get { bool("AllowDuplicates", false) }
        set { set("AllowDuplicates", newValue) }
    }

    /// `GetAdjustClipsForCRC` - normalise RTF before hashing so that Word and
    /// Outlook's ever-changing rsid values don't defeat duplicate detection.
    var adjustClipsForCRC: Bool {
        get { bool("AdjustClipsForCRC", true) }
        set { set("AdjustClipsForCRC", newValue) }
    }

    /// `GetMaxClipSizeInBytes` - 0 means no limit.
    var maxClipSizeInBytes: Int {
        get { long("MaxClipSizeInBytes", 0) }
        set { set("MaxClipSizeInBytes", newValue) }
    }

    /// `GetDescTextSize` - how much of the text is kept as the description.
    var descriptionTextSize: Int {
        get { max(16, long("DescTextSize", 500)) }
        set { set("DescTextSize", newValue) }
    }

    var descriptionShowsLeadingWhitespace: Bool {
        get { bool("DescShowLeadingWhiteSpace", false) }
        set { set("DescShowLeadingWhiteSpace", newValue) }
    }

    /// Formats Ditto is allowed to store. Mirrors the "Types" option page.
    var enabledFormats: Set<String> {
        get {
            if let saved = defaults.array(forKey: "EnabledFormats") as? [String] {
                return Set(saved)
            }
            return Set(ClipFormat.defaultEnabledFormats)
        }
        set { set("EnabledFormats", Array(newValue).sorted()) }
    }

    /// Bundle identifiers Ditto must never capture from (password managers and
    /// the like). Equivalent to Windows Ditto's "Ignore these programs" list.
    var ignoredBundleIdentifiers: [String] {
        get {
            if let saved = defaults.array(forKey: "IgnoredBundleIdentifiers") as? [String] {
                return saved
            }
            return Options.defaultIgnoredBundleIdentifiers
        }
        set { set("IgnoredBundleIdentifiers", newValue) }
    }

    static let defaultIgnoredBundleIdentifiers = [
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess"
    ]

    /// Honour `org.nspasteboard.ConcealedType` and friends - the macOS
    /// convention by which password managers ask clipboard tools to skip an
    /// item. There is no Windows equivalent; the closest is the
    /// `Clipboard Viewer Ignore` format, which Ditto already respects.
    var honourConcealedPasteboardTypes: Bool {
        get { bool("HonourConcealedTypes", true) }
        set { set("HonourConcealedTypes", newValue) }
    }

    // MARK: - Auto delete

    var checkForMaxEntries: Bool {
        get { bool("CheckForMaxEntries", false) }
        set { set("CheckForMaxEntries", newValue) }
    }

    var maxEntries: Int {
        get { long("MaxEntries", 500) }
        set { set("MaxEntries", newValue) }
    }

    var checkForExpiredEntries: Bool {
        get { bool("CheckForExpiredEntries", false) }
        set { set("CheckForExpiredEntries", newValue) }
    }

    /// Days a clip may go unpasted before it is removed.
    var expiredEntries: Int {
        get { long("ExpiredEntries", 5) }
        set { set("ExpiredEntries", newValue) }
    }

    /// `GetIdleSecondsBeforeDelete` - only drain the delete queue once the
    /// machine has been idle this long, so deleting never fights the UI.
    var idleSecondsBeforeDelete: Int {
        get { long("IdleSecondsBeforeDelete", 10) }
        set { set("IdleSecondsBeforeDelete", newValue) }
    }

    /// `GetMainDeletesDeleteCount` - rows drained from MainDeletes per pass.
    var mainDeletesDeleteCount: Int {
        get { long("MainDeletesDeleteCount", 5) }
        set { set("MainDeletesDeleteCount", newValue) }
    }

    var promptWhenDeletingClips: Bool {
        get { bool("PromptWhenDeletingClips", true) }
        set { set("PromptWhenDeletingClips", newValue) }
    }

    // MARK: - Quick paste window

    var quickPasteWidth: Double {
        get { double("QuickPasteWidth", 480) }
        set { set("QuickPasteWidth", newValue) }
    }

    var quickPasteHeight: Double {
        get { double("QuickPasteHeight", 520) }
        set { set("QuickPasteHeight", newValue) }
    }

    var quickPasteX: Double {
        get { double("QuickPasteX", -1) }
        set { set("QuickPasteX", newValue) }
    }

    var quickPasteY: Double {
        get { double("QuickPasteY", -1) }
        set { set("QuickPasteY", newValue) }
    }

    /// `GetQuickPastePosition` - where the window appears when summoned.
    var quickPastePosition: QuickPastePosition {
        get { QuickPastePosition(rawValue: long("QuickPastePosition", QuickPastePosition.atCursor.rawValue)) ?? .atCursor }
        set { set("QuickPastePosition", newValue.rawValue) }
    }

    enum QuickPastePosition: Int, CaseIterable {
        case atCursor = 0
        case lastPosition = 1
        case screenCenter = 2
        case activeWindowCenter = 3

        var title: String {
            switch self {
            case .atCursor: return "At the mouse cursor"
            case .lastPosition: return "Where I left it"
            case .screenCenter: return "Centred on the screen"
            case .activeWindowCenter: return "Centred on the active window"
            }
        }
    }

    var linesPerRow: Int {
        get { max(1, min(10, long("LinesPerRow", 2))) }
        set { set("LinesPerRow", newValue) }
    }

    var showPersistent: Bool {
        get { bool("ShowPersistent", false) }
        set { set("ShowPersistent", newValue) }
    }

    var hideDittoOnPaste: Bool {
        get { bool("HideDittoOnPaste", true) }
        set { set("HideDittoOnPaste", newValue) }
    }

    var hideOnHotKeyIfAlreadyShown: Bool {
        get { bool("HideDittoOnHotKeyIfAlreadyShown", true) }
        set { set("HideDittoOnHotKeyIfAlreadyShown", newValue) }
    }

    var findAsYouType: Bool {
        get { bool("FindAsYouType", true) }
        set { set("FindAsYouType", newValue) }
    }

    var drawThumbnail: Bool {
        get { bool("DrawThumbnail", true) }
        set { set("DrawThumbnail", newValue) }
    }

    var showAllClipsInMainList: Bool {
        get { bool("ShowAllClipsInMainList", true) }
        set { set("ShowAllClipsInMainList", newValue) }
    }

    var showGroupsInMainList: Bool {
        get { bool("ShowGroupsInMainList", true) }
        set { set("ShowGroupsInMainList", newValue) }
    }

    /// `GetUseCtrlNumForFirstTenHotKeys` - on macOS this is Command+1..0
    /// inside the quick paste window.
    var useNumbersForFirstTenHotKeys: Bool {
        get { bool("UseCtrlNumForFirstTenHotKeys", true) }
        set { set("UseCtrlNumForFirstTenHotKeys", newValue) }
    }

    var showTextForFirstTenHotKeys: Bool {
        get { bool("ShowTextForFirstTenHotKeys", true) }
        set { set("ShowTextForFirstTenHotKeys", newValue) }
    }

    var updateTimeOnPaste: Bool {
        get { bool("UpdateTimeOnPaste", true) }
        set { set("UpdateTimeOnPaste", newValue) }
    }

    /// `GetSendPasteAfterSelection` - actually send Command+V after putting the
    /// clip on the pasteboard, rather than only loading the pasteboard.
    var sendPasteAfterSelection: Bool {
        get { bool("SendPasteAfterSelection", true) }
        set { set("SendPasteAfterSelection", newValue) }
    }

    /// Milliseconds to wait after re-activating the target app before the
    /// synthetic Command+V. Windows Ditto has the same knob for its SendKeys.
    var pasteDelayMilliseconds: Int {
        get { max(0, long("PasteDelay", 120)) }
        set { set("PasteDelay", newValue) }
    }

    /// Put the clipboard back the way it was after pasting a clip.
    var restoreClipboardAfterPaste: Bool {
        get { bool("RestoreClipboardAfterPaste", false) }
        set { set("RestoreClipboardAfterPaste", newValue) }
    }

    var enableTransparency: Bool {
        get { bool("EnableTransparency", false) }
        set { set("EnableTransparency", newValue) }
    }

    var transparencyPercent: Int {
        get { max(0, min(90, long("Transparency", 15))) }
        set { set("Transparency", newValue) }
    }

    // MARK: - Searching

    var searchDescription: Bool {
        get { bool("SearchDescription", true) }
        set { set("SearchDescription", newValue) }
    }

    var searchQuickPaste: Bool {
        get { bool("SearchQuickPaste", false) }
        set { set("SearchQuickPaste", newValue) }
    }

    var searchFullText: Bool {
        get { bool("SearchFullText", false) }
        set { set("SearchFullText", newValue) }
    }

    /// `GetSimpleTextSearch` - treat the whole box as one literal phrase.
    var simpleTextSearch: Bool {
        get { bool("SimpleTextSearch", false) }
        set { set("SimpleTextSearch", newValue) }
    }

    /// `GetRegExTextSearch` - the search text is a regular expression.
    var regExTextSearch: Bool {
        get { bool("RegExTextSearch", false) }
        set { set("RegExTextSearch", newValue) }
    }

    var caseSensitiveSearch: Bool {
        get { bool("CaseSensitiveSearch", false) }
        set { set("CaseSensitiveSearch", newValue) }
    }

    // MARK: - Hot keys (see HotKey.swift for the string format)

    var showQuickPasteHotKey: String {
        get { string("ShowDittoHotKey", "ctrl+`") }
        set { set("ShowDittoHotKey", newValue) }
    }

    var showQuickPasteHotKey2: String {
        get { string("ShowDittoHotKey2", "cmd+shift+v") }
        set { set("ShowDittoHotKey2", newValue) }
    }

    var textOnlyPasteHotKey: String {
        get { string("TextOnlyPasteHotKey", "") }
        set { set("TextOnlyPasteHotKey", newValue) }
    }

    var saveClipboardHotKey: String {
        get { string("SaveClipboardHotKey", "") }
        set { set("SaveClipboardHotKey", newValue) }
    }

    var showStarredClipsHotKey: String {
        get { string("ShowStarredClipsHotKey", "") }
        set { set("ShowStarredClipsHotKey", newValue) }
    }

    /// Global "paste clip at position N" hot keys, N in 1...10.
    func pastePositionHotKey(_ position: Int) -> String {
        return string("PastePositionHotKey\(position)", "")
    }

    func setPastePositionHotKey(_ position: Int, _ value: String) {
        set("PastePositionHotKey\(position)", value)
    }

    /// Copy buffers - Windows Ditto's Ctrl+Shift+1..5 / Ctrl+1..5 pairs.
    func copyBufferHotKey(_ buffer: Int) -> String {
        return string("CopyBufferHotKey\(buffer)", "")
    }

    func setCopyBufferHotKey(_ buffer: Int, _ value: String) {
        set("CopyBufferHotKey\(buffer)", value)
    }

    func pasteBufferHotKey(_ buffer: Int) -> String {
        return string("PasteBufferHotKey\(buffer)", "")
    }

    func setPasteBufferHotKey(_ buffer: Int, _ value: String) {
        set("PasteBufferHotKey\(buffer)", value)
    }

    static let copyBufferCount = 5
    static let firstTenCount = 10

    // MARK: - Appearance

    var appearance: AppearanceSetting {
        get { AppearanceSetting(rawValue: long("Appearance", 0)) ?? .system }
        set { set("Appearance", newValue.rawValue) }
    }

    enum AppearanceSetting: Int, CaseIterable {
        case system = 0
        case light = 1
        case dark = 2

        var title: String {
            switch self {
            case .system: return "Match System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    var showIconInMenuBar: Bool {
        get { bool("ShowIconInSysTray", true) }
        set { set("ShowIconInSysTray", newValue) }
    }

    var playSoundOnCopy: Bool {
        get { bool("PlaySoundOnCopy", false) }
        set { set("PlaySoundOnCopy", newValue) }
    }

    var enableDebugLogging: Bool {
        get { bool("EnableDebugLogging", false) }
        set { set("EnableDebugLogging", newValue) }
    }

    var runOnStartup: Bool {
        get { bool("RunOnStartUp", false) }
        set { set("RunOnStartUp", newValue) }
    }

    var hasCompletedFirstRun: Bool {
        get { bool("CompletedFirstRun", false) }
        set { set("CompletedFirstRun", newValue) }
    }

    // MARK: - Statistics (OptionsStats.cpp)

    var totalCopyCount: Int {
        get { long("TotalCopyCount", 0) }
        set { set("TotalCopyCount", newValue) }
    }

    var totalPasteCount: Int {
        get { long("TotalPasteCount", 0) }
        set { set("TotalPasteCount", newValue) }
    }

    var totalDate: Double {
        get { double("TotalDate", 0) }
        set { set("TotalDate", newValue) }
    }

    var tripCopyCount: Int {
        get { long("TripCopyCount", 0) }
        set { set("TripCopyCount", newValue) }
    }

    var tripPasteCount: Int {
        get { long("TripPasteCount", 0) }
        set { set("TripPasteCount", newValue) }
    }

    var tripDate: Double {
        get { double("TripDate", 0) }
        set { set("TripDate", newValue) }
    }

    func recordCopy() {
        if totalDate == 0 { totalDate = Date().timeIntervalSince1970 }
        if tripDate == 0 { tripDate = Date().timeIntervalSince1970 }
        totalCopyCount += 1
        tripCopyCount += 1
    }

    func recordPaste() {
        if totalDate == 0 { totalDate = Date().timeIntervalSince1970 }
        if tripDate == 0 { tripDate = Date().timeIntervalSince1970 }
        totalPasteCount += 1
        tripPasteCount += 1
    }

    func resetTripStatistics() {
        tripCopyCount = 0
        tripPasteCount = 0
        tripDate = Date().timeIntervalSince1970
    }
}
