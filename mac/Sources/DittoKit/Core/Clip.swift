import Foundation
import AppKit

/// Port of `CClip` (Clip.cpp) - one row of `Main` plus its `Data` rows.
final class Clip {

    var id: Int = 0
    var date: Date = Date()
    var lastPasteDate: Date = Date()
    /// `Main.mText` - the text shown in the list.
    var desc: String = ""
    /// `Main.lShortCut` - a per-clip accelerator, packed by `HotKey`.
    var shortcut: Int = 0
    var globalShortcut: Bool = false
    /// `Main.lDontAutoDelete` - Ditto's "starred"/never-expire flag.
    var dontAutoDelete: Int = 0
    var crc: UInt32 = 0
    var isGroup: Bool = false
    var parentID: Int = -1
    var quickPasteText: String = ""
    var clipOrder: Double = 0
    var clipGroupOrder: Double = 0
    var stickyClipOrder: Double = DatabaseSchema.invalidSticky
    var stickyClipGroupOrder: Double = DatabaseSchema.invalidSticky
    var moveToGroupShortcut: Int = 0
    var globalMoveToGroupShortcut: Bool = false

    var formats: [ClipFormatData] = []

    /// Set when the clip came from a copy, for the log and for statistics.
    var sourceApplication: String = ""

    init() {}

    var totalSize: Int {
        return formats.reduce(0) { $0 + $1.bytes.count }
    }

    var isStarred: Bool {
        return dontAutoDelete > 0
    }

    var isSticky: Bool {
        return stickyClipOrder != DatabaseSchema.invalidSticky
            || stickyClipGroupOrder != DatabaseSchema.invalidSticky
    }

    func format(_ name: String) -> ClipFormatData? {
        return formats.first { $0.format == name }
    }

    /// The clip's text, from whichever text format it carries.
    var text: String? {
        if let unicode = format(ClipFormat.unicodeText) {
            return ClipFormat.decodeUnicodeText(unicode.bytes)
        }
        if let ansi = format(ClipFormat.text) {
            return ClipFormat.decodeText(ansi.bytes)
        }
        if let rtf = format(ClipFormat.richText),
           let attributed = NSAttributedString(rtf: ClipFormat.decodeRTF(rtf.bytes),
                                               documentAttributes: nil) {
            return attributed.string
        }
        return nil
    }

    var image: NSImage? {
        if let png = format(ClipFormat.png) {
            return NSImage(data: png.bytes)
        }
        if let dib = format(ClipFormat.dib) {
            return BitmapHelper.image(fromDIB: dib.bytes)
        }
        return nil
    }

    var filePaths: [String] {
        guard let drop = format(ClipFormat.fileDrop) else { return [] }
        return ClipFormat.decodeFileDrop(drop.bytes)
    }

    // MARK: - Description

    /// Port of `SetDescFromText` and `SetDescFromType`.
    ///
    /// Ditto keeps the first `DescTextSize` characters of the text as the
    /// description; clips with no text are described by what they contain.
    func generateDescription() {
        let limit = Options.shared.descriptionTextSize

        if let text = text, text.isEmpty == false {
            var trimmed = text
            if Options.shared.descriptionShowsLeadingWhitespace == false {
                trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if trimmed.count > limit {
                trimmed = String(trimmed.prefix(limit))
            }
            if trimmed.isEmpty == false {
                desc = trimmed
                return
            }
        }

        let paths = filePaths
        if paths.isEmpty == false {
            let names = paths.map { ($0 as NSString).lastPathComponent }
            var text = names.joined(separator: ", ")
            if text.count > limit { text = String(text.prefix(limit)) }
            desc = paths.count == 1 ? text : "\(paths.count) files: \(text)"
            return
        }

        if let image = image {
            let size = image.size
            desc = String(format: "Image %.0f x %.0f", size.width, size.height)
            return
        }

        if let first = formats.first {
            desc = ClipFormat.displayName(first.format)
            return
        }

        desc = ""
    }

    // MARK: - CRC

    /// Port of `CClip::GenerateCRC`.
    ///
    /// Every format's bytes are folded into one CRC-32. With
    /// "adjust clips for CRC" on, RTF is normalised first, because Word and
    /// Outlook rewrite `\rsid` values on every copy and would otherwise make
    /// every copy of the same text look new.
    func computeCRC() -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        let adjust = Options.shared.adjustClipsForCRC

        for format in formats {
            if adjust && format.format == ClipFormat.richText {
                let normalised = Clip.normaliseRTFForCRC(ClipFormat.decodeRTF(format.bytes))
                crc = Crc32.update(crc, normalised)
            } else if adjust && ClipFormat.isTextFormat(format.format) {
                // Ditto trims to the real string length here: it saw buffers
                // padded past the terminator, which produced random CRCs.
                crc = Crc32.update(crc, Clip.trimToTerminator(format.bytes,
                                                              wide: format.format == ClipFormat.unicodeText))
            } else {
                crc = Crc32.update(crc, format.bytes)
            }
        }

        return Crc32.finalize(crc)
    }

    private static func trimToTerminator(_ data: Data, wide: Bool) -> Data {
        if wide {
            var index = data.startIndex
            while index + 1 < data.endIndex {
                if data[index] == 0 && data[index + 1] == 0 {
                    return data.subdata(in: data.startIndex..<(index + 2))
                }
                index += 2
            }
            return data
        }
        if let terminator = data.firstIndex(of: 0) {
            return data.subdata(in: data.startIndex..<(terminator + 1))
        }
        return data
    }

    /// Port of `RemoveRTFSection` / `DeleteParamFromRTF` (Misc.cpp).
    static func normaliseRTFForCRC(_ data: Data) -> Data {
        guard var rtf = String(data: data, encoding: .isoLatin1) else { return data }
        rtf = removeRTFSection(rtf, "{\\*\\datastore")
        rtf = deleteParameter(rtf, "\\insrsid", numeric: true)
        rtf = deleteParameter(rtf, "\\rsid", numeric: true)
        rtf = deleteParameter(rtf, "\\mdispDef1", numeric: false)
        return rtf.data(using: .isoLatin1) ?? data
    }

    /// Drop a brace-balanced RTF group, e.g. the `{\*\datastore ...}` block
    /// Word rewrites on every copy.
    private static func removeRTFSection(_ rtf: String, _ marker: String) -> String {
        guard let start = rtf.range(of: marker) else { return rtf }

        var depth = 0
        var index = start.lowerBound
        var escaped = false

        while index < rtf.endIndex {
            let character = rtf[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let end = rtf.index(after: index)
                    var result = rtf
                    result.removeSubrange(start.lowerBound..<end)
                    return result
                }
            }
            index = rtf.index(after: index)
        }

        // Unbalanced - keep everything before the marker rather than guessing.
        return String(rtf[rtf.startIndex..<start.lowerBound])
    }

    /// Remove every `\keywordNNN` (or bare `\keyword`) from the RTF.
    private static func deleteParameter(_ rtf: String, _ keyword: String, numeric: Bool) -> String {
        var result = ""
        result.reserveCapacity(rtf.count)

        var index = rtf.startIndex
        while index < rtf.endIndex {
            if rtf[index] == "\\", rtf[index...].hasPrefix(keyword) {
                var cursor = rtf.index(index, offsetBy: keyword.count)
                if numeric {
                    if cursor < rtf.endIndex && (rtf[cursor] == "-") {
                        cursor = rtf.index(after: cursor)
                    }
                    while cursor < rtf.endIndex && rtf[cursor].isNumber {
                        cursor = rtf.index(after: cursor)
                    }
                }
                // An RTF control word may be followed by one optional space.
                if cursor < rtf.endIndex && rtf[cursor] == " " {
                    cursor = rtf.index(after: cursor)
                }
                index = cursor
                continue
            }
            result.append(rtf[index])
            index = rtf.index(after: index)
        }

        return result
    }
}

/// A row of the quick paste list. Deliberately light: the list can hold
/// thousands of these, and the format blobs are only read when a clip is
/// actually used. Mirrors what `CQPasteWnd`'s list thread selects.
struct ClipListItem {
    var id: Int
    var desc: String
    var parentID: Int
    var dontAutoDelete: Int
    var shortcut: Int
    var isGroup: Bool
    var quickPasteText: String
    var clipOrder: Double
    var clipGroupOrder: Double
    var stickyClipOrder: Double
    var stickyClipGroupOrder: Double
    var date: Date
    var lastPasteDate: Date

    var isStarred: Bool { return dontAutoDelete > 0 }

    var isSticky: Bool {
        return stickyClipOrder != DatabaseSchema.invalidSticky
            || stickyClipGroupOrder != DatabaseSchema.invalidSticky
    }

    init(row: SQLiteRow) {
        id = row.int("lID")
        desc = row.string("mText")
        parentID = row.int("lParentID", -1)
        dontAutoDelete = row.int("lDontAutoDelete")
        shortcut = row.int("lShortCut")
        isGroup = row.int("bIsGroup") != 0
        quickPasteText = row.string("QuickPasteText")
        clipOrder = row.double("clipOrder")
        clipGroupOrder = row.double("clipGroupOrder")
        stickyClipOrder = row.double("stickyClipOrder", DatabaseSchema.invalidSticky)
        stickyClipGroupOrder = row.double("stickyClipGroupOrder", DatabaseSchema.invalidSticky)
        date = Date(timeIntervalSince1970: TimeInterval(row.int("lDate")))
        lastPasteDate = Date(timeIntervalSince1970: TimeInterval(row.int("lastPasteDate")))
    }
}
