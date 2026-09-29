import Foundation
import XCTest
@testable import DittoKit

/// The blobs in the Data table use the Windows byte layouts. A round trip here
/// only proves this port is self-consistent, so these also assert the layout
/// itself - the NUL terminators, the DROPFILES header, the CF_HTML offsets -
/// which is what Windows Ditto actually reads.
final class ClipFormatTests: XCTestCase {

    // MARK: - CF_UNICODETEXT

    func testUnicodeTextRoundTrips() {
        for text in ["hello", "", "a longer line with spaces", "tab\tand\nnewline"] {
            let encoded = ClipFormat.encodeUnicodeText(text)
            XCTAssertEqual(ClipFormat.decodeUnicodeText(encoded), text)
        }
    }

    /// Anything outside the basic plane is a surrogate pair in UTF-16, which is
    /// where a naive encoder goes wrong.
    func testUnicodeTextRoundTripsSurrogatePairs() {
        let text = "clipboard 📋 ok"
        XCTAssertEqual(ClipFormat.decodeUnicodeText(ClipFormat.encodeUnicodeText(text)), text)
    }

    func testUnicodeTextIsLittleEndianWithANulTerminator() {
        let encoded = ClipFormat.encodeUnicodeText("AB")
        // 'A' = 0x41, 'B' = 0x42, then the two-byte terminator.
        XCTAssertEqual(Array(encoded), [0x41, 0x00, 0x42, 0x00, 0x00, 0x00])
    }

    func testUnicodeTextDecodeStopsAtTheTerminator() {
        // A buffer padded past the terminator, which Ditto notes it has seen.
        var padded = ClipFormat.encodeUnicodeText("real")
        padded.append(contentsOf: [0x58, 0x00, 0x59, 0x00])
        XCTAssertEqual(ClipFormat.decodeUnicodeText(padded), "real")
    }

    // MARK: - CF_TEXT

    func testTextRoundTripsAndIsNulTerminated() {
        let encoded = ClipFormat.encodeText("hi")
        XCTAssertEqual(Array(encoded), [0x68, 0x69, 0x00])
        XCTAssertEqual(ClipFormat.decodeText(encoded), "hi")
    }

    // MARK: - Rich text

    func testRichTextKeepsItsBytesAndLosesTheTerminator() {
        let rtf = Data("{\\rtf1 hello}".utf8)
        let encoded = ClipFormat.encodeRTF(rtf)
        XCTAssertEqual(encoded.last, 0)
        XCTAssertEqual(ClipFormat.decodeRTF(encoded), rtf)
    }

    // MARK: - CF_HDROP

    func testFileDropRoundTrips() {
        let paths = ["/Users/someone/one.txt", "/tmp/two.png"]
        XCTAssertEqual(ClipFormat.decodeFileDrop(ClipFormat.encodeFileDrop(paths)), paths)
    }

    func testFileDropRoundTripsASinglePath() {
        XCTAssertEqual(ClipFormat.decodeFileDrop(ClipFormat.encodeFileDrop(["/one"])), ["/one"])
    }

    /// The DROPFILES header Windows expects: the file list starts at byte 20,
    /// and fWide says the paths are UTF-16.
    func testFileDropWritesTheWindowsDropfilesHeader() {
        let encoded = ClipFormat.encodeFileDrop(["/a"])
        XCTAssertGreaterThan(encoded.count, 20)

        func uint32(at offset: Int) -> UInt32 {
            return UInt32(encoded[offset])
                | (UInt32(encoded[offset + 1]) << 8)
                | (UInt32(encoded[offset + 2]) << 16)
                | (UInt32(encoded[offset + 3]) << 24)
        }

        XCTAssertEqual(uint32(at: 0), 20, "pFiles should point past the 20 byte header")
        XCTAssertEqual(uint32(at: 4), 0, "pt.x")
        XCTAssertEqual(uint32(at: 8), 0, "pt.y")
        XCTAssertEqual(uint32(at: 12), 0, "fNC")
        XCTAssertEqual(uint32(at: 16), 1, "fWide should be set for UTF-16 paths")
    }

    /// The list ends with an extra NUL, so the last path is followed by two
    /// terminators in a row.
    func testFileDropEndsWithADoubleTerminator() {
        let encoded = ClipFormat.encodeFileDrop(["/a"])
        XCTAssertEqual(Array(encoded.suffix(4)), [0x00, 0x00, 0x00, 0x00])
    }

    func testFileDropHandlesGarbage() {
        XCTAssertEqual(ClipFormat.decodeFileDrop(Data()), [])
        XCTAssertEqual(ClipFormat.decodeFileDrop(Data([1, 2, 3])), [])
    }

    // MARK: - CF_HTML

    func testHTMLRoundTrips() {
        let html = "<p>some <b>markup</b></p>"
        XCTAssertEqual(ClipFormat.decodeHTML(ClipFormat.encodeHTML(html)), html)
    }

    /// The header's byte offsets have to actually delimit the fragment - the
    /// part a two-pass header calculation gets wrong.
    func testHTMLOffsetsPointAtTheFragment() throws {
        let html = "<p>offsets matter</p>"
        let encoded = ClipFormat.encodeHTML(html)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        func offset(_ key: String) throws -> Int {
            let range = try XCTUnwrap(text.range(of: key + ":"))
            let digits = text[range.upperBound...].prefix(while: { $0.isNumber })
            return try XCTUnwrap(Int(digits))
        }

        let startFragment = try offset("StartFragment")
        let endFragment = try offset("EndFragment")
        let startHTML = try offset("StartHTML")
        let endHTML = try offset("EndHTML")

        let bytes = Array(encoded)
        XCTAssertEqual(String(decoding: bytes[startFragment..<endFragment], as: UTF8.self), html,
                       "StartFragment and EndFragment should bracket exactly the fragment")
        XCTAssertEqual(endHTML, bytes.count, "EndHTML should be the end of the payload")
        XCTAssertTrue(String(decoding: bytes[startHTML..<endHTML], as: UTF8.self).hasPrefix("<html"),
                      "StartHTML should be where the markup begins")
    }

    /// Multi-byte characters shift every offset, so the header has to be
    /// measured in bytes rather than characters.
    func testHTMLOffsetsAreCountedInBytes() throws {
        let html = "<p>café 📋</p>"
        let encoded = ClipFormat.encodeHTML(html)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        let range = try XCTUnwrap(text.range(of: "StartFragment:"))
        let digits = text[range.upperBound...].prefix(while: { $0.isNumber })
        let startFragment = try XCTUnwrap(Int(digits))

        let bytes = Array(encoded)
        XCTAssertTrue(String(decoding: bytes[startFragment...], as: UTF8.self).hasPrefix(html))
        XCTAssertEqual(ClipFormat.decodeHTML(encoded), html)
    }

    func testHTMLDecodeFallsBackWhenThereIsNoHeader() {
        let bare = Data("<html><body>no header</body></html>".utf8)
        XCTAssertTrue(ClipFormat.decodeHTML(bare).contains("no header"))
    }

    // MARK: - Names

    func testEveryDefaultFormatIsAKnownFormat() {
        for format in ClipFormat.defaultEnabledFormats {
            XCTAssertTrue(ClipFormat.allKnownFormats.contains(format), format)
            XCTAssertFalse(ClipFormat.displayName(format).isEmpty)
        }
    }
}
