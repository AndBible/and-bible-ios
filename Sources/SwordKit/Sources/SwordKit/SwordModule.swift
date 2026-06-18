// SwordModule.swift — SWModule wrapper for SwordKit

import Foundation
import CLibSword

/// Structured VerseKey metadata for a module's current position.
public struct VerseKeyChildren: Sendable {
    public let testament: Int
    public let book: Int
    public let chapter: Int
    public let verse: Int
    /// SWORD/JSword-style versification ordinal including book and chapter intro slots.
    public let index: Int
    public let chapterMax: Int
    public let verseMax: Int
    public let bookName: String
    public let osisRef: String
    public let shortText: String
    public let bookAbbreviation: String
    public let osisBookName: String
}

/**
 A resolved verse reference from SWORD's active versification.

 The reader bridge needs the same category of answers Android receives from JSword's
 `Versification`: exact book/chapter/verse identity plus the intro-inclusive ordinal used by
 bookmarks, navigation, highlighting, memorization, and reference documents. This value is copied
 out of the SWORD module while the module cursor is protected by `SwordRuntime`, so callers can
 retain it without holding any SWORD-owned pointers.
 */
public struct VerseKeyReference: Sendable, Equatable {
    /// OSIS book identifier, such as `Gen`, `Ruth`, or `1Cor`.
    public let osisBookId: String

    /// One-based chapter number resolved by the module's versification.
    public let chapter: Int

    /// One-based verse number resolved by the module's versification.
    public let verse: Int

    /// SWORD/JSword-style versification ordinal including book and chapter intro slots.
    public let ordinal: Int

    /**
     Creates a copied verse reference for callers outside the SwordKit module.

     - Parameters:
       - osisBookId: OSIS book identifier, such as `Gen` or `1Cor`.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
       - ordinal: SWORD/JSword-style versification ordinal.
     - Side effects: None.
     - Failure modes: None; callers are responsible for supplying values already validated by
       SWORD or by a documented no-module compatibility fallback.
     */
    public init(osisBookId: String, chapter: Int, verse: Int, ordinal: Int) {
        self.osisBookId = osisBookId
        self.chapter = chapter
        self.verse = verse
        self.ordinal = ordinal
    }

    /// Canonical OSIS reference for this verse.
    public var osisRef: String {
        "\(osisBookId).\(chapter).\(verse)"
    }
}

/**
 Swift wrapper around a SWORD SWModule instance.

 Provides verse key navigation, text retrieval, and search capabilities.
 All operations are serialized through `SwordRuntime` since libsword and the flat bridge keep
 process-global state and are not thread-safe.

 Do not create instances directly — obtain them from `SwordManager.module(named:)`.
 */
public final class SwordModule: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer

    /// Module metadata.
    public let info: ModuleInfo

    init(handle: UnsafeMutableRawPointer, modulePath: String? = nil) {
        self.handle = handle

        self.info = SwordRuntime.sync {
            // Extract metadata once at init
            let name = String(cString: SWModule_getName(handle))
            let description = String(cString: SWModule_getDescription(handle))
            let typeStr = String(cString: SWModule_getType(handle))
            let language = String(cString: SWModule_getLanguage(handle))

            // Detect features by parsing the .conf file directly from disk.
            // SWORD's flat API getConfigEntry() only returns the FIRST value for
            // multi-value keys (Feature, GlobalOptionFilter), so modules like KJV
            // where StrongsNumbers isn't the first entry are missed. Reading the
            // .conf file catches ALL entries.
            let features = SwordModule.detectFeatures(
                name: name, handle: handle, modulePath: modulePath
            )

            let cipherKey = SWModule_getConfigEntry(handle, "CipherKey")
            let isEncrypted = cipherKey != nil
            let directionPtr = SWModule_getConfigEntry(handle, "Direction")
            let direction = directionPtr != nil ? String(cString: directionPtr!) : "LtoR"
            let versionPtr = SWModule_getConfigEntry(handle, "Version")
            let versionStr = versionPtr != nil ? String(cString: versionPtr!) : ""

            return ModuleInfo(
                name: name,
                description: description,
                category: ModuleCategory(typeString: typeStr),
                language: language,
                version: versionStr,
                isEncrypted: isEncrypted,
                isUnlocked: !isEncrypted || (cipherKey.map { String(cString: $0) } ?? "").isEmpty == false,
                features: features,
                isRightToLeft: direction == "RtoL"
            )
        }
    }

    // MARK: - Key Navigation

    /**
     Set the current verse/key position.
     - Parameter keyText: A verse reference like "Gen 1:1" or a dictionary key.
     */
    public func setKey(_ keyText: String) {
        SwordRuntime.sync {
            SWModule_setKeyText(handle, keyText)
        }
    }

    /// Get the current key text.
    public func currentKey() -> String {
        SwordRuntime.sync {
            String(cString: SWModule_getKeyText(handle))
        }
    }

    /// Get structured VerseKey data for the current position when the module uses VerseKey.
    public func currentVerseKeyChildren() -> VerseKeyChildren? {
        SwordRuntime.sync {
            Self.currentVerseKeyChildren(handle: handle)
        }
    }

    /// Get the current SWORD VerseKey index for verse-key modules.
    public func currentVerseKeyIndex() -> Int? {
        SwordRuntime.sync {
            let index = SWModule_getVerseKeyIndex(handle)
            return index >= 0 ? Int(index) : nil
        }
    }

    /**
     Resolves a verse to the ordinal used by the module's active versification.

     Android gets these ordinals through JSword `Versification.getOrdinal(Verse)`. This method
     delegates to SWORD's native `VerseKey.getIndex()`, including intro slots for the Bible,
     testament, book, and chapter. The method uses exact-key syntax and validates the resolved key
     so a missing or out-of-range verse cannot silently normalize to a neighboring reference.

     - Parameters:
       - osisBookId: OSIS book identifier such as `Gen`, `Ruth`, or `1Cor`.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: The versification ordinal, or `nil` when the reference cannot be resolved exactly.
     - Side effects: Temporarily moves the SWORD module cursor inside the serialization queue and
       restores the previous key before returning.
     - Important: Use this for reader bridge ordinals instead of arithmetic based on chapter and
       verse counts; those arithmetic schemes do not match JSword/SWORD versification semantics.
     */
    public func verseOrdinal(osisBookId: String, chapter: Int, verse: Int) -> Int? {
        guard chapter > 0, verse > 0, !osisBookId.isEmpty else { return nil }

        return SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, previousKey) }

            guard let children = exactVerseKeyChildrenLocked(
                osisBookId: osisBookId,
                chapter: chapter,
                verse: verse
            ) else {
                return nil
            }

            let index = SWModule_getVerseKeyIndex(handle)
            guard index >= 0, children.chapter > 0, children.verse > 0 else { return nil }
            return Int(index)
        }
    }

    /**
     Resolves a versification ordinal back to a concrete verse reference.

     Android can reverse-map bookmark and memorization ordinals through JSword's versification. This
     method provides the same boundary for iOS by positioning SWORD's native `VerseKey` with
     `setIndex(_:)`, reading structured key metadata, and then restoring the caller's prior cursor.
     When `osisBookId` is provided, the method rejects ordinals that resolve outside that book.

     - Parameters:
       - osisBookId: Optional OSIS book identifier that the ordinal must resolve within.
       - ordinal: SWORD/JSword-style versification ordinal.
     - Returns: A copied verse reference, or `nil` if the ordinal does not represent a normal
       verse for the requested book.
     - Side effects: Temporarily moves the SWORD module cursor inside the serialization queue and
       restores the previous key before returning.
     */
    public func verseReference(osisBookId: String? = nil, ordinal: Int) -> VerseKeyReference? {
        guard ordinal > 0 else { return nil }

        return SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, previousKey) }

            guard SWModule_setVerseKeyIndex(handle, CLong(ordinal)) == 0,
                  let children = Self.currentVerseKeyChildren(handle: handle),
                  children.chapter > 0,
                  children.verse > 0 else {
                return nil
            }

            let resolvedOsisBookId = children.osisBookName
            if let osisBookId, osisBookId != resolvedOsisBookId {
                return nil
            }

            let resolvedOrdinal = SWModule_getVerseKeyIndex(handle)
            guard Int(resolvedOrdinal) == ordinal else { return nil }
            return VerseKeyReference(
                osisBookId: resolvedOsisBookId,
                chapter: children.chapter,
                verse: children.verse,
                ordinal: Int(resolvedOrdinal)
            )
        }
    }

    /**
     Atomically inspects one verse key and restores the module's previous cursor.

     - Parameter keyText: SWORD key text to inspect, such as `=Gen.1.1`.
     - Returns: The resolved key text, structured VerseKey metadata when available, and raw OSIS
       entry captured at the resolved key.
     - Side effects: temporarily moves the SWORD module cursor inside one serialized queue block,
       then restores the cursor that was active before the call returns.
     - Failure modes: returns `nil` VerseKey metadata when the module is not positioned on a
       VerseKey or SWORD cannot expose structured key children.
     - Important: Use this instead of separate `setKey`, `currentVerseKeyChildren`, and `rawEntry`
       calls when the key metadata and raw entry must describe the same module position.
     */
    public func inspectVerseKeyAndRawEntryRestoringPrevious(
        _ keyText: String
    ) -> (actualKey: String, verseKey: VerseKeyChildren?, rawEntry: String) {
        SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            SWModule_setKeyText(handle, keyText)
            let actualKey = String(cString: SWModule_getKeyText(handle))
            let verseKey = Self.currentVerseKeyChildren(handle: handle)
            let rawEntry = String(cString: SWModule_getRawEntry(handle))
            SWModule_setKeyText(handle, previousKey)
            return (actualKey, verseKey, rawEntry)
        }
    }

    private static func currentVerseKeyChildren(handle: UnsafeMutableRawPointer) -> VerseKeyChildren? {
        guard let children = SWModule_getKeyChildren(handle) else { return nil }

        var parts: [String] = []
        var index = 0
        while index < 11, let ptr = children[index] {
            parts.append(String(cString: ptr))
            index += 1
        }

        guard parts.count >= 8,
              let testament = Int(parts[0]),
              let book = Int(parts[1]),
              let chapter = Int(parts[2]),
              let verse = Int(parts[3]),
              let chapterMax = Int(parts[4]),
              let verseMax = Int(parts[5]) else {
            return nil
        }

        let keyIndex = SWModule_getVerseKeyIndex(handle)
        guard keyIndex >= 0 else { return nil }

        let osisRef = parts[7]
        let fallbackOsisBookName = osisRef.components(separatedBy: ".").first ?? osisRef
        let shortText = parts.count > 8 && !parts[8].isEmpty ? parts[8] : osisRef
        let bookAbbreviation = parts.count > 9 && !parts[9].isEmpty ? parts[9] : fallbackOsisBookName
        let osisBookName = parts.count > 10 && !parts[10].isEmpty ? parts[10] : fallbackOsisBookName

        return VerseKeyChildren(
            testament: testament,
            book: book,
            chapter: chapter,
            verse: verse,
            index: Int(keyIndex),
            chapterMax: chapterMax,
            verseMax: verseMax,
            bookName: parts[6],
            osisRef: osisRef,
            shortText: shortText,
            bookAbbreviation: bookAbbreviation,
            osisBookName: osisBookName
        )
    }

    /// Positions an exact verse key and rejects SWORD normalization to neighboring references.
    private func exactVerseKeyChildrenLocked(osisBookId: String, chapter: Int, verse: Int) -> VerseKeyChildren? {
        SWModule_setKeyText(handle, "=\(osisBookId).\(chapter).\(verse)")
        guard let children = Self.currentVerseKeyChildren(handle: handle),
              children.osisBookName == osisBookId,
              children.chapter == chapter,
              children.verse == verse,
              children.chapter <= children.chapterMax,
              children.verse <= children.verseMax else {
            return nil
        }
        return children
    }

    /**
     Parses a Bible key string through SWORD's VerseKey parser and returns normalized OSIS keys.

     Android routes Bible references through JSword `PassageKeyFactory`; the closest available
     iOS boundary in the current flat bridge is SWORD's `SWModule_parseKeyList`, which expands
     ranges and lists against the active module's versification instead of using string splitting.
     The result is copied immediately because the C array belongs to the module handle and is
     invalidated by later parse calls.

     - Parameter keyText: OSIS or human-readable key text such as `Gen.1.1-Gen.1.3`.
     - Returns: Normalized OSIS references, one per parsed verse/range item. Returns an empty
       array when SWORD cannot parse the text for a VerseKey module.
     - Side effects: Uses SWORD's parser inside the module serialization queue. The method restores
       the module cursor after parsing so callers can use it in reader link handling without
       desynchronizing later raw-entry reads.
     */
    public func parseKeyList(_ keyText: String) -> [String] {
        SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, previousKey) }

            guard let values = SWModule_parseKeyList(handle, keyText) else { return [] }
            return Self.copyCStringArray(values)
        }
    }

    /**
     Returns the active module versification's last verse number for a chapter.

     Android's passage chooser uses JSword `Versification.getLastVerse(book, chapterNo)`. SWORD
     exposes the equivalent through the current `VerseKey` children after resolving any verse in
     the target chapter. The method rejects SWORD normalization onto a neighboring key by checking
     the resolved OSIS book and chapter before returning `verseMax`.

     - Parameters:
       - osisBookId: OSIS book identifier such as `Gen`, `Ruth`, or `1Cor`.
       - chapter: One-based chapter number.
     - Returns: The last valid verse number for that chapter, or `nil` if the reference cannot be
       resolved exactly by the module's versification.
     - Side effects: Temporarily moves the module cursor and restores the previous key before
       returning.
     */
    public func verseCount(osisBookId: String, chapter: Int) -> Int? {
        guard chapter > 0, !osisBookId.isEmpty else { return nil }

        return SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, previousKey) }

            SWModule_setKeyText(handle, "=\(osisBookId).\(chapter).1")
            guard let children = Self.currentVerseKeyChildren(handle: handle),
                  children.osisBookName == osisBookId,
                  children.chapter == chapter,
                  children.chapter <= children.chapterMax,
                  children.verseMax > 0 else {
                return nil
            }
            return children.verseMax
        }
    }

    /**
     Copies a NULL-terminated C string array returned by the SWORD flat API.

     - Parameter values: Pointer to a NULL-terminated array owned by SWORD.
     - Returns: Swift strings copied before a later SWORD call can invalidate the backing storage.
     */
    private static func copyCStringArray(_ values: UnsafePointer<UnsafePointer<CChar>?>) -> [String] {
        var result: [String] = []
        var index = 0
        while let value = values[index] {
            result.append(String(cString: value))
            index += 1
        }
        return result
    }

    /**
     Get entry attributes produced by the current render pipeline.

     SWORD populates these attributes after rendering a verse. They expose
     structural metadata like preverse and interverse headings in a much more
     stable form than `renderHeader()`, which is only CSS.
     */
    public func entryAttributes(level1: String? = nil,
                                level2: String? = nil,
                                level3: String? = nil,
                                filtered: Bool = false) -> [String] {
        SwordRuntime.sync {
            func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
                guard let value else { return body(nil) }
                return value.withCString(body)
            }

            return withOptionalCString(level1) { level1Ptr in
                withOptionalCString(level2) { level2Ptr in
                    withOptionalCString(level3) { level3Ptr in
                        guard let values = SWModule_getEntryAttribute(
                            handle,
                            level1Ptr,
                            level2Ptr,
                            level3Ptr,
                            filtered ? 1 : 0
                        ) else {
                            return []
                        }

                        return Self.copyCStringArray(values)
                    }
                }
            }
        }
    }

    /**
     Navigate to the next entry/verse.
     - Returns: `true` if navigation succeeded (not at end).
     */
    @discardableResult
    public func next() -> Bool {
        SwordRuntime.sync {
            SWModule_next(handle) == 0
        }
    }

    /**
     Navigate to the previous entry/verse.
     - Returns: `true` if navigation succeeded (not at beginning).
     */
    @discardableResult
    public func previous() -> Bool {
        SwordRuntime.sync {
            SWModule_previous(handle) == 0
        }
    }

    /// Navigate to the beginning of the module.
    public func begin() {
        SwordRuntime.sync {
            SWModule_begin(handle)
        }
    }

    /// Check if the current position is at the end.
    public var isAtEnd: Bool {
        SwordRuntime.sync {
            SWModule_isEnd(handle) != 0
        }
    }

    // MARK: - Text Retrieval

    /**
     Atomically set key, read back actual key, and render text in one `SwordRuntime.sync` block.
     This prevents interleaving with other SWORD operations between setKey/currentKey/renderText.
     Returns (actualKey, renderedText).
     */
    public func setKeyAndRender(_ keyText: String) -> (actualKey: String, text: String) {
        SwordRuntime.sync {
            SWModule_setKeyText(handle, keyText)
            let actualKey = String(cString: SWModule_getKeyText(handle))
            let text = String(cString: SWModule_getRenderText(handle))
            return (actualKey, text)
        }
    }

    /**
     Atomically set key, then capture the resolved key and entry text forms.

     Dictionary and lexical-search lookups need these values together because SWORD can reposition
     to a nearby key when an exact match is missing, and some modules expose canonical metadata only
     through raw entry markup. Callers that need only raw OSIS can skip rendered/stripped text to
     avoid paying that cost for every verse during module-wide scans.
     */
    public func setKeyAndInspect(
        _ keyText: String,
        includeRenderedText: Bool = true,
        includeStrippedText: Bool = true
    ) -> (actualKey: String, rawEntry: String, renderedText: String, strippedText: String) {
        SwordRuntime.sync {
            SWModule_setKeyText(handle, keyText)
            let actualKey = String(cString: SWModule_getKeyText(handle))
            let rawEntry = String(cString: SWModule_getRawEntry(handle))
            let renderedText = includeRenderedText
                ? String(cString: SWModule_getRenderText(handle))
                : ""
            let strippedText = includeStrippedText
                ? String(cString: SWModule_getStripText(handle))
                : ""
            return (actualKey, rawEntry, renderedText, strippedText)
        }
    }

    /// Get rendered text (with markup/HTML) at the current position.
    public func renderText() -> String {
        SwordRuntime.sync {
            String(cString: SWModule_getRenderText(handle))
        }
    }

    /// Get raw entry text at the current position (no markup processing).
    public func rawEntry() -> String {
        SwordRuntime.sync {
            String(cString: SWModule_getRawEntry(handle))
        }
    }

    /// Get plain/strip text at the current position (no markup at all).
    public func stripText() -> String {
        SwordRuntime.sync {
            String(cString: SWModule_getStripText(handle))
        }
    }

    /// Get rendered header text (chapter/book introductions).
    public func renderHeader() -> String {
        SwordRuntime.sync {
            String(cString: SWModule_getRenderHeader(handle))
        }
    }

    // MARK: - Configuration

    /**
     Get a module configuration entry value.
     - Parameter key: The config key (e.g., "About", "LCSH", "DistributionLicense").
     - Returns: The value, or nil if not found.
     */
    public func configEntry(_ key: String) -> String? {
        SwordRuntime.sync {
            guard let cStr = SWModule_getConfigEntry(handle, key) else { return nil }
            return String(cString: cStr)
        }
    }

    /**
     Set the cipher key for encrypted modules.
     - Parameter key: The decryption key.
     */
    public func setCipherKey(_ key: String) {
        SwordRuntime.sync {
            SWModule_setCipherKey(handle, key)
        }
    }

    // MARK: - Versification / Book List

    /**
     Get the list of all books in this Bible module's versification.

     Mirrors Android's `DocumentBibleBooks`/JSword contract as closely as the current
     CLibSword wrapper allows: discover candidate books from real SWORD key positions, then
     include only books whose first or second verse resolves exactly and has raw content.
     This intentionally avoids synthetic "high verse" jumps such as `Gen 50:200`;
     compressed zText modules can normalize those fake keys past intervening books, which
     hides valid restored Android module content from the reader's book picker.

     - Returns: Ordered array of `BookInfo` for each book in the module's canon.
       Returns empty array for non-Bible modules or if the module has no verse key.
     - Side effects: Temporarily moves the module cursor while holding the module queue,
       then restores the previously selected key before returning.
     - Complexity: O(n) over the module's key entries. The reader calls this only when
       refreshing module metadata, and correctness is more important than key-jump speed.
     */
    public func getBookList() -> [BookInfo] {
        guard info.category == .bible || info.category == .commentary else { return [] }
        return SwordRuntime.sync {
            let savedKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, savedKey) }

            SWModule_begin(handle)
            guard SWModule_popError(handle) == 0 else { return [] }

            var candidateBooks: [BookInfo] = []
            var seenBookIds = Set<String>()
            var previousKey: String?
            let isProbablyIBTSynodalDocument = Self.isProbablyIBTSynodalDocument(handle: handle)

            while true {
                let key = String(cString: SWModule_getKeyText(handle))
                guard key != previousKey else { break }
                previousKey = key

                if let children = Self.currentVerseKeyChildren(handle: handle),
                   children.testament > 0,
                   !children.osisBookName.isEmpty,
                   seenBookIds.insert(children.osisBookName).inserted {
                    candidateBooks.append(BookInfo(
                        name: children.bookName,
                        osisId: children.osisBookName,
                        abbreviation: children.bookAbbreviation,
                        chapterCount: children.chapterMax,
                        testament: children.testament
                    ))
                }

                if SWModule_next(handle) != 0 { break }
            }

            return candidateBooks.filter { book in
                Self.moduleContainsAndroidProbeVerse(
                    handle: handle,
                    book: book,
                    chapter: 1,
                    verse: 1,
                    isProbablyIBTSynodalDocument: isProbablyIBTSynodalDocument
                ) || Self.moduleContainsAndroidProbeVerse(
                    handle: handle,
                    book: book,
                    chapter: 1,
                    verse: 2,
                    isProbablyIBTSynodalDocument: isProbablyIBTSynodalDocument
                )
            }
        }
    }

    /**
     Checks one Android-compatible book-list probe verse.

     Android's `DocumentBibleBooks.isVerseInBook()` includes a book only when JSword's backend
     reports raw content for either 1:1 or 1:2. This helper uses exact OSIS keys and verifies
     that SWORD did not normalize the request onto a neighboring key before checking raw content.
     It runs inside `getBookList()`'s serialized queue block and intentionally leaves cursor
     restoration to the outer caller.

     - Parameters:
       - handle: SWORD module handle already owned by the caller's queue.
       - book: Candidate book metadata collected from real SWORD key traversal.
       - chapter: Probe chapter number, normally `1`.
       - verse: Probe verse number, normally `1` or `2`.
       - isProbablyIBTSynodalDocument: Whether the module matches Android's known IBT Synodal
         empty-stub pattern for deuterocanonical books.
     - Returns: `true` when the requested exact verse belongs to the candidate book and has
       non-empty raw content that Android would treat as real content.
     - Side effects: Moves the module cursor to the probe key.
     */
    private static func moduleContainsAndroidProbeVerse(
        handle: UnsafeMutableRawPointer,
        book: BookInfo,
        chapter: Int,
        verse: Int,
        isProbablyIBTSynodalDocument: Bool
    ) -> Bool {
        guard let rawEntryLength = rawEntryLengthForExactVerse(
            handle: handle,
            osisBookId: book.osisId,
            chapter: chapter,
            verse: verse
        ), rawEntryLength > 0 else {
            return false
        }

        if isProbablyIBTSynodalDocument,
           isProbablyIBTEmptyVerseStub(rawEntryLength: rawEntryLength, isShortBook: book.chapterCount <= 1) {
            return false
        }

        return true
    }

    /**
     Returns the raw entry length for one exact OSIS verse key.

     SWORD may normalize invalid references to nearby verses. Android's JSword path checks a
     concrete `Verse`, so this helper rejects normalized probes by comparing structured
     `VerseKey` children after setting the key.

     - Parameters:
       - handle: SWORD module handle already owned by the caller's queue.
       - osisBookId: OSIS book identifier such as `Gen` or `1Cor`.
       - chapter: Chapter to inspect.
       - verse: Verse to inspect.
     - Returns: Raw entry character count when SWORD resolves exactly to the requested verse;
       otherwise `nil`.
     - Side effects: Moves the module cursor to the requested key.
     */
    private static func rawEntryLengthForExactVerse(
        handle: UnsafeMutableRawPointer,
        osisBookId: String,
        chapter: Int,
        verse: Int
    ) -> Int? {
        SWModule_setKeyText(handle, "=\(osisBookId).\(chapter).\(verse)")
        guard let children = currentVerseKeyChildren(handle: handle),
              children.osisBookName == osisBookId,
              children.chapter == chapter,
              children.verse == verse else {
            return nil
        }
        return String(cString: SWModule_getRawEntry(handle)).count
    }

    /**
     Detects Android's known IBT Synodal empty deuterocanonical-verse stub condition.

     Android checks for Synodal modules where `Tob 1:1` contains generated empty markup rather
     than real verse content, then excludes similarly-shaped stubs from the book list. This keeps
     iOS book visibility aligned for the same module family without applying the heuristic to
     unrelated versifications.

     - Parameter handle: SWORD module handle already owned by the caller's queue.
     - Returns: `true` when the module declares `Versification=Synodal` and `Tob 1:1` has the
       raw-length signature Android treats as an IBT empty stub.
     - Side effects: Moves the module cursor to `Tob 1:1`; `getBookList()` restores the original
       cursor before returning.
     */
    private static func isProbablyIBTSynodalDocument(handle: UnsafeMutableRawPointer) -> Bool {
        let versificationPointer = SWModule_getConfigEntry(handle, "Versification")
        let versificationName = versificationPointer.map { String(cString: $0) } ?? "KJV"
        guard versificationName == "Synodal",
              let rawEntryLength = rawEntryLengthForExactVerse(
                handle: handle,
                osisBookId: "Tob",
                chapter: 1,
                verse: 1
              ) else {
            return false
        }
        return isProbablyIBTEmptyVerseStub(rawEntryLength: rawEntryLength, isShortBook: false)
    }

    /**
     Matches Android's raw-length heuristic for IBT Synodal empty verse stubs.

     Android identifies generated empty markup by length range because the affected modules return
     non-empty raw XML for books that are not actually present. The constants below are the Swift
     equivalents of `DocumentBibleBooks` in Android.

     - Parameters:
       - rawEntryLength: Length of the raw SWORD entry.
       - isShortBook: Whether the probed book has a single chapter.
     - Returns: `true` when the raw entry length falls inside Android's empty-stub range.
     */
    private static func isProbablyIBTEmptyVerseStub(rawEntryLength: Int, isShortBook: Bool) -> Bool {
        if isShortBook {
            return ibtShortBookEmptyVerseStubRange.contains(rawEntryLength)
        }
        return ibtEmptyVerseStubRange.contains(rawEntryLength)
    }

    private static let ibtEmptyVerseStubRange: ClosedRange<Int> = {
        let lowerBound = "<chapter eID=\"gen4\" osisID=\"Gen.1\"/>".count
        let upperBound = "<chapter eID=\"gen1146\" osisID=\"1Macc.1\"/>".count
        return lowerBound...upperBound
    }()

    private static let ibtShortBookEmptyVerseStubRange: ClosedRange<Int> = {
        let lowerBound = "<chapter eID=\"gen955\" osisID=\"Obad.1\"/> <div eID=\"gen954\" osisID=\"Obad\" type=\"book\"/> <div eID=\"gen953\" type=\"x-Synodal-empty\"/>".count
        let upperBound = "<chapter eID=\"gen1136\" osisID=\"EpJer.1\"/> <div eID=\"gen1135\" osisID=\"EpJer\" type=\"book\"/> <div eID=\"gen1134\" type=\"x-Synodal-non-canonical\"/>".count
        return lowerBound...upperBound
    }()

    // MARK: - Key Browsing

    /**
     Collect all entry keys in the module (for dictionary/genbook key browsing).
     Uses begin()/next() iteration, returns array of key strings.
     Faster than `iterateAllEntries` since it skips text retrieval.
     */
    public func allKeys() -> [String] {
        SwordRuntime.sync {
            let savedKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, savedKey) }

            SWModule_begin(handle)
            guard SWModule_popError(handle) == 0 else { return [] }

            var keys: [String] = []
            while true {
                let key = String(cString: SWModule_getKeyText(handle))
                keys.append(key)
                if SWModule_next(handle) != 0 { break }
            }
            return keys
        }
    }

    /**
     Get child keys at the current position (for tree-key modules like general books).
     Returns the NULL-terminated string array from SWORD's getKeyChildren.
     */
    public func keyChildren() -> [String] {
        SwordRuntime.sync {
            guard let children = SWModule_getKeyChildren(handle) else { return [] }
            var result: [String] = []
            var i = 0
            while let ptr = children[i] {
                result.append(String(cString: ptr))
                i += 1
            }
            return result
        }
    }

    // MARK: - Bulk Iteration

    /**
     Iterate through all entries in the module, calling the callback for each.

     The callback receives `(key, plainText, index)` and should return `true` to continue.
     All SWORD operations run in a single `SwordRuntime.sync` block for correctness.
     The module's current key position is saved and restored after iteration.

     - Parameter callback: Called for each entry. Return `false` to stop early.
     */
    public func iterateAllEntries(_ callback: (String, String, Int) -> Bool) {
        SwordRuntime.sync {
            // Save current position
            let savedKey = String(cString: SWModule_getKeyText(handle))

            SWModule_begin(handle)
            guard SWModule_popError(handle) == 0 else {
                SWModule_setKeyText(handle, savedKey)
                return
            }

            var index = 0
            while true {
                let key = String(cString: SWModule_getKeyText(handle))
                let text = String(cString: SWModule_getStripText(handle))
                if !callback(key, text, index) { break }
                index += 1
                if SWModule_next(handle) != 0 { break }
            }

            // Restore position
            SWModule_setKeyText(handle, savedKey)
        }
    }

    // MARK: - Search

    /**
     Search the module for the given query.
     - Parameter options: Search configuration.
     - Returns: Search results.
     */
    public func search(_ options: SearchOptions) -> SearchResults {
        SwordRuntime.sync {
            let flags: Int32 = options.caseInsensitive ? 2 : 0 // REG_ICASE = 2

            _ = SWModule_search(
                handle,
                options.query,
                Int32(options.searchType.rawValue),
                flags,
                options.scope,
                nil
            )

            let count = SWModule_searchResultCount(handle)
            var results: [SearchResult] = []
            results.reserveCapacity(Int(count))

            for i in 0..<count {
                let key = String(cString: SWModule_getSearchResultKeyText(handle, i))
                // Get preview text by navigating to the result key
                SWModule_setKeyText(handle, key)
                let preview = String(cString: SWModule_getStripText(handle))
                results.append(SearchResult(
                    key: key,
                    moduleName: info.name,
                    previewText: String(preview.prefix(200))
                ))
            }

            return SearchResults(
                options: options,
                moduleName: info.name,
                results: results
            )
        }
    }

    /**
     Search the module and return only matching keys.

     Strong's candidate-index searches need SWORD's result keys but validate and render each verse
     through a separate canonical-token path. Keeping this key-only avoids stripping preview text
     for thousands of candidates before the caller knows which verses are semantically valid.

     - Parameters:
       - options: Search configuration.
       - limit: Optional maximum number of keys to return.
     - Returns: Matching SWORD keys in result order.
     - Side effects:
       - performs a SWORD search while holding the runtime lock
       - restores the module's current key after reading search results
     - Failure modes:
       - returns an empty list when SWORD reports no results or the limit is zero
     */
    public func searchKeys(_ options: SearchOptions, limit: Int? = nil) -> [String] {
        SwordRuntime.sync {
            let savedKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, savedKey) }

            let flags: Int32 = options.caseInsensitive ? 2 : 0 // REG_ICASE = 2

            _ = SWModule_search(
                handle,
                options.query,
                Int32(options.searchType.rawValue),
                flags,
                options.scope,
                nil
            )

            let count = Int(SWModule_searchResultCount(handle))
            let boundedCount = limit.map { min(max($0, 0), count) } ?? count
            guard boundedCount > 0 else { return [] }

            var keys: [String] = []
            keys.reserveCapacity(boundedCount)
            for index in 0..<boundedCount {
                keys.append(String(cString: SWModule_getSearchResultKeyText(handle, Int32(index))))
            }
            return keys
        }
    }

    // MARK: - Feature Detection

    /**
     Detect module features by parsing the .conf file directly from disk.

     SWORD's flat API `getConfigEntry()` only returns the first value for
     multi-value keys like `Feature` and `GlobalOptionFilter`. This causes
     modules where `StrongsNumbers` isn't the first entry (e.g., KJV) to
     be missed. Parsing the .conf file catches all entries.

     Falls back to the C API if the conf file can't be read.
     */
    private static func detectFeatures(
        name: String,
        handle: UnsafeMutableRawPointer,
        modulePath: String?
    ) -> ModuleFeatures {
        var features: ModuleFeatures = []

        // Try reading .conf file directly (reliable for multi-value keys)
        if let modulePath,
           let confLines = readConfFile(name: name, modulePath: modulePath) {
            for line in confLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Feature=") || trimmed.hasPrefix("GlobalOptionFilter=") {
                    let value = String(trimmed[trimmed.index(after: trimmed.firstIndex(of: "=")!)...])
                        .trimmingCharacters(in: .whitespaces)
                    if value.contains("Strongs") || value.contains("OSISStrongs") {
                        features.insert(.strongsNumbers)
                    }
                    if value.contains("Morphology") || value.contains("OSISMorph") {
                        features.insert(.morphology)
                    }
                    if value.contains("Footnotes") || value.contains("OSISFootnotes") {
                        features.insert(.footnotes)
                    }
                    if value.contains("Headings") || value.contains("OSISHeadings") {
                        features.insert(.headings)
                    }
                    if value.contains("RedLetterWords") || value.contains("OSISRedLetterWords") {
                        features.insert(.redLetterWords)
                    }
                    if value.contains("GreekDef") { features.insert(.greekDef) }
                    if value.contains("HebrewDef") { features.insert(.hebrewDef) }
                    if value.contains("GreekParse") { features.insert(.greekParse) }
                    if value.contains("HebrewParse") { features.insert(.hebrewParse) }
                    if value.contains("DailyDevotion") { features.insert(.dailyDevotion) }
                }
            }
        } else {
            // Fallback: use C API (only gets first value for multi-value keys)
            if SWModule_hasFeature(handle, "StrongsNumbers") != 0 { features.insert(.strongsNumbers) }
            if SWModule_hasFeature(handle, "GreekDef") != 0 { features.insert(.greekDef) }
            if SWModule_hasFeature(handle, "HebrewDef") != 0 { features.insert(.hebrewDef) }
            if SWModule_hasFeature(handle, "GreekParse") != 0 { features.insert(.greekParse) }
            if SWModule_hasFeature(handle, "HebrewParse") != 0 { features.insert(.hebrewParse) }
            if SWModule_hasFeature(handle, "DailyDevotion") != 0 { features.insert(.dailyDevotion) }
        }

        return features
    }

    /// Read all lines from a module's .conf file.
    private static func readConfFile(name: String, modulePath: String) -> [String]? {
        let confPath = (modulePath as NSString)
            .appendingPathComponent("mods.d")
            .appending("/\(name.lowercased()).conf")
        guard let contents = try? String(contentsOfFile: confPath, encoding: .utf8) else {
            return nil
        }
        return contents.components(separatedBy: .newlines)
    }
}
