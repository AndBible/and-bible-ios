import CryptoKit
import Foundation

/**
 Editable text content types preserved across AI transformation writeback.

 Raw values match existing My Documents and Android note-editor payloads where applicable.
 */
public enum AITextContentType: String, Codable, CaseIterable, Sendable {
    /// Markdown source text.
    case markdown = "MARKDOWN"
    /// HTML source text.
    case html = "HTML"
    /// OSIS source text.
    case osis = "OSIS"
    /// Unformatted text supplied by a host adapter.
    case plainText = "PLAIN_TEXT"
}

/**
 Typed identity for every note-editor destination accepted by AI transformation output.

 Bible and generic-book bookmark notes are distinct because they are stored by different existing
 bookmark services even though Android exposes both through `BOOKMARK_NOTE`.
 */
public enum AITextTarget: Hashable, Codable, Sendable {
    /// Bible bookmark note identity.
    case bibleBookmarkNote(UUID)
    /// Generic-book bookmark note identity.
    case genericBookmarkNote(UUID)
    /// StudyPad text-entry identity.
    case studyPadText(UUID)
    /// My Documents page identity.
    case myDocumentPage(UUID)

    /// Android note-editor entity type shared with prompt execution context.
    public var noteEditorEntityType: NoteEditorEntityType {
        switch self {
        case .bibleBookmarkNote, .genericBookmarkNote: return .bookmarkNote
        case .studyPadText: return .studyPadText
        case .myDocumentPage: return .myDocumentPage
        }
    }

    /// Stable UUID owned by the backing domain service.
    public var id: UUID {
        switch self {
        case .bibleBookmarkNote(let id), .genericBookmarkNote(let id),
             .studyPadText(let id), .myDocumentPage(let id):
            return id
        }
    }

    /// Stable kind discriminator used in captured-input digests.
    fileprivate var digestKind: String {
        switch self {
        case .bibleBookmarkNote: return "BIBLE_BOOKMARK_NOTE"
        case .genericBookmarkNote: return "GENERIC_BOOKMARK_NOTE"
        case .studyPadText: return "STUDYPAD_TEXT"
        case .myDocumentPage: return "MY_DOCUMENT_PAGE"
        }
    }
}

/** Current text and content type read from an owning domain service. */
public struct AITextTargetValue: Equatable, Sendable {
    /// Exact editable source text.
    public let content: String
    /// Durable content type that writeback must preserve.
    public let contentType: AITextContentType

    /** Creates an immutable domain text value. */
    public init(content: String, contentType: AITextContentType) {
        self.content = content
        self.contentType = contentType
    }
}

/** Outcome of an owning service's atomic compare-and-write operation. */
public enum AITextTargetWriteResult: Equatable, Sendable {
    /// Expected content matched and the replacement was committed.
    case written
    /// The target was deleted before the conditional write.
    case targetNotFound
    /// Identity still exists but its content or content type changed.
    case staleContent
}

/**
 Captured input returned before a transformation request begins.

 `capturedInputDigest` must be supplied unchanged to writeback. The store re-reads the target and
 rejects stale content rather than overwriting edits made while the model was running.
 */
public struct AITextTargetSnapshot: Equatable, Sendable {
    /// Typed destination.
    public let target: AITextTarget
    /// Exact captured source text.
    public let content: String
    /// Captured durable content type.
    public let contentType: AITextContentType
    /// SHA-256 digest binding target identity, type, and exact input content.
    public let capturedInputDigest: String

    /** Creates an immutable capture returned by `AITextTargetStore.capture(_:)`. */
    public init(
        target: AITextTarget,
        content: String,
        contentType: AITextContentType,
        capturedInputDigest: String
    ) {
        self.target = target
        self.content = content
        self.contentType = contentType
        self.capturedInputDigest = capturedInputDigest
    }
}

/**
 Adapter boundary for existing Bookmark, StudyPad, and My Documents services.

 Implementations must preserve target identity and content type. The conditional write must compare
 and replace atomically within the owning service's actor, main actor, or database transaction so an
 independent editor or sync mutation cannot land between validation and replacement.
 */
public protocol AITextTargetBacking: Sendable {
    /** Reads the current editable text value, or `nil` when the target was deleted. */
    func read(_ target: AITextTarget) async throws -> AITextTargetValue?

    /**
     Replaces a target only when its current value exactly equals the expected captured value.

     - Returns: Whether the write committed, the target disappeared, or content became stale.
     */
    func compareAndWrite(
        _ value: AITextTargetValue,
        to target: AITextTarget,
        replacing expectedValue: AITextTargetValue
    ) async throws -> AITextTargetWriteResult
}

/** Stable text-target failures used by UI and execution coordinators. */
public enum AITextTargetStoreError: Error, Equatable, Sendable {
    /// The target was deleted or never existed.
    case targetNotFound
    /// Writeback omitted the required captured-input digest.
    case missingCapturedInputDigest
    /// Current identity, type, or content no longer matches the captured input.
    case staleContent
}

/**
 Conflict-safe transformation capture and writeback coordinator.

 The actor serializes capture/write operations made through this store. It still re-reads before
 every write because owning domain services may be mutated independently by UI or sync code.
 */
public actor AITextTargetStore {
    /// Adapter routing typed targets to their existing owning services.
    private let backing: any AITextTargetBacking

    /** Creates a text-target store over a host-provided service adapter. */
    public init(backing: any AITextTargetBacking) {
        self.backing = backing
    }

    /**
     Captures exact editable input for a future AI transformation.

     - Parameter target: Typed bookmark, generic-book bookmark, StudyPad, or My Documents target.
     - Returns: Current content, type, and required digest.
     - Side effects: Reads through the owning service adapter.
     - Throws: `targetNotFound` or adapter errors.
     */
    public func capture(_ target: AITextTarget) async throws -> AITextTargetSnapshot {
        guard let value = try await backing.read(target) else {
            throw AITextTargetStoreError.targetNotFound
        }
        return AITextTargetSnapshot(
            target: target,
            content: value.content,
            contentType: value.contentType,
            capturedInputDigest: Self.digest(target: target, value: value)
        )
    }

    /**
     Writes transformed text only when the exact captured input is still current.

     Content type is not accepted as an input: the current captured type is passed back to the owning
     service unchanged, making accidental Markdown/HTML/OSIS conversion impossible at this boundary.

     - Parameters:
       - content: Transformed source text.
       - target: Original typed destination.
       - capturedInputDigest: Non-empty digest returned by `capture(_:)`.
     - Returns: Fresh snapshot of the committed output for subsequent transformations.
     - Side effects: Re-reads and then writes through the owning domain service adapter.
     - Throws: Missing digest, deleted target, stale identity/type/content, or adapter errors.
     */
    public func write(
        content: String,
        to target: AITextTarget,
        capturedInputDigest: String
    ) async throws -> AITextTargetSnapshot {
        guard !capturedInputDigest.isEmpty else {
            throw AITextTargetStoreError.missingCapturedInputDigest
        }
        guard let current = try await backing.read(target) else {
            throw AITextTargetStoreError.targetNotFound
        }
        guard Self.digest(target: target, value: current) == capturedInputDigest else {
            throw AITextTargetStoreError.staleContent
        }
        let updated = AITextTargetValue(content: content, contentType: current.contentType)
        switch try await backing.compareAndWrite(updated, to: target, replacing: current) {
        case .written:
            break
        case .targetNotFound:
            throw AITextTargetStoreError.targetNotFound
        case .staleContent:
            throw AITextTargetStoreError.staleContent
        }
        return AITextTargetSnapshot(
            target: target,
            content: updated.content,
            contentType: updated.contentType,
            capturedInputDigest: Self.digest(target: target, value: updated)
        )
    }

    /** Computes a domain-separated SHA-256 digest over identity, type, and exact UTF-8 content. */
    private static func digest(target: AITextTarget, value: AITextTargetValue) -> String {
        let canonical = [
            "andbible-ai-text-target-v1",
            target.digestKind,
            target.id.uuidString.lowercased(),
            value.contentType.rawValue,
            value.content,
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
