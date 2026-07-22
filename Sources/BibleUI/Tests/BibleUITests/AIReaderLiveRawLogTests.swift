import BibleCore
import XCTest

@testable import BibleUI

/**
 Protects the active-session raw-log contracts implemented by Android's `RawLlmLogActivity` and
 `RawLlmLogAdapter`. Fixtures are immutable and perform no persistence, network, or clipboard work.
 A failure means the live AI panel could display, share, or report a transcript differently from
 Android even while persisted history remains correct.
 */
final class AIReaderLiveRawLogTests: XCTestCase {
  /**
   Verifies structured rows and the total header use Android's titles, token compaction, and cost.

   - Setup: One system message and one priced raw response with provider-reported usage.
   - Expected result: Rows remain ordered; estimates apply to messages and actual usage to responses.
   - Failure meaning: The full-screen active log has drifted from `RawLlmLogAdapter`.
   - Side effects: None.
   */
  func testStructuredEntriesAndTotalSummaryMatchAndroid() {
    let presentation = makePresentation()

    XCTAssertTrue(presentation.showsTotalSummary)
    XCTAssertEqual(presentation.totalSummary, "Total: in 1.5k / out 250 · $0.002")
    XCTAssertEqual(presentation.entries.map(\.title), ["System prompt", "API response (iteration 1)"])
    XCTAssertEqual(presentation.entries[0].tokenSummary, "~2 tokens")
    XCTAssertEqual(presentation.entries[1].tokenSummary, "in: 1.5k / out: 250 · $0.002")
    XCTAssertEqual(presentation.entries[1].content, "{\n  \"answer\" : \"ok\"\n}")
  }

  /**
   Verifies copy/share and report attachments receive Android's complete plain-text transcript.

   - Setup: The same ordered message and API-response fixture used by the structured UI.
   - Expected result: Exact Android headings and blank-line boundaries are retained.
   - Failure meaning: Diagnostics sent from the active panel could differ from persisted raw logs.
   - Side effects: None; no gzip file or system chooser is created.
   */
  func testFormattedTextMatchesAndroidRawLogFormat() {
    XCTAssertEqual(
      makePresentation().formattedText,
      """
      === SYSTEM ===
      Be helpful.

      === RAW API RESPONSE (iteration 1) ===
      {
        "answer" : "ok"
      }


      """
    )
  }

  /**
   Verifies the supported-model action builds Android's addressed active-log report metadata.

   - Setup: A supported Gemini model, deterministic app/device strings, and priced usage.
   - Expected result: Subject, model/provider, iteration, token, cost, and attachment notice match
     Android's `reportAiBugFromRawLog` contract.
   - Failure meaning: The shared system mail composer would receive incomplete report context.
   - Side effects: None; the test does not present `MFMailComposeViewController`.
   */
  func testActiveLogBugReportContentMatchesAndroid() {
    let presentation = makePresentation()
    let body = presentation.bugReportBody(
      appVersion: "1.2.3",
      timestamp: Date(timeIntervalSince1970: 0),
      platformLine: "iOS: 18.0",
      deviceLine: "Device: iPhone"
    )

    XCTAssertEqual(
      presentation.bugReportSubject(appVersion: "1.2.3"),
      "AI Bug Report v1.2.3: gemini-2.5-pro"
    )
    XCTAssertTrue(AIModelCatalog.isSupported(presentation.snapshot.modelName))
    XCTAssertTrue(body.contains("Model: gemini-2.5-pro"))
    XCTAssertTrue(body.contains("Provider: GEMINI"))
    XCTAssertTrue(body.contains("Iterations: 1"))
    XCTAssertTrue(body.contains("Tokens: 1500 in / 250 out"))
    XCTAssertTrue(body.contains("Estimated cost: $0.0020"))
    XCTAssertTrue(body.contains("Attached: ai_raw_log.txt.gz (gzipped raw LLM conversation log)"))
  }

  /** Creates one deterministic Android-parity presentation without app services or actor work. */
  private func makePresentation() -> AIReaderLiveRawLogPresentation {
    AIReaderLiveRawLogPresentation(
      snapshot: AIReaderLiveRawLogSnapshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        transcript: LLMRunTranscript(
          entries: [
            .message(role: .system, content: "Be helpful."),
            .rawAPIResponse(iteration: 1, body: #"{"answer":"ok"}"#),
          ],
          iterationUsage: [
            LLMRunIterationUsage(
              iteration: 1,
              usage: LLMUsage(inputTokens: 1_500, outputTokens: 250)
            )
          ]
        ),
        modelName: "gemini-2.5-pro",
        providerType: "GEMINI",
        pricing: AIReaderLiveRawLogPricing(
          inputPerMillion: 1,
          outputPerMillion: 2,
          cacheCreationPerMillion: 1,
          cacheReadPerMillion: 0.1
        )
      )
    )
  }
}
