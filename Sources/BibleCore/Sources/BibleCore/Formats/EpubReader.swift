// EpubReader.swift -- Android-shaped EPUB general-book adapter and local index

import Foundation
import SQLite3
import SwordKit

/**
 SQLite destructor marker that makes SQLite copy temporary Swift string buffers.
 */
let epubSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Describes one EPUB installed in the local general-book library.

 `identifier` remains the filesystem/library lookup token. `initials` is the Android-compatible
 document identity (`Epub-...`) persisted in `PageManager.generalBookDocument` and emitted through
 the reader bridge. The Java-trimmed package title is also the generated-book Description and
 therefore participates in Android `Books.getBook` exact-full-name and case-insensitive lookup.
 */
public struct EpubInfo: Sendable, Equatable, Identifiable {
    /// Stable library directory identifier.
    public let identifier: String

    /// Stable Android-style general-book initials.
    public let initials: String

    /// NFC-normalized import display filename used by Android to derive module initials.
    public let sourceFileName: String

    /// Package title from OPF metadata.
    public let title: String

    /// Package description used by Android's document About dialog.
    public let description: String

    /// Package creator from OPF metadata.
    public let author: String

    /// Package language, defaulting to `en`.
    public let language: String

    /// SwiftUI list identity, equal to the stable library identifier.
    public var id: String { identifier }
}

/**
 Failures raised while installing, indexing, or opening EPUB packages.

 Import callers surface these errors to the user and never publish a partially extracted or
 partially indexed book.
 */
public enum EpubError: LocalizedError, Equatable {
    /// Archive, container, package, navigation, or XHTML structure is invalid.
    case invalidEpub(String)

    /// A ZIP member could not be decompressed.
    case decompressionFailed

    /// The SQLite package index could not be built atomically.
    case indexingFailed(String)

    /// A distinct imported filename maps to initials already owned by another EPUB.
    case identityConflict(initials: String, existingFileName: String, incomingFileName: String)

    /// User-visible diagnostic for import and open failures.
    public var errorDescription: String? {
        switch self {
        case .invalidEpub(let message):
            return "Invalid EPUB: \(message)"
        case .decompressionFailed:
            return "Failed to decompress EPUB data"
        case .indexingFailed(let message):
            return "Failed to build EPUB index: \(message)"
        case .identityConflict(let initials, let existingFileName, let incomingFileName):
            return "Cannot import \(incomingFileName) because \(existingFileName) already uses EPUB module identity \(initials)"
        }
    }
}

/**
 Typed failures from strict EPUB PageManager-key resolution.

 The compatibility reader accepts manifest identifiers and hrefs for chooser/internal-link flows.
 Bookmark navigation must instead prove that the supplied value is the canonical numeric key stored
 in `PageManager.generalBookKey`, so aliases and malformed index rows fail visibly.
 */
public enum EpubPersistedKeyLookupError: Error, Equatable, LocalizedError, Sendable {
    /// The supplied value is not the canonical positive decimal representation of a fragment ID.
    case invalidPersistedKey(String)

    /// No indexed content row owns the canonical persisted key.
    case contentNotFound(String)

    /// SQLite could not read a complete, ordered content row for the key.
    case indexReadFailed(String)

    /**
     Returns the closest existing Android-localized reader error message.

     - Returns: The shared no-content message for an absent row and generic error text for invalid or
       unreadable identities.
     - Side effects: Reads localized string resources only.
     - Failure modes: None; every current case has a fallback value.
     */
    public var errorDescription: String? {
        switch self {
        case .contentNotFound:
            return String(localized: "error_no_content", defaultValue: "No content for selected verse")
        case .invalidPersistedKey, .indexReadFailed:
            return String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}

/**
 Reads installed EPUB packages through an Android-shaped general-book contract.

 Installation extracts the central-directory-described ZIP into an immutable generation, parses
 the OCF container and OPF package with structured XML, transforms every readable spine document
 into native HTML with BVA ordinals, builds an FTS5 index, and atomically switches a stable pointer
 only after package and index are complete. Runtime calls expose stable Android module initials,
 generation-contained resources, manifest keys, TOC entries, ordinal ranges, navigation, and hits.

 - Important: Each instance owns one read-only SQLite connection. Callers must serialize calls on
   an instance; resource serving opens a fresh instance per request.
 */
public final class EpubReader: @unchecked Sendable {
    /**
     Immutable EPUB identity proposed at the global installed-book admission boundary.

     - Properties:
       - identifier: Collision-resistant exact-source identity used for same-book replacement.
       - initials: Android `Book.initials` token resolved against the complete current registry.
     - Side effects: None; values are derived before candidate-owned paths are created.
     */
    public struct InstallCandidate: Sendable, Equatable {
        /// Stable exact-source identifier that distinguishes updates from colliding new books.
        public let identifier: String

        /// Android-compatible initials generated from the NFC-normalized display filename.
        public let initials: String

        /**
         Creates one immutable typed admission candidate.

         - Parameters:
           - identifier: Stable exact-source identity used to recognize a reinstall.
           - initials: Android-compatible lookup token checked against the combined registry.
         - Side effects: None.
         - Failure modes: This initializer cannot fail; callers derive both values before mutation.
         */
        public init(identifier: String, initials: String) {
            self.identifier = identifier
            self.initials = initials
        }
    }

    /**
     Validates one proposed EPUB identity at the atomic library mutation boundary.

     The callback runs synchronously while `libraryMutationLock` is held and before the candidate
     receives a staging directory or published pointer. It may inspect the complete live book
     registry and throw to reject installation without candidate artifacts.

     - Parameter candidate: Exact-source identifier plus NFC-derived Android module initials.
     - Side effects: Defined by the caller; the EPUB library itself is not mutated before return.
     - Failure modes: Any thrown error aborts the install unchanged and is propagated verbatim.
     - Important: The callback must not wait for another operation that requires the EPUB library
       lock. Recursive EPUB metadata reads on the same thread are supported by the library lock.
     */
    public typealias InstallAdmission = @Sendable (_ candidate: InstallCandidate) throws -> Void

    /// Current on-disk index schema/transform version.
    static let indexVersion = "8"

    /// Android `EPUB_OPTIMIZER_VERSION` projected by the generated-book About metadata.
    public static let androidOptimizerVersion = "2"

    /// Serializes publication and identity-conflict checks across local EPUB imports/deletions.
    static let libraryMutationLock = NSRecursiveLock()

    /// Per-member expansion limit applied before extracting an untrusted EPUB archive.
    static let maximumArchiveEntryByteCount: UInt64 = 256 * 1024 * 1024

    /// Aggregate expansion limit applied before extracting an untrusted EPUB archive.
    static let maximumArchiveByteCount: UInt64 = 512 * 1024 * 1024

    /// Maximum file count accepted from one package to bound extraction and indexing work.
    static let maximumArchiveEntryCount = 10_000

    /// Extracted package root for this reader.
    private let packageRootURL: URL

    /// Library root used to locate the companion index.
    private let libraryRootURL: URL

    /// Exact immutable package/index generation retained for this reader's lifetime.
    private let generationLocation: EpubGenerationLocation

    /// Open read-only SQLite connection.
    private var indexDB: OpaquePointer?

    /// Stable local library identifier.
    public let identifier: String

    /// Opaque iOS-local generation token carried by contained resource URLs.
    public let generationIdentifier: String

    /// Stable Android-style general-book initials.
    public private(set) var initials: String

    /// NFC-normalized display filename retained for Android-compatible initials and diagnostics.
    public private(set) var sourceFileName: String = ""

    /// Package title loaded from the index.
    public private(set) var title: String = ""

    /// Package description loaded from the index for Android's document About dialog.
    public private(set) var description: String = ""

    /// Package creator loaded from the index.
    public private(set) var author: String = ""

    /// Package language loaded from the index.
    public private(set) var language: String = "en"

    /**
     One flattened chooser row from EPUB 2 NCX, EPUB 3 nav, or spine fallback navigation.
     */
    public struct TOCEntry: Sendable, Equatable, Identifiable {
        /// User-visible navigation label.
        public let title: String

        /// Numeric Android-compatible fragment key, optionally followed by an HTML id.
        public let key: String

        /// Canonical package-relative href, including an optional fragment suffix.
        public let href: String

        /// Zero-based flattened navigation order.
        public let ordinal: Int

        /// Zero-based source hierarchy depth.
        public let depth: Int

        /// Stable row identity within one EPUB navigation list.
        public var id: Int { ordinal }
    }

    /**
     One resolved EPUB general-book page.
     */
    public struct Content: Sendable, Equatable {
        /// Numeric Android-compatible fragment key.
        public let key: String

        /// Numeric key persisted by the general-book PageManager contract.
        public let persistedKey: String

        /// Canonical package-relative XHTML href.
        public let href: String

        /// Optional decoded HTML fragment identifier.
        public let fragment: String?

        /// User-visible page title.
        public let title: String

        /// Native HTML consumed by the Vue reader.
        public let html: String

        /// Inclusive BVA ordinal range for generic annotations and search jumps.
        public let ordinalRange: ClosedRange<Int>
    }

    /**
     One Android-shaped EPUB FTS hit.
     */
    public struct SearchResult: Sendable, Equatable, Identifiable {
        /// Numeric fragment key owning the matching BVA anchor.
        public let key: String

        /// Canonical package-relative page href.
        public let href: String

        /// User-visible page title.
        public let title: String

        /// Matching BVA ordinal inside the page.
        public let ordinal: Int

        /// Original plain-text sentence containing the hit.
        public let snippet: String

        /// Source-preserving runs emphasized only from nonce-marked SQLite hit positions.
        public let snippetSegments: [EpubSearchSnippetSegment]

        /// Stable identity for a key/ordinal result row.
        public var id: String { "\(key):\(ordinal)" }
    }

    /// Default app-managed EPUB library directory.
    private static var defaultLibraryRootURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("epub", isDirectory: true)
    }

    /// Canonical app SWORD root whose coordinator serializes every installed-book publication.
    private static var defaultModuleStoreRootURL: URL {
        URL(fileURLWithPath: SwordManager.defaultModulePath(), isDirectory: true)
    }

    /**
     Derives the exact typed identity used by EPUB admission without touching storage.

     - Parameter epubURL: Candidate source URL whose provider-visible basename owns identity.
     - Returns: Stable source identifier plus Android-compatible generated initials.
     - Side effects: None; the basename is NFC-normalized before both values are generated.
     - Failure modes: This derivation cannot fail; punctuation-only names use the established
       stable-identifier fallback and Android initials sanitizer.
     */
    public static func installCandidate(forEpubURL epubURL: URL) -> InstallCandidate {
        let sourceFileName = epubURL.lastPathComponent.precomposedStringWithCanonicalMapping
        return InstallCandidate(
            identifier: stableIdentifier(forSourceFileName: sourceFileName),
            initials: initials(forDisplayFileName: sourceFileName)
        )
    }

    /**
     Installs an EPUB into the default app library.

     - Parameter epubURL: User-selected local or security-scoped EPUB URL.
     - Returns: Stable local identifier used to reopen the package.
     - Side effects: Reads the archive, writes a staged extraction/index, and atomically replaces a
       prior current-generation pointer only after complete validation succeeds.
     - Throws: `EpubError`, `ZipArchiveReaderError`, or file-system errors. A failure leaves any
       previously installed package intact.
     - Important: This compatibility entry point cannot inspect the app's SwiftData registry. App
       import flows must use `install(epubURL:moduleStoreRootURL:admittingCandidateWith:)` so native,
       SQLite, EPUB, and My Documents ownership is revalidated under the global publication lease.
     */
    public static func install(epubURL: URL) throws -> String {
        try install(
            epubURL: epubURL,
            moduleStoreRootURL: defaultModuleStoreRootURL,
            admittingCandidateWith: { _ in }
        )
    }

    /**
     Installs an EPUB only after a lock-owned live-registry admission check succeeds.

     This overload is the production boundary for Android-compatible global book registration.
     It closes the interval between a detached caller's preflight and atomic EPUB publication: a
     concurrent import that publishes first is visible to the next callback before that next
     candidate can create staging artifacts.

     - Parameters:
       - epubURL: User-selected local or security-scoped EPUB URL.
       - moduleStoreRootURL: SWORD root whose canonical mutation coordinator owns global ordering.
       - admission: Live complete-registry validator invoked with the typed EPUB identity.
     - Returns: Stable local identifier used to reopen the package.
     - Side effects: On admission, performs the same staged extraction, indexing, and atomic
       publication as `install(epubURL:)`; rejection leaves the candidate unpublished and unstaged.
     - Throws: Propagates admission, EPUB validation, ZIP, indexing, and filesystem errors.
     - Important: Admission and all candidate file mutation execute under one library lock hold.
     */
    public static func install(
        epubURL: URL,
        moduleStoreRootURL: URL,
        admittingCandidateWith admission: InstallAdmission
    ) throws -> String {
        let coordinator = ModuleStoreMutationCoordinator.shared(forModuleRoot: moduleStoreRootURL)
        return try coordinator.withExclusiveTransaction(kind: .epub, prepare: { () }, commit: { _ in
            try install(
                epubURL: epubURL,
                libraryRootURL: defaultLibraryRootURL,
                admittingCandidateWith: admission
            )
        })
    }

    /**
     Lists valid EPUB general-book adapters in the default app library.

     - Returns: Metadata in native filesystem enumeration order, matching Android's raw
       `File.listFiles()` first-owner registration replay. Presentation callers may sort only after
       the combined registry has resolved ownership.
     - Side effects: May migrate pre-generation installs, then opens each current index read-only.
     - Failure modes: Incomplete or unreadable package rows are omitted.
     */
    public static func installedEpubs() -> [EpubInfo] {
        installedEpubs(libraryRootURL: defaultLibraryRootURL)
    }

    /**
     Captures the default library's complete published registration state without mutation.

     - Returns: Valid EPUB metadata in native filesystem enumeration order, or an empty array when
       the library root does not yet exist.
     - Side effects: Performs strictly read-only pointer, filesystem, and SQLite metadata access.
     - Throws: Any existing corrupt, unsafe, legacy, or unreadable library state so identity
       admission can fail closed.
     */
    public static func registrationSnapshot() throws -> [EpubInfo] {
        try throwingReadOnlyInstalledEpubs(libraryRootURL: defaultLibraryRootURL)
    }

    /**
     Deletes one installed EPUB's stable pointer from the default app library.

     - Parameter identifier: Stable identifier returned by `install(epubURL:)`.
     - Side effects: Prevents new opens immediately; immutable generations are removed after all
       readers holding them close.
     - Throws: File-system errors raised before the published EPUB identity can be removed. A failed
       transaction restores every path already moved aside, so the installed book remains visible.
     */
    public static func delete(identifier: String) throws {
        let coordinator = ModuleStoreMutationCoordinator.shared(
            forModuleRoot: defaultModuleStoreRootURL
        )
        try coordinator.withExclusiveTransaction(kind: .epub, prepare: { () }, commit: { _ in
            try delete(identifier: identifier, libraryRootURL: defaultLibraryRootURL)
        })
    }

    /**
     Rebuilds one installed EPUB's search/index generation and opens the replacement reader.

     Android exposes Rebuild index from EPUB Search. The native adapter fulfills that command by
     copying the currently published immutable package, constructing a complete replacement SQLite
     index, atomically switching the stable generation pointer, and only then opening the new
     generation. Existing readers retain their leased package/index pair until they close.

     - Parameter identifier: Stable identifier of the installed EPUB to rebuild.
     - Returns: A reader leased to the newly published generation.
     - Side effects: Writes and atomically publishes one immutable EPUB generation, then opens its
       SQLite index read-only.
     - Throws: Validation, index-construction, publication, or reopen failures. Any prior generation
       remains current when publication fails; existing readers are never mutated in place.
     */
    public static func rebuildSearchIndex(identifier: String) throws -> EpubReader {
        try rebuildSearchIndex(identifier: identifier, libraryRootURL: defaultLibraryRootURL)
    }

    /**
     Deletes one installed EPUB's full-text search index without removing the document.

     Android exposes Delete search index from the Choose Document contextual action mode. The
     native adapter publishes a new immutable generation whose rendered content, navigation, and
     resources remain intact while its FTS table is empty. Existing readers retain their prior
     searchable generation until released.

     - Parameter identifier: Stable identifier of the installed EPUB whose FTS rows are removed.
     - Returns: A reader leased to the newly published index-free generation.
     - Side effects: Writes and atomically publishes one immutable EPUB generation.
     - Throws: Validation, staging, SQLite, publication, or reopen failures; the prior stable
       generation remains selected whenever publication fails.
     */
    public static func deleteSearchIndex(identifier: String) throws -> EpubReader {
        try deleteSearchIndex(identifier: identifier, libraryRootURL: defaultLibraryRootURL)
    }

    /**
     Opens a default-library EPUB by stable identifier.

     Legacy layouts and outdated indexes are rebuilt into a new immutable generation before open.

     - Parameter identifier: Installed package directory identifier.
     - Side effects: May rebuild an outdated companion index, then opens SQLite read-only.
     - Failure modes: Returns `nil` for missing, invalid, or unindexable packages.
     */
    public convenience init?(identifier: String) {
        self.init(identifier: identifier, libraryRootURL: Self.defaultLibraryRootURL)
    }

    /**
     Opens a default-library EPUB by Android-style module initials.

     - Parameter initials: Value such as `Epub-my_book` stored as `generalBookDocument`.
     - Side effects: Scans installed metadata and opens the matching index.
     - Failure modes: Returns `nil` when the initials identify zero or multiple installed EPUBs;
       ambiguous legacy libraries fail closed instead of loading another book's resources.
     */
    public convenience init?(initials: String) {
        let matches = Self.installedEpubs().filter { $0.initials == initials }
        guard matches.count == 1, let info = matches.first else {
            return nil
        }
        self.init(identifier: info.identifier)
    }

    /**
     Opens the exact immutable generation encoded in an EPUB resource URL.

     This initializer is for contained resource serving. It verifies both Android-visible initials
     and the opaque generation against index metadata, including for an old generation retained by
     a still-open reader after reinstall or deletion.

     - Parameters:
       - initials: Android-compatible EPUB initials.
       - generationIdentifier: Opaque generation token emitted in transformed native HTML.
     - Side effects: Acquires a generation lease and opens its SQLite index read-only.
     - Failure modes: Returns `nil` for missing, unleased/pruned, ambiguous, or cross-book identity.
     */
    public convenience init?(initials: String, generationIdentifier: String) {
        guard let location = Self.acquireGeneration(
            initials: initials,
            generationIdentifier: generationIdentifier,
            libraryRootURL: Self.defaultLibraryRootURL
        ) else {
            return nil
        }
        self.init(acquiredLocation: location, libraryRootURL: Self.defaultLibraryRootURL)
    }

    /**
     Opens an EPUB inside an explicit library root.

     This initializer is internal so deterministic tests can isolate package storage without
     mutating the app's Documents directory.
     */
    convenience init?(identifier: String, libraryRootURL: URL) {
        guard let location = Self.acquireCurrentGeneration(
            identifier: identifier,
            libraryRootURL: libraryRootURL
        ) else {
            return nil
        }
        self.init(acquiredLocation: location, libraryRootURL: libraryRootURL)
    }

    /** Opens an exact explicit-root generation for resource-isolation tests. */
    convenience init?(
        initials: String,
        generationIdentifier: String,
        libraryRootURL: URL
    ) {
        guard let location = Self.acquireGeneration(
            initials: initials,
            generationIdentifier: generationIdentifier,
            libraryRootURL: libraryRootURL
        ) else {
            return nil
        }
        self.init(acquiredLocation: location, libraryRootURL: libraryRootURL)
    }

    /**
     Opens one already-leased immutable generation.

     - Parameters:
       - acquiredLocation: Package/index pair whose lease was acquired under the library lock.
       - libraryRootURL: Owning library root used to release that lease.
     - Side effects: Opens SQLite read-only; releases the lease immediately if open fails.
     - Important: Successful instances release exactly one lease in `deinit`.
     */
    private init?(acquiredLocation: EpubGenerationLocation, libraryRootURL: URL) {
        self.identifier = acquiredLocation.identifier
        self.generationIdentifier = acquiredLocation.generationIdentifier
        self.initials = Self.initials(forIdentifier: acquiredLocation.identifier)
        self.libraryRootURL = libraryRootURL.standardizedFileURL
        self.generationLocation = acquiredLocation
        self.packageRootURL = acquiredLocation.packageRootURL.standardizedFileURL

        guard sqlite3_open_v2(
            acquiredLocation.indexURL.path,
            &indexDB,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK else {
            sqlite3_close(indexDB)
            indexDB = nil
            Self.releaseGeneration(acquiredLocation, libraryRootURL: libraryRootURL)
            return nil
        }
        loadMetadata()
    }

    deinit {
        sqlite3_close(indexDB)
        Self.releaseGeneration(generationLocation, libraryRootURL: libraryRootURL)
    }

    /// Filesystem path to the extracted package root for diagnostics.
    public var extractedPath: String { packageRootURL.path }

    /// Identity embedded in every resource/style URL emitted by this immutable generation.
    public var resourceIdentity: EpubResourceIdentity {
        EpubResourceIdentity(
            bookInitials: initials,
            generationIdentifier: generationIdentifier
        )
    }

    /**
     Returns the flattened EPUB navigation list.

     - Returns: NCX, EPUB 3 nav, or spine fallback entries in source order.
     - Side effects: Reads the local SQLite index.
     */
    public func tableOfContents() -> [TOCEntry] {
        let sql = "SELECT title, key, href, fragment, ordinal, depth FROM toc ORDER BY ordinal"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(indexDB, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var entries: [TOCEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let title = Self.columnText(statement, index: 0) ?? ""
            let baseKey = Self.columnText(statement, index: 1) ?? ""
            let baseHref = Self.columnText(statement, index: 2) ?? ""
            let fragment = Self.columnText(statement, index: 3)
            entries.append(TOCEntry(
                title: title,
                key: Self.composite(base: baseKey, fragment: fragment),
                href: Self.composite(base: baseHref, fragment: fragment),
                ordinal: Int(sqlite3_column_int(statement, 4)),
                depth: Int(sqlite3_column_int(statement, 5))
            ))
        }
        return entries
    }

    /**
     Resolves a numeric fragment key, original manifest key, or legacy href into one page.

     - Parameter requestedKey: Numeric key, manifest id, or href, optionally followed by an id.
     - Returns: Page metadata and native HTML, or `nil` when the key is absent.
     - Side effects: Reads the local SQLite index.
     - Failure modes: Missing keys return `nil`; no unrelated page is substituted.
     */
    public func content(forKey requestedKey: String) -> Content? {
        let (base, fragment) = Self.splitComposite(requestedKey)
        guard let fragmentID = resolvedFragmentID(base: base, htmlID: fragment) else { return nil }
        let sql = """
            SELECT id, href, title, content, ordinal_start, ordinal_end
            FROM content
            WHERE id = ?
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(indexDB, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, fragmentID)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let href = Self.columnText(statement, index: 1),
              let pageTitle = Self.columnText(statement, index: 2),
              let html = Self.columnText(statement, index: 3) else {
            return nil
        }
        let key = String(sqlite3_column_int64(statement, 0))
        let start = Int(sqlite3_column_int64(statement, 4))
        let end = max(start, Int(sqlite3_column_int64(statement, 5)))
        return Content(
            key: key,
            persistedKey: key,
            href: href,
            fragment: fragment,
            title: pageTitle,
            html: html,
            ordinalRange: start...end
        )
    }

    /**
     Resolves only an exact numeric key previously persisted by the EPUB PageManager contract.

     Manifest IDs, hrefs, fragment suffixes, whitespace, signs, and alternate decimal spellings such
     as `01` are rejected before SQLite lookup. Unlike chooser and restore compatibility paths, this
     method never consults alias tables and never substitutes the first or current fragment.

     - Parameter persistedKey: Canonical positive decimal `content.id` string.
     - Returns: Immutable indexed content whose `persistedKey` exactly equals the input.
     - Side effects: Reads this reader's immutable SQLite generation; no cursor, library, or reader
       state is changed.
     - Throws: `EpubPersistedKeyLookupError` when the key is noncanonical, absent, or the index row
       cannot be read with a nonnegative ordered BVA range.
     - Important: Calls on one `EpubReader` instance must follow the class's serialization contract.
     */
    public func exactContent(forPersistedKey persistedKey: String) throws -> Content {
        guard let fragmentID = Int64(persistedKey),
              fragmentID > 0,
              String(fragmentID) == persistedKey else {
            throw EpubPersistedKeyLookupError.invalidPersistedKey(persistedKey)
        }

        let sql = """
            SELECT id, href, title, content, ordinal_start, ordinal_end
            FROM content
            WHERE id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(indexDB, sql, -1, &statement, nil) == SQLITE_OK else {
            throw EpubPersistedKeyLookupError.indexReadFailed(persistedKey)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, fragmentID)

        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            if step == SQLITE_DONE {
                throw EpubPersistedKeyLookupError.contentNotFound(persistedKey)
            }
            throw EpubPersistedKeyLookupError.indexReadFailed(persistedKey)
        }
        guard let href = Self.columnText(statement, index: 1),
              let pageTitle = Self.columnText(statement, index: 2),
              let html = Self.columnText(statement, index: 3) else {
            throw EpubPersistedKeyLookupError.indexReadFailed(persistedKey)
        }
        let resolvedKey = String(sqlite3_column_int64(statement, 0))
        let start = Int(sqlite3_column_int64(statement, 4))
        let end = Int(sqlite3_column_int64(statement, 5))
        guard resolvedKey == persistedKey, start >= 0, end >= start else {
            throw EpubPersistedKeyLookupError.indexReadFailed(persistedKey)
        }

        return Content(
            key: resolvedKey,
            persistedKey: resolvedKey,
            href: href,
            fragment: nil,
            title: pageTitle,
            html: html,
            ordinalRange: start...end
        )
    }

    /**
     Resolves an EPUB-native internal-link target to its numeric general-book fragment.

     - Parameters:
       - originalKey: OPF manifest id emitted in `epubRef`'s `to-key` attribute.
       - htmlID: Optional source XHTML id emitted in `to-id`.
     - Returns: Content for the mapped fragment, retaining `htmlID` as the scroll target.
     - Side effects: Reads the local SQLite index.
     - Failure modes: Returns `nil` when the source target was not indexed.
     */
    public func content(originalKey: String, htmlID: String?) -> Content? {
        content(forKey: Self.composite(base: originalKey, fragment: htmlID))
    }

    /**
     Compatibility accessor for callers that still hold an href.

     - Parameter href: Canonical or legacy package href, optionally with a fragment.
     - Returns: Native HTML for the resolved page.
     - Side effects: Reads the local SQLite index.
     */
    public func getContent(href: String) -> String? {
        content(forKey: href)?.html
    }

    /**
     Resolves a page title from a manifest key or href.

     - Parameter href: Manifest key or package href, optionally with a fragment.
     - Returns: Indexed page/TOC title, or `nil` when absent.
     - Side effects: Reads the local SQLite index.
     */
    public func getTitle(href: String) -> String? {
        if let content = content(forKey: href) {
            return content.title
        }
        let (base, _) = Self.splitComposite(href)
        let sql = "SELECT title FROM toc WHERE key = ? OR href = ? ORDER BY ordinal LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(indexDB, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        Self.bindText(base, to: statement, index: 1)
        Self.bindText(base, to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.columnText(statement, index: 0)
    }

    /**
     Returns the first navigable general-book key, preferring TOC order then spine order.

     - Returns: Stable key or `nil` for an empty/corrupt index.
     - Side effects: Reads SQLite.
     */
    public func firstKey() -> String? {
        tableOfContents().first?.key ?? orderedContentKeys().first
    }

    /**
     Returns the next spine key after the current page.

     - Parameter key: Current manifest/composite key.
     - Returns: Next key, or `nil` at the end.
     - Side effects: Reads SQLite.
     */
    public func nextKey(after key: String?) -> String? {
        adjacentKey(to: key, offset: 1)
    }

    /**
     Returns the previous spine key before the current page.

     - Parameter key: Current manifest/composite key.
     - Returns: Previous key, or `nil` at the beginning.
     - Side effects: Reads SQLite.
     */
    public func previousKey(before key: String?) -> String? {
        adjacentKey(to: key, offset: -1)
    }

    /**
     Searches Android-style BVA sentence anchors with the EPUB search-mode contract.

     - Parameters:
       - query: User-entered text interpreted according to `epubMode`.
       - epubMode: Android's complete persisted phrase/all/any/advanced query selection.
     - Returns: Matching rows in insertion/reading order with typed, source-preserving emphasis.
     - Side effects: Reads SQLite and generates request-local marker strings; persisted state is
       unchanged.
     - Failure modes: Throws `SearchIndexError` for empty or malformed advanced queries and SQLite
       failures. Authored EPUB text is never interpreted as markup.
     - Note: Results are returned in package reading order. Android EPUB search uses raw
       `unicode61` text and deliberately does not apply JSword's Bible-language analyzers.
     */
    public func searchResults(
        query: String,
        epubMode: EpubSearchMode
    ) throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SearchIndexError.emptyQuery }
        let ftsQuery = try SearchQueryCompiler.compile(
            query: trimmed,
            epubMode: epubMode,
            languageCode: language
        )
        let scopedQuery = "contentText : (\(ftsQuery))"
        let nonce = UUID().uuidString
        let openingMarker = "\u{E000}andbible-\(nonce)-open\u{E001}"
        let closingMarker = "\u{E000}andbible-\(nonce)-close\u{E001}"
        let sql = """
            SELECT key, href, title, ordinal, contentText,
                   highlight(content_fts, 0, ?, ?)
            FROM content_fts
            WHERE content_fts MATCH ?
            ORDER BY rowid
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(indexDB, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SearchIndexError.sqlite(
                operation: "preparing EPUB search",
                code: sqlite3_errcode(indexDB),
                message: Self.sqliteMessage(indexDB)
            )
        }
        defer { sqlite3_finalize(statement) }
        Self.bindText(openingMarker, to: statement, index: 1)
        Self.bindText(closingMarker, to: statement, index: 2)
        Self.bindText(scopedQuery, to: statement, index: 3)

        var results: [SearchResult] = []
        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            guard let key = Self.columnText(statement, index: 0),
                  let href = Self.columnText(statement, index: 1),
                  let title = Self.columnText(statement, index: 2),
                  let sourceText = Self.columnText(statement, index: 4),
                  let highlightedSearchText = Self.columnText(statement, index: 5) else {
                throw SearchIndexError.sqlite(
                    operation: "reading EPUB search results",
                    code: SQLITE_CORRUPT,
                    message: "EPUB search row is incomplete"
                )
            }
            results.append(SearchResult(
                key: key,
                href: href,
                title: title,
                ordinal: Int(sqlite3_column_int64(statement, 3)),
                snippet: sourceText,
                snippetSegments: EpubSearchTextProjection.sourceSnippetSegments(
                    sourceText: sourceText,
                    highlightedSourceText: highlightedSearchText,
                    openingMarker: openingMarker,
                    closingMarker: closingMarker
                )
            ))
            stepCode = sqlite3_step(statement)
        }
        guard stepCode == SQLITE_DONE else {
            let message = Self.sqliteMessage(indexDB)
            if epubMode == .fullTextQuery {
                throw SearchIndexError.invalidQuery(reason: message)
            }
            throw SearchIndexError.sqlite(
                operation: "executing EPUB search",
                code: stepCode,
                message: message
            )
        }
        return results
    }

    /**
     Compatibility wrapper for callers that already supply Android advanced FTS syntax.

     - Parameter query: Raw FTS5 query text.
     - Returns: Matching rows, or an empty list when the legacy caller cannot surface an error.
     - Side effects: Reads SQLite through the throwing search API.
     - Failure modes: Explicit failures are intentionally collapsed only for legacy callers; new UI
       must call `searchResults(query:epubMode:)` and render the error.
     */
    public func searchResults(query: String) -> [SearchResult] {
        (try? searchResults(query: query, epubMode: .fullTextQuery)) ?? []
    }

    /**
     Compatibility search projection used by the existing SwiftUI result list.

     - Parameter query: FTS5 query text.
     - Returns: Legacy href/title/snippet tuples backed by anchor-level search.
     - Side effects: Reads SQLite.
     */
    public func search(query: String) -> [(href: String, title: String, snippet: String)] {
        searchResults(query: query).map { ($0.href, $0.title, $0.snippet) }
    }

    /**
     Resolves one package-contained resource file.

     - Parameter canonicalPath: Canonical package path from transformed native HTML.
     - Returns: Readable file URL, or `nil` when absent/escaping.
     - Side effects: Checks local file metadata.
     */
    public func resourceURL(for canonicalPath: String) -> URL? {
        let resolver = EpubPackagePathResolver(packageRootURL: packageRootURL)
        guard let url = try? resolver.fileURL(for: canonicalPath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /**
     Builds the sanitized stylesheet bundle for one rendered EPUB key.

     Android combines linked stylesheets for the active EPUB fragment and removes declarations
     that override reader colors, body layout, and line height. iOS applies the same policy while
     rewriting nested CSS resources to the contained custom scheme.

     - Parameter key: Numeric, manifest, or legacy href key for the rendered page.
     - Returns: UTF-8 stylesheet bytes; empty data when no stylesheets are linked.
     - Side effects: Reads stylesheet files inside the package.
     */
    public func styleSheetData(forKey key: String) -> Data {
        let split = Self.splitComposite(key)
        guard let fragmentID = resolvedFragmentID(base: split.base, htmlID: split.fragment) else {
            return Data()
        }
        let sql = """
            SELECT styles.path
            FROM styles
            JOIN content ON content.original_key = styles.original_key
            WHERE content.id = ?
            ORDER BY styles.ordinal
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(indexDB, sql, -1, &statement, nil) == SQLITE_OK else { return Data() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, fragmentID)
        var parts: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = Self.columnText(statement, index: 0),
                  let css = String(data: styleSheetData(forCanonicalPath: path), encoding: .utf8),
                  !css.isEmpty else {
                continue
            }
            parts.append(css)
        }
        return parts.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    /**
     Loads and sanitizes one canonical package stylesheet, including nested `@import` targets.

     - Parameter canonicalPath: Indexed or custom-route package path for a CSS member.
     - Returns: UTF-8 CSS with reader-owned declarations removed and local resources rewritten;
       empty data when the path is not a readable stylesheet.
     - Side effects: Reads one contained package file.
     - Failure modes: Missing, escaping, non-CSS, and undecodable resources return empty data so
       WebKit cannot receive unsanitized package bytes through the stylesheet route.
     */
    public func styleSheetData(forCanonicalPath canonicalPath: String) -> Data {
        guard URL(fileURLWithPath: canonicalPath).pathExtension.lowercased() == "css",
              let url = resourceURL(for: canonicalPath),
              let data = try? Data(contentsOf: url),
              let css = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return Data()
        }
        return EpubCSSProcessor.process(
            css,
            styleSheetPath: canonicalPath,
            packageRootURL: packageRootURL,
            resourceIdentity: resourceIdentity
        ).data(using: .utf8) ?? Data()
    }

    /**
     Preserves initials for an index created before exact source filenames were retained.

     - Parameter identifier: Legacy extracted-directory name.
     - Returns: Best-effort `Epub-...` identity used only while rebuilding a pre-v4 index.
     - Side effects: None.
     - Failure modes: The result is not cross-platform portable because the original Android
       display filename is unavailable; current installs persist their exact initials in metadata.
     */
    private static func initials(forIdentifier identifier: String) -> String {
        initials(forDisplayFileName: identifier)
    }

    /**
     Converts an exact import display filename to Android's `epubInitials(dirName)` value.

     Android keeps ASCII digits plus the Java-regex `A-z` range and replaces every other scalar
     with `_`. The filename extension participates in identity because Android's EPUB directory is
     the full document-provider display name.

     - Parameter displayFileName: Exact imported filename, including `.epub` when present.
     - Returns: Android-portable general-book initials beginning with `Epub-`.
     - Side effects: None.
     - Failure modes: None; an empty filename produces `Epub-`.
     */
    public static func initials(forDisplayFileName displayFileName: String) -> String {
        let sanitized = displayFileName.unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            let isDigit = value >= 48 && value <= 57
            let isAndroidAZRange = value >= 65 && value <= 122
            return Character(isDigit || isAndroidAZRange ? String(scalar) : "_")
        }
        return "Epub-" + String(sanitized)
    }

    // MARK: - Runtime helpers

    /// Loads Android-visible package metadata from the open index.
    private func loadMetadata() {
        initials = metadataValue("initials") ?? initials
        sourceFileName = metadataValue("source_file_name")
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? identifier
        title = metadataValue("title") ?? identifier
        description = metadataValue("description") ?? sourceFileName
        author = metadataValue("author") ?? ""
        language = metadataValue("language") ?? "en"
    }

    /// Reads one metadata value from the open index.
    private func metadataValue(_ key: String) -> String? {
        let sql = "SELECT value FROM metadata WHERE key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(indexDB, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        Self.bindText(key, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.columnText(statement, index: 0)
    }

    /// Returns all content keys in spine order.
    private func orderedContentKeys() -> [String] {
        let sql = "SELECT CAST(id AS TEXT) FROM content ORDER BY spine_ordinal, fragment_ordinal"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(indexDB, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var keys: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let key = Self.columnText(statement, index: 0) { keys.append(key) }
        }
        return keys
    }

    /// Resolves one adjacent key in spine order.
    private func adjacentKey(to key: String?, offset: Int) -> String? {
        let keys = orderedContentKeys()
        guard !keys.isEmpty else { return nil }
        guard let key else { return offset > 0 ? keys.first : keys.last }
        guard let content = content(forKey: key),
              let index = keys.firstIndex(of: content.persistedKey) else { return nil }
        let target = index + offset
        guard keys.indices.contains(target) else { return nil }
        return keys[target]
    }

    /// Resolves numeric, manifest-id, and legacy-href forms to one numeric fragment id.
    private func resolvedFragmentID(base: String, htmlID: String?) -> Int64? {
        if let numeric = Int64(base), numeric > 0 {
            return numeric
        }
        let sql = """
            SELECT anchor_map.fragment_id
            FROM anchor_map
            WHERE anchor_map.original_key = COALESCE(
                (SELECT original_key FROM content WHERE href = ? ORDER BY id LIMIT 1),
                ?
            )
              AND anchor_map.html_id = ?
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(indexDB, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        Self.bindText(base, to: statement, index: 1)
        Self.bindText(base, to: statement, index: 2)
        Self.bindText(htmlID ?? "", to: statement, index: 3)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

}
