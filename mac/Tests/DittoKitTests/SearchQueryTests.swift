import Foundation
import XCTest
@testable import DittoKit

/// Ditto's search language, ported from `CFormatSQL`. These check the clause
/// that comes out; `ClipRepositoryTests` checks that it finds the right clips.
final class SearchQueryTests: DittoTestCase {

    private func clause(_ text: String) -> String {
        return SearchQuery(text).whereClause() ?? ""
    }

    func testAnEmptySearchHasNoClause() {
        XCTAssertTrue(SearchQuery("").isEmpty)
        XCTAssertNil(SearchQuery("").whereClause())
        XCTAssertNil(SearchQuery("   ").whereClause())
    }

    func testASingleWordSearchesTheDescription() {
        XCTAssertTrue(clause("hello").contains("ditto_like(Main.mText, '%hello%', 0)"))
    }

    func testSeveralWordsAreAndedTogether() {
        let result = clause("one two")
        XCTAssertTrue(result.contains(" AND "), result)
        XCTAssertTrue(result.contains("%one%"), result)
        XCTAssertTrue(result.contains("%two%"), result)
    }

    func testOrJoinsTwoWords() {
        XCTAssertTrue(clause("one OR two").contains(" OR "))
    }

    func testNotNegatesAWord() {
        XCTAssertTrue(clause("NOT one").contains("NOT ditto_like"))
        XCTAssertTrue(clause("! one").contains("NOT ditto_like"))
    }

    func testAQuotedPhraseStaysTogether() {
        let result = clause("\"two words\"")
        XCTAssertTrue(result.contains("%two words%"), result)
        XCTAssertFalse(result.contains(" AND "), result)
    }

    func testAnAsteriskBecomesAWildcard() {
        XCTAssertTrue(clause("foo*").contains("foo%"))
    }

    func testApostrophesAreEscapedForSql() {
        XCTAssertTrue(clause("it's").contains("it''s"))
    }

    func testSlashFSearchesTheClipContents() {
        let query = SearchQuery("/f inside")
        XCTAssertEqual(query.text, "inside")
        XCTAssertTrue(query.needsDataJoin)

        let result = query.whereClause() ?? ""
        XCTAssertTrue(result.contains("Data.ooData"), result)
        XCTAssertTrue(result.contains("strClipBoardFormat = 'CF_UNICODETEXT'"), result)
    }

    func testSlashQSearchesTheQuickPasteText() {
        let result = SearchQuery("/q shortname").whereClause() ?? ""
        XCTAssertTrue(result.contains("Main.QuickPasteText"), result)
        XCTAssertFalse(result.contains("Main.mText"), result)
    }

    func testSimpleSearchTreatsTheWholeBoxAsOnePhrase() {
        environment.options.simpleTextSearch = true
        let result = clause("two words")
        XCTAssertTrue(result.contains("%two words%"), result)
        XCTAssertFalse(result.contains(" AND "), result)
    }

    func testRegexSearchUsesTheRegexpFunction() {
        environment.options.regExTextSearch = true
        XCTAssertTrue(clause("^start").contains("ditto_regexp("))
    }

    func testCaseSensitivityIsPassedToTheMatcher() {
        XCTAssertTrue(clause("word").contains(", 0)"))
        environment.options.caseSensitiveSearch = true
        XCTAssertTrue(clause("word").contains(", 1)"))
    }

    func testTurningEveryScopeOffStillSearchesTheDescription() {
        environment.options.searchDescription = false
        environment.options.searchQuickPaste = false
        environment.options.searchFullText = false
        XCTAssertTrue(clause("word").contains("Main.mText"))
    }
}

/// The matching behind `ditto_like` and `ditto_regexp`. Clip contents are stored
/// as UTF-16 blobs, so decoding them correctly is what makes `/f` work at all.
final class PatternMatcherTests: XCTestCase {

    func testFindsASubstringCaseInsensitively() {
        XCTAssertTrue(DittoPatternMatcher.matches(subject: "Hello World",
                                                  pattern: "%world%",
                                                  caseSensitive: false))
    }

    func testCaseSensitiveMatchingRespectsCase() {
        XCTAssertFalse(DittoPatternMatcher.matches(subject: "Hello World",
                                                   pattern: "%world%",
                                                   caseSensitive: true))
        XCTAssertTrue(DittoPatternMatcher.matches(subject: "Hello World",
                                                  pattern: "%World%",
                                                  caseSensitive: true))
    }

    func testUnderscoreMatchesOneCharacter() {
        XCTAssertTrue(DittoPatternMatcher.matches(subject: "abc",
                                                  pattern: "%a_c%",
                                                  caseSensitive: false))
        XCTAssertFalse(DittoPatternMatcher.matches(subject: "ac",
                                                   pattern: "%a_c%",
                                                   caseSensitive: false))
    }

    func testAnEscapedWildcardIsALiteral() {
        XCTAssertTrue(DittoPatternMatcher.matches(subject: "the rate is 50% today",
                                                  pattern: "%50\\%%",
                                                  caseSensitive: false))
    }

    func testDecodesUtf16BlobsTheWayDittoWritesThem() {
        let blob = ClipFormat.encodeUnicodeText("a clip stored as UTF-16")
        XCTAssertEqual(DittoPatternMatcher.decodeBlob(blob), "a clip stored as UTF-16")
    }

    func testDecodesPlainUtf8Blobs() {
        let blob = Data("a clip stored as plain UTF-8 text".utf8)
        XCTAssertEqual(DittoPatternMatcher.decodeBlob(blob), "a clip stored as plain UTF-8 text")
    }

    func testRegexMatching() {
        XCTAssertTrue(DittoPatternMatcher.matchesRegex(subject: "start here",
                                                       pattern: "^start",
                                                       caseSensitive: false))
        XCTAssertFalse(DittoPatternMatcher.matchesRegex(subject: "not at the start",
                                                        pattern: "^start",
                                                        caseSensitive: false))
    }

    func testAnInvalidRegexDoesNotMatchRatherThanCrashing() {
        XCTAssertFalse(DittoPatternMatcher.matchesRegex(subject: "anything",
                                                        pattern: "([unclosed",
                                                        caseSensitive: false))
    }
}
