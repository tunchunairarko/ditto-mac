import Foundation
import AppKit

/// One stored format of a clip: the row that goes into the `Data` table.
struct ClipFormatData {
    var format: String
    var bytes: Data

    init(_ format: String, _ bytes: Data) {
        self.format = format
        self.bytes = bytes
    }
}

/// Port of `GetFormatName` / `GetFormatID` (Misc.cpp) plus the macOS half of
/// the bridge that Windows Ditto never needed.
///
/// Ditto names its `Data.strClipBoardFormat` rows with Windows clipboard format
/// names. This port keeps those names and stores the bytes in the Windows
/// layout, so the database stays readable by Windows Ditto - a clip copied on a
/// Mac pastes correctly on a PC pointed at the same file. `PasteboardBridge`
/// does the actual translation to and from `NSPasteboard`.
enum ClipFormat {

    static let unicodeText = "CF_UNICODETEXT"
    static let text = "CF_TEXT"
    static let richText = "Rich Text Format"
    static let html = "HTML Format"
    static let png = "PNG"
    static let dib = "CF_DIB"
    static let fileDrop = "CF_HDROP"
    static let fileURL = "UniformResourceLocatorW"

    /// Formats a fresh install captures. Matches the boxes Windows Ditto ticks
    /// on the Types page out of the box.
    static let defaultEnabledFormats = [
        unicodeText, text, richText, html, png, dib, fileDrop, fileURL
    ]

    /// Every format the options UI offers, in display order.
    static let allKnownFormats = [
        unicodeText, text, richText, html, png, dib, fileDrop, fileURL
    ]

    static func displayName(_ format: String) -> String {
        switch format {
        case unicodeText: return "Unicode text"
        case text: return "Plain text (ANSI)"
        case richText: return "Rich text (RTF)"
        case html: return "HTML"
        case png: return "Image (PNG)"
        case dib: return "Image (Windows DIB)"
        case fileDrop: return "Files"
        case fileURL: return "URL"
        default: return format
        }
    }

    static func isTextFormat(_ format: String) -> Bool {
        return format == unicodeText || format == text
    }

    static func isImageFormat(_ format: String) -> Bool {
        return format == png || format == dib
    }

    // MARK: - CF_UNICODETEXT

    /// Windows stores CF_UNICODETEXT as UTF-16LE with a terminating NUL.
    static func encodeUnicodeText(_ string: String) -> Data {
        var bytes = Data()
        for unit in Array(string.utf16) {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8((unit >> 8) & 0xFF))
        }
        bytes.append(0)
        bytes.append(0)
        return bytes
    }

    static func decodeUnicodeText(_ data: Data) -> String {
        guard data.count >= 2 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let low = UInt16(data[index])
            let high = UInt16(data[index + 1])
            let unit = low | (high << 8)
            if unit == 0 { break }          // stop at the Windows NUL terminator
            units.append(unit)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: - CF_TEXT

    /// CF_TEXT is a NUL-terminated single-byte string. Windows writes it in the
    /// system code page; UTF-8 is the only sane choice on macOS and round-trips
    /// ASCII, which is what CF_TEXT is realistically used for.
    static func encodeText(_ string: String) -> Data {
        var bytes = Data(string.utf8)
        bytes.append(0)
        return bytes
    }

    static func decodeText(_ data: Data) -> String {
        var bytes = data
        if let terminator = bytes.firstIndex(of: 0) {
            bytes = bytes.subdata(in: bytes.startIndex..<terminator)
        }
        if let string = String(data: bytes, encoding: .utf8) { return string }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Rich Text Format

    static func encodeRTF(_ data: Data) -> Data {
        var bytes = data
        if bytes.last != 0 { bytes.append(0) }
        return bytes
    }

    static func decodeRTF(_ data: Data) -> Data {
        var bytes = data
        while bytes.last == 0 { bytes.removeLast() }
        return bytes
    }

    // MARK: - CF_HTML

    /// Windows' "HTML Format" is the HTML wrapped in a small offset header.
    /// `CF_HTML` in the Windows SDK; Ditto stores it exactly as the clipboard
    /// hands it over, so we build the same wrapper here.
    static func encodeHTML(_ html: String) -> Data {
        let prefix = "<html><body>\r\n<!--StartFragment-->"
        let suffix = "<!--EndFragment-->\r\n</body>\r\n</html>"

        func header(_ startHTML: Int, _ endHTML: Int,
                    _ startFragment: Int, _ endFragment: Int) -> String {
            return "Version:0.9\r\n"
                + String(format: "StartHTML:%08ld\r\n", startHTML)
                + String(format: "EndHTML:%08ld\r\n", endHTML)
                + String(format: "StartFragment:%08ld\r\n", startFragment)
                + String(format: "EndFragment:%08ld\r\n", endFragment)
        }

        // The offset fields are fixed width, so measuring the header once with
        // placeholder values gives the length the real one will have.
        let headerLength = header(0, 0, 0, 0).utf8.count
        let startHTML = headerLength
        let startFragment = startHTML + prefix.utf8.count
        let endFragment = startFragment + html.utf8.count
        let endHTML = endFragment + suffix.utf8.count

        let text = header(startHTML, endHTML, startFragment, endFragment)
            + prefix + html + suffix
        return Data(text.utf8)
    }

    /// Pull the fragment back out of a CF_HTML blob. Falls back to the whole
    /// payload when the header is missing or the offsets are nonsense.
    static func decodeHTML(_ data: Data) -> String {
        var bytes = data
        while bytes.last == 0 { bytes.removeLast() }
        guard let full = String(data: bytes, encoding: .utf8)
                ?? String(data: bytes, encoding: .isoLatin1) else { return "" }

        func offset(_ key: String) -> Int? {
            guard let range = full.range(of: key + ":") else { return nil }
            let rest = full[range.upperBound...]
            let digits = rest.prefix(while: { $0.isNumber })
            return Int(digits)
        }

        let utf8 = Array(full.utf8)
        if let start = offset("StartFragment"), let end = offset("EndFragment"),
           start >= 0, end <= utf8.count, start < end {
            let slice = Data(utf8[start..<end])
            if let fragment = String(data: slice, encoding: .utf8) {
                return fragment
            }
        }

        // No usable offsets - strip the header lines if they are there.
        if let bodyStart = full.range(of: "<html", options: .caseInsensitive) {
            return String(full[bodyStart.lowerBound...])
        }
        return full
    }

    // MARK: - CF_HDROP

    /// Windows packs dropped files as a `DROPFILES` header followed by a
    /// double-NUL-terminated list of UTF-16 paths.
    ///
    ///     typedef struct _DROPFILES {
    ///         DWORD pFiles;   // offset of the file list
    ///         POINT pt;       // drop point
    ///         BOOL  fNC;
    ///         BOOL  fWide;    // TRUE when the paths are UTF-16
    ///     } DROPFILES;
    static func encodeFileDrop(_ paths: [String]) -> Data {
        var bytes = Data()

        func appendUInt32(_ value: UInt32) {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 24) & 0xFF))
        }

        appendUInt32(20)    // pFiles: the header is 20 bytes
        appendUInt32(0)     // pt.x
        appendUInt32(0)     // pt.y
        appendUInt32(0)     // fNC
        appendUInt32(1)     // fWide

        for path in paths {
            for unit in Array(path.utf16) {
                bytes.append(UInt8(unit & 0xFF))
                bytes.append(UInt8((unit >> 8) & 0xFF))
            }
            bytes.append(0)
            bytes.append(0)
        }
        bytes.append(0)     // the extra NUL that ends the list
        bytes.append(0)
        return bytes
    }

    static func decodeFileDrop(_ data: Data) -> [String] {
        guard data.count > 20 else { return [] }
        let base = data.startIndex

        func readUInt32(_ at: Int) -> UInt32 {
            let i = base + at
            guard i + 3 < data.endIndex else { return 0 }
            return UInt32(data[i])
                | (UInt32(data[i + 1]) << 8)
                | (UInt32(data[i + 2]) << 16)
                | (UInt32(data[i + 3]) << 24)
        }

        let listOffset = Int(readUInt32(0))
        let wide = readUInt32(16) != 0
        guard listOffset >= 20, base + listOffset < data.endIndex else { return [] }

        let payload = data.subdata(in: (base + listOffset)..<data.endIndex)
        var paths: [String] = []

        if wide {
            var units: [UInt16] = []
            var index = payload.startIndex
            while index + 1 < payload.endIndex {
                let unit = UInt16(payload[index]) | (UInt16(payload[index + 1]) << 8)
                index += 2
                if unit == 0 {
                    if units.isEmpty { break }      // double NUL: end of list
                    paths.append(String(decoding: units, as: UTF16.self))
                    units.removeAll()
                    continue
                }
                units.append(unit)
            }
            if units.isEmpty == false {
                paths.append(String(decoding: units, as: UTF16.self))
            }
        } else {
            var current = Data()
            for byte in payload {
                if byte == 0 {
                    if current.isEmpty { break }
                    paths.append(String(decoding: current, as: UTF8.self))
                    current.removeAll()
                    continue
                }
                current.append(byte)
            }
            if current.isEmpty == false {
                paths.append(String(decoding: current, as: UTF8.self))
            }
        }

        return paths
    }

    /// Windows paths in a clip written on a PC mean nothing here, and vice
    /// versa. Keep them anyway (so the clip survives a round trip) but only
    /// offer to paste the ones that exist locally.
    static func localFileURLs(from paths: [String]) -> [URL] {
        return paths.compactMap { path in
            let converted = path.replacingOccurrences(of: "\\", with: "/")
            guard FileManager.default.fileExists(atPath: converted) else { return nil }
            return URL(fileURLWithPath: converted)
        }
    }
}
