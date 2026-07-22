import XCTest
@testable import BibleCore

/** Exact plan-canon request coverage for Daily Reading Read, Speak, and Speak All workflows. */
final class DailyReadingActionRequestTests: XCTestCase {
    /**
     Verifies chapter and multi-range assignments expand to concrete inclusive KJV endpoints.

     Failure meaning:
     - a parent reader cannot map and validate the complete requested range because the UI dropped
       a chapter boundary or emitted an ambiguous chapter-only reference.
     */
    func testRequestExpandsWholeChaptersAndPreservesMultipleRanges() throws {
        let request = try DailyReadingActionRequestFactory.makeRequest(
            planID: UUID(uuidString: "b1000000-0000-0000-0000-000000000001")!,
            planCode: "ranges",
            dayNumber: 7,
            assignment: ReadingPlanDayAssignment(
                rawValue: "Gen.1-Gen.2,Matt.1.1-Matt.1.3"
            ),
            planVersification: "KJV",
            kind: .read,
            readingNumbers: [1, 2]
        )

        XCTAssertEqual(request.kind, .read)
        XCTAssertEqual(request.readingNumbers, [1, 2])
        XCTAssertEqual(request.passages.map(\.osisReference), [
            "Gen.1.1-Gen.2.25",
            "Matt.1.1-Matt.1.3",
        ])
        XCTAssertEqual(request.passages.map(\.sourceVersification), ["KJV", "KJV"])
    }

    /**
     Verifies Android's bare-book assignments expand through the last verse in the plan canon.

     Failure meaning:
     - bundled entries such as `Ruth`, `Obad`, `Phlm`, and `Jude` fail instead of opening or
       speaking the whole book as Android's OSIS parser does.
     */
    func testRequestExpandsBareBookAssignmentsFromBundledPlans() throws {
        let request = try DailyReadingActionRequestFactory.makeRequest(
            planID: UUID(uuidString: "b1500000-0000-0000-0000-000000000001")!,
            planCode: "whole-books",
            dayNumber: 97,
            assignment: ReadingPlanDayAssignment(rawValue: "Ruth,Obad"),
            planVersification: "KJV",
            kind: .read,
            readingNumbers: [1, 2]
        )

        XCTAssertEqual(request.passages.map(\.osisReference), [
            "Ruth.1.1-Ruth.4.22",
            "Obad.1.1-Obad.1.21",
        ])
    }

    /**
     Verifies a deuterocanonical NRSVA reading stays in the plan's declared canon.

     Failure meaning:
     - iOS silently reparses a plan through KJV, rejects a valid Android plan, or loses an
       addressable deuterocanonical passage before active-module conversion.
     */
    func testRequestResolvesDeuterocanonicalPassageInNRSVA() throws {
        let request = try DailyReadingActionRequestFactory.makeRequest(
            planID: UUID(uuidString: "b2000000-0000-0000-0000-000000000001")!,
            planCode: "deuterocanonical",
            dayNumber: 1,
            assignment: ReadingPlanDayAssignment(rawValue: "1Macc.1.1-1Macc.1.3,Tob.1"),
            planVersification: "NRSVA",
            kind: .speak,
            readingNumbers: [1, 2]
        )

        XCTAssertEqual(request.passages[0].osisReference, "1Macc.1.1-1Macc.1.3")
        XCTAssertEqual(request.passages[0].sourceVersification, "NRSVA")
        XCTAssertEqual(request.passages[1].start.osisBookId, "Tob")
        XCTAssertEqual(request.passages[1].start.chapter, 1)
        XCTAssertEqual(request.passages[1].start.verse, 1)
        XCTAssertEqual(request.passages[1].end.osisBookId, "Tob")
        XCTAssertGreaterThan(request.passages[1].end.verse, 1)
    }

    /**
     Verifies missing and unknown plan metadata follow Android's KJV/NRSVA fallback policy.

     Failure meaning:
     - ordinary plans without a `Versification` property fail instead of using KJV, or a plan with
       unknown metadata cannot retain deuterocanonical references through Android's NRSVA fallback.
     */
    func testPlanVersificationFallbacksMatchAndroid() throws {
        let defaulted = try DailyReadingActionRequestFactory.makeRequest(
            planID: UUID(uuidString: "b2500000-0000-0000-0000-000000000001")!,
            planCode: "default-v11n",
            dayNumber: 1,
            assignment: ReadingPlanDayAssignment(rawValue: "Gen.1.1"),
            planVersification: nil,
            kind: .read,
            readingNumbers: [1]
        )
        XCTAssertEqual(defaulted.passages.map(\.sourceVersification), ["KJV"])

        let inclusive = try DailyReadingActionRequestFactory.makeRequest(
            planID: UUID(uuidString: "b2500000-0000-0000-0000-000000000002")!,
            planCode: "unknown-v11n",
            dayNumber: 1,
            assignment: ReadingPlanDayAssignment(rawValue: "Tob.1.1"),
            planVersification: "UnknownCanon",
            kind: .speak,
            readingNumbers: [1]
        )
        XCTAssertEqual(inclusive.passages.map(\.sourceVersification), ["NRSVA"])
        XCTAssertEqual(inclusive.passages.map(\.osisReference), ["Tob.1.1"])
    }

    /**
     Verifies Speak All preserves every one-based reading number and source order.

     Failure meaning:
     - speech queues omit a range, reorder plan content, or mark the wrong Android status slot.
     */
    func testSpeakAllRequestPreservesEveryReadingNumberAndOrder() throws {
        let request = try DailyReadingActionRequestFactory.makeRequest(
            planID: UUID(uuidString: "b3000000-0000-0000-0000-000000000001")!,
            planCode: "speech",
            dayNumber: 12,
            assignment: ReadingPlanDayAssignment(rawValue: "Ps.1,John.3.16,Rev.22.20-Rev.22.21"),
            planVersification: "KJV",
            kind: .speak,
            readingNumbers: [1, 2, 3]
        )

        XCTAssertEqual(request.kind, .speak)
        XCTAssertEqual(request.readingNumbers, [1, 2, 3])
        XCTAssertEqual(request.passages.map(\.sourceExpression), [
            "Ps.1",
            "John.3.16",
            "Rev.22.20-Rev.22.21",
        ])
    }

    /**
     Verifies one invalid selected range rejects the complete action request.

     Failure meaning:
     - valid siblings can start navigation or speech while malformed plan content is silently
       omitted, allowing progress to be marked for an action the user did not receive.
     */
    func testInvalidRangeRejectsCompleteRequest() {
        XCTAssertThrowsError(
            try DailyReadingActionRequestFactory.makeRequest(
                planID: UUID(uuidString: "b4000000-0000-0000-0000-000000000001")!,
                planCode: "invalid",
                dayNumber: 2,
                assignment: ReadingPlanDayAssignment(rawValue: "Gen.1,NotABook.4"),
                planVersification: "KJV",
                kind: .speak,
                readingNumbers: [1, 2]
            )
        ) { error in
            XCTAssertEqual(
                error as? DailyReadingActionError,
                .invalidReference("NotABook.4")
            )
        }
    }

    /**
     Verifies every Daily Reading construction failure uses Android's shared localized error message.

     Android catches Daily Reading action exceptions with `R.string.error_occurred`. A failure means
     iOS introduced an untranslated platform-only key or exposed different messages by failure case.
     */
    func testActionErrorsUseAndroidSharedLocalization() {
        let expected = String(localized: "error_occurred", defaultValue: "An error has occurred")
        let errors: [DailyReadingActionError] = [
            .unsupportedVersification("Unknown"),
            .missingReading(2),
            .invalidReference("NotABook.1"),
            .handlerUnavailable,
            .versificationResolverUnavailable,
        ]

        XCTAssertEqual(errors.map(\.errorDescription), Array(repeating: expected, count: errors.count))
    }
}
