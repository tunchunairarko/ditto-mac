import Foundation
import XCTest
@testable import DittoKit

/// Storing, finding and organising clips - the logic in `Clip.cpp` and the list
/// query in `QPasteWnd.cpp`.
final class ClipRepositoryTests: DittoTestCase {

    private var repository: ClipRepository { return ClipRepository.shared }

    // MARK: - Adding

    func testAddingAClipStoresItsTextAndDescription() throws {
        let id = try environment.addTextClip("a line of text")

        let clip = try XCTUnwrap(try repository.loadClip(id: id))
        XCTAssertEqual(clip.desc, "a line of text")
        XCTAssertEqual(clip.text, "a line of text")
        XCTAssertEqual(clip.formats.count, 2)
    }

    func testTheDescriptionIsTrimmedToTheConfiguredLength() throws {
        environment.options.descriptionTextSize = 20
        let id = try environment.addTextClip(String(repeating: "x", count: 100))

        let clip = try XCTUnwrap(try repository.loadClip(id: id))
        XCTAssertEqual(clip.desc.count, 20)
        XCTAssertEqual(clip.text?.count, 100, "only the description is shortened")
    }

    /// Ditto's default: a copy that matches an existing clip moves that clip
    /// back to the top instead of adding a second row.
    func testACopyOfTheSameThingIsNotStoredTwice() throws {
        environment.options.allowDuplicates = false

        let first = try repository.add(environment.textClip("the same thing"))
        let second = try repository.add(environment.textClip("the same thing"))

        guard case .added(let firstID) = first else {
            return XCTFail("the first copy should have been added, got \(first)")
        }
        guard case .duplicate(let secondID) = second else {
            return XCTFail("the second copy should have been a duplicate, got \(second)")
        }

        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(try repository.clipCount(), 1)
    }

    func testDuplicatesAreKeptWhenTheOptionIsOn() throws {
        environment.options.allowDuplicates = true

        _ = try repository.add(environment.textClip("the same thing"))
        _ = try repository.add(environment.textClip("the same thing"))

        XCTAssertEqual(try repository.clipCount(), 2)
    }

    func testAnEmptyClipIsNotStored() throws {
        let empty = Clip()
        let result = try repository.add(empty)
        guard case .skipped = result else {
            return XCTFail("a clip with no formats should be skipped, got \(result)")
        }
        XCTAssertEqual(try repository.clipCount(), 0)
    }

    // MARK: - The list

    func testTheNewestClipComesFirst() throws {
        _ = try environment.addTextClip("older")
        _ = try environment.addTextClip("newer")

        let items = try repository.list(ClipRepository.ListRequest())
        XCTAssertEqual(items.map { $0.desc }, ["newer", "older"])
    }

    func testAStuckClipSortsAboveEverythingElse() throws {
        let stuck = try environment.addTextClip("stuck to the top")
        _ = try environment.addTextClip("newer than the stuck one")

        try repository.setSticky(ids: [stuck], position: .top, inGroup: -1)

        let items = try repository.list(ClipRepository.ListRequest())
        XCTAssertEqual(items.first?.desc, "stuck to the top")
        XCTAssertTrue(try XCTUnwrap(items.first).isSticky)
    }

    func testSearchingTheDescription() throws {
        _ = try environment.addTextClip("alpha beta")
        _ = try environment.addTextClip("gamma delta")

        var request = ClipRepository.ListRequest()
        request.search = "beta"

        let items = try repository.list(request)
        XCTAssertEqual(items.map { $0.desc }, ["alpha beta"])
        XCTAssertEqual(try repository.count(request), 1)
    }

    func testSearchingIgnoresCaseByDefault() throws {
        _ = try environment.addTextClip("Mixed Case Text")

        var request = ClipRepository.ListRequest()
        request.search = "mixed case"
        XCTAssertEqual(try repository.list(request).count, 1)
    }

    /// `/f` has to reach inside the stored blob, which is UTF-16. This is the
    /// end-to-end check that the `ditto_like` SQL function is registered and
    /// decodes what Ditto writes.
    func testFullTextSearchLooksInsideTheStoredClip() throws {
        environment.options.descriptionTextSize = 12
        _ = try environment.addTextClip("short enough, but hidden word is buried")
        _ = try environment.addTextClip("nothing to find here")

        var request = ClipRepository.ListRequest()
        request.search = "/f buried"

        let items = try repository.list(request)
        XCTAssertEqual(items.count, 1, "full text search should have found the buried word")

        // The word is genuinely not in the description, so a description-only
        // search must not find it.
        request.search = "buried"
        XCTAssertEqual(try repository.list(request).count, 0)
    }

    func testStarredClipsCanBeListedOnTheirOwn() throws {
        let starred = try environment.addTextClip("worth keeping")
        _ = try environment.addTextClip("ordinary")

        try repository.setStarred(ids: [starred], starred: true)

        var request = ClipRepository.ListRequest()
        request.starredOnly = true

        let items = try repository.list(request)
        XCTAssertEqual(items.map { $0.desc }, ["worth keeping"])
        XCTAssertTrue(try XCTUnwrap(items.first).isStarred)
    }

    // MARK: - Groups

    func testMovingAClipIntoAGroup() throws {
        let group = try repository.createGroup(named: "Snippets")
        let clip = try environment.addTextClip("belongs in the group")

        try repository.move(ids: [clip], toGroup: group)

        var request = ClipRepository.ListRequest()
        request.groupID = group

        XCTAssertEqual(try repository.list(request).map { $0.desc }, ["belongs in the group"])
        XCTAssertEqual(try repository.groupName(id: group), "Snippets")

        let reloaded = try XCTUnwrap(try repository.loadClip(id: clip))
        XCTAssertEqual(reloaded.parentID, group)
    }

    func testDeletingAGroupTakesItsClipsWithIt() throws {
        let group = try repository.createGroup(named: "Temporary")
        let clip = try environment.addTextClip("inside the group")
        try repository.move(ids: [clip], toGroup: group)

        try repository.delete(ids: [group])

        XCTAssertNil(try repository.loadClip(id: clip))
        XCTAssertNil(try repository.loadClip(id: group))
    }

    func testGroupsAreListed() throws {
        _ = try repository.createGroup(named: "Beta")
        _ = try repository.createGroup(named: "Alpha")

        XCTAssertEqual(try repository.groups().map { $0.desc }, ["Alpha", "Beta"])
    }

    // MARK: - Editing

    func testEditingAClipReplacesItsTextAndDropsTheRest() throws {
        let clip = Clip()
        clip.formats = [
            ClipFormatData(ClipFormat.unicodeText, ClipFormat.encodeUnicodeText("before")),
            ClipFormatData(ClipFormat.richText, ClipFormat.encodeRTF(Data("{\\rtf1 before}".utf8)))
        ]
        clip.generateDescription()
        guard case .added(let id) = try repository.add(clip) else {
            return XCTFail("the clip should have been added")
        }

        try repository.replaceText(id: id, text: "after")

        let reloaded = try XCTUnwrap(try repository.loadClip(id: id))
        XCTAssertEqual(reloaded.text, "after")
        XCTAssertEqual(reloaded.desc, "after")
        XCTAssertNil(reloaded.format(ClipFormat.richText),
                     "rich text no longer matches the edited text, so it goes")
    }

    func testQuickPasteTextIsStoredAndSearchable() throws {
        let id = try environment.addTextClip("a long and forgettable clip")
        try repository.setQuickPasteText(id: id, text: "sig")

        var request = ClipRepository.ListRequest()
        request.search = "/q sig"
        XCTAssertEqual(try repository.list(request).count, 1)
    }

    func testAShortcutIsStoredAndFoundAgain() throws {
        let id = try environment.addTextClip("has a shortcut")
        let hotKey = try XCTUnwrap(HotKey(string: "ctrl+alt+7"))

        try repository.setShortcut(id: id, shortcut: hotKey.packed, global: true)

        let withShortcuts = try repository.clipsWithGlobalShortcuts()
        XCTAssertEqual(withShortcuts.count, 1)
        XCTAssertEqual(withShortcuts.first?.id, id)
        XCTAssertEqual(HotKey(packed: try XCTUnwrap(withShortcuts.first).shortcut), hotKey)
    }

    // MARK: - Copy buffers

    func testACopyBufferRemembersOneClip() throws {
        let first = try environment.addTextClip("in the buffer")
        let second = try environment.addTextClip("replaces it")

        try repository.setCopyBuffer(1, clipID: first)
        XCTAssertEqual(try repository.copyBufferClipID(1), first)

        try repository.setCopyBuffer(1, clipID: second)
        XCTAssertEqual(try repository.copyBufferClipID(1), second,
                       "setting a buffer should replace what was there")
        XCTAssertNil(try repository.copyBufferClipID(2))
    }

    // MARK: - Paste bookkeeping

    func testPastingMovesAClipBackToTheTop() throws {
        let first = try environment.addTextClip("pasted later")
        _ = try environment.addTextClip("added later")

        XCTAssertEqual(try repository.list(ClipRepository.ListRequest()).first?.desc,
                       "added later")

        repository.markAsPasted(ids: [first], updateClipOrder: true, fromGroup: false)

        XCTAssertEqual(try repository.list(ClipRepository.ListRequest()).first?.desc,
                       "pasted later")
    }

    func testPastingCanLeaveTheOrderAlone() throws {
        let first = try environment.addTextClip("pasted but not moved")
        _ = try environment.addTextClip("stays on top")

        repository.markAsPasted(ids: [first], updateClipOrder: false, fromGroup: false)

        XCTAssertEqual(try repository.list(ClipRepository.ListRequest()).first?.desc,
                       "stays on top")
    }
}
