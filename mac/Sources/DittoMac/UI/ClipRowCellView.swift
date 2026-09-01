import Foundation
import AppKit

/// Thumbnails for image clips, kept small and off the main path.
/// `GetDrawThumbnail` / `GetFastThumbnailMode` on Windows.
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSNumber, NSImage>()
    private let queue = DispatchQueue(label: "io.ditto.thumbnails", qos: .utility)
    private var inFlight: Set<Int> = []
    private let lock = NSLock()

    private init() {
        cache.countLimit = 300
    }

    func cached(for clipID: Int) -> NSImage? {
        return cache.object(forKey: NSNumber(value: clipID))
    }

    /// Load a thumbnail in the background; `completion` runs on the main queue
    /// only if there is something to show.
    func thumbnail(for clipID: Int, completion: @escaping (NSImage) -> Void) {
        if let cached = cached(for: clipID) {
            completion(cached)
            return
        }

        lock.lock()
        if inFlight.contains(clipID) {
            lock.unlock()
            return
        }
        inFlight.insert(clipID)
        lock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.lock.lock()
                self.inFlight.remove(clipID)
                self.lock.unlock()
            }

            var image: NSImage?
            let pngResult = try? ClipRepository.shared.loadFormat(clipID: clipID,
                                                                  format: ClipFormat.png)
            if let png = pngResult ?? nil, png.isEmpty == false {
                image = NSImage(data: png)
            } else {
                let dibResult = try? ClipRepository.shared.loadFormat(clipID: clipID,
                                                                      format: ClipFormat.dib)
                if let dib = dibResult ?? nil, dib.isEmpty == false {
                    image = BitmapHelper.image(fromDIB: dib)
                }
            }

            guard let loaded = image else { return }
            let thumbnail = BitmapHelper.thumbnail(loaded, maxSize: Theme.thumbnailSize)
            self.cache.setObject(thumbnail, forKey: NSNumber(value: clipID))

            DispatchQueue.main.async {
                completion(thumbnail)
            }
        }
    }

    func clear() {
        cache.removeAllObjects()
    }
}

/// One row of the quick paste list. The Windows original is `CQListCtrl`'s
/// owner-drawn row; this draws the same information: the 1-10 shortcut number,
/// markers for group / starred / stuck, the description over as many lines as
/// `LinesPerRow` allows, a thumbnail for images, and the clip's own shortcut.
final class ClipRowCellView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("DittoClipRow")

    private let badgeLabel = NSTextField(labelWithString: "")
    private let markerLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()

    private var clipID: Int = 0
    private var showsThumbnail = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        badgeLabel.font = Theme.badgeFont
        badgeLabel.textColor = Theme.shortcutBadgeText
        badgeLabel.alignment = .center
        badgeLabel.lineBreakMode = .byClipping

        markerLabel.font = Theme.listSecondaryFont
        markerLabel.alignment = .center

        bodyLabel.font = Theme.listFont
        bodyLabel.textColor = Theme.listText
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.cell?.wraps = true
        bodyLabel.cell?.isScrollable = false
        bodyLabel.maximumNumberOfLines = Options.shared.linesPerRow

        detailLabel.font = Theme.listSecondaryFont
        detailLabel.textColor = Theme.secondaryText
        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingHead

        thumbnailView.imageScaling = .scaleProportionallyDown
        thumbnailView.isHidden = true

        for view in [badgeLabel, markerLabel, bodyLabel, detailLabel, thumbnailView] as [NSView] {
            addSubview(view)
        }
    }

    // MARK: - Content

    func configure(with item: ClipListItem, position: Int?, isSelected: Bool) {
        clipID = item.id

        if let position = position,
           position <= Options.firstTenCount,
           Options.shared.showTextForFirstTenHotKeys {
            badgeLabel.stringValue = position == 10 ? "0" : "\(position)"
            badgeLabel.isHidden = false
        } else {
            badgeLabel.stringValue = ""
            badgeLabel.isHidden = true
        }

        var markers = ""
        if item.isGroup { markers += "▸" }
        if item.isSticky { markers += "📌" }
        if item.isStarred { markers += "★" }
        markerLabel.stringValue = markers
        markerLabel.textColor = item.isGroup ? Theme.groupColor
            : (item.isSticky ? Theme.stickyColor : Theme.starColor)

        bodyLabel.maximumNumberOfLines = Options.shared.linesPerRow
        bodyLabel.stringValue = ClipRowCellView.displayText(item.desc,
                                                            lines: Options.shared.linesPerRow)
        bodyLabel.textColor = isSelected ? Theme.selectionText : Theme.listText
        if item.isGroup {
            bodyLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        } else {
            bodyLabel.font = Theme.listFont
        }

        var detail: [String] = []
        if let hotKey = HotKey(packed: item.shortcut) {
            detail.append(hotKey.description)
        }
        if item.quickPasteText.isEmpty == false {
            detail.append(item.quickPasteText)
        }
        detailLabel.stringValue = detail.joined(separator: "  ")
        detailLabel.textColor = isSelected ? Theme.selectionText : Theme.secondaryText

        thumbnailView.image = nil
        thumbnailView.isHidden = true
        showsThumbnail = false

        if Options.shared.drawThumbnail && item.isGroup == false {
            let id = item.id
            ThumbnailCache.shared.thumbnail(for: id) { [weak self] image in
                guard let self = self, self.clipID == id else { return }
                self.thumbnailView.image = image
                self.thumbnailView.isHidden = false
                self.showsThumbnail = true
                self.needsLayout = true
            }
        }

        needsLayout = true
    }

    /// Port of `CMainTableFunctions::GetDisplayText` - collapse the clip's text
    /// into the number of lines the row has room for.
    static func displayText(_ text: String, lines: Int) -> String {
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")

        var kept: [String] = []
        for line in normalised.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty && kept.isEmpty { continue }   // skip leading blanks
            kept.append(trimmed)
            if kept.count >= max(1, lines) { break }
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let bounds = self.bounds
        var left = Theme.rowInset.left
        let top = Theme.rowInset.top
        let height = bounds.height - Theme.rowInset.top - Theme.rowInset.bottom

        if badgeLabel.isHidden == false {
            badgeLabel.frame = NSRect(x: left, y: top,
                                      width: Theme.shortcutColumnWidth,
                                      height: min(height, 18))
            left += Theme.shortcutColumnWidth + 2
        }

        if markerLabel.stringValue.isEmpty == false {
            markerLabel.frame = NSRect(x: left, y: top,
                                       width: Theme.markerColumnWidth,
                                       height: min(height, 18))
            left += Theme.markerColumnWidth + 2
        }

        var right = bounds.width - Theme.rowInset.right

        if showsThumbnail, thumbnailView.image != nil {
            let size = Theme.thumbnailSize
            let width = min(size.width, height)
            thumbnailView.frame = NSRect(x: right - width,
                                         y: (bounds.height - width) / 2,
                                         width: width, height: width)
            right -= width + 6
        }

        let detailWidth = detailLabel.stringValue.isEmpty
            ? 0
            : min(140, detailLabel.intrinsicContentSize.width + 4)
        if detailWidth > 0 {
            detailLabel.frame = NSRect(x: right - detailWidth, y: top,
                                       width: detailWidth, height: min(height, 16))
            right -= detailWidth + 6
        } else {
            detailLabel.frame = .zero
        }

        bodyLabel.frame = NSRect(x: left, y: top,
                                 width: max(20, right - left),
                                 height: height)
    }
}
