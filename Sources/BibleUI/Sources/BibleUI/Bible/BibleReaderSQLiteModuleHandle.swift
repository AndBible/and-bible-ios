// BibleReaderSQLiteModuleHandle.swift -- Reader access for Android SQLite modules

import BibleCore
import Foundation
import SwordKit

/**
 Retains one Android-compatible SQLite module for reader and speech operations.

 Built-in format readers open one read-only connection per operation. Rendering, speech, and
 catalog calls can therefore overlap without blocking a cooperative-executor thread or sharing
 mutable SQLite statement state. The handle adds no second synchronization layer.

 Inputs are exact KJVA verse coordinates or dictionary keys. Outputs preserve the reader's raw
 content and source ordering. The handle performs no key normalization and creates no fallback
 content.
 */
final class BibleReaderSQLiteModuleHandle: @unchecked Sendable {
    /// Immutable picker and document metadata captured before concurrent runtime access begins.
    let info: ModuleInfo

    /// Immutable format metadata used for source labels, language, direction, and feature flags.
    let metadata: SQLiteDocumentMetadata

    /// Discovery origin retained for package-aware tests and diagnostics.
    let origin: SQLiteDocumentModuleOrigin

    /// Immutable module facade whose built-in reader owns per-operation SQLite connections.
    private let module: SQLiteDocumentModule

    /**
     Creates one runtime handle for a freshly discovered module.

     - Parameter module: Validated SQLite module owned by one catalog snapshot.
     - Side effects: Captures immutable metadata; no content or key query is executed.
     - Failure modes: None.
     - Important: Publication occurs only after all immutable snapshots are initialized.
    */
    init(module: SQLiteDocumentModule) {
        self.module = module
        self.info = module.info
        self.metadata = module.reader.metadata
        self.origin = module.origin
    }

    /**
     Reads every real verse in one Bible chapter on an operation-owned SQLite connection.

     - Parameters:
       - osisId: Canonical KJVA OSIS book identifier.
       - chapter: One-based chapter.
     - Returns: Source rows in reader order without invented gaps.
     - Side effects: Executes one read-only SQLite chapter query.
     - Throws: Re-throws mapping, key, and query failures from the module facade.
     */
    func chapterContent(
        osisId: String,
        chapter: Int
    ) throws -> [(verse: Int, text: String)] {
        try module.chapterContent(osisId: osisId, chapter: chapter)
    }

    /**
     Reads one exact Bible or covering commentary verse on its own SQLite connection.

     - Parameters describe an exact one-based KJVA verse coordinate.
     - Returns: Source content, or nil when the coordinate has no Bible/covering commentary row.
     - Side effects: Executes one read-only SQLite lookup.
     - Throws: Re-throws source mapping and query failures without fallback.
     */
    func verseContent(
        osisId: String,
        chapter: Int,
        verse: Int
    ) throws -> SQLiteDocumentContent? {
        try module.verseContent(osisId: osisId, chapter: chapter, verse: verse)
    }

    /**
     Reads exact source-order dictionary chooser keys.

     - Returns: Exact, case-sensitive source keys in Android database order.
     - Side effects: Executes one read-only key enumeration.
     - Throws: Re-throws enumeration and CursorWindow failures.
     */
    func dictionaryKeys() throws -> [String] {
        try module.dictionaryKeys()
    }

    /**
     Reads one byte-exact dictionary key.

     - Parameter key: Exact source key; case and leading zeroes are significant.
     - Returns: Source content, or nil when that exact key is absent.
     - Side effects: Executes one read-only SQLite lookup.
     - Throws: Re-throws source query failures without key normalization.
     */
    func dictionaryContent(for key: String) throws -> SQLiteDocumentContent? {
        try module.dictionaryContent(for: key)
    }

    /**
     Reads the real-key-derived Bible/commentary book list.

     - Returns: KJVA-ordered books and real maximum chapter counts exposed by source keys.
     - Side effects: Executes one read-only key enumeration.
     - Throws: Re-throws key enumeration and source metadata failures.
     */
    func bookList() throws -> [BookInfo] {
        try module.bookList()
    }
}
