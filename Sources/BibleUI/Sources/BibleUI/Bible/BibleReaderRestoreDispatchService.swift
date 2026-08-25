// BibleReaderRestoreDispatchService.swift — category-safe saved-document dispatch

import BibleCore
import Foundation
import SwordKit

/** Category-safe commentary owner selected from one fresh installed-book snapshot. */
enum BibleReaderCommentaryRestoreDecision {
    /// Android's synthetic Memorize document.
    case memorize
    /// Exact readable installed commentary owner.
    case source(BibleReaderInstalledModuleSource)
    /// First readable commentary in the controller's established setup order.
    case fallback(BibleReaderInstalledModuleSource)
    /// Unreadable/uninstalled saved identity retained without a content handle.
    case unresolved(String)
    /// No saved identity and no readable fallback.
    case none
}

/** Category-safe dictionary owner selected from one fresh installed-book snapshot. */
enum BibleReaderDictionaryRestoreDecision {
    /// Exact readable installed dictionary or glossary owner.
    case source(BibleReaderInstalledModuleSource)
    /// Unreadable/uninstalled saved identity retained without a content handle.
    case unresolved(String)
    /// No saved identity.
    case none
}

/** Category-safe general-book owner selected from the complete installed/local registry. */
enum BibleReaderGeneralBookRestoreDecision {
    /// Android's synthetic Multi document.
    case multi
    /// Exact readable native general-book owner.
    case sword(SwordModule)
    /// Exact admitted My Documents or EPUB owner.
    case local(BibleReaderLocalGeneralBookDocument)
    /// Unreadable/uninstalled saved identity retained without a content handle.
    case unresolved(String)
    /// An installed wrong-category owner makes the saved general-book selection invalid.
    case rejectedWrongCategory
    /// No saved identity.
    case none
}

/** Category-safe map owner selected from one fresh installed-book snapshot. */
enum BibleReaderMapRestoreDecision {
    /// Exact readable native map owner.
    case sword(SwordModule)
    /// Unreadable/uninstalled saved identity retained without a content handle.
    case unresolved(String)
    /// An installed wrong-category owner makes the saved map selection invalid.
    case rejectedWrongCategory
    /// No saved identity.
    case none
}

/**
 Dispatches persisted auxiliary-document tokens through Android's fresh global ownership snapshot.

 The service selects owners only. `BibleReaderController` remains responsible for visible state,
 PageManager canonicalization, exact key validation, content reads, and navigation. Separating the
 decision boundary prevents restore code from rebuilding partial native/SQLite/local precedence.

 - Side effects: Local general-book dispatch may enumerate persisted My Documents/EPUB metadata
 through the supplied authorization closure; installed dispatch reads only the captured resolver.
 - Failure modes: Locked, unreadable, wrong-category, replaced, and shadowed owners fail closed and
 are represented explicitly; no decision silently substitutes a different category.
 */
struct BibleReaderRestoreDispatchService {
    /// Fresh installed native/SQLite resolver shared across all category decisions.
    let resolver: BibleReaderInstalledModuleResolver

    /// Established commentary setup order used only for Android's readable fallback behavior.
    let orderedCommentaryModules: [ModuleInfo]

    /// Canonical native spelling projection retained for unresolved persisted identities.
    let canonicalSwordModuleName: (String) -> String

    /// Complete local-owner resolver sharing this service's installed snapshot.
    let localGeneralBookDocument: (String) -> BibleReaderLocalGeneralBookDocument?

    /**
     Selects the saved commentary or established readable fallback.

     - Parameter savedName: Persisted PageManager commentary token.
     - Returns: Synthetic, exact source, fallback, unresolved identity, or absence decision.
     - Side effects: None beyond resolver metadata reads.
     - Failure modes: Wrong-category/locked saved owners do not become readable; the established
       commentary fallback remains eligible exactly as in Android setup restoration.
     */
    func commentary(savedName: String?) -> BibleReaderCommentaryRestoreDecision {
        if savedName.map({
            SwordJavaStringIdentity.equals(
                $0,
                AndroidSpecialDocumentIdentity.memorizeDocumentInitials
            )
        }) == true {
            return .memorize
        }
        if let savedName,
           let source = resolver.module(named: savedName),
           source.info.category == .commentary {
            return .source(source)
        }
        if let fallback = resolver.modules(
            category: .commentary,
            orderedBy: orderedCommentaryModules
        ).first {
            return .fallback(fallback)
        }
        if let savedName {
            return .unresolved(canonicalSwordModuleName(savedName))
        }
        return .none
    }

    /**
     Selects one exact dictionary/glossary owner without fallback.

     - Parameter savedName: Persisted PageManager dictionary token.
     - Returns: Exact readable source, unresolved canonical identity, or absence.
     - Side effects: None beyond resolver metadata reads.
     - Failure modes: Locked and wrong-category owners become unresolved without substitution.
     */
    func dictionary(savedName: String?) -> BibleReaderDictionaryRestoreDecision {
        guard let savedName else { return .none }
        if let source = resolver.module(named: savedName),
           source.info.category == .dictionary || source.info.category == .glossary {
            return .source(source)
        }
        return .unresolved(canonicalSwordModuleName(savedName))
    }

    /**
     Selects one exact installed or local general-book owner.

     - Parameter savedName: Persisted PageManager general-book token.
     - Returns: Synthetic Multi, native SWORD, admitted local owner, unresolved identity,
       wrong-category rejection, or absence.
     - Side effects: Invokes `localGeneralBookDocument` only after installed resolution declines.
     - Failure modes: A registered wrong-category owner rejects before local lookup or fallback.
     */
    func generalBook(savedName: String?) -> BibleReaderGeneralBookRestoreDecision {
        guard let savedName else { return .none }
        if SwordJavaStringIdentity.equals(
            savedName,
            AndroidSpecialDocumentIdentity.multiDocumentInitials
        ) {
            return .multi
        }
        if let registered = resolver.registeredModuleInfo(named: savedName),
           registered.category != .generalBook {
            return .rejectedWrongCategory
        }
        if case .sword(let module)? = resolver.module(named: savedName),
           module.info.category == .generalBook {
            return .sword(module)
        }
        if let local = localGeneralBookDocument(savedName) {
            return .local(local)
        }
        return .unresolved(canonicalSwordModuleName(savedName))
    }

    /**
     Selects one exact native map owner without fallback.

     - Parameter savedName: Persisted PageManager map token.
     - Returns: Exact readable native map, unresolved identity, wrong-category rejection, or absence.
     - Side effects: None beyond resolver metadata reads.
     - Failure modes: SQLite/non-map/locked owners cannot activate map content.
     */
    func map(savedName: String?) -> BibleReaderMapRestoreDecision {
        guard let savedName else { return .none }
        if let registered = resolver.registeredModuleInfo(named: savedName),
           registered.category != .map {
            return .rejectedWrongCategory
        }
        if case .sword(let module)? = resolver.module(named: savedName),
           module.info.category == .map {
            return .sword(module)
        }
        return .unresolved(canonicalSwordModuleName(savedName))
    }
}
