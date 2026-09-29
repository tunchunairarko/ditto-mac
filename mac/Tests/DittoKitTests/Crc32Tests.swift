import Foundation
import XCTest
@testable import DittoKit

/// Ditto stores a CRC of every clip and uses it to recognise duplicates, so a
/// database written on one platform has to agree with the other about what a
/// duplicate is. These are the standard CRC-32 check values.
final class Crc32Tests: XCTestCase {

    private func crc(_ text: String) -> UInt32 {
        return Crc32.compute(Data(text.utf8))
    }

    func testMatchesTheStandardCheckValues() {
        XCTAssertEqual(crc(""), 0x0000_0000)
        XCTAssertEqual(crc("a"), 0xE8B7_BE43)
        XCTAssertEqual(crc("123456789"), 0xCBF4_3926)
    }

    /// `CClip::GenerateCRC` folds each format into one running CRC, so feeding
    /// two buffers has to equal feeding their concatenation.
    func testUpdatingIncrementallyMatchesOneShot() {
        let first = Data("hello ".utf8)
        let second = Data("world".utf8)

        var running: UInt32 = 0xFFFF_FFFF
        running = Crc32.update(running, first)
        running = Crc32.update(running, second)

        XCTAssertEqual(Crc32.finalize(running), crc("hello world"))
    }

    func testDifferentTextGivesDifferentValues() {
        XCTAssertNotEqual(crc("one"), crc("two"))
    }
}
