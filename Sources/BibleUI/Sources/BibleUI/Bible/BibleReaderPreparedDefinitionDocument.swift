// BibleReaderPreparedDefinitionDocument.swift -- Immutable definition preparation

import BibleCore
import BibleView
import Foundation
import SwordKit

/** Exact Android definition item identity without Swift Unicode canonicalization. */
enum BibleReaderDefinitionItemIdentity: Hashable, Sendable {
    case strong(BibleReaderPreparationExactText)
    case robinson(BibleReaderPreparationExactText)

    init(_ item: BibleReaderDefinitionItem) {
        switch item {
        case .strong(let value): self = .strong(BibleReaderPreparationExactText(value))
        case .robinson(let value): self = .robinson(BibleReaderPreparationExactText(value))
        }
    }
}

/** Copied settings that select Strong's, morphology, and word-lookup sources. */
struct BibleReaderDefinitionPreferenceSnapshot: Sendable {
    let hebrewDictionaries: [String]
    let greekDictionaries: [String]
    let robinsonDictionaries: [String]
    let disabledWordLookupDictionaries: [String]

    var identity: BibleReaderDefinitionPreferenceIdentity {
        BibleReaderDefinitionPreferenceIdentity(
            hebrewDictionaries: hebrewDictionaries.map { BibleReaderPreparationExactText($0) },
            greekDictionaries: greekDictionaries.map { BibleReaderPreparationExactText($0) },
            robinsonDictionaries: robinsonDictionaries.map { BibleReaderPreparationExactText($0) },
            disabledWordLookupDictionaries: disabledWordLookupDictionaries.map {
                BibleReaderPreparationExactText($0)
            }
        )
    }

    func selectedValues(for key: AppPreferenceKey) -> [String] {
        switch key {
        case .strongsHebrewDictionary: return hebrewDictionaries
        case .strongsGreekDictionary: return greekDictionaries
        case .robinsonGreekMorphology: return robinsonDictionaries
        default: return []
        }
    }
}

/** Exact structural identity for copied definition-source preferences. */
struct BibleReaderDefinitionPreferenceIdentity: Hashable, Sendable {
    let hebrewDictionaries: [BibleReaderPreparationExactText]
    let greekDictionaries: [BibleReaderPreparationExactText]
    let robinsonDictionaries: [BibleReaderPreparationExactText]
    let disabledWordLookupDictionaries: [BibleReaderPreparationExactText]
}

/** Collision-free identity for one definition preparation operation. */
enum BibleReaderDefinitionPreparationRequestIdentity: Hashable, Sendable {
    case strongs(
        items: [BibleReaderDefinitionItemIdentity],
        emitsEmptyMultiOnMiss: Bool,
        stateJSON: BibleReaderPreparationExactText?,
        preferences: BibleReaderDefinitionPreferenceIdentity
    )
    case wordLookup(
        query: BibleReaderPreparationExactText,
        preferences: BibleReaderDefinitionPreferenceIdentity
    )
}

/** Source and selection inputs retained for replay of a definition document. */
struct BibleReaderDefinitionPreparationRequest: Sendable {
    let source: BibleReaderDefinitionRenderSource
    let stateJSON: String?
    let preferences: BibleReaderDefinitionPreferenceSnapshot

    var identity: BibleReaderDefinitionPreparationRequestIdentity {
        switch source {
        case .strongs(let items, let emitsEmptyMultiOnMiss):
            return .strongs(
                items: items.map { BibleReaderDefinitionItemIdentity($0) },
                emitsEmptyMultiOnMiss: emitsEmptyMultiOnMiss,
                stateJSON: stateJSON.map { BibleReaderPreparationExactText($0) },
                preferences: preferences.identity
            )
        case .wordLookup(let query):
            return .wordLookup(
                query: BibleReaderPreparationExactText(query),
                preferences: preferences.identity
            )
        }
    }
}

/** Copied definition source result before pure JSON serialization. */
enum BibleReaderDefinitionSourceCapture: Sendable {
    case noResult
    case document(
        fragments: [OsisFragment],
        contentType: String?,
        stateJSON: String?,
        preferredFamilyUpdates: [BibleReaderStrongsDocumentBuilder.PreferredFamilyUpdate],
        sourceDependencies: [BibleReaderPreparationSourceDependency],
        requiresRenderOptionAuthorization: Bool,
        renderOptionSettings: [SwordManager.GlobalOptionSetting]
    )
}

/** Authorized bridge document and deferred side effects from one definition operation. */
struct BibleReaderPreparedDefinitionDocument: Sendable {
    let documentJSON: String
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
    let preferredFamilyUpdates: [BibleReaderStrongsDocumentBuilder.PreferredFamilyUpdate]
    let requiresRenderOptionAuthorization: Bool
    let renderOptionSettings: [SwordManager.GlobalOptionSetting]

    /** Captures source-neutral definition fragments through already-authorized builders. */
    static func capture(
        request: BibleReaderDefinitionPreparationRequest,
        strongsBuilder: BibleReaderStrongsDocumentBuilder,
        wordLookupBuilder: BibleReaderWordLookupDocumentBuilder,
        sourceDependencies: [BibleReaderPreparationSourceDependency],
        renderOptionSettings: [SwordManager.GlobalOptionSetting]
    ) -> BibleReaderDefinitionSourceCapture {
        switch request.source {
        case .strongs(let items, let emitsEmptyMultiOnMiss):
            guard let capture = strongsBuilder.captureStrongsMultiDocument(
                items: items,
                stateJSON: request.stateJSON,
                emitsEmptyMultiOnMiss: emitsEmptyMultiOnMiss
            ) else { return .noResult }
            return .document(
                fragments: capture.fragments,
                contentType: capture.contentType,
                stateJSON: capture.stateJSON,
                preferredFamilyUpdates: capture.preferredFamilyUpdates,
                sourceDependencies: sourceDependencies,
                requiresRenderOptionAuthorization: capture.requiresRenderOptionAuthorization,
                renderOptionSettings: renderOptionSettings
            )
        case .wordLookup(let query):
            guard let capture = wordLookupBuilder.captureWordLookupMultiDocument(query: query) else {
                return .noResult
            }
            return .document(
                fragments: capture.fragments,
                contentType: nil,
                stateJSON: nil,
                preferredFamilyUpdates: [],
                sourceDependencies: sourceDependencies,
                requiresRenderOptionAuthorization: capture.requiresRenderOptionAuthorization,
                renderOptionSettings: renderOptionSettings
            )
        }
    }

    /** Purely serializes copied fragments and retains source authorization for publication. */
    static func encode(
        _ capture: BibleReaderDefinitionSourceCapture
    ) -> BibleReaderPreparedDefinitionOutcome? {
        switch capture {
        case .noResult:
            return .noResult
        case .document(
            let fragments,
            let contentType,
            let stateJSON,
            let preferredFamilyUpdates,
            let sourceDependencies,
            let requiresRenderOptionAuthorization,
            let renderOptionSettings
        ):
            guard let documentJSON = BibleReaderMultiFragmentDocumentBuilder.buildJSON(
                fragments: fragments,
                compare: false,
                contentType: contentType,
                stateJSON: stateJSON,
                id: "strongs-multi-\(UUID().uuidString)"
            ) else { return nil }
            return .document(Self(
                documentJSON: documentJSON,
                sourceDependencies: sourceDependencies,
                preferredFamilyUpdates: preferredFamilyUpdates,
                requiresRenderOptionAuthorization: requiresRenderOptionAuthorization,
                renderOptionSettings: renderOptionSettings
            ))
        }
    }
}

/** Legitimate definition miss or a complete bridge-ready document. */
enum BibleReaderPreparedDefinitionOutcome: Sendable {
    case noResult
    case document(BibleReaderPreparedDefinitionDocument)
}
