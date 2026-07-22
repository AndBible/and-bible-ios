// AIReaderLiveRawLogView.swift -- Android-compatible in-memory AI run diagnostics

import BibleCore
import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/** Immutable per-million-token prices retained with one in-memory raw-log snapshot. */
struct AIReaderLiveRawLogPricing: Equatable, Sendable {
  /// Input-token price in US dollars per million tokens.
  let inputPerMillion: Double
  /// Output-token price in US dollars per million tokens.
  let outputPerMillion: Double
  /// Cache-creation price in US dollars per million tokens.
  let cacheCreationPerMillion: Double
  /// Cache-read price in US dollars per million tokens.
  let cacheReadPerMillion: Double

  /**
   Resolves Android's configured-price-first, catalog-price-second policy.

   - Parameters:
     - modelName: Exact provider model identifier used by the run.
     - configuredModel: Persisted model row, when it still exists.
   - Returns: Effective prices, or `nil` when Android would omit cost.
   - Side effects: None; persisted values are copied into an immutable value.
   - Failure modes: Invalid or negative prices are normalized by the shared cost calculator.
   */
  static func resolve(
    modelName: String,
    configuredModel: LLMConfiguredModel?
  ) -> AIReaderLiveRawLogPricing? {
    if let configuredModel,
      configuredModel.inputPricePerMillion > 0 || configuredModel.outputPricePerMillion > 0
    {
      return AIReaderLiveRawLogPricing(
        inputPerMillion: configuredModel.inputPricePerMillion,
        outputPerMillion: configuredModel.outputPricePerMillion,
        cacheCreationPerMillion: configuredModel.cacheCreationPricePerMillion,
        cacheReadPerMillion: configuredModel.cacheReadPricePerMillion
      )
    }
    guard let catalog = AIModelCatalog.pricing(for: modelName) else { return nil }
    return AIReaderLiveRawLogPricing(
      inputPerMillion: catalog.inputPerMillion,
      outputPerMillion: catalog.outputPerMillion,
      cacheCreationPerMillion: catalog.cacheCreationPerMillion,
      cacheReadPerMillion: catalog.cacheReadPerMillion
    )
  }

  /** Returns Android's estimated USD cost for one provider usage value. */
  func estimatedCost(for usage: LLMUsage) -> Double {
    AIUsageCostCalculator.estimatedCostUSD(
      usage: usage,
      inputPricePerMillion: inputPerMillion,
      outputPricePerMillion: outputPerMillion,
      cacheCreationPricePerMillion: cacheCreationPerMillion,
      cacheReadPricePerMillion: cacheReadPerMillion
    )
  }
}

/** Detached in-memory transcript and model metadata for one completed reader run. */
struct AIReaderLiveRawLogSnapshot: Identifiable, Equatable, Sendable {
  /// Run identity used by full-screen item presentation.
  let id: UUID
  /// Ordered credential-free provider and tool transcript.
  let transcript: LLMRunTranscript
  /// Exact provider model identifier used by every iteration.
  let modelName: String
  /// Android provider raw value retained for the report body.
  let providerType: String
  /// Effective cost metadata, absent when Android cannot price the model.
  let pricing: AIReaderLiveRawLogPricing?

  /** Creates a value snapshot without retaining SwiftData or recorder actors. */
  init(
    id: UUID,
    transcript: LLMRunTranscript,
    modelName: String,
    providerType: String,
    pricing: AIReaderLiveRawLogPricing?
  ) {
    self.id = id
    self.transcript = transcript
    self.modelName = modelName
    self.providerType = providerType
    self.pricing = pricing
  }

  /// Whether Android would suppress the active-session raw-log link.
  var isEmpty: Bool { transcript.entries.isEmpty }
}

/** One expandable row matching Android's `RawLlmLogAdapter` presentation contract. */
struct AIReaderLiveRawLogDisplayEntry: Identifiable, Equatable {
  /// Stable transcript position.
  let id: Int
  /// Localized Android entry title.
  let title: String
  /// Estimated or provider-reported token and cost summary.
  let tokenSummary: String
  /// Selectable plain-text or pretty-printed JSON body.
  let content: String
}

/** Pure formatter shared by the active-log UI, copy/share, and report attachment. */
struct AIReaderLiveRawLogPresentation: Equatable {
  /// Source snapshot detached from the active execution actor.
  let snapshot: AIReaderLiveRawLogSnapshot

  /// Android-formatted expandable rows in exact transcript order.
  var entries: [AIReaderLiveRawLogDisplayEntry] {
    snapshot.transcript.entries.enumerated().map { index, entry in
      AIReaderLiveRawLogDisplayEntry(
        id: index,
        title: title(for: entry),
        tokenSummary: tokenSummary(for: entry),
        content: content(for: entry)
      )
    }
  }

  /// Whether Android displays the total token/cost header.
  var showsTotalSummary: Bool { !snapshot.transcript.iterationUsage.isEmpty }

  /// Android's total input/output header with optional estimated cost.
  var totalSummary: String {
    let cost = totalCost.map { " · \(Self.formatCost($0))" } ?? ""
    return String(
      format: String(
        localized: "raw_llm_log_total",
        defaultValue: "Total: in %1$@ / out %2$@%3$@"
      ),
      Self.formatTokenCount(totalUsage.inputTokens),
      Self.formatTokenCount(totalUsage.outputTokens),
      cost
    )
  }

  /// Complete `RawLlmLog.format()` text used by Android copy, share, and gzip reports.
  var formattedText: String {
    var result = ""
    for entry in snapshot.transcript.entries {
      switch entry {
      case .message(let role, let content):
        result += "=== \(role.rawValue.uppercased()) ===\n"
        result += content ?? "(empty)"
        result += "\n\n"
      case .toolCall(let tool, let id, let arguments):
        result += "=== TOOL_CALL: \(tool.wireName) [\(id)] ===\n"
        result += Self.prettyFormattedJSON(arguments)
        result += "\n\n"
      case .toolResult(let id, let value):
        result += "=== TOOL_RESULT [\(id)] ===\n"
        result += Self.prettyFormattedJSON(value)
        result += "\n\n"
      case .toolDefinitions(let definitions):
        result += "=== TOOL DEFINITIONS (\(definitions.count) tools) ===\n"
        for definition in definitions {
          result += "--- \(definition.tool.wireName) ---\n"
          result += "Description: \(definition.description)\n"
          result += "Parameters: \(Self.encodedParameters(definition.parameters))\n\n"
        }
      case .rawAPIResponse(let iteration, let body):
        result += "=== RAW API RESPONSE (iteration \(iteration)) ===\n"
        result += Self.prettyFormattedJSON(body)
        result += "\n\n"
      }
    }
    return result
  }

  /// Saturating aggregate of Android's successful per-iteration usage map.
  var totalUsage: LLMUsage {
    snapshot.transcript.iterationUsage.reduce(LLMUsage()) { partial, item in
      LLMUsage(
        inputTokens: Self.saturatingAdd(partial.inputTokens, item.usage.inputTokens),
        outputTokens: Self.saturatingAdd(partial.outputTokens, item.usage.outputTokens),
        cacheCreationTokens: Self.saturatingAdd(
          partial.cacheCreationTokens,
          item.usage.cacheCreationTokens
        ),
        cacheReadTokens: Self.saturatingAdd(
          partial.cacheReadTokens,
          item.usage.cacheReadTokens
        )
      )
    }
  }

  /// Android's total cost when effective pricing is known.
  var totalCost: Double? { snapshot.pricing?.estimatedCost(for: totalUsage) }

  /** Builds Android's addressed active-log report subject. */
  func bugReportSubject(appVersion: String) -> String {
    "AI Bug Report v\(appVersion): \(snapshot.modelName)"
  }

  /**
   Builds Android's credential-free active-session report body.

   - Parameters:
     - appVersion: Current marketing version.
     - timestamp: Report creation time, matching Android rather than run completion time.
     - platformLine: Platform/version line adapted for iOS or macOS.
     - deviceLine: Device model line adapted for the current Apple platform.
   - Returns: Plain-text addressed email body.
   - Side effects: None.
   - Failure modes: None; unknown pricing simply omits the estimated-cost line.
   */
  func bugReportBody(
    appVersion: String,
    timestamp: Date,
    platformLine: String,
    deviceLine: String
  ) -> String {
    var lines = [
      "--- AI Bug Report ---",
      "",
      "Please describe the issue:",
      "",
      "",
      "--- Details ---",
      "Model: \(snapshot.modelName)",
      "Provider: \(snapshot.providerType)",
      "Timestamp: \(Self.reportTimestamp(timestamp))",
      "Iterations: \(snapshot.transcript.iterationUsage.count)",
      "Tokens: \(totalUsage.inputTokens) in / \(totalUsage.outputTokens) out",
    ]
    if let totalCost, totalCost > 0 {
      lines.append(String(format: "Estimated cost: $%.4f", totalCost))
    }
    lines.append(contentsOf: [
      "",
      "--- Device ---",
      "App: \(appVersion)",
      platformLine,
      deviceLine,
      "",
      "Attached: ai_raw_log.txt.gz (gzipped raw LLM conversation log)",
    ])
    return lines.joined(separator: "\n")
  }

  /** Formats token counts with Android's exact million/thousand thresholds. */
  static func formatTokenCount(_ count: Int64) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
    return String(count)
  }

  /** Formats estimated cost with Android's sub-cent precision rule. */
  static func formatCost(_ cost: Double) -> String {
    String(format: cost < 0.01 && cost > 0 ? "$%.3f" : "$%.2f", cost)
  }

  /** Returns Android's localized heading for one structured transcript entry. */
  private func title(for entry: LLMRunTranscriptEntry) -> String {
    switch entry {
    case .message(let role, _):
      switch role {
      case .system:
        return String(localized: "raw_llm_log_entry_system", defaultValue: "System prompt")
      case .user:
        return String(localized: "raw_llm_log_entry_user", defaultValue: "User message")
      case .assistant:
        return String(
          localized: "raw_llm_log_entry_assistant",
          defaultValue: "Assistant response"
        )
      case .tool:
        return role.rawValue
      }
    case .toolCall(let tool, _, _):
      return String(
        format: String(
          localized: "raw_llm_log_entry_tool_call",
          defaultValue: "Tool call: %@"
        ),
        tool.wireName
      )
    case .toolResult(let id, _):
      return String(
        format: String(
          localized: "raw_llm_log_entry_tool_result",
          defaultValue: "Tool result [%@]"
        ),
        id
      )
    case .toolDefinitions(let definitions):
      return String(
        format: String(
          localized: "raw_llm_log_entry_tool_definitions",
          defaultValue: "Tool definitions (%d tools)"
        ),
        definitions.count
      )
    case .rawAPIResponse(let iteration, _):
      return String(
        format: String(
          localized: "raw_llm_log_entry_api_response",
          defaultValue: "API response (iteration %d)"
        ),
        iteration
      )
    }
  }

  /** Returns actual iteration usage or Android's four-characters-per-token estimate. */
  private func tokenSummary(for entry: LLMRunTranscriptEntry) -> String {
    if case .rawAPIResponse(let iteration, _) = entry,
      let usage = snapshot.transcript.iterationUsage.first(where: { $0.iteration == iteration })?.usage
    {
      let cost = snapshot.pricing.map { " · \(Self.formatCost($0.estimatedCost(for: usage)))" } ?? ""
      return String(
        format: String(
          localized: "raw_llm_log_entry_usage",
          defaultValue: "in: %1$@ / out: %2$@%3$@"
        ),
        Self.formatTokenCount(usage.inputTokens),
        Self.formatTokenCount(usage.outputTokens),
        cost
      )
    }
    return String(
      format: String(
        localized: "raw_llm_log_entry_tokens",
        defaultValue: "~%@ tokens"
      ),
      Self.formatTokenCount(Int64(max(estimatedCharacterCount(for: entry) / 4, 1)))
    )
  }

  /** Produces Android's selectable content for one expanded entry. */
  private func content(for entry: LLMRunTranscriptEntry) -> String {
    switch entry {
    case .message(_, let content):
      return content
        ?? String(localized: "raw_llm_log_entry_empty", defaultValue: "(empty)")
    case .toolCall(_, _, let arguments):
      return Self.prettyFormattedJSON(arguments)
    case .toolResult(_, let result):
      return Self.prettyFormattedJSON(result)
    case .toolDefinitions(let definitions):
      return definitions.map { definition in
        let description = String(
          format: String(
            localized: "raw_llm_log_entry_tool_desc",
            defaultValue: "Description: %@"
          ),
          definition.description
        )
        let parameters = String(
          format: String(
            localized: "raw_llm_log_entry_tool_params",
            defaultValue: "Parameters: %@"
          ),
          Self.encodedParameters(definition.parameters)
        )
        return "--- \(definition.tool.wireName) ---\n\(description)\n\(parameters)\n"
      }.joined(separator: "\n")
    case .rawAPIResponse(_, let body):
      return Self.prettyFormattedJSON(body)
    }
  }

  /** Mirrors Android's UTF-16 character-count token heuristic for non-response rows. */
  private func estimatedCharacterCount(for entry: LLMRunTranscriptEntry) -> Int {
    switch entry {
    case .message(_, let content): return content?.utf16.count ?? 0
    case .toolCall(_, _, let arguments): return arguments.utf16.count
    case .toolResult(_, let result): return result.utf16.count
    case .toolDefinitions(let definitions):
      return definitions.reduce(0) {
        $0 + $1.tool.wireName.utf16.count + $1.description.utf16.count + 100
      }
    case .rawAPIResponse(_, let body): return body.utf16.count
    }
  }

  /** Encodes and pretty-prints one tool parameter schema without throwing into UI rendering. */
  private static func encodedParameters(_ parameters: [String: JSONValue]) -> String {
    guard let data = try? JSONValue.object(parameters).encodedData() else { return "{}" }
    return prettyFormattedJSON(String(decoding: data, as: UTF8.self))
  }

  /** Pretty-prints JSON objects/arrays and leaves malformed or scalar payloads unchanged. */
  private static func prettyFormattedJSON(_ source: String) -> String {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.first == "{" || trimmed.first == "[",
      let data = trimmed.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      JSONSerialization.isValidJSONObject(object),
      let formatted = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      )
    else { return source }
    return unescapeLongJSONStringContents(String(decoding: formatted, as: UTF8.self))
  }

  /** Applies Android's display-only newline/tab unescaping inside long JSON strings. */
  private static func unescapeLongJSONStringContents(_ source: String) -> String {
    let pattern = #"\"((?:[^\"\\]|\\.){80,})\""#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
    var result = source
    for match in expression.matches(
      in: source,
      range: NSRange(source.startIndex..<source.endIndex, in: source)
    ).reversed() {
      guard let range = Range(match.range, in: result) else { continue }
      let replacement = result[range]
        .replacingOccurrences(of: #"\n"#, with: "\n")
        .replacingOccurrences(of: #"\t"#, with: "\t")
      result.replaceSubrange(range, with: replacement)
    }
    return result
  }

  /** Adds non-negative token counters without allowing diagnostic UI overflow. */
  private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : sum
  }

  /** Formats report creation time with Android's English second-resolution pattern. */
  private static func reportTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
  }
}

/** Android's full-screen structured reader for one active-session raw transcript. */
struct AIReaderLiveRawLogView: View {
  /// Dismisses the full-screen destination like Android's action-bar up button.
  @Environment(\.dismiss) private var dismiss

  /// Immutable terminal snapshot supplied by the live AI panel.
  let snapshot: AIReaderLiveRawLogSnapshot

  /// Whether Android's app-owned report confirmation is blocking the log.
  @State private var showsBugReportConfirmation = false
  /// Addressed payload presented only through the system mail composer.
  @State private var bugReportMail: AIBugReportMailPayload?
  /// Android-style copy acknowledgement.
  @State private var toastMessage: String?
  /// Credential-free attachment or mail availability failure.
  @State private var failureMessage: String?

  var body: some View {
    let presentation = AIReaderLiveRawLogPresentation(snapshot: snapshot)
    NavigationStack {
      ZStack {
        VStack(spacing: 0) {
          if presentation.showsTotalSummary {
            Text(presentation.totalSummary)
              .font(.caption)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
            Divider()
          }
          if presentation.entries.isEmpty {
            ContentUnavailableView(
              String(
                localized: "raw_llm_log_empty",
                defaultValue: "No raw log data available"
              ),
              systemImage: "doc.text"
            )
          } else {
            List(presentation.entries) { entry in
              AIReaderLiveRawLogEntryView(entry: entry)
            }
            .listStyle(.plain)
          }
        }
        .accessibilityHidden(showsBugReportConfirmation)

        if showsBugReportConfirmation {
          AIReaderLiveRawLogBugReportConfirmationDialog(
            onConfirm: { prepareBugReport(presentation) },
            onCancel: { showsBugReportConfirmation = false }
          )
        }
      }
      .navigationTitle(String(localized: "raw_llm_log_title", defaultValue: "Raw LLM Log"))
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(action: dismiss.callAsFunction) {
            Image(systemName: "chevron.backward")
          }
        }
        ToolbarItemGroup(placement: .primaryAction) {
          Button { copy(presentation.formattedText) } label: {
            Image(systemName: "doc.on.doc")
          }
          .accessibilityLabel(String(localized: "copy", defaultValue: "Copy"))

          ShareLink(item: presentation.formattedText) {
            Image(systemName: "square.and.arrow.up")
          }
          .accessibilityLabel(String(localized: "share", defaultValue: "Share"))

          if !snapshot.transcript.iterationUsage.isEmpty {
            Menu {
              Button {
                showsBugReportConfirmation = true
              } label: {
                Label(
                  String(localized: "ai_bug_report_menu", defaultValue: "Report AI bug"),
                  systemImage: "exclamationmark.bubble"
                )
              }
              .disabled(!AIModelCatalog.isSupported(snapshot.modelName))
            } label: {
              Image(systemName: "ellipsis")
            }
            .accessibilityLabel(String(localized: "system_items1", defaultValue: "More"))
          }
        }
      }
      .sheet(item: $bugReportMail) { payload in
        AIBugReportMailComposer(payload: payload) {
          bugReportMail = nil
        }
      }
      .androidToastFeedback(toastMessage)
      .overlay {
        if let message = failureMessage {
          AndroidMyDocumentDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
            .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
          ])
        }
      }
    }
  }

  /** Copies the complete Android-formatted log and emits Android's short toast. */
  private func copy(_ text: String) {
    #if os(iOS)
      UIPasteboard.general.string = text
    #elseif os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #endif
    toastMessage = String(
      localized: "raw_llm_log_copied",
      defaultValue: "Log copied to clipboard"
    )
    Task {
      try? await Task.sleep(for: .seconds(AndroidToastFeedback.shortDuration))
      toastMessage = nil
    }
  }

  /** Creates Android's gzip payload, then opens the addressed system mail composer. */
  private func prepareBugReport(_ presentation: AIReaderLiveRawLogPresentation) {
    showsBugReportConfirmation = false
    guard AIModelCatalog.isSupported(snapshot.modelName) else { return }
    guard AIBugReportMailComposer.canSendMail else {
      failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
      return
    }
    do {
      let attachment = try LLMRawLogPayloadDecoder.gzipAttachmentData(
        Data(presentation.formattedText.utf8)
      )
      let version = AndBibleAppVersionMetadata.current().marketingVersion
      bugReportMail = AIBugReportMailPayload(
        recipient: "errors.andbible@gmail.com",
        subject: presentation.bugReportSubject(appVersion: version),
        body: presentation.bugReportBody(
          appVersion: version,
          timestamp: Date(),
          platformLine: Self.platformLine,
          deviceLine: Self.deviceLine
        ),
        attachmentData: attachment,
        attachmentFilename: "ai_raw_log.txt.gz"
      )
    } catch {
      failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
    }
  }

  /// Current Apple platform line replacing Android's OS/SDK report line.
  private static var platformLine: String {
    #if os(iOS)
      "iOS: \(UIDevice.current.systemVersion)"
    #else
      "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)"
    #endif
  }

  /// Current Apple device line replacing Android's manufacturer/model report line.
  private static var deviceLine: String {
    #if os(iOS)
      "Device: \(UIDevice.current.model)"
    #else
      "Device: Mac"
    #endif
  }
}

/** One independently expandable raw-log row with a stable Android-sized header. */
private struct AIReaderLiveRawLogEntryView: View {
  /// Android-formatted row content.
  let entry: AIReaderLiveRawLogDisplayEntry
  /// Local expansion state; rows start collapsed like Android.
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 8) {
          Text(entry.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(entry.tokenSummary)
            .font(.caption2)
            .foregroundStyle(.secondary)
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        Text(entry.content)
          .font(.system(size: 11, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.vertical, 2)
  }
}

/** App-owned confirmation shown before the addressed system mail composer. */
private struct AIReaderLiveRawLogBugReportConfirmationDialog: View {
  /// Builds the report and opens the system composer.
  let onConfirm: () -> Void
  /// Returns to the raw log without creating an attachment.
  let onCancel: () -> Void

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.4)
          .ignoresSafeArea()
          .accessibilityHidden(true)
        AIAndroidDialogSurface(
          title: String(localized: "send_ai_bug_report_title", defaultValue: "Report AI bug")
        ) {
          Text(
            String(
              localized: "bug_report_email_text",
              defaultValue:
                "Next, please select your preferred email application (Gmail for example) to send the report to the developer team."
            )
          )
          .padding(.horizontal, 20)
          .padding(.vertical, 8)
        } actions: {
          Spacer()
          AIAndroidDialogAction(
            title: String(localized: "cancel", defaultValue: "Cancel"),
            action: onCancel
          )
          AIAndroidDialogAction(
            title: String(localized: "okay", defaultValue: "OK"),
            action: onConfirm
          )
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: geometry.size.height * 0.8)
      }
    }
    .zIndex(20)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
    .accessibilityIdentifier("aiReaderLiveRawLogBugReportConfirmationDialog")
  }
}
