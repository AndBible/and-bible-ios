// BibleReaderRenderInvalidation.swift -- Reader display-setting invalidation policy

import BibleCore
import Foundation
import SwordKit

/**
 Durable authorization for a prepared payload routed from one reader controller to another.

 The witness validates the backing source objects that produced the payload. It deliberately does
 not retain the source pane's selected destination: closing or navigating that pane after handoff
 does not invalidate content whose manager and installed-source generation are still current. The
 destination calls `isCurrent()` at each publication boundary on the main queue.
 */
final class BibleReaderRoutedSourceAuthorization: @unchecked Sendable, Equatable {
    /// Exact source dependencies retained for diagnostics, equality, and destination replay.
    let dependencies: [BibleReaderPreparationSourceDependency]

    /// Immutable source-owner generation included in pending-request equality.
    let sourceGeneration: UInt64

    private let sourceOwner: ObjectIdentifier
    private let validator: () -> Bool

    init(
        sourceOwner: AnyObject,
        sourceGeneration: UInt64,
        dependencies: [BibleReaderPreparationSourceDependency],
        validator: @escaping () -> Bool
    ) {
        self.sourceOwner = ObjectIdentifier(sourceOwner)
        self.sourceGeneration = sourceGeneration
        self.dependencies = dependencies
        self.validator = validator
    }

    /** Explicit authorization for bounded payloads that have no mutable backing source. */
    static let independent: BibleReaderRoutedSourceAuthorization = {
        let owner = BibleReaderIndependentSourceAuthorizationOwner.shared
        return BibleReaderRoutedSourceAuthorization(
            sourceOwner: owner,
            sourceGeneration: 0,
            dependencies: [.independent],
            validator: { true }
        )
    }()

    /// Validates the captured backing source without consulting destination-controller state.
    func isCurrent() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return validator()
    }

    static func == (lhs: BibleReaderRoutedSourceAuthorization,
                    rhs: BibleReaderRoutedSourceAuthorization) -> Bool {
        lhs.sourceOwner == rhs.sourceOwner
            && lhs.sourceGeneration == rhs.sourceGeneration
            && lhs.dependencies == rhs.dependencies
    }
}

private final class BibleReaderIndependentSourceAuthorizationOwner: @unchecked Sendable {
    static let shared = BibleReaderIndependentSourceAuthorizationOwner()
}

/**
 Native identity of the document generation most recently accepted by the reader bridge.

 This value is runtime authority for navigation and invalidation. Its compact accessibility string
 is derived separately so delimiter sanitization and legacy diagnostics cannot influence behavior.
 */
struct BibleReaderCommittedRenderIdentity: Equatable {
    /// Category that owns the rendered document.
    let category: DocumentCategory

    /// Installed or synthetic document initials exposed by native pane state.
    let moduleName: String?

    /// Visible book, entry, label, or document title.
    let book: String

    /// Optional rendered chapter.
    let chapter: Int?

    /// Optional rendered source key.
    let key: String?

    /// Compact legacy state derived from this typed identity for diagnostics and UI automation.
    var diagnosticState: BibleReaderRenderedContentState {
        BibleReaderRenderedContentState(
            category: category,
            moduleName: moduleName,
            book: book,
            chapter: chapter,
            key: key
        )
    }
}

/**
 Records whether native extraction settings contributed content to a committed document generation.

 Direct SWORD and SQLite renders retain exact module identities for loaded-range navigation.
 Composite documents can contain several independently selected backends; their conservative case
 preserves correctness when an opaque routed payload may include SWORD fragments. EPUB and My
 Documents payloads remain extraction-independent.
 */
enum BibleReaderRenderSourceProvenance: Equatable, Sendable {
    /// No installed SWORD or SQLite source owns the document payload.
    case independent

    /// Exact native SWORD modules that contributed to the payload.
    case swordModules([String])

    /// Exact serialized SQLite modules that contributed to the payload.
    case sqliteModules([String])

    /// Routed composite content can contain SWORD fragments but no longer carries exact sources.
    case compositeMayUseSword

    /// Whether an extraction-option change requires rebuilding the visible document.
    var usesSwordExtraction: Bool {
        switch self {
        case .independent, .sqliteModules:
            return false
        case .swordModules, .compositeMayUseSword:
            return true
        }
    }

    /**
     Tests whether one exact installed source owns this direct render.

     - Parameter moduleName: Current active module initials.
     - Returns: `true` only for a direct SWORD or SQLite Java-exact identity recorded at render time.
     - Side effects: None.
     - Failure modes: Missing names and composite/independent provenance return `false`.
     */
    func containsExactModule(_ moduleName: String?) -> Bool {
        guard let moduleName else { return false }
        let moduleNames: [String]
        switch self {
        case .swordModules(let names), .sqliteModules(let names):
            moduleNames = names
        case .independent, .compositeMayUseSword:
            return false
        }
        let target = SwordJavaExactStringIdentity(moduleName)
        return moduleNames.contains { SwordJavaExactStringIdentity($0) == target }
    }
}

/** Native display setting whose value changed the bytes captured for one committed generation. */
enum BibleReaderRenderExtractionDependency: Equatable, Sendable {
    /// The full source payload is retained; Vue owns every display toggle for this document family.
    case none

    /// SWORD Bible book/chapter introduction capture followed `showSectionTitles`.
    case sectionTitles
}

/** Typed identity and source provenance committed by one successful bridge replacement. */
struct BibleReaderCommittedRenderState: Equatable {
    /// Typed document identity used by runtime decisions.
    let identity: BibleReaderCommittedRenderIdentity?

    /// Native extraction provenance used by settings invalidation and loaded navigation.
    let sourceProvenance: BibleReaderRenderSourceProvenance

    /// Exact native display dependency for this document family and generation.
    let extractionDependency: BibleReaderRenderExtractionDependency

    /// Neutral state before any bridge replacement succeeds.
    static let empty = BibleReaderCommittedRenderState(
        identity: nil,
        sourceProvenance: .independent,
        extractionDependency: .none
    )
}

/** Source inputs retained so a composite document can be rebuilt after extraction settings change. */
enum BibleReaderCompositeRebuildRequest {
    /// Immutable source operation used by Multi, restored Multi, or Compare content.
    case prepared(BibleReaderCompositePreparationRequest)

    /// Strong's, morphology, or word-lookup source inputs plus the initially authorized payload.
    case definition(BibleReaderDefinitionRenderRequest)
}

/** Typed passages and initial payload routed together for a multi-reference document. */
struct BibleReaderMultiReferenceRenderRequest {
    /// Exact source operation used to re-read every fragment.
    let sourceRequest: BibleReaderMultiReferencePreparationRequest

    /// Payload already built and authorized by the source controller for the first render.
    let initialDocumentJSON: String

    /// Exact copied backing families used by this prepared payload.
    let sourceProvenance: BibleReaderRenderSourceProvenance

    /// Source-owned authorization retained through destination selection and bridge callbacks.
    let sourceAuthorization: BibleReaderRoutedSourceAuthorization

    init(
        sourceRequest: BibleReaderMultiReferencePreparationRequest,
        initialDocumentJSON: String,
        sourceProvenance: BibleReaderRenderSourceProvenance,
        sourceAuthorization: BibleReaderRoutedSourceAuthorization
    ) {
        self.sourceRequest = sourceRequest
        self.initialDocumentJSON = initialDocumentJSON
        self.sourceProvenance = sourceProvenance
        self.sourceAuthorization = sourceAuthorization
    }
}

/** Source operation that can rebuild a transient dictionary-style document. */
enum BibleReaderDefinitionRenderSource: Sendable {
    /// Ordered Strong's/morphology items and Android's empty-multi behavior.
    case strongs(items: [BibleReaderDefinitionItem], emitsEmptyMultiOnMiss: Bool)

    /// Exact normalized word-lookup query.
    case wordLookup(query: String)
}

/** Typed definition source and initial payload routed together to the destination controller. */
struct BibleReaderDefinitionRenderRequest {
    /// Complete source and preference operation used for authorized reconstruction.
    let sourceRequest: BibleReaderDefinitionPreparationRequest

    /// Payload already built and authorized by the source controller for the first render.
    let initialDocumentJSON: String

    /// Legacy display label retained for diagnostic compatibility.
    let renderedBook: String

    /// Stable synthetic key such as `strongs` or `dictionary`.
    let renderedKey: String

    /// Source-owned authorization retained through destination selection and bridge callbacks.
    let sourceAuthorization: BibleReaderRoutedSourceAuthorization

    /// Exact copied source generations that produced `initialDocumentJSON`.
    var sourceDependencies: [BibleReaderPreparationSourceDependency] {
        sourceAuthorization.dependencies
    }

    /// Strong's lookup preference changes deferred until bridge acceptance.
    let preferredFamilyUpdates: [BibleReaderStrongsDocumentBuilder.PreferredFamilyUpdate]

    /// Source-pane follow-up performed only after the destination accepts the document.
    let onAccepted: (() -> Void)?

    init(
        sourceRequest: BibleReaderDefinitionPreparationRequest,
        initialDocumentJSON: String,
        renderedBook: String,
        renderedKey: String,
        sourceAuthorization: BibleReaderRoutedSourceAuthorization,
        preferredFamilyUpdates: [BibleReaderStrongsDocumentBuilder.PreferredFamilyUpdate],
        onAccepted: (() -> Void)?
    ) {
        self.sourceRequest = sourceRequest
        self.initialDocumentJSON = initialDocumentJSON
        self.renderedBook = renderedBook
        self.renderedKey = renderedKey
        self.sourceAuthorization = sourceAuthorization
        self.preferredFamilyUpdates = preferredFamilyUpdates
        self.onAccepted = onAccepted
    }

    /// Request retained for replay after the first accepted publication.
    var replayRequest: Self {
        Self(
            sourceRequest: sourceRequest,
            initialDocumentJSON: initialDocumentJSON,
            renderedBook: renderedBook,
            renderedKey: renderedKey,
            sourceAuthorization: sourceAuthorization,
            preferredFamilyUpdates: [],
            onAccepted: nil
        )
    }
}

/**
 Resolved settings that change native source extraction rather than Vue presentation.

 Reader payloads retain morphology, footnote, and cross-reference OSIS so bibleview-js can apply
 those visibility settings without another source read. Section-title visibility is different: the
 native Bible builder conditionally includes book/chapter introduction entries, so changing it
 invalidates the current SWORD Bible generation. Every other `TextDisplaySettings` field updates the
 existing document without destroying appended chapters, selection, or scroll state.
 */
struct BibleReaderExtractionOptions: Equatable {
    /// Whether Bible book/chapter introduction fragments are included during extraction.
    let showSectionTitles: Bool

    /**
     Resolves extraction-affecting settings against application defaults.

     - Parameters:
       - settings: Pane-resolved display settings.
       - defaults: Fully populated fallback settings.
     - Side effects: None.
     - Failure modes: Missing fallback values use the same hard defaults as the SWORD coordinator.
    */
    init(settings: TextDisplaySettings, defaults: TextDisplaySettings = .appDefaults) {
        showSectionTitles = settings.showSectionTitles ?? defaults.showSectionTitles ?? true
    }
}

/**
 Classifies one display-settings update against the currently rendered source family.

 Annotation revisions are intentionally outside this policy: bookmark and note handlers already
 send targeted Vue delta events. Keeping those revisions separate prevents unrelated display edits
 from rebuilding annotation state or treating a presentation config as new source content.
 */
enum BibleReaderDisplayUpdateAction: Equatable {
    /// Resolved settings and appearance are unchanged, so no bridge work is necessary.
    case none

    /// Vue can apply the new presentation config to the existing document generation.
    case setConfig

    /// Native SWORD extraction changed and the active document must be rebuilt once.
    case replaceContent

    /**
     Chooses the smallest update that preserves the current rendered document contract.

     - Parameters:
       - previousSettings: Settings used by the current controller state.
       - settings: Newly resolved settings.
       - previousNightMode: Appearance mode used by the current controller state.
       - nightMode: Newly resolved appearance mode.
       - sourceUsesSwordExtraction: Whether the visible source was built from SWORD-filtered text.
     - Returns: No work, a config-only update, or a full native extraction replacement.
     - Side effects: None.
     - Failure modes: None; unresolved values use `TextDisplaySettings.appDefaults` consistently.
     */
    static func resolve(
        previousSettings: TextDisplaySettings,
        settings: TextDisplaySettings,
        previousNightMode: Bool,
        nightMode: Bool,
        sourceUsesSwordExtraction: Bool
    ) -> Self {
        guard previousSettings != settings || previousNightMode != nightMode else {
            return .none
        }
        guard sourceUsesSwordExtraction else { return .setConfig }
        return BibleReaderExtractionOptions(settings: previousSettings)
            == BibleReaderExtractionOptions(settings: settings)
            ? .setConfig
            : .replaceContent
    }
}
