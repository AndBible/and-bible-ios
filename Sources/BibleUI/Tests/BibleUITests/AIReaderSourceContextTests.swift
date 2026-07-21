import XCTest

@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Verifies AI actions retain Android's source passage identity independently from cache projection.

 The suite uses a real SWORD Bible and pure resolver inputs to cover cursor ownership, bounded source
 ranges, partial extraction, exact bridge identity, and note-editor routing without UI timing.
 */
final class AIReaderSourceContextTests: BibleUISwordFixtureTestCase {
  /**
   Verifies a selected Bible passage uses converted source OSIS and one canonical projection.

   - Setup: Reads Genesis 1:1-2 while the real fixture module is positioned at Genesis 1:5.
   - Expected result: Source OSIS has no generic anchors, canonical text equals the atomic SWORD
     range projection, and the original cursor remains exact.
   - Failure meaning: AI may parse source-format bytes, drift canonical whitespace, or move the pane.
   */
  func testSwordBibleSelectionUsesSourceOSISAndRestoresCursor() throws {
    let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
    let module = try XCTUnwrap(manager.module(named: "KJV"))
    let start = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
    let end = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2))
    module.setKey("=Gen.1.5")
    let previousKey = module.currentKey()
    let sourceProjection = try module.inspectVerseSourceRangeRestoringPrevious(
      startOrdinal: start,
      endOrdinal: end
    )

    let context = try XCTUnwrap(AIReaderSourceContextExtractor.swordBible(
      module: module,
      request: .selection(
        sourceBookKey: "Gen.1",
        startOrdinal: start,
        endOrdinal: end
      )
    ))
    let selectedContent = try XCTUnwrap(context.selectedContent)

    XCTAssertEqual(module.currentKey(), previousKey)
    XCTAssertEqual(context.sourceDocumentInitials, "KJV")
    XCTAssertEqual(context.sourceBookKey, "Gen.1")
    XCTAssertEqual(context.sourceOSISRange, "Gen.1.1-Gen.1.2")
    XCTAssertEqual(context.sourceOrdinalRange, start...end)
    XCTAssertEqual(context.selectedText, sourceProjection.canonicalText)
    XCTAssertEqual(
      context.selectedText,
      "In the beginning God created the heaven and the earth. "
        + "And the earth was without form and void; and darkness was upon the face of the deep. "
        + "And the Spirit of God moved upon the face of the waters. "
    )
    XCTAssertTrue(selectedContent.contains("osisID=\"Gen.1.1\""))
    XCTAssertTrue(selectedContent.contains("osisID=\"Gen.1.2\""))
    XCTAssertFalse(selectedContent.contains("osisID=\"Gen.1.3\""))
    XCTAssertFalse(selectedContent.contains("<BVA"))
  }

  /**
   Verifies source inspection restores an exact chapter-introduction cursor that key text can snap.

   - Setup: Positions the real fixture at Genesis 1:0, whose display key alone resolves to verse 1,
     then captures Genesis 1:1-2.
   - Expected result: Both the introduction key and its VerseKey index are restored exactly.
   - Failure meaning: A successful AI source read can silently move a pane from an intro to verse 1.
   - Side effects: Temporarily moves only the isolated fixture module cursor.
   */
  func testSwordBibleSourceInspectionRestoresChapterIntroductionCursor() throws {
    let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
    let module = try XCTUnwrap(manager.module(named: "KJV"))
    let start = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
    let end = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2))
    module.setKey("=Gen.1.0")
    let previousKey = module.currentKey()
    let previousIndex = module.currentVerseKeyIndex()

    _ = try module.inspectVerseSourceRangeRestoringPrevious(
      startOrdinal: start,
      endOrdinal: end
    )

    XCTAssertEqual(previousKey, "Genesis 1:0")
    XCTAssertEqual(module.currentKey(), previousKey)
    XCTAssertEqual(module.currentVerseKeyIndex(), previousIndex)
  }

  /**
   Verifies whole-page extraction retains the source chapter key and source range.

   - Setup: Reads the real Genesis 1 fixture without a selection.
   - Expected result: The first/final source verse, OSIS identity, and canonical text are present,
     while generic sentence anchors are absent.
   - Failure meaning: Window prompts can collapse to one verse or contaminate Bible OSIS with BVA.
   */
  func testSwordBibleWholePageCapturesSourceChapterWithoutGenericAnchors() throws {
    let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
    let module = try XCTUnwrap(manager.module(named: "KJV"))
    let first = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
    let verseCount = try XCTUnwrap(module.verseCount(osisBookId: "Gen", chapter: 1))
    let last = try XCTUnwrap(
      module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: verseCount)
    )

    let context = try XCTUnwrap(AIReaderSourceContextExtractor.swordBible(
      module: module,
      request: .page(sourceBookKey: "Gen.1", osisBookId: "Gen", chapter: 1)
    ))
    let selectedContent = try XCTUnwrap(context.selectedContent)

    XCTAssertEqual(context.sourceBookKey, "Gen.1")
    XCTAssertEqual(context.sourceOSISRange, "Gen.1.1-Gen.1.\(verseCount)")
    XCTAssertEqual(context.sourceOrdinalRange, first...last)
    XCTAssertFalse(context.selectedText?.isEmpty ?? true)
    XCTAssertTrue(selectedContent.contains("osisID=\"Gen.1.1\""))
    XCTAssertTrue(selectedContent.contains("osisID=\"Gen.1.\(verseCount)\""))
    XCTAssertFalse(selectedContent.contains("<BVA"))
  }

  /**
   Verifies bounded source inspection crosses chapter and book intro ordinals correctly.

   - Setup: Reads Genesis 1:31-2:1 and Genesis 50:last-Exodus 1:1 from the full fixture.
   - Expected result: Both endpoint OSIS identities survive while internal intro ordinals are skipped.
   - Failure meaning: Valid Android VerseRanges can truncate or fail at chapter/book boundaries.
   */
  func testSwordBibleSelectionCrossesChapterAndBookBoundaries() throws {
    let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
    let module = try XCTUnwrap(manager.module(named: "KJV"))
    let chapterStart = try XCTUnwrap(
      module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 31)
    )
    let chapterEnd = try XCTUnwrap(
      module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 1)
    )
    let finalGenesisVerse = try XCTUnwrap(module.verseCount(osisBookId: "Gen", chapter: 50))
    let bookStart = try XCTUnwrap(
      module.verseOrdinal(osisBookId: "Gen", chapter: 50, verse: finalGenesisVerse)
    )
    let bookEnd = try XCTUnwrap(
      module.verseOrdinal(osisBookId: "Exod", chapter: 1, verse: 1)
    )

    let chapterContext = try XCTUnwrap(AIReaderSourceContextExtractor.swordBible(
      module: module,
      request: .selection(
        sourceBookKey: nil,
        startOrdinal: chapterStart,
        endOrdinal: chapterEnd
      )
    ))
    let bookContext = try XCTUnwrap(AIReaderSourceContextExtractor.swordBible(
      module: module,
      request: .selection(
        sourceBookKey: nil,
        startOrdinal: bookStart,
        endOrdinal: bookEnd
      )
    ))

    XCTAssertEqual(chapterContext.sourceOSISRange, "Gen.1.31-Gen.2.1")
    XCTAssertEqual(chapterContext.sourceBookKey, "Gen.1.31-Gen.2.1")
    XCTAssertTrue(chapterContext.selectedContent?.contains("osisID=\"Gen.2.1\"") == true)
    XCTAssertEqual(bookContext.sourceOSISRange, "Gen.50.\(finalGenesisVerse)-Exod.1.1")
    XCTAssertTrue(bookContext.selectedContent?.contains("osisID=\"Exod.1.1\"") == true)
  }

  /**
   Verifies invalid and excessive bridge endpoints perform bounded work and preserve the cursor.

   - Setup: Supplies `Int.max` and an ordinal beyond the final Revelation verse.
   - Expected result: Numeric validation rejects the huge span before range construction, SWORD
     rejects the non-addressable endpoint, and the active key never changes.
   - Failure meaning: Malicious bridge values can trap, loop indefinitely, or retarget the reader.
   */
  func testSwordBibleRejectsHugeAndNonAddressableRangesWithoutMovingCursor() throws {
    let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
    let module = try XCTUnwrap(manager.module(named: "KJV"))
    module.setKey("=Gen.1.5")
    let previousKey = module.currentKey()

    XCTAssertNil(AIReaderSourceRange.bibleBounds(start: 1, end: Int.max))
    XCTAssertNil(AIReaderSourceContextExtractor.swordBible(
      module: module,
      request: .selection(sourceBookKey: "Gen.1", startOrdinal: 1, endOrdinal: Int.max)
    ))
    XCTAssertThrowsError(try module.inspectVerseSourceRangeRestoringPrevious(
      startOrdinal: 1,
      endOrdinal: Int.max
    )) { error in
      XCTAssertEqual(
        error as? SwordVerseSourceInspectionError,
        .rangeTooLarge(maximumCount: AIReaderSourceRange.maximumVerseCount)
      )
    }

    let finalOrdinal = try XCTUnwrap(
      module.verseOrdinal(osisBookId: "Rev", chapter: 22, verse: 21)
    )
    XCTAssertThrowsError(try module.inspectVerseSourceRangeRestoringPrevious(
      startOrdinal: finalOrdinal + 1,
      endOrdinal: finalOrdinal + 1
    )) { error in
      XCTAssertEqual(
        error as? SwordVerseSourceInspectionError,
        .nonAddressableEndpoint(finalOrdinal + 1)
      )
    }
    XCTAssertEqual(module.currentKey(), previousKey)
  }

  /**
   Verifies a valid source selection survives when KJVA cache conversion is unavailable.

   - Setup: Resolves a Bible pane with source ordinals/OSIS and passes no verified KJVA range.
   - Expected result: Prompt identity uses source OSIS and source ordinals; KJVA fields remain nil.
   - Failure meaning: Non-KJVA source passages are incorrectly rejected before prompting.
   */
  func testBibleSelectionResolverDoesNotRequireKJVACacheRange() throws {
    let request = AISelectionActionRequest(
      bookInitials: "KJV",
      startOrdinal: 7,
      endOrdinal: 8,
      text: "highlight only"
    )
    let pane = makePaneSnapshot(
      initials: "KJV",
      category: .bible,
      sourceBookKey: "Gen.1",
      sourceOSISRange: "Gen.1.1-Gen.1.2",
      selectedContent: "<div><verse osisID=\"Gen.1.1\">context</verse></div>",
      selectedText: "canonical source",
      sourceRange: 7...8,
      kjvaRange: nil
    )

    let action = try XCTUnwrap(AIReaderBridgeActionResolver.selection(
      request,
      pane: pane,
      verifiedKJVARange: nil
    ))

    XCTAssertEqual(action.sourceBookKey, "Gen.1")
    XCTAssertEqual(action.verseReference, "Gen.1.1-Gen.1.2")
    XCTAssertEqual(action.selectedText, "canonical source")
    XCTAssertEqual(action.highlightedText, "highlight only")
    XCTAssertEqual(action.sourceOrdinalStart, 7)
    XCTAssertEqual(action.sourceOrdinalEnd, 8)
    XCTAssertNil(action.kjvaOrdinalStart)
    XCTAssertNil(action.kjvaOrdinalEnd)
  }

  /**
   Verifies canonical text and structured OSIS remain independently optional.

   - Setup: Resolves otherwise identical Bible selections with only canonical text and only OSIS.
   - Expected result: Both actions survive and preserve the projection that was available.
   - Failure meaning: One extraction failure incorrectly discards the other Android context value.
   */
  func testBibleSelectionResolverPreservesPartialExtraction() throws {
    let request = AISelectionActionRequest(
      bookInitials: "KJV",
      startOrdinal: 7,
      endOrdinal: 7,
      text: ""
    )
    let canonicalOnly = makePaneSnapshot(
      initials: "KJV",
      category: .bible,
      sourceBookKey: "Gen.1",
      sourceOSISRange: "Gen.1.1",
      selectedContent: nil,
      selectedText: "canonical",
      sourceRange: 7...7,
      kjvaRange: nil
    )
    let osisOnly = makePaneSnapshot(
      initials: "KJV",
      category: .bible,
      sourceBookKey: "Gen.1",
      sourceOSISRange: "Gen.1.1",
      selectedContent: "<div><verse osisID=\"Gen.1.1\">source</verse></div>",
      selectedText: nil,
      sourceRange: 7...7,
      kjvaRange: nil
    )

    let canonicalAction = try XCTUnwrap(AIReaderBridgeActionResolver.selection(
      request,
      pane: canonicalOnly,
      verifiedKJVARange: nil
    ))
    let osisAction = try XCTUnwrap(AIReaderBridgeActionResolver.selection(
      request,
      pane: osisOnly,
      verifiedKJVARange: nil
    ))

    XCTAssertEqual(canonicalAction.selectedText, "canonical")
    XCTAssertNil(canonicalAction.selectedContent)
    XCTAssertNil(osisAction.selectedText)
    XCTAssertNotNil(osisAction.selectedContent)
  }

  /**
   Verifies stale module/key events and excessive endpoints are rejected before action creation.

   - Setup: Labels module-B content as module A, changes an exact generic key by one space, and sends
     an `Int.max` endpoint.
   - Expected result: Every stale or excessive request returns nil.
   - Failure meaning: Content can be mislabeled for prompts/cache or bridge input can trigger a trap.
   */
  func testSelectionResolverRejectsStaleIdentityWhitespaceDriftAndHugeRanges() {
    let biblePane = makePaneSnapshot(
      initials: "MODULE_B",
      category: .bible,
      sourceBookKey: "Gen.1",
      sourceOSISRange: "Gen.1.1",
      selectedContent: "<div/>",
      selectedText: "B content",
      sourceRange: 7...7,
      kjvaRange: nil
    )
    XCTAssertNil(AIReaderBridgeActionResolver.selection(
      AISelectionActionRequest(
        bookInitials: "MODULE_A",
        startOrdinal: 7,
        endOrdinal: 7,
        text: ""
      ),
      pane: biblePane,
      verifiedKJVARange: nil
    ))
    XCTAssertNil(AIReaderBridgeActionResolver.selection(
      AISelectionActionRequest(
        bookInitials: "MODULE_B",
        startOrdinal: 7,
        endOrdinal: Int.max,
        text: ""
      ),
      pane: biblePane,
      verifiedKJVARange: nil
    ))

    let genericPane = makePaneSnapshot(
      initials: "DICT",
      category: .dictionary,
      sourceBookKey: " key ",
      sourceOSISRange: nil,
      selectedContent: "<div><BVA ordinal=\"0\">entry</BVA></div>",
      selectedText: "",
      sourceRange: nil,
      kjvaRange: nil
    )
    XCTAssertNil(AIReaderBridgeActionResolver.selection(
      AISelectionActionRequest(
        bookInitials: "DICT",
        osisRef: "key",
        startOrdinal: 0,
        endOrdinal: 0,
        text: "entry"
      ),
      pane: genericPane,
      verifiedKJVARange: nil
    ))
  }

  /**
   Verifies note-editor context comes only from the typed target entity.

   - Setup: Supplies unrelated module-B pane content, an entity-owned module-A Bible bookmark, and
     each generic editor target.
   - Expected result: Bible actions use module A/source OSIS; generic actions expose no pane source
     fields and retain Android's empty-string selected text.
   - Failure meaning: Notes can inherit unrelated visible-pane content or cache identity.
   */
  func testNoteEditorResolverUsesOnlyTargetOwnedSourceContext() throws {
    let pane = makePaneSnapshot(
      initials: "MODULE_B",
      category: .dictionary,
      sourceBookKey: "unrelated",
      sourceOSISRange: nil,
      selectedContent: "<div>module B</div>",
      selectedText: "",
      sourceRange: nil,
      kjvaRange: nil
    )
    let bibleID = UUID()
    let bibleRequest = noteRequest(id: bibleID, type: .bookmarkNote)
    let bibleContext = AIReaderBibleBookmarkContext(
      bookInitials: "MODULE_A",
      sourceBookKey: "Ps.3.1-Ps.3.2",
      sourceOSISRange: "Ps.3.1-Ps.3.2",
      sourceOrdinalRange: 40...41,
      kjvaOrdinalRange: nil,
      selectedContent: "<div><verse osisID=\"Ps.3.1\">A</verse></div>",
      selectedText: "module A canonical"
    )
    let bibleAction = try XCTUnwrap(AIReaderBridgeActionResolver.noteEditor(
      bibleRequest,
      target: .bibleBookmarkNote(bibleID),
      pane: pane,
      bibleBookmark: bibleContext
    ))

    XCTAssertEqual(bibleAction.activeDocumentInitials, "MODULE_A")
    XCTAssertEqual(bibleAction.sourceBookKey, "Ps.3.1-Ps.3.2")
    XCTAssertEqual(bibleAction.verseReference, "Ps.3.1-Ps.3.2")
    XCTAssertEqual(bibleAction.sourceOrdinalStart, 40)
    XCTAssertEqual(bibleAction.sourceOrdinalEnd, 41)
    XCTAssertEqual(bibleAction.selectedText, "module A canonical")
    XCTAssertNil(bibleAction.kjvaOrdinalStart)

    let genericTargets: [(AITextTarget, NoteEditorEntityType)] = [
      (.genericBookmarkNote(UUID()), .bookmarkNote),
      (.studyPadText(UUID()), .studyPadText),
      (.myDocumentPage(UUID()), .myDocumentPage),
    ]
    for (target, type) in genericTargets {
      let action = try XCTUnwrap(AIReaderBridgeActionResolver.noteEditor(
        noteRequest(id: target.id, type: type),
        target: target,
        pane: pane,
        bibleBookmark: nil
      ))
      XCTAssertNil(action.documentCategory)
      XCTAssertNil(action.activeDocumentInitials)
      XCTAssertNil(action.sourceBookKey)
      XCTAssertNil(action.sourceOrdinalStart)
      XCTAssertNil(action.kjvaOrdinalStart)
      XCTAssertNil(action.verseReference)
      XCTAssertNil(action.selectedContent)
      XCTAssertEqual(action.selectedText, "")
    }
  }

  /**
   Verifies window context uses source OSIS while retaining optional KJVA cache identity.

   - Setup: Builds a Bible pane whose source and KJVA ranges intentionally differ.
   - Expected result: Prompt reference remains source OSIS and KJVA remains separate cache metadata.
   - Failure meaning: Commentary/prompt lookup can be retargeted through KJVA conversion.
   */
  func testWindowResolverSeparatesSourceReferenceFromKJVACacheRange() throws {
    let pane = makePaneSnapshot(
      initials: "KJV",
      category: .bible,
      sourceBookKey: "Gen.1",
      sourceOSISRange: "Gen.1.1-Gen.1.31",
      selectedContent: "<div/>",
      selectedText: "canonical source",
      sourceRange: 7...37,
      kjvaRange: 11...41
    )

    let action = try XCTUnwrap(AIReaderBridgeActionResolver.window(pane))

    XCTAssertEqual(action.sourceOrdinalStart, 7)
    XCTAssertEqual(action.sourceOrdinalEnd, 37)
    XCTAssertEqual(action.kjvaOrdinalStart, 11)
    XCTAssertEqual(action.kjvaOrdinalEnd, 41)
    XCTAssertEqual(action.verseReference, "Gen.1.1-Gen.1.31")
  }

  /** Builds a complete immutable pane fixture for pure resolver tests. */
  private func makePaneSnapshot(
    initials: String,
    category: DocumentCategory,
    sourceBookKey: String,
    sourceOSISRange: String?,
    selectedContent: String?,
    selectedText: String?,
    sourceRange: ClosedRange<Int>?,
    kjvaRange: ClosedRange<Int>?
  ) -> AIReaderPaneSnapshot {
    AIReaderPaneSnapshot(
      workspaceID: UUID(),
      windowID: UUID(),
      documentCategory: category,
      activeDocumentInitials: initials,
      sourceBookKey: sourceBookKey,
      sourceOSISRange: sourceOSISRange,
      selectedContent: selectedContent,
      selectedText: selectedText,
      sourceOrdinalRange: sourceRange,
      kjvaOrdinalRange: kjvaRange
    )
  }

  /** Builds one exact note-editor bridge payload for a typed target. */
  private func noteRequest(
    id: UUID,
    type: NoteEditorEntityType
  ) -> AINoteEditorActionRequest {
    AINoteEditorActionRequest(
      entityType: type.rawValue,
      entityId: id.uuidString,
      currentText: "editable",
      contentType: "MARKDOWN"
    )
  }
}
