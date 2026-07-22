import Foundation
import BibleCore

/**
 Formats successful reference-chooser results exactly like Android's JSword bridge.

 Android `BibleJavascriptInterface.refChooserDialog` parses the selected OSIS id as a KJVA
 `Verse`, temporarily sets `BookName` to short mode, and returns `Verse.name`. The bundled
 `JSwordKJVAVersification` catalog is generated from the same JSword `BibleNames.properties`
 source, so iOS can produce the same stable English short name without leaking an OSIS id.
 */
enum BibleReaderReferenceChooserResultFormatter {
    /**
     Builds one JSword short `Verse.name` such as `Gen 1:1` or `Joh 3:16`.

     - Parameters:
       - osisBookId: KJVA OSIS book identifier selected by the chooser.
       - chapter: One-based KJVA chapter number.
       - verse: One-based KJVA verse number.
     - Returns: JSword short-name reference, or `nil` when the KJVA coordinate is invalid.
     - Side effects: None; reads immutable bundled JSword canon/name data.
     - Failure modes: Unknown books and out-of-range chapter/verse coordinates return `nil` rather
       than emitting a plausible but invalid bridge value.
     */
    static func verseName(
        osisBookId: String,
        chapter: Int,
        verse: Int
    ) -> String? {
        guard chapter > 0,
              verse > 0,
              JSwordKJVAVersification.verseOrdinal(
                  osisId: osisBookId,
                  chapter: chapter,
                  verse: verse
              ) != nil,
              let shortBookName = JSwordKJVAVersification.shortBookName(
                  osisId: osisBookId
              ) else { return nil }
        return "\(shortBookName) \(chapter):\(verse)"
    }
}

/**
 Owns the one pending bridge completion for the reader reference chooser.

 Android completes every `refChooserDialog` request exactly once: selecting a verse returns its
 short JSword `Verse.name`, while cancellation returns an empty result. Each iOS presentation gets
 a unique generation so an old sheet's delayed dismissal or selection cannot resolve a replacement
 request.

 Side effects:
 - replacing a pending request cancels the previous request before returning the new generation
 - resolving a matching generation invokes and clears its completion synchronously

 Failure modes:
 - resolving without a pending matching generation is a no-op and reports `false`
 */
struct BibleReaderReferenceChooserRequest {
    /** Stable identity for one chooser presentation and its retained bridge callback. */
    struct Generation: Hashable, Identifiable {
        /// Opaque identity used by SwiftUI sheet presentation and stale-callback rejection.
        let id: UUID

        /** Creates a fresh chooser identity unless a deterministic test id is supplied. */
        init(id: UUID = UUID()) {
            self.id = id
        }
    }

    /** Completion and identity retained atomically for the current presentation. */
    private struct PendingRequest {
        /// Presentation identity required by every completion or dismissal attempt.
        let generation: Generation

        /// Bridge callback receiving JSword short `Verse.name` or `nil` cancellation.
        let completion: (String?) -> Void
    }

    /// Current request retained until matching completion, cancellation, or replacement.
    private var pendingRequest: PendingRequest?

    /// Whether a bridge request is waiting for chooser completion.
    var isPending: Bool {
        pendingRequest != nil
    }

    /// Identity of the pending chooser presentation, if one exists.
    var generation: Generation? {
        pendingRequest?.generation
    }

    /**
     Begins a chooser request and terminates any request it supersedes.

     - Parameter completion: Callback for JSword short `Verse.name` or `nil` cancellation.
     - Returns: Fresh generation that every selection/dismissal callback must present to resolve
       this request.
     - Side effects: Installs the new request, then invokes the superseded callback with `nil`.
     - Failure modes: None; replacement is deterministic even when no request is pending. A
       reentrant superseded callback cannot resolve the replacement without its generation.
     */
    @discardableResult
    mutating func replace(with completion: @escaping (String?) -> Void) -> Generation {
        let supersededRequest = pendingRequest
        let generation = Generation()
        pendingRequest = PendingRequest(
            generation: generation,
            completion: completion
        )
        supersededRequest?.completion(nil)
        return generation
    }

    /**
     Completes one matching request at most once.

     - Parameters:
       - generation: Identity captured by the sheet or selection callback being completed.
       - result: JSword short `Verse.name`, or `nil` when that presentation was cancelled.
     - Returns: `true` only when this call owned and completed the pending generation.
     - Side effects: Clears the retained callback before invoking it, preventing reentrant double
       completion.
     - Failure modes: Stale generations and an empty pending state return `false` without invoking
       the current callback.
     */
    @discardableResult
    mutating func resolve(
        for generation: Generation,
        with result: String?
    ) -> Bool {
        guard pendingRequest?.generation == generation else { return false }
        let completion = pendingRequest?.completion
        pendingRequest = nil
        completion?(result)
        return true
    }
}
