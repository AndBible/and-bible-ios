// MyDocumentReaderMetadata.swift -- AI metadata projected into My Documents reader payloads

import Foundation

/**
 Android `AiDocMarkerInfo` fields needed by BibleView for one source-page marker.
 */
public struct MyDocumentAIDocMarker: Equatable, Sendable {
    public let pageId: UUID
    public let documentId: UUID
    public let documentInitials: String
    public let pageTitle: String
    public let pageKey: String
    public let kjvOrdinalStart: Int?
    public let kjvOrdinalEnd: Int?
    public let sourcePromptId: UUID?
    public let sourceBookInitials: String?
    public let sourceBookKey: String?

    public init(
        pageId: UUID,
        documentId: UUID,
        documentInitials: String,
        pageTitle: String,
        pageKey: String,
        kjvOrdinalStart: Int?,
        kjvOrdinalEnd: Int?,
        sourcePromptId: UUID?,
        sourceBookInitials: String?,
        sourceBookKey: String?
    ) {
        self.pageId = pageId
        self.documentId = documentId
        self.documentInitials = documentInitials
        self.pageTitle = pageTitle
        self.pageKey = pageKey
        self.kjvOrdinalStart = kjvOrdinalStart
        self.kjvOrdinalEnd = kjvOrdinalEnd
        self.sourcePromptId = sourcePromptId
        self.sourceBookInitials = sourceBookInitials
        self.sourceBookKey = sourceBookKey
    }
}

/**
 Prompt/model/footer and source-page markers for one rendered My Documents page.
 */
public struct MyDocumentReaderMetadata: Equatable, Sendable {
    public let sourcePromptId: UUID?
    public let sourcePromptName: String?
    public let sourceModelName: String?
    public let aiDocMarkers: [MyDocumentAIDocMarker]

    public init(
        sourcePromptId: UUID?,
        sourcePromptName: String?,
        sourceModelName: String?,
        aiDocMarkers: [MyDocumentAIDocMarker]
    ) {
        self.sourcePromptId = sourcePromptId
        self.sourcePromptName = sourcePromptName
        self.sourceModelName = sourceModelName
        self.aiDocMarkers = aiDocMarkers
    }
}

/**
 Native share contract matching Android's separate `EXTRA_SUBJECT` and `EXTRA_TEXT` values.
 */
public struct MyDocumentSharePayload: Equatable, Sendable {
    public let subject: String?
    public let body: String

    public init(subject: String?, body: String) {
        let trimmedSubject = subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subject = trimmedSubject?.isEmpty == false ? trimmedSubject : nil
        self.body = body
    }
}
