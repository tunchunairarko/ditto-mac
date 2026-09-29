import Foundation
import XCTest
@testable import DittoKit

/// The paste transforms, ported from `COleClipSource`.
final class SpecialPasteTests: XCTestCase {

    private func apply(_ transform: SpecialPaste.Transform, _ text: String) -> String {
        return SpecialPaste.apply(transform, to: text)
    }

    func testCaseTransforms() {
        XCTAssertEqual(apply(.upperCase, "Hello World"), "HELLO WORLD")
        XCTAssertEqual(apply(.lowerCase, "Hello World"), "hello world")
        XCTAssertEqual(apply(.capitalize, "hello world"), "Hello World")
        XCTAssertEqual(apply(.invertCase, "AbC"), "aBc")
        XCTAssertEqual(apply(.camelCase, "hello world again"), "HelloWorldAgain")
    }

    /// A capital at the start and after every `.`, `!` and `?`.
    func testSentenceCase() {
        XCTAssertEqual(apply(.sentenceCase, "hello. there"), "Hello. There")
        XCTAssertEqual(apply(.sentenceCase, "ONE! two? three"), "One! Two? Three")
    }

    func testLineFeedTransforms() {
        XCTAssertEqual(apply(.removeLineFeeds, "one\ntwo\r\nthree"), "onetwothree")
        XCTAssertEqual(apply(.addOneLineFeed, "line"), "line\n")
        XCTAssertEqual(apply(.addTwoLineFeeds, "line"), "line\n\n")
    }

    func testTrimWhiteSpace() {
        XCTAssertEqual(apply(.trimWhiteSpace, "  padded \n"), "padded")
    }

    func testAsciiOnlyDropsEverythingElse() {
        XCTAssertEqual(apply(.asciiOnly, "a\u{20AC}b"), "ab")
        XCTAssertEqual(apply(.asciiOnly, "plain"), "plain")
    }

    func testSlugify() {
        XCTAssertEqual(SpecialPaste.slugify("Héllo, World!"), "hello-world")
        XCTAssertEqual(SpecialPaste.slugify("already-a-slug"), "already-a-slug")
        XCTAssertEqual(SpecialPaste.slugify("  spaces   everywhere  "), "spaces-everywhere")
    }

    /// A Windows path pasted into a shell. The drive letter's case is kept.
    func testPosixifyPaths() {
        XCTAssertEqual(apply(.posixifyPaths, "C:\\Users\\me"), "/C/Users/me")
        XCTAssertEqual(apply(.posixifyPaths, "relative\\path"), "relative/path")
    }

    func testGenerateGuidProducesAUsableUuid() {
        let first = apply(.generateGUID, "")
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertNotEqual(first, apply(.generateGUID, ""))
    }

    /// Typoglycemia shuffles the inside of a word and leaves the ends alone, so
    /// the result is an anagram with the same first and last letter.
    func testTypoglycemiaKeepsTheEndsAndTheLetters() {
        let result = apply(.typoglycemia, "abcdefgh")
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(result.first, "a")
        XCTAssertEqual(result.last, "h")
        XCTAssertEqual(result.sorted(), "abcdefgh".sorted())
    }

    func testTypoglycemiaLeavesShortWordsAlone() {
        XCTAssertEqual(apply(.typoglycemia, "the cat sat"), "the cat sat")
    }

    func testNoneChangesNothing() {
        XCTAssertEqual(apply(.none, "untouched"), "untouched")
    }

    /// Any transform rewrites the text, so the clip has to paste as plain text.
    func testEveryTransformForcesPlainText() {
        for transform in SpecialPaste.Transform.allCases where transform != .none {
            XCTAssertTrue(transform.forcesPlainText, transform.rawValue)
            XCTAssertFalse(transform.title.isEmpty, transform.rawValue)
        }
        XCTAssertFalse(SpecialPaste.Transform.none.forcesPlainText)
    }

    func testAggregatingSeveralClipsJoinsTheirText() {
        let clips = ["one", "two", "three"].map { text -> Clip in
            let clip = Clip()
            clip.formats = [ClipFormatData(ClipFormat.unicodeText,
                                           ClipFormat.encodeUnicodeText(text))]
            return clip
        }

        XCTAssertEqual(SpecialPaste.aggregateText(clips, separator: "\n", reverse: false),
                       "one\ntwo\nthree")
        XCTAssertEqual(SpecialPaste.aggregateText(clips, separator: "\n", reverse: true),
                       "three\ntwo\none")
    }
}

/// The key packing that goes into `Main.lShortCut`.
final class HotKeyTests: XCTestCase {

    func testParsesAModifierCombination() throws {
        let hotKey = try XCTUnwrap(HotKey(string: "cmd+shift+v"))
        XCTAssertTrue(hotKey.modifiers.contains(.command))
        XCTAssertTrue(hotKey.modifiers.contains(.shift))
        XCTAssertFalse(hotKey.modifiers.contains(.option))
        XCTAssertEqual(HotKey.name(forKeyCode: hotKey.keyCode), "v")
    }

    func testPackingRoundTrips() throws {
        for text in ["cmd+shift+v", "ctrl+`", "ctrl+alt+shift+cmd+f1", "cmd+space"] {
            let hotKey = try XCTUnwrap(HotKey(string: text), text)
            XCTAssertEqual(HotKey(packed: hotKey.packed), hotKey, text)
        }
    }

    func testTheStoredStringRoundTrips() throws {
        let hotKey = try XCTUnwrap(HotKey(string: "ctrl+alt+`"))
        XCTAssertEqual(hotKey.stringValue, "ctrl+alt+`")
        XCTAssertEqual(HotKey(string: hotKey.stringValue), hotKey)
    }

    func testNoShortcutIsNotAHotKey() {
        XCTAssertNil(HotKey(packed: 0))
        XCTAssertNil(HotKey(string: ""))
        XCTAssertNil(HotKey(string: "cmd+notakey"))
    }

    func testTheDescriptionUsesTheUsualSymbols() throws {
        let hotKey = try XCTUnwrap(HotKey(string: "cmd+shift+v"))
        XCTAssertTrue(hotKey.description.contains("⌘"))
        XCTAssertTrue(hotKey.description.contains("⇧"))
    }

    /// Only a single character works as a menu item's key equivalent.
    func testMenuKeyEquivalentIsEmptyForNamedKeys() throws {
        XCTAssertEqual(try XCTUnwrap(HotKey(string: "cmd+v")).menuKeyEquivalent, "v")
        XCTAssertEqual(try XCTUnwrap(HotKey(string: "cmd+space")).menuKeyEquivalent, "")
    }
}
