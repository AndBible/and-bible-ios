// BibleReaderBookmarkCommitPreflightService.swift — Exact destination reauthorization before commit

import BibleCore
import Foundation
import SwordKit

/**
 Reauthorizes detached bookmark plans and re-reads exact destination content before reader mutation.

 Planning snapshots are intentionally not trusted at commit time. This service captures fresh
 installed/local ownership, exact backend content, and persisted My Documents metadata, then returns
 immutable commit inputs to `BibleReaderController`. It never changes pane, PageManager, WebView, or
 persistence state.

 - Side effects: Performs cursor-restoring SWORD reads, SQLite reads, immutable EPUB reads, or clean
   persisted My Documents reads depending on the destination family.
 - Failure modes: Removed, relocked, replaced, shadowed, wrong-category, Java-distinct, missing-key,
   and changed-content destinations throw the existing typed navigation/commit failures.
 */
struct BibleReaderBookmarkCommitPreflightService {
    /** Fully reauthorized native SWORD generic destination. */
    struct SwordDestination {
        /// Fresh readable native owner.
        let module: SwordModule

        /// Exact raw fragment proven equal to the detached plan.
        let fragment: SwordRawOSISFragment
    }

    /** Fully reauthorized Android SQLite generic destination. */
    struct SQLiteDestination {
        /// Fresh globally admitted SQLite owner.
        let module: BibleReaderSQLiteModuleHandle

        /// Exact structural fragment proven equal to the detached plan.
        let fragment: BibleReaderBookmarkNavigationSQLiteFragment
    }

    /** Fully reauthorized persisted My Documents destination. */
    struct MyDocumentDestination {
        /// Exact persisted document row.
        let document: MyDocument

        /// Exact persisted page row and content.
        let page: MyDocumentPage

        /// Marker/prompt metadata read from the clean persisted graph.
        let metadata: MyDocumentReaderMetadata
    }

    /** Fully reauthorized immutable EPUB destination. */
    struct EpubDestination {
        /// Current globally admitted immutable generation.
        let reader: EpubReader

        /// Exact fragment proven equal to the detached plan.
        let content: EpubReader.Content
    }

    /// Fresh installed/local ownership service for the active pane operation.
    let authorization: BibleReaderDocumentAuthorizationService

    /// Persisted My Documents store required only for My Documents destinations.
    let myDocumentStore: MyDocumentStore?

    /**
     Reauthorizes and re-reads one native SWORD generic plan.

     - Parameter plan: Detached fragment identity produced by bookmark planning.
     - Returns: Fresh native handle and exact unchanged raw fragment.
     - Side effects: Captures installed ownership and performs one cursor-restoring raw fragment read.
     - Failure modes: Throws existing not-found, lookup, or destination-changed failures.
     */
    func swordDestination(
        for plan: BibleReaderBookmarkNavigationSwordPlan
    ) throws -> SwordDestination {
        let resolver = authorization.installedModuleResolver()
        guard case .sword(let module)? = resolver.module(named: plan.moduleInitials),
              module.info.category == plan.category else {
            throw BibleReaderBookmarkNavigationFailure.genericModuleNotFound(plan.moduleInitials)
        }
        let currentFragment: SwordRawOSISFragment
        do {
            currentFragment = try module.rawOSISFragment(forKey: plan.key)
        } catch {
            throw BibleReaderBookmarkNavigationFailure.genericKeyLookupFailed(
                moduleInitials: plan.moduleInitials,
                key: plan.key
            )
        }
        guard currentFragment == plan.fragment, currentFragment.hasRenderableContent else {
            throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
        }
        return SwordDestination(module: module, fragment: currentFragment)
    }

    /**
     Reauthorizes and re-reads one Android SQLite generic plan.

     - Parameter plan: Detached SQLite fragment produced by bookmark planning.
     - Returns: Fresh globally admitted handle and exact unchanged fragment.
     - Side effects: Captures installed ownership and reads one exact SQLite key.
     - Failure modes: Throws existing not-found, lookup, or destination-changed failures.
     */
    func sqliteDestination(
        for plan: BibleReaderBookmarkNavigationSQLitePlan
    ) throws -> SQLiteDestination {
        let resolver = authorization.installedModuleResolver()
        guard case .sqlite(let module)? = resolver.module(named: plan.fragment.moduleInitials),
              module.info.category == plan.fragment.category else {
            throw BibleReaderBookmarkNavigationFailure.genericModuleNotFound(
                plan.fragment.moduleInitials
            )
        }
        let currentFragment: BibleReaderBookmarkNavigationSQLiteFragment
        do {
            currentFragment = try BibleReaderBookmarkNavigationSQLiteCandidate(module: module)
                .fragmentForExactKey(plan.fragment.key)
        } catch {
            throw BibleReaderBookmarkNavigationFailure.genericKeyLookupFailed(
                moduleInitials: plan.fragment.moduleInitials,
                key: plan.fragment.key
            )
        }
        guard currentFragment == plan.fragment else {
            throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
        }
        return SQLiteDestination(module: module, fragment: currentFragment)
    }

    /**
     Reauthorizes and re-reads one persisted My Documents plan.

     - Parameters:
       - plan: Detached local page/content identity produced by bookmark planning.
       - unknownPromptName: Localized fallback used by persisted reader metadata.
     - Returns: Exact persisted document/page and current clean marker/prompt metadata.
     - Side effects: Replays complete installed/local ownership and performs isolated persisted reads.
     - Failure modes: Throws reader-unavailable, exact-key, or destination-changed failures before
       controller state or persistence mutation.
     */
    func myDocumentDestination(
        for plan: BibleReaderBookmarkNavigationMyDocumentPlan,
        unknownPromptName: String
    ) throws -> MyDocumentDestination {
        guard let owner = authorization.owner(named: plan.fragment.moduleInitials),
              case .local(.myDocument(let authorizedDocument)) = owner,
              authorizedDocument.id == plan.fragment.documentID,
              SwordJavaStringIdentity.equals(
                authorizedDocument.initials,
                plan.fragment.moduleInitials
              ),
              SwordJavaStringIdentity.equals(
                authorizedDocument.name,
                plan.fragment.documentName
              ) else {
            throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
        }
        guard let myDocumentStore else {
            throw BibleReaderBookmarkNavigationCommitFailure.readerUnavailable
        }
        let document: MyDocument
        let page: MyDocumentPage
        do {
            document = try myDocumentStore.exactDocument(initials: plan.fragment.moduleInitials)
            page = try myDocumentStore.exactPage(
                bookInitials: plan.fragment.moduleInitials,
                pageKey: plan.fragment.key
            )
        } catch {
            throw BibleReaderBookmarkNavigationFailure.genericKeyLookupFailed(
                moduleInitials: plan.fragment.moduleInitials,
                key: plan.fragment.key
            )
        }
        guard document.id == authorizedDocument.id,
              SwordJavaStringIdentity.equals(document.initials, authorizedDocument.initials),
              SwordJavaStringIdentity.equals(document.name, authorizedDocument.name),
              page.id == plan.fragment.pageID,
              page.document?.id == document.id,
              page.title == plan.fragment.title,
              page.contentTypeRawValue == plan.fragment.contentTypeRawValue,
              page.pageContent?.content ?? "" == plan.fragment.rawContent,
              page.languageCode == plan.fragment.languageCode else {
            throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
        }
        return MyDocumentDestination(
            document: document,
            page: page,
            metadata: myDocumentStore.readerMetadata(
                for: page,
                bookInitials: document.initials,
                pageKey: page.pageKey,
                unknownPromptName: unknownPromptName
            )
        )
    }

    /**
     Reauthorizes and re-reads one immutable EPUB plan.

     - Parameter plan: Detached EPUB generation/content identity produced by bookmark planning.
     - Returns: Current globally admitted generation and exact unchanged content fragment.
     - Side effects: Replays complete ownership and opens one immutable fragment.
     - Failure modes: Throws exact-key or destination-changed failures for collisions, replacement,
       unreadable content, or metadata/content drift.
     */
    func epubDestination(
        for plan: BibleReaderBookmarkNavigationEpubPlan
    ) throws -> EpubDestination {
        guard let owner = authorization.owner(named: plan.moduleInitials),
              case .local(.epub(let reader)) = owner,
              reader.identifier == plan.identifier,
              reader.generationIdentifier == plan.generationIdentifier,
              SwordJavaStringIdentity.equals(reader.initials, plan.moduleInitials),
              SwordJavaStringIdentity.equals(reader.title, plan.title),
              SwordJavaStringIdentity.equals(reader.language, plan.language) else {
            throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
        }
        let content: EpubReader.Content
        do {
            content = try reader.exactContent(forPersistedKey: plan.content.persistedKey)
        } catch {
            throw BibleReaderBookmarkNavigationFailure.genericKeyLookupFailed(
                moduleInitials: plan.moduleInitials,
                key: plan.content.persistedKey
            )
        }
        guard content == plan.content else {
            throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
        }
        return EpubDestination(reader: reader, content: content)
    }
}
