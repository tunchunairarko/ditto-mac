import Foundation
import AppKit

/// Port of `Theme.cpp` - the colours and metrics the quick paste list draws
/// with. Windows Ditto ships its own light and dark palettes; on macOS the
/// system semantic colours already follow the user's appearance, so this maps
/// Ditto's roles onto those and only adds the few colours it does not have.
enum Theme {

    /// Apply the user's appearance choice to a window.
    static func apply(to window: NSWindow?) {
        guard let window = window else { return }
        switch Options.shared.appearance {
        case .system:
            window.appearance = nil
        case .light:
            window.appearance = NSAppearance(named: .aqua)
        case .dark:
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static var listBackground: NSColor { return .controlBackgroundColor }
    static var listText: NSColor { return .labelColor }
    static var secondaryText: NSColor { return .secondaryLabelColor }
    static var selectionBackground: NSColor { return .selectedContentBackgroundColor }
    static var selectionText: NSColor { return .alternateSelectedControlTextColor }
    static var separator: NSColor { return .separatorColor }

    /// The badge behind the 1-10 shortcut numbers.
    static var shortcutBadgeBackground: NSColor {
        return NSColor.controlAccentColor.withAlphaComponent(0.16)
    }

    static var shortcutBadgeText: NSColor { return .controlAccentColor }

    /// Starred clips (`lDontAutoDelete`) and stuck clips get a marker in the
    /// margin, as they do on Windows.
    static var starColor: NSColor { return .systemYellow }
    static var stickyColor: NSColor { return .systemOrange }
    static var groupColor: NSColor { return .systemBlue }

    // MARK: - Metrics

    static let rowInset = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    static let thumbnailSize = NSSize(width: 44, height: 44)
    static let markerColumnWidth: CGFloat = 22
    static let shortcutColumnWidth: CGFloat = 30

    static var listFont: NSFont {
        return NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }

    static var listSecondaryFont: NSFont {
        return NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    }

    static var badgeFont: NSFont {
        return NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                weight: .medium)
    }

    /// `GetLinesPerRow` turned into a pixel height.
    static func rowHeight(lines: Int) -> CGFloat {
        let lineHeight = ceil(listFont.ascender - listFont.descender + listFont.leading) + 2
        return max(24, lineHeight * CGFloat(max(1, lines)) + rowInset.top + rowInset.bottom)
    }
}
