// BibleReaderDocumentAuthorizationService.swift — Fresh installed/local ownership authorization

import BibleCore
import Foundation
import SwordKit

/** One globally unowned local general-book adapter after shared ownership resolution. */
enum BibleReaderLocalGeneralBookDocument {
    /// Exact My Documents graph row and its lazily read pages.
    case myDocument(MyDocument)

    /// Exact immutable EPUB generation and its lazily read fragments.
    case epub(EpubReader)
}

/**
 Replays Android's installed-book and local-general-book ownership contract for reader operations.

 The service is intentionally operation-scoped. Every instance captures the live SWORD manager,
 current admitted SQLite registrations, persisted My Documents store, and active immutable EPUB
 generation supplied by one reader pane. It centralizes authorization only; the controller retains
 ownership of visible state, navigation commits, and rendering.

 - Side effects: Resolver construction enumerates installed metadata. Local-owner resolution also
   reads persisted My Documents metadata and opens immutable EPUB generations.
 - Failure modes: Missing stores and unreadable local metadata fail closed. Locked, shadowed,
   wrong-category, replaced, and Java-distinct owners are never substituted with another backend.
 */
struct BibleReaderDocumentAuthorizationService {
    /// Live native SWORD manager, or nil for a SQLite/local-only reader environment.
    let swordManager: SwordManager?

    /// Current SQLite registrations already admitted against native SWORD ownership.
    let sqliteModules: [BibleReaderSQLiteModuleHandle]

    /// Persisted My Documents reader used only for registration metadata at authorization time.
    let myDocumentStore: MyDocumentStore?

    /// Pane-retained immutable EPUB generation reused when it still owns the installed identifier.
    let activeEpubReader: EpubReader?

    /// Active-versification reference resolver used for installed commentary key preflight.
    let resolveCommentaryReference: (String) -> String?

    /**
     Captures Android's global installed-book registry for one reader operation.

     - Returns: A resolver replaying native/custom admission, locked ownership, exact identity maps,
       and JSword TreeSet ordering over the supplied runtime snapshot.
     - Side effects: Enumerates current native access metadata; no content is opened or mutated.
     - Failure modes: A missing manager produces a SQLite-only resolver. Locked native rows retain
       ownership metadata but expose no readable handle.
     */
    func installedModuleResolver() -> BibleReaderInstalledModuleResolver {
        BibleReaderInstalledModuleResolver(
            swordManager: swordManager,
            sqliteModules: sqliteModules
        )
    }

    /**
     Reports whether the complete installed/local registry owns one proposed document token.

     - Parameter name: Candidate initials or full name.
     - Returns: `true` for any installed/local owner and for metadata failure; `false` only when the
       complete registry proves the token is unowned.
     - Side effects: Performs the metadata reads described by `owner(named:preferredEpub:resolver:)`.
     - Failure modes: Local metadata failure conservatively reserves the token.
     */
    func hasRegisteredDocument(named name: String) -> Bool {
        guard let owner = owner(named: name) else { return true }
        if case .missing = owner { return false }
        return true
    }

    /**
     Resolves a local general-book source only after the global registry declines ownership.

     - Parameters:
       - name: Exact local initials token checked through Android's complete lookup tiers.
       - preferredEpub: Operation-retained EPUB generation to reuse when still current.
       - resolver: Optional installed snapshot shared by a larger restore or commit operation.
     - Returns: Exact My Documents or EPUB owner, or nil for installed/missing/unreadable ownership.
     - Side effects: Reads persisted local metadata and opens immutable EPUB generations only.
     - Failure modes: Installed collisions and metadata failures fail closed without content reads.
     */
    func localDocument(
        named name: String,
        preferredEpub: EpubReader? = nil,
        resolver: BibleReaderInstalledModuleResolver? = nil
    ) -> BibleReaderLocalGeneralBookDocument? {
        guard let owner = owner(
            named: name,
            preferredEpub: preferredEpub,
            resolver: resolver
        ), case .local(let document) = owner else {
            return nil
        }
        return document
    }

    /**
     Captures the complete installed/EPUB/My Documents owner for one Android book token.

     - Parameters:
       - name: Initials, full-name, or Java case-tier lookup token.
       - preferredEpub: Operation-retained EPUB generation to reuse when still current.
       - resolver: Optional installed snapshot shared by a larger operation.
     - Returns: Deterministic JSword owner, `.missing`, or nil when persisted local metadata cannot
       be read safely.
     - Side effects: Reads installed/local metadata and opens immutable EPUB generations only.
     - Failure modes: My Documents metadata failure returns nil before content or visible mutation.
     */
    func owner(
        named name: String,
        preferredEpub: EpubReader? = nil,
        resolver: BibleReaderInstalledModuleResolver? = nil
    ) -> BibleReaderInstalledOrLocalDocumentOwner<BibleReaderLocalGeneralBookDocument>? {
        let installedResolver = resolver ?? installedModuleResolver()
        let documents: [MyDocument]
        if let myDocumentStore {
            guard let ordered = try? myDocumentStore.documentsInRegistrationOrder() else {
                return nil
            }
            documents = ordered
        } else {
            documents = []
        }

        let epubReaders = EpubReader.installedEpubs().compactMap { info -> EpubReader? in
            if preferredEpub?.identifier == info.identifier { return preferredEpub }
            if activeEpubReader?.identifier == info.identifier { return activeEpubReader }
            return EpubReader(identifier: info.identifier)
        }
        let localRegistrations = epubReaders.map { reader in
            BibleReaderLocalDocumentRegistration(
                document: BibleReaderLocalGeneralBookDocument.epub(reader),
                initials: reader.initials,
                fullName: reader.title,
                abbreviation: reader.title,
                category: .generalBook
            )
        } + documents.map { document in
            BibleReaderLocalDocumentRegistration(
                document: BibleReaderLocalGeneralBookDocument.myDocument(document),
                initials: document.initials,
                fullName: document.name,
                abbreviation: document.initials,
                category: .generalBook
            )
        }
        return installedResolver.resolveDocumentOwner(
            named: name,
            localRegistrations: { localRegistrations }
        )
    }

    /**
     Authorizes one installed AI window-document request and validates its optional key atomically.

     - Parameters:
       - name: Initials or full-name token resolved through the global JSword registry tiers.
       - category: Exact category required by the caller.
       - key: Optional non-empty Bible/commentary reference or exact generic source key.
     - Returns: Canonical readable-source/key authorization or a typed fail-closed rejection.
     - Side effects: May enumerate generic keys or perform cursor-restoring reference inspection;
       controller, pane, persistence, navigation, and rendered state remain unchanged.
     - Failure modes: Locked, replaced, missing, wrong-category, invalid-key, and backend failures
       return `.sourceUnavailable` or `.keyUnavailable` without fallback.
     */
    func preflightInstalledWindowDocument(
        named name: String,
        category: ModuleCategory,
        key: String?
    ) -> BibleReaderInstalledWindowDocumentPreflight {
        let resolver = installedModuleResolver()
        guard let registeredInfo = resolver.registeredModuleInfo(named: name),
              registeredInfo.category == category,
              let source = resolver.module(named: name),
              source.info.category == category,
              SwordJavaStringIdentity.equals(source.info.name, registeredInfo.name) else {
            return .sourceUnavailable
        }

        guard let key, !key.isEmpty else { return .authorized(key: nil) }

        switch category {
        case .bible:
            guard let scripture = source.scripture else { return .sourceUnavailable }
            do {
                let books = try scripture.bookList()
                let referenceResolver: BibleReaderReferenceResolver
                switch scripture {
                case .sword(let module):
                    referenceResolver = BibleReaderReferenceResolver(
                        activeModule: module,
                        bookList: books,
                        fallbackBooks: [],
                        fallbackVerseCount: { _, _ in 0 }
                    )
                case .sqlite:
                    referenceResolver = BibleReaderReferenceResolver(
                        activeModule: nil,
                        bookList: books,
                        fallbackBooks: books,
                        fallbackVerseCount: { bookName, chapter in
                            guard let osisID = books.first(where: { $0.name == bookName })?.osisId
                            else {
                                return 0
                            }
                            return JSwordKJVAVersification.verseCount(
                                osisId: osisID,
                                chapter: chapter
                            ) ?? 0
                        }
                    )
                }
                guard let reference = referenceResolver.resolveReference(key) else {
                    return .keyUnavailable
                }
                return .authorized(key: reference)
            } catch {
                return .keyUnavailable
            }

        case .commentary:
            guard let reference = resolveCommentaryReference(key) else {
                return .keyUnavailable
            }
            return .authorized(key: reference)

        case .dictionary, .glossary:
            let keys: [String]
            do {
                switch source {
                case .sword(let module): keys = try module.loadAllKeys()
                case .sqlite(let module): keys = try module.dictionaryKeys()
                }
            } catch {
                return .keyUnavailable
            }
            guard let exactKey = keys.first(where: {
                SwordJavaStringIdentity.equals($0, key)
            }) else {
                return .keyUnavailable
            }
            return .authorized(key: exactKey)

        case .generalBook, .map:
            guard case .sword(let module) = source else { return .sourceUnavailable }
            let keys: [String]
            do {
                keys = try module.loadAllKeys()
            } catch {
                return .keyUnavailable
            }
            guard let exactKey = keys.first(where: {
                SwordJavaStringIdentity.equals($0, key)
            }) else {
                return .keyUnavailable
            }
            return .authorized(key: exactKey)

        case .dailyDevotion, .questionable, .essays, .images, .addon, .unknown:
            return .sourceUnavailable
        }
    }
}
