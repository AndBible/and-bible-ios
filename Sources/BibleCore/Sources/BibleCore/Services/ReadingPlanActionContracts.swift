// ReadingPlanActionContracts.swift -- Typed daily-reading navigation and speech requests

import Foundation
import SwordKit

/** User action requested from Android's Daily Reading screen. */
public enum DailyReadingActionKind: Equatable, Sendable {
    /// Navigate the active Bible to one reading.
    case read

    /// Speak one or more readings through the active Bible.
    case speak
}

/**
 One reading-plan passage resolved in the plan's declared versification.

 Chapter-only plan entries are expanded to exact first/last verse coordinates before this value is
 created. The reader applies Android's public conversion to both endpoints and fails when the active
 module cannot address the mapped or retained coordinates.
 */
public struct ReadingPlanPassageTarget: Equatable, Sendable {
    /// Versification declared by the selected reading-plan definition.
    public let sourceVersification: String

    /// Original trimmed plan assignment retained for diagnostics and history labels.
    public let sourceExpression: String

    /// Exact inclusive source-versification start reference.
    public let start: SwordVersification.Reference

    /// Exact inclusive source-versification end reference.
    public let end: SwordVersification.Reference

    /// Exact OSIS verse or range after expanding chapter-only input.
    public let osisReference: String

    /**
     Creates one validated reading-plan passage.

     - Parameters:
       - sourceVersification: Versification owning both endpoints.
       - sourceExpression: Original assignment text.
       - start: Exact inclusive start reference.
       - end: Exact inclusive end reference.
       - osisReference: Exact expanded OSIS reference or range.
     - Side effects: None.
     - Failure modes: Validation belongs to `DailyReadingActionRequestFactory`.
     */
    public init(
        sourceVersification: String,
        sourceExpression: String,
        start: SwordVersification.Reference,
        end: SwordVersification.Reference,
        osisReference: String
    ) {
        self.sourceVersification = sourceVersification
        self.sourceExpression = sourceExpression
        self.start = start
        self.end = end
        self.osisReference = osisReference
    }
}

/**
 Typed request emitted by `DailyReadingView` after strict plan-canon parsing.

 The request deliberately stops at the reader boundary: the parent owns the active module and must
 convert every `ReadingPlanPassageTarget` with Android's public versification behavior, then validate
 active-module addressability before navigation or speech begins. Successful callback return is the
 UI's signal that progress may be marked read.
 */
public struct DailyReadingActionRequest: Equatable, Sendable {
    /// Stable local plan identity.
    public let planID: UUID

    /// Android reading-plan code used for history and diagnostics.
    public let planCode: String

    /// One-based plan day.
    public let dayNumber: Int

    /// Read or speech operation requested by the user.
    public let kind: DailyReadingActionKind

    /// One-based Android reading numbers represented by `passages` in the same order.
    public let readingNumbers: [Int]

    /// Strictly parsed passages in the plan's declared canon.
    public let passages: [ReadingPlanPassageTarget]

    /**
     Creates one validated daily-reading action request.

     - Parameters:
       - planID: Stable local plan identifier.
       - planCode: Android plan code.
       - dayNumber: One-based plan day.
       - kind: Requested action.
       - readingNumbers: One-based reading positions.
       - passages: Plan-canon passages paired with those positions.
     - Side effects: None.
     - Failure modes: Validation belongs to `DailyReadingActionRequestFactory`.
     */
    public init(
        planID: UUID,
        planCode: String,
        dayNumber: Int,
        kind: DailyReadingActionKind,
        readingNumbers: [Int],
        passages: [ReadingPlanPassageTarget]
    ) {
        self.planID = planID
        self.planCode = planCode
        self.dayNumber = dayNumber
        self.kind = kind
        self.readingNumbers = readingNumbers
        self.passages = passages
    }
}

/**
 Applies Android's reading-plan versification fallback policy before passage parsing.

 Android defaults a missing `Versification` property to KJV. If a declared name is unknown,
 `ReadingPlanTextFileDao` falls back to NRSVA because its broader canon can address the largest
 practical set of plan references. Keeping that policy in BibleCore prevents each parent reader
 integration from making a different fallback decision.
 */
public enum ReadingPlanVersificationPolicy {
    /**
     Resolves a raw plan-definition value to the JSword canon iOS must use.

     - Parameter declaredName: Optional `Versification` property or add-on metadata value.
     - Returns: A supported declared name, KJV when missing, or NRSVA when unknown.
     - Side effects: Reads the pinned versification registry.
     - Failure modes: None; the bundled registry guarantees KJV and NRSVA support.
     */
    public static func resolve(_ declaredName: String?) -> String {
        let candidate = declaredName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if candidate.isEmpty {
            return "KJV"
        }
        return VersificationMapper.supports(candidate) ? candidate : "NRSVA"
    }
}

/** Fail-closed daily-reading request construction errors. */
public enum DailyReadingActionError: Error, Equatable, LocalizedError, Sendable {
    /// The plan does not expose a supported JSword versification.
    case unsupportedVersification(String)

    /// The selected one-based reading number does not exist.
    case missingReading(Int)

    /// A plan assignment cannot be resolved exactly in its declared canon.
    case invalidReference(String)

    /// Read and speech actions cannot run without a parent reader handler.
    case handlerUnavailable

    /// The parent cannot provide the selected plan's definition metadata.
    case versificationResolverUnavailable

    /// Android-shared generic description for the Daily Reading error alert.
    public var errorDescription: String? {
        String(localized: "error_occurred", defaultValue: "An error has occurred")
    }
}

/**
 Parses Android reading-plan assignments into exact action requests.

 Android's `PassageReader` interprets entries in the plan's declared JSword versification and
 accepts whole chapters as well as exact verse ranges. This factory mirrors that contract using the
 pinned JSword canon. It does not perform target-module mapping, navigation, speech, or persistence.
 */
public enum DailyReadingActionRequestFactory {
    /**
     Creates one read or speech request from selected one-based reading numbers.

     - Parameters:
       - planID: Stable local plan identity.
       - planCode: Android reading-plan code.
       - dayNumber: One-based plan day.
       - assignment: Parsed Android day assignment.
       - planVersification: Optional versification declared by the plan definition. Missing values
         default to KJV and unknown values fall back to NRSVA, matching Android.
       - kind: Requested read or speech operation.
       - readingNumbers: One-based assignment positions to include.
     - Returns: Typed request whose passages use exact source-canon verse endpoints.
     - Side effects: Reads the pinned JSword canon lazily.
     - Throws: `DailyReadingActionError` for unsupported canons, missing readings, or malformed
       references. No partial request is returned.
     */
    public static func makeRequest(
        planID: UUID,
        planCode: String,
        dayNumber: Int,
        assignment: ReadingPlanDayAssignment,
        planVersification: String?,
        kind: DailyReadingActionKind,
        readingNumbers: [Int]
    ) throws -> DailyReadingActionRequest {
        let versification = ReadingPlanVersificationPolicy.resolve(planVersification)
        guard VersificationMapper.supports(versification) else {
            throw DailyReadingActionError.unsupportedVersification(versification)
        }
        guard dayNumber > 0, !readingNumbers.isEmpty else {
            throw DailyReadingActionError.missingReading(readingNumbers.first ?? 0)
        }

        var passages: [ReadingPlanPassageTarget] = []
        passages.reserveCapacity(readingNumbers.count)
        for readingNumber in readingNumbers {
            guard readingNumber > 0, assignment.readings.indices.contains(readingNumber - 1) else {
                throw DailyReadingActionError.missingReading(readingNumber)
            }
            let expression = assignment.readings[readingNumber - 1]
            passages.append(try passage(expression, versification: versification))
        }

        return DailyReadingActionRequest(
            planID: planID,
            planCode: planCode,
            dayNumber: dayNumber,
            kind: kind,
            readingNumbers: readingNumbers,
            passages: passages
        )
    }

    /** Parses one OSIS chapter, verse, or range expression in a named JSword canon. */
    private static func passage(
        _ rawExpression: String,
        versification: String
    ) throws -> ReadingPlanPassageTarget {
        let expression = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        let rangeParts = expression.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !expression.isEmpty,
              rangeParts.count == 1 || rangeParts.count == 2,
              let startEndpoint = endpoint(String(rangeParts[0])) else {
            throw DailyReadingActionError.invalidReference(rawExpression)
        }

        let endEndpoint: Endpoint
        if rangeParts.count == 2 {
            guard let parsed = endpoint(String(rangeParts[1])) else {
                throw DailyReadingActionError.invalidReference(rawExpression)
            }
            endEndpoint = parsed
        } else {
            endEndpoint = startEndpoint
        }

        guard let start = boundaryReference(
                  startEndpoint,
                  boundary: .start,
                  versification: versification
              ),
              let end = boundaryReference(
                  endEndpoint,
                  boundary: .end,
                  versification: versification
              ),
              let startIndex = JSwordCanon.referenceIndex(
                  for: start,
                  versification: versification
              ),
              let endIndex = JSwordCanon.referenceIndex(
                  for: end,
                  versification: versification
              ),
              startIndex <= endIndex else {
            throw DailyReadingActionError.invalidReference(rawExpression)
        }

        let startOSIS = osisReference(start)
        let endOSIS = osisReference(end)
        return ReadingPlanPassageTarget(
            sourceVersification: versification,
            sourceExpression: expression,
            start: start,
            end: end,
            osisReference: start == end ? startOSIS : "\(startOSIS)-\(endOSIS)"
        )
    }

    /// Parsed endpoint before chapter-only values are expanded to concrete verses.
    private struct Endpoint {
        let osisBookID: String
        let chapter: Int?
        let verse: Int?
    }

    /// Inclusive boundary being resolved for a chapter-only endpoint.
    private enum Boundary: Equatable {
        case start
        case end
    }

    /** Parses `Book`, `Book.chapter`, or `Book.chapter.verse` OSIS endpoints. */
    private static func endpoint(_ rawValue: String) -> Endpoint? {
        let components = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count), !components[0].isEmpty else {
            return nil
        }
        guard components.count > 1 else {
            return Endpoint(osisBookID: String(components[0]), chapter: nil, verse: nil)
        }
        guard let chapter = Int(components[1]), chapter > 0 else { return nil }
        let verse: Int?
        if components.count == 3 {
            guard let value = Int(components[2]), value >= 0 else { return nil }
            verse = value
        } else {
            verse = nil
        }
        return Endpoint(osisBookID: String(components[0]), chapter: chapter, verse: verse)
    }

    /** Expands one endpoint to an exact verse using the plan's canon dimensions. */
    private static func boundaryReference(
        _ endpoint: Endpoint,
        boundary: Boundary,
        versification: String
    ) -> SwordVersification.Reference? {
        if let chapter = endpoint.chapter, let verse = endpoint.verse {
            let reference = SwordVersification.Reference(
                osisBookId: endpoint.osisBookID,
                chapter: chapter,
                verse: verse
            )
            return JSwordCanon.referenceIndex(for: reference, versification: versification) == nil
                ? nil
                : reference
        }

        let first = SwordVersification.Reference(
            osisBookId: endpoint.osisBookID,
            chapter: endpoint.chapter ?? 1,
            verse: 1
        )
        guard let firstIndex = JSwordCanon.referenceIndex(
            for: first,
            versification: versification
        ) else {
            return nil
        }
        guard boundary == .end else { return first }

        var last = first
        var index = firstIndex + 1
        while let candidate = JSwordCanon.reference(forIndex: index, versification: versification),
              candidate.osisBookId == endpoint.osisBookID,
              endpoint.chapter == nil || candidate.chapter == endpoint.chapter {
            if candidate.verse > 0 {
                last = candidate
            }
            index += 1
        }
        return last
    }

    /** Formats one exact source-canon verse as OSIS. */
    private static func osisReference(_ reference: SwordVersification.Reference) -> String {
        "\(reference.osisBookId).\(reference.chapter).\(reference.verse)"
    }
}
