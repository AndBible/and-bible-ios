import CryptoKit
import Foundation

/**
 Android-aligned execution context available to every typed tool invocation.

 UI and document services can populate the identifiers they own without BibleCore depending on
 BibleUI or reader types. KJVA ordinal conversion remains the caller's responsibility at this core
 boundary because it depends on the active document's versification.
 */
public struct AgentExecutionContext: Sendable, Equatable {
  /// Prompt identity for logs and cache matching.
  public let promptId: UUID
  /// Optional workspace identity.
  public let workspaceId: UUID?
  /// Selected range start in KJVA ordinal space.
  public let kjvOrdinalStart: Int?
  /// Selected range end in KJVA ordinal space.
  public let kjvOrdinalEnd: Int?
  /// OSIS reference used as a source key when no non-Bible key exists.
  public let verseReference: String?
  /// Rendered selected content.
  public let selectedContent: String?
  /// Active document initials.
  public let activeDocumentInitials: String?
  /// Optional selected label identity.
  public let activeLabelId: UUID?
  /// Active window identity.
  public let windowId: UUID?
  /// Exact selected text.
  public let selectedText: String?
  /// Exact highlighted text.
  public let highlightedText: String?
  /// Character offset within the first selected verse.
  public let selectionStartOffset: Int?
  /// Character offset within the last selected verse.
  public let selectionEndOffset: Int?
  /// Optional non-Bible selection start ordinal.
  public let selectionStartOrdinal: Int?
  /// Optional non-Bible selection end ordinal.
  public let selectionEndOrdinal: Int?
  /// User-supplied task specification.
  public let userSpecification: String?
  /// Previous response supplied when regenerating an answer.
  public let previousResponse: String?
  /// User instructions applied to regeneration.
  public let additionalInstructions: String?
  /// Source key for commentary or general-book content.
  public let sourceBookKey: String?
  /// Note-editor destination type.
  public let noteEditorEntityType: NoteEditorEntityType?
  /// Note-editor entity identity in its owning service's canonical string form.
  public let noteEditorEntityId: String?
  /// Captured note-editor content.
  public let noteEditorContent: String?
  /// Captured note-editor content-type raw value.
  public let noteEditorContentType: String?
  /// Workspace-window summary supplied to workspace prompts.
  public let workspaceWindowsSummary: String?
  /// Whether this run is a direct text transformation with structural tools only.
  public let isTextTransformation: Bool
  /// Whether document-creation tools are unavailable for this run.
  public let noDocumentCreation: Bool
  /// Pages created by this run and eligible for host-defined permission relaxation.
  public var createdPageIds: Set<UUID>

  /**
   Creates a typed execution context from host-owned identifiers and captured content.

   Construction is deterministic and has no side effects. Optional values remain distinct from
   empty strings because Android cache and routing behavior distinguishes them.
   */
  public init(
    promptId: UUID,
    workspaceId: UUID? = nil,
    kjvOrdinalStart: Int? = nil,
    kjvOrdinalEnd: Int? = nil,
    verseReference: String? = nil,
    selectedContent: String? = nil,
    activeDocumentInitials: String? = nil,
    activeLabelId: UUID? = nil,
    windowId: UUID? = nil,
    selectedText: String? = nil,
    highlightedText: String? = nil,
    selectionStartOffset: Int? = nil,
    selectionEndOffset: Int? = nil,
    selectionStartOrdinal: Int? = nil,
    selectionEndOrdinal: Int? = nil,
    userSpecification: String? = nil,
    previousResponse: String? = nil,
    additionalInstructions: String? = nil,
    sourceBookKey: String? = nil,
    noteEditorEntityType: NoteEditorEntityType? = nil,
    noteEditorEntityId: String? = nil,
    noteEditorContent: String? = nil,
    noteEditorContentType: String? = nil,
    workspaceWindowsSummary: String? = nil,
    isTextTransformation: Bool = false,
    noDocumentCreation: Bool = false,
    createdPageIds: Set<UUID> = []
  ) {
    self.promptId = promptId
    self.workspaceId = workspaceId
    self.kjvOrdinalStart = kjvOrdinalStart
    self.kjvOrdinalEnd = kjvOrdinalEnd
    self.verseReference = verseReference
    self.selectedContent = selectedContent
    self.activeDocumentInitials = activeDocumentInitials
    self.activeLabelId = activeLabelId
    self.windowId = windowId
    self.selectedText = selectedText
    self.highlightedText = highlightedText
    self.selectionStartOffset = selectionStartOffset
    self.selectionEndOffset = selectionEndOffset
    self.selectionStartOrdinal = selectionStartOrdinal
    self.selectionEndOrdinal = selectionEndOrdinal
    self.userSpecification = userSpecification
    self.previousResponse = previousResponse
    self.additionalInstructions = additionalInstructions
    self.sourceBookKey = sourceBookKey
    self.noteEditorEntityType = noteEditorEntityType
    self.noteEditorEntityId = noteEditorEntityId
    self.noteEditorContent = noteEditorContent
    self.noteEditorContentType = noteEditorContentType
    self.workspaceWindowsSummary = workspaceWindowsSummary
    self.isTextTransformation = isTextTransformation
    self.noDocumentCreation = noDocumentCreation
    self.createdPageIds = createdPageIds
  }
}

/// Android-compatible message composition for initial and regenerated agent requests.
public enum AgentMessageComposer {
  /** Maximum previous-response length Android includes in a regeneration request. */
  public static let maximumPreviousResponseCharacters = 10_000

  /**
   Appends regeneration inputs to the last ordinary user message.

   The original array is returned unchanged when neither regeneration field is present. When no
   ordinary user message exists, a user message containing only the regeneration sections is
   appended. Tool-result messages are never modified.

   - Parameters:
     - messages: Initial provider-neutral conversation.
     - context: Execution context containing the optional previous response and instructions.
   - Returns: Conversation containing Android's regeneration sections exactly once.
   - Side effects: none.
   */
  public static func applyingRegenerationContext(
    to messages: [LLMMessage],
    context: AgentExecutionContext
  ) -> [LLMMessage] {
    var suffix = ""
    if let previousResponse = context.previousResponse {
      suffix += "\n\n--- Previous Response (for reference \u{2014} improve upon this) ---\n"
      suffix += String(previousResponse.prefix(maximumPreviousResponseCharacters))
    }
    if let additionalInstructions = context.additionalInstructions {
      suffix += "\n\n--- Additional Instructions ---\n"
      suffix += additionalInstructions
    }
    guard !suffix.isEmpty else { return messages }

    var result = messages
    if let index = result.lastIndex(where: {
      $0.role == .user && $0.toolCallId == nil && $0.toolCalls.isEmpty
    }) {
      let message = result[index]
      result[index] = LLMMessage(role: .user, content: (message.content ?? "") + suffix)
    } else {
      result.append(
        LLMMessage(
          role: .user,
          content: suffix.trimmingCharacters(in: .newlines)
        )
      )
    }
    return result
  }
}

/**
 Fields that participate in Android strict cache identity.

 `canonicalJSON()` reproduces kotlinx.serialization's declaration order, explicit null behavior for
 non-default fields, and omission of default-null fields. `computeHash()` is the lowercase SHA-256
 prefix of the first 16 digest bytes, matching Android `CacheableContext.computeHash()`.
 */
public struct CacheableContext: Codable, Equatable, Sendable {
  /// KJVA start ordinal.
  public let kjvOrdinalStart: Int?
  /// KJVA end ordinal.
  public let kjvOrdinalEnd: Int?
  /// Active document initials.
  public let activeDocumentInitials: String?
  /// Rendered selected content.
  public let selectedContent: String?
  /// Exact selected text.
  public let selectedText: String?
  /// Exact highlighted text.
  public let highlightedText: String?
  /// First-verse character offset.
  public let selectionStartOffset: Int?
  /// Last-verse character offset.
  public let selectionEndOffset: Int?
  /// Optional non-Bible selection start ordinal; omitted from canonical JSON when `nil`.
  public let selectionStartOrdinal: Int?
  /// Optional non-Bible selection end ordinal; omitted from canonical JSON when `nil`.
  public let selectionEndOrdinal: Int?
  /// Optional user specification; omitted from canonical JSON when `nil`.
  public let userSpecification: String?
  /// Optional non-Bible key or OSIS fallback; omitted from canonical JSON when `nil`.
  public let sourceBookKey: String?

  /** Creates a cacheable value directly from canonical fields. */
  public init(
    kjvOrdinalStart: Int?,
    kjvOrdinalEnd: Int?,
    activeDocumentInitials: String?,
    selectedContent: String?,
    selectedText: String?,
    highlightedText: String?,
    selectionStartOffset: Int?,
    selectionEndOffset: Int?,
    selectionStartOrdinal: Int? = nil,
    selectionEndOrdinal: Int? = nil,
    userSpecification: String? = nil,
    sourceBookKey: String? = nil
  ) {
    self.kjvOrdinalStart = kjvOrdinalStart
    self.kjvOrdinalEnd = kjvOrdinalEnd
    self.activeDocumentInitials = activeDocumentInitials
    self.selectedContent = selectedContent
    self.selectedText = selectedText
    self.highlightedText = highlightedText
    self.selectionStartOffset = selectionStartOffset
    self.selectionEndOffset = selectionEndOffset
    self.selectionStartOrdinal = selectionStartOrdinal
    self.selectionEndOrdinal = selectionEndOrdinal
    self.userSpecification = userSpecification
    self.sourceBookKey = sourceBookKey
  }

  /**
   Projects output-affecting fields from an execution context.

   `sourceBookKey` falls back to the selected OSIS reference exactly as Android does.
   */
  public init(context: AgentExecutionContext) {
    self.init(
      kjvOrdinalStart: context.kjvOrdinalStart,
      kjvOrdinalEnd: context.kjvOrdinalEnd,
      activeDocumentInitials: context.activeDocumentInitials,
      selectedContent: context.selectedContent,
      selectedText: context.selectedText,
      highlightedText: context.highlightedText,
      selectionStartOffset: context.selectionStartOffset,
      selectionEndOffset: context.selectionEndOffset,
      selectionStartOrdinal: context.selectionStartOrdinal,
      selectionEndOrdinal: context.selectionEndOrdinal,
      userSpecification: context.userSpecification,
      sourceBookKey: context.sourceBookKey ?? context.verseReference
    )
  }

  /**
   Serializes this value byte-for-byte in Android's field order and omission mode.

   - Returns: Compact UTF-8 JSON string.
   - Side effects: none.
   - Throws: String JSON encoding errors, which indicate a platform encoder failure.
   */
  public func canonicalJSON() throws -> String {
    var fields = [
      pair("kjvOrdinalStart", integer: kjvOrdinalStart),
      pair("kjvOrdinalEnd", integer: kjvOrdinalEnd),
      try pair("activeDocumentInitials", string: activeDocumentInitials),
      try pair("selectedContent", string: selectedContent),
      try pair("selectedText", string: selectedText),
      try pair("highlightedText", string: highlightedText),
      pair("selectionStartOffset", integer: selectionStartOffset),
      pair("selectionEndOffset", integer: selectionEndOffset),
    ]
    if let selectionStartOrdinal {
      fields.append("\"selectionStartOrdinal\":\(selectionStartOrdinal)")
    }
    if let selectionEndOrdinal {
      fields.append("\"selectionEndOrdinal\":\(selectionEndOrdinal)")
    }
    if let userSpecification {
      fields.append("\"userSpecification\":\(try jsonString(userSpecification))")
    }
    if let sourceBookKey {
      fields.append("\"sourceBookKey\":\(try jsonString(sourceBookKey))")
    }
    return "{\(fields.joined(separator: ","))}"
  }

  /** Returns Android's 32-character strict cache hash. */
  public func computeHash() throws -> String {
    let digest = SHA256.hash(data: Data(try canonicalJSON().utf8))
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  /** Builds a canonical nullable integer field. */
  private func pair(_ key: String, integer: Int?) -> String {
    "\"\(key)\":\(integer.map(String.init) ?? "null")"
  }

  /** Builds a canonical nullable string field. */
  private func pair(_ key: String, string: String?) throws -> String {
    "\"\(key)\":\(try string.map(jsonString) ?? "null")"
  }

  /** Encodes one JSON string using Foundation without escaping URL slashes. */
  private func jsonString(_ value: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}

/// A fully resolved non-persisted model/provider/credential tuple.
public struct ResolvedLLMModel:
  Sendable,
  Equatable,
  CustomStringConvertible,
  CustomDebugStringConvertible
{
  /// Configured model identity used for usage attribution.
  public let configuredModelId: UUID
  /// Provider configuration identity used for credential lookup.
  public let providerConfigId: UUID
  /// Model identifier sent to the provider.
  public let modelId: String
  /// Provider wire format.
  public let apiFormat: APIFormat
  /// Provider base endpoint.
  public let endpoint: URL
  /// Transient device-only credential; this value must never be persisted or logged.
  public let credential: String
  /// Whether the provider can forward explicit cache breakpoints.
  public let supportsCacheControl: Bool
  /// Provider-specific headers generated once and reused across every iteration in the run.
  public let extraHeaders: [String: String]

  /** Creates an immutable resolved tuple. */
  public init(
    configuredModelId: UUID,
    providerConfigId: UUID,
    modelId: String,
    apiFormat: APIFormat,
    endpoint: URL,
    credential: String,
    supportsCacheControl: Bool = false,
    extraHeaders: [String: String] = [:]
  ) {
    self.configuredModelId = configuredModelId
    self.providerConfigId = providerConfigId
    self.modelId = modelId
    self.apiFormat = apiFormat
    self.endpoint = endpoint
    self.credential = credential
    self.supportsCacheControl = supportsCacheControl
    self.extraHeaders = extraHeaders
  }

  /// Secret-free summary suitable for diagnostics.
  public var description: String {
    "ResolvedLLMModel(configuredModelId: \(configuredModelId), credential: <redacted>)"
  }

  /// Mirrors the secret-free diagnostic summary and never reflects stored fields.
  public var debugDescription: String { description }
}

/// Stable model-resolution failures that contain no credentials.
public enum AIModelResolutionError: Error, Equatable, Sendable {
  /// Neither an explicit valid model nor a valid global default exists.
  case noConfiguredModel
  /// The selected model's provider row was removed.
  case providerNotFound
  /// The provider endpoint is absent or malformed.
  case invalidEndpoint
  /// The provider has no device-local credential.
  case missingCredential
}

/// Resolves prompt model override, stale-ID fallback, global default, provider, endpoint, and Keychain key.
@MainActor
public final class AIModelResolver {
  /// SwiftData settings source.
  private let settingsStore: AISettingsStore
  /// Device-only credential source.
  private let credentialStore: AICredentialStore

  /** Creates a resolver over explicit persistence boundaries. */
  public init(settingsStore: AISettingsStore, credentialStore: AICredentialStore) {
    self.settingsStore = settingsStore
    self.credentialStore = credentialStore
  }

  /**
   Resolves an explicit model, falling back to the global default when it was deleted.

   - Parameter configuredModelId: Prompt or user-selected model identity; `nil` uses the default.
   - Returns: Complete transient execution tuple.
   - Side effects: Reads SwiftData and device-only Keychain state.
   - Throws: Stable resolution errors without model secrets.
   */
  public func resolve(configuredModelId: UUID?) throws -> ResolvedLLMModel {
    let requested = try configuredModelId.flatMap { try settingsStore.model(id: $0) }
    let settings = try settingsStore.globalSettings()
    let configured =
      requested
      ?? settings.defaultModelId.flatMap { try? settingsStore.model(id: $0) }
    guard let configured else { throw AIModelResolutionError.noConfiguredModel }
    guard let provider = try settingsStore.provider(id: configured.providerConfigId) else {
      throw AIModelResolutionError.providerNotFound
    }
    guard let endpoint = provider.resolvedEndpoint else {
      throw AIModelResolutionError.invalidEndpoint
    }
    guard let credential = credentialStore.credential(for: provider.id) else {
      throw AIModelResolutionError.missingCredential
    }
    return ResolvedLLMModel(
      configuredModelId: configured.id,
      providerConfigId: provider.id,
      modelId: configured.modelId,
      apiFormat: provider.apiFormat,
      endpoint: endpoint,
      credential: credential,
      supportsCacheControl: provider.provider.supportsCacheControl,
      extraHeaders: provider.provider == .xAI
        ? ["x-grok-conv-id": UUID().uuidString.lowercased()]
        : [:]
    )
  }
}

/// Global and per-prompt inputs to Android permission precedence.
public struct AgentPermissionSettings: Sendable, Equatable {
  /// Global mode; Android defaults to `alwaysAsk` when the persisted field is `nil`.
  public let globalMode: AIPermissionMode
  /// Global permanent allow set.
  public let permanentlyAllowedTools: Set<AgentTool>
  /// Global permanent deny set.
  public let permanentlyDeniedTools: Set<AgentTool>
  /// Optional per-prompt allow override.
  public let promptAllowedTools: Set<AgentTool>?
  /// Optional per-prompt deny override.
  public let promptDeniedTools: Set<AgentTool>?
  /// Optional per-prompt mode override.
  public let promptMode: AIPermissionMode?

  /** Creates immutable permission inputs. */
  public init(
    globalMode: AIPermissionMode = .alwaysAsk,
    permanentlyAllowedTools: Set<AgentTool> = [],
    permanentlyDeniedTools: Set<AgentTool> = [],
    promptAllowedTools: Set<AgentTool>? = nil,
    promptDeniedTools: Set<AgentTool>? = nil,
    promptMode: AIPermissionMode? = nil
  ) {
    self.globalMode = globalMode
    self.permanentlyAllowedTools = permanentlyAllowedTools
    self.permanentlyDeniedTools = permanentlyDeniedTools
    self.promptAllowedTools = promptAllowedTools
    self.promptDeniedTools = promptDeniedTools
    self.promptMode = promptMode
  }
}

/// Result of pure permission routing before any UI approval request.
public enum AgentPermissionDecision: Equatable, Sendable {
  /// Execute the tool.
  case allowed
  /// Do not execute the tool.
  case denied
  /// Ask the host for an explicit grant.
  case needsApproval
}

/// Pure Android permission precedence shared by every mutating tool.
public enum AgentPermissionPolicy {
  /**
   Decides whether one invocation may execute.

   Global deny is absolute, followed by permanent deny/allow, prompt deny/allow, global allow,
   run grant, then effective prompt/global mode. Read-only invocations bypass write policy.
   */
  public static func decision(
    for tool: AgentTool,
    requiresPermission: Bool,
    settings: AgentPermissionSettings,
    writePermissionGrantedForRun: Bool,
    allToolsGrantedForRun: Bool
  ) -> AgentPermissionDecision {
    guard requiresPermission else { return .allowed }
    if settings.globalMode == .denyAll { return .denied }
    if settings.permanentlyDeniedTools.contains(tool) { return .denied }
    if settings.permanentlyAllowedTools.contains(tool) { return .allowed }
    if settings.promptDeniedTools?.contains(tool) == true { return .denied }
    if settings.promptAllowedTools?.contains(tool) == true { return .allowed }
    if settings.globalMode == .allowAll { return .allowed }
    if allToolsGrantedForRun { return .allowed }

    switch settings.promptMode ?? settings.globalMode {
    case .denyAll: return .denied
    case .allowAll: return .allowed
    case .alwaysAsk, .askOncePerRun:
      return writePermissionGrantedForRun ? .allowed : .needsApproval
    }
  }
}

/// Pure Android tool-visibility precedence used before provider definitions are built.
public enum AgentToolVisibilityPolicy {
  /**
   Computes denied tool definitions while preserving prompt-required and structural tools.

   Prompt availability overrides both global and prompt deny sets. Text transformations expose
   only structural completion tools.
   */
  public static func excludedTools(
    permanentlyDeniedTools: Set<AgentTool>,
    promptDeniedTools: Set<AgentTool>?,
    promptAvailableTools: Set<AgentTool>?,
    isTextTransformation: Bool = false
  ) -> Set<AgentTool> {
    if isTextTransformation {
      return Set(AgentTool.allCases).subtracting(BuiltInPromptCatalog.structuralTools)
    }
    var excluded = permanentlyDeniedTools
    excluded.formUnion(promptDeniedTools ?? [])
    excluded.subtract(promptAvailableTools ?? [])
    excluded.subtract(BuiltInPromptCatalog.structuralTools)
    return excluded
  }
}

/// One host-visible approval request for a concrete tool invocation.
public struct AgentPermissionRequest: Sendable, Equatable {
  /// Tool requesting approval.
  public let tool: AgentTool
  /// Concrete arguments supplied by the model.
  public let arguments: [String: JSONValue]

  /** Creates one immutable approval request. */
  public init(tool: AgentTool, arguments: [String: JSONValue]) {
    self.tool = tool
    self.arguments = arguments
  }
}

/// User or host response to one permission request.
public enum AgentPermissionGrant: Equatable, Sendable {
  /// Reject this invocation.
  case deny
  /// Allow this invocation only.
  case allowOnce
  /// Allow subsequent permission-requiring tools in this run.
  case allowForRun
  /// Allow every subsequent tool in this run.
  case allowAllToolsForRun
  /// Allow this invocation after the host has persisted the tool in the global allow set.
  case allowAlways
}

/// UI-independent approval boundary implemented by an app coordinator.
public protocol AgentPermissionRequesting: Sendable {
  /**
   Asks the user or policy host to approve a concrete tool invocation.

   Implementations returning `.allowAlways` must first persist the tool in
   `GlobalAISettings.permanentlyAllowedTools` and remove it from the permanent deny set.
   */
  func requestPermission(_ request: AgentPermissionRequest) async -> AgentPermissionGrant
}

/// Typed terminal output produced by text or a structural tool.
public enum AgentExecutionOutput: Sendable, Equatable {
  /// Ordinary final assistant text.
  case text(String)
  /// New document content with its accepted title.
  case document(title: String, content: String)
  /// Completion that intentionally creates no document.
  case withoutDocument(message: String)
  /// Completion routed to a StudyPad destination.
  case studyPad(labelId: UUID, scrollToEntryId: UUID?, message: String)
  /// Completion routed to a My Documents page.
  case myDocumentPage(documentInitials: String, pageKey: String, message: String)

  /// User-visible completion text without discarding typed destination metadata.
  public var content: String {
    switch self {
    case .text(let content), .withoutDocument(let content):
      return content
    case .document(_, let content):
      return content
    case .studyPad(_, _, let message), .myDocumentPage(_, _, let message):
      return message
    }
  }
}

/// Typed result returned by an agent tool adapter.
public struct AgentToolResult: Sendable, Equatable {
  /// Successful data nested under Android's `status`/`data` result envelope.
  public let data: JSONValue?
  /// Recoverable domain-error message returned to the model.
  public let errorMessage: String?
  /// Optional stable domain-error code returned to the model.
  public let errorCode: String?
  /// Typed terminal output for structural tool calls.
  public let completion: AgentExecutionOutput?
  /// Pages created by this invocation and available to later permission checks in the run.
  public let createdPageIds: Set<UUID>

  /** Creates a successful typed tool result. */
  public init(
    data: JSONValue,
    completion: AgentExecutionOutput? = nil,
    createdPageIds: Set<UUID> = []
  ) {
    self.data = data
    errorMessage = nil
    errorCode = nil
    self.completion = completion
    self.createdPageIds = createdPageIds
  }

  /** Creates a recoverable failure that is returned to the model without terminating the run. */
  public init(errorMessage: String, errorCode: String? = nil) {
    data = nil
    self.errorMessage = errorMessage
    self.errorCode = errorCode
    completion = nil
    createdPageIds = []
  }

  /// Whether this result represents a recoverable tool failure.
  public var isError: Bool { errorMessage != nil }

  /** Serializes Android's compact deterministic result envelope for conversation history. */
  public func modelContent() throws -> String {
    let payload: JSONValue
    if let errorMessage {
      var object: [String: JSONValue] = [
        "status": .string("error"),
        "message": .string(errorMessage),
      ]
      if let errorCode {
        object["code"] = .string(errorCode)
      }
      payload = .object(object)
    } else {
      payload = .object([
        "status": .string("success"),
        "data": data ?? .null,
      ])
    }
    return String(decoding: try payload.encodedData(), as: UTF8.self)
  }
}

/**
 Host adapter for all concrete Bible, bookmark, label, StudyPad, document, and window tools.

 The typed `AgentTool` argument prevents collapsing the tool surface to one text command. Hosts must
 route every enum case to the corresponding existing service or return a domain error result.
 */
public protocol AgentToolDispatching: Sendable {
  /**
   Returns the semantic description and argument schema for one exact Android tool.

   Hosts must expose the real domain parameters for every case; the core does not substitute an
   empty or text-only schema for missing tool behavior.
   */
  func definition(for tool: AgentTool) -> LLMToolDefinition

  /** Returns whether this exact invocation requires approval. */
  func requiresPermission(
    for tool: AgentTool,
    arguments: [String: JSONValue],
    context: AgentExecutionContext
  ) async throws -> Bool

  /**
   Executes one exact typed tool through its owning service adapter.

   Structural tools return matching typed completion metadata. Page-creation tools report created
   IDs so later calls can apply Android's permission-free editing rule. Recoverable domain errors
   are returned as `AgentToolResult` failures rather than thrown.
   */
  func execute(
    tool: AgentTool,
    arguments: [String: JSONValue],
    context: AgentExecutionContext
  ) async throws -> AgentToolResult
}

/// One registered typed tool contract.
public struct RegisteredAgentTool: Sendable {
  /// Provider-visible function definition.
  public let definition: LLMToolDefinition
  /// Exact invocation permission resolver.
  public let requiresPermission:
    @Sendable ([String: JSONValue], AgentExecutionContext) async throws -> Bool
  /// Exact typed execution closure.
  public let execute:
    @Sendable ([String: JSONValue], AgentExecutionContext) async throws -> AgentToolResult

  /** Creates one executable typed registration. */
  public init(
    definition: LLMToolDefinition,
    requiresPermission:
      @escaping @Sendable ([String: JSONValue], AgentExecutionContext) async throws -> Bool,
    execute:
      @escaping @Sendable ([String: JSONValue], AgentExecutionContext) async throws ->
      AgentToolResult
  ) {
    self.definition = definition
    self.requiresPermission = requiresPermission
    self.execute = execute
  }
}

/// Registry construction and lookup failures.
public enum AgentToolRegistryError: Error, Equatable, Sendable {
  /// More than one registration claimed the same typed tool.
  case duplicate(AgentTool)
  /// Registry omitted one or more Android tools.
  case missing([AgentTool])
  /// A dispatcher returned a definition for a different typed tool.
  case mismatchedDefinition(expected: AgentTool, actual: AgentTool)
  /// A definition omitted its description or object-shaped JSON Schema.
  case invalidDefinition(AgentTool)
  /// A provider call reached a tool absent from the registry.
  case unregistered(AgentTool)
}

/// Immutable registry that requires executable coverage for every Android `AgentTool` case.
public struct AgentToolRegistry: Sendable {
  /// Complete typed registrations keyed by enum identity.
  private let registrations: [AgentTool: RegisteredAgentTool]

  /**
   Creates a registry and rejects duplicate or incomplete coverage.

   - Parameter registrations: Executable typed tool registrations.
   - Throws: Duplicate, missing, or invalid definition failures.
   */
  public init(registrations: [RegisteredAgentTool]) throws {
    var values: [AgentTool: RegisteredAgentTool] = [:]
    for registration in registrations {
      let tool = registration.definition.tool
      guard values[tool] == nil else { throw AgentToolRegistryError.duplicate(tool) }
      guard
        !registration.definition.description
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        registration.definition.parameters["type"] == .string("object"),
        registration.definition.parameters["properties"]?.objectValue != nil
      else {
        throw AgentToolRegistryError.invalidDefinition(tool)
      }
      values[tool] = registration
    }
    let missing = AgentTool.allCases.filter { values[$0] == nil }
    guard missing.isEmpty else { throw AgentToolRegistryError.missing(missing) }
    self.registrations = values
  }

  /**
   Creates complete registrations that preserve definitions and execution for every typed tool.
   */
  public init(dispatcher: any AgentToolDispatching) throws {
    var registrations: [RegisteredAgentTool] = []
    for tool in AgentTool.allCases {
      let definition = dispatcher.definition(for: tool)
      guard definition.tool == tool else {
        throw AgentToolRegistryError.mismatchedDefinition(
          expected: tool,
          actual: definition.tool
        )
      }
      guard !definition.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        definition.parameters["type"] == .string("object"),
        definition.parameters["properties"]?.objectValue != nil
      else {
        throw AgentToolRegistryError.invalidDefinition(tool)
      }
      registrations.append(
        RegisteredAgentTool(
          definition: definition,
          requiresPermission: { arguments, context in
            try await dispatcher.requiresPermission(
              for: tool,
              arguments: arguments,
              context: context
            )
          },
          execute: { arguments, context in
            try await dispatcher.execute(
              tool: tool,
              arguments: arguments,
              context: context
            )
          }
        )
      )
    }
    try self.init(registrations: registrations)
  }

  /** Returns one executable registration or throws instead of silently dropping a tool call. */
  public func registration(for tool: AgentTool) throws -> RegisteredAgentTool {
    guard let registration = registrations[tool] else {
      throw AgentToolRegistryError.unregistered(tool)
    }
    return registration
  }

  /**
   Returns model-visible definitions after applying exclusions.

   Structural completion tools remain visible regardless of exclusions, matching Android.
   */
  public func definitions(excluding excluded: Set<AgentTool> = []) -> [LLMToolDefinition] {
    AgentTool.allCases.compactMap { tool in
      guard !excluded.contains(tool) || BuiltInPromptCatalog.structuralTools.contains(tool) else {
        return nil
      }
      return registrations[tool].map {
        Self.definitionWithTaskCompletion($0.definition)
      }
    }
  }

  /** Adds Android's optional completion signal to every non-structural tool schema. */
  private static func definitionWithTaskCompletion(
    _ definition: LLMToolDefinition
  ) -> LLMToolDefinition {
    guard !BuiltInPromptCatalog.structuralTools.contains(definition.tool),
      case .object(var properties) = definition.parameters["properties"]
    else {
      return definition
    }
    properties["taskComplete"] = .object([
      "type": .string("boolean"),
      "description": .string(
        "Set to true if this tool call completes the entire task and no further actions or document output are needed."
      ),
    ])
    properties["taskCompleteMessage"] = .object([
      "type": .string("string"),
      "description": .string(
        "Brief message confirming what was done (shown to user). Required when taskComplete is true."
      ),
    ])
    var parameters = definition.parameters
    parameters["properties"] = .object(properties)
    return LLMToolDefinition(
      tool: definition.tool,
      description: definition.description,
      parameters: parameters
    )
  }
}

/// Stable failures emitted by the execution coordinator.
public enum AgentExecutionError: Error, Equatable, Sendable {
  /// A provider attempted to invoke a tool excluded from this run.
  case toolUnavailable(AgentTool)
  /// No approval host was supplied for an invocation requiring user consent.
  case approvalUnavailable(AgentTool)
  /// A structural tool returned no compatible typed terminal result.
  case invalidToolResult(AgentTool)
  /// The configured iteration cap was reached before a terminal response.
  case maximumIterationsReached(Int)
}

/// Final output and cumulative usage from one agent run.
public struct AgentExecutionResult: Sendable, Equatable {
  /// Typed text or destination output.
  public let output: AgentExecutionOutput
  /// Usage accumulated across every provider iteration.
  public let usage: LLMUsage
  /// Number of provider calls performed.
  public let iterationCount: Int
  /// Whether at least one successful invocation required write permission.
  public let usedWriteTools: Bool

  /**
   Creates one immutable execution result.

   `usedWriteTools` defaults to false for callers that construct synthetic results. Production
   execution sets it only after a permission-requiring invocation succeeds.
   */
  public init(
    output: AgentExecutionOutput,
    usage: LLMUsage,
    iterationCount: Int,
    usedWriteTools: Bool = false
  ) {
    self.output = output
    self.usage = usage
    self.iterationCount = iterationCount
    self.usedWriteTools = usedWriteTools
  }

  /// User-visible text retained for callers that do not need destination metadata.
  public var content: String { output.content }
}

/// Non-persistent progress events emitted during one agent run.
public enum AgentExecutionProgress: Sendable, Equatable {
  /// Provider model resolution has completed and execution is beginning.
  case started(model: String)
  /// A provider iteration is about to begin.
  case iterationStarted(Int)
  /// One provider call completed with token usage.
  case providerCompleted(iteration: Int, usage: LLMUsage)
  /// A typed tool invocation is about to request permission or execute.
  case toolStarted(iteration: Int, callID: String, tool: AgentTool)
  /// A typed tool invocation produced a success or recoverable error.
  case toolCompleted(iteration: Int, callID: String, tool: AgentTool, isError: Bool)
  /// Provider text was received; it is final only when no tool calls accompanied it.
  case textReceived(iteration: Int, text: String, isFinal: Bool)
  /// The run produced a typed terminal result.
  case completed(AgentExecutionResult)
}

/// UI-independent observer boundary for agent execution progress.
public protocol AgentExecutionProgressReporting: Sendable {
  /** Receives one ordered event without persisting request credentials or message bodies. */
  func report(_ progress: AgentExecutionProgress) async
}

/// UI-independent boundary for extending a capped agent run by one configured iteration block.
public protocol AgentIterationContinuationRequesting: Sendable {
  /**
   Asks whether execution should continue after reaching the current block limit.

   - Parameters:
     - currentIteration: Number of provider calls completed so far.
     - increment: Number of additional calls that approval permits.
   - Returns: `true` to run another block, or `false` to stop with the cap error.
   - Side effects: The conformer may suspend for user input.
   */
  func shouldContinueAfterIterationLimit(
    currentIteration: Int,
    increment: Int
  ) async -> Bool
}

/// Canonical tool identity and arguments retained for Android-compatible loop detection.
struct AgentToolCallSignature: Equatable, Sendable {
  let tool: AgentTool
  let canonicalArguments: String
}

/**
 Produces order-independent signatures for one provider tool-call batch.

 JSON arguments are encoded with recursively sorted keys. Valid provider arguments always encode;
 the fallback remains deterministic and deliberately groups malformed non-JSON values together.
 */
func agentToolCallSignatures(_ calls: [LLMToolCall]) -> [AgentToolCallSignature] {
  calls.map { call in
    let encoded = try? JSONValue.object(call.arguments).encodedData()
    return AgentToolCallSignature(
      tool: call.tool,
      canonicalArguments: encoded.map { String(decoding: $0, as: UTF8.self) }
        ?? "<unencodable>"
    )
  }
}

/**
 Detects Android's repeated-call pattern within the trailing call window.

 A loop exists when one exact tool-and-arguments signature occurs at least three times among the
 last five calls. Threshold and window parameters exist for focused contract tests.
 */
func detectsRepeatedAgentToolCalls(
  _ history: [AgentToolCallSignature],
  threshold: Int = 3,
  windowSize: Int = 5
) -> Bool {
  guard threshold > 0, windowSize > 0, history.count >= threshold else { return false }
  let window = history.suffix(windowSize)
  return window.contains { signature in
    window.lazy.filter { $0 == signature }.prefix(threshold).count == threshold
  }
}

/// Coordinates cancellable model iterations, complete tool dispatch, and Android permission routing.
public struct AgentExecutionCoordinator: Sendable {
  /// Injected network or test completion client.
  private let client: any LLMCompleting
  /// Complete executable tool registry.
  private let registry: AgentToolRegistry
  /// Optional UI-independent approval host.
  private let permissionRequester: (any AgentPermissionRequesting)?
  /// Optional UI-independent progress observer.
  private let progressReporter: (any AgentExecutionProgressReporting)?
  /// Optional user decision boundary invoked after each positive iteration block.
  private let iterationContinuationRequester: (any AgentIterationContinuationRequesting)?
  /// Optional credential-free transcript recorder.
  private let transcriptRecorder: (any AgentExecutionRecording)?

  /// Corrective instruction Android appends after detecting repeated tool calls.
  private static let loopDetectionHint =
    "SYSTEM NOTE: You appear to be repeating the same tool calls without making progress. "
    + "The tool has returned the same results multiple times. Please try a completely different "
    + "approach, use different tools, or complete your response with the information you already have. "
    + "Do not retry the same tool with similar arguments."

  /**
   Creates an execution coordinator over explicit side-effect boundaries.

   - Parameters:
     - client: Cancellable provider transport.
     - registry: Complete typed registry for every Android tool.
     - permissionRequester: Host consent UI or policy bridge; required only when routing asks.
     - progressReporter: Optional ordered, non-persistent progress observer.
     - iterationContinuationRequester: Optional user decision boundary for extending capped runs.
     - transcriptRecorder: Optional bounded recorder for Android-compatible local diagnostics.
   - Side effects: none until `execute` is awaited.
   */
  public init(
    client: any LLMCompleting,
    registry: AgentToolRegistry,
    permissionRequester: (any AgentPermissionRequesting)? = nil,
    progressReporter: (any AgentExecutionProgressReporting)? = nil,
    iterationContinuationRequester: (any AgentIterationContinuationRequesting)? = nil,
    transcriptRecorder: (any AgentExecutionRecording)? = nil
  ) {
    self.client = client
    self.registry = registry
    self.permissionRequester = permissionRequester
    self.progressReporter = progressReporter
    self.iterationContinuationRequester = iterationContinuationRequester
    self.transcriptRecorder = transcriptRecorder
  }

  /**
   Executes an agent until it returns text, signals task completion, is cancelled, or reaches its cap.

   - Parameters:
     - model: Resolved provider/model/credential tuple.
     - messages: Initial system and user conversation; regeneration fields are appended once.
     - context: Typed host context supplied to every tool.
     - permissionSettings: Global and prompt permission precedence inputs.
     - excludedTools: Tools hidden from the model; structural tools remain available.
     - maximumIterations: Android block size; non-positive values mean unlimited.
     - temperature: Optional provider sampling value.
     - extraHeaders: Provider-specific non-authentication headers.
   - Returns: Final text, cumulative usage, and provider call count.
   - Side effects: Performs network calls, reports progress, requests user permission, and
     dispatches registered tools.
   - Throws: Cancellation, client, registry, tool, permission, or iteration-cap failures.
   */
  public func execute(
    model: ResolvedLLMModel,
    messages: [LLMMessage],
    context: AgentExecutionContext,
    permissionSettings: AgentPermissionSettings,
    excludedTools: Set<AgentTool> = [],
    maximumIterations: Int = 10,
    temperature: Double? = 0.3,
    extraHeaders: [String: String] = [:]
  ) async throws -> AgentExecutionResult {
    var conversation = AgentMessageComposer.applyingRegenerationContext(
      to: messages,
      context: context
    )
    var currentContext = context
    var iteration = 0
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cacheCreationTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var pendingDocumentTitle: String?
    var writePermissionGrantedForRun = false
    var allToolsGrantedForRun = false
    var usedWriteTools = false
    var toolCallHistory: [AgentToolCallSignature] = []
    let iterationIncrement = maximumIterations > 0 ? maximumIterations : nil
    var iterationLimit = iterationIncrement
    let definitions = registry.definitions(excluding: excludedTools)
    let requestHeaders = model.extraHeaders.merging(extraHeaders) { _, supplied in supplied }
    await transcriptRecorder?.recordPrepared(
      messages: conversation,
      toolDefinitions: definitions
    )
    await progressReporter?.report(.started(model: model.modelId))

    while true {
      while iterationLimit.map({ iteration < $0 }) ?? true {
        try Task.checkCancellation()
        iteration += 1
        await progressReporter?.report(.iterationStarted(iteration))
        let request = LLMCompletionRequest(
          endpoint: model.endpoint,
          credential: model.credential,
          apiFormat: model.apiFormat,
          model: model.modelId,
          messages: conversation,
          tools: definitions,
          temperature: temperature,
          extraHeaders: requestHeaders,
          supportsCacheControl: model.supportsCacheControl
        )
        let completion = try await complete(request, iteration: iteration)
        try Task.checkCancellation()
        inputTokens += completion.usage.inputTokens
        outputTokens += completion.usage.outputTokens
        cacheCreationTokens += completion.usage.cacheCreationTokens
        cacheReadTokens += completion.usage.cacheReadTokens
        await transcriptRecorder?.recordProviderUsage(
          iteration: iteration,
          usage: completion.usage
        )
        await progressReporter?.report(
          .providerCompleted(iteration: iteration, usage: completion.usage)
        )

        if completion.toolCalls.isEmpty {
          let content = completion.content ?? ""
          await progressReporter?.report(
            .textReceived(iteration: iteration, text: content, isFinal: true)
          )
          let output: AgentExecutionOutput =
            pendingDocumentTitle.map {
              .document(title: $0, content: content)
            } ?? .text(content)
          let result = AgentExecutionResult(
            output: output,
            usage: LLMUsage(
              inputTokens: inputTokens,
              outputTokens: outputTokens,
              cacheCreationTokens: cacheCreationTokens,
              cacheReadTokens: cacheReadTokens
            ),
            iterationCount: iteration,
            usedWriteTools: usedWriteTools
          )
          await progressReporter?.report(.completed(result))
          return result
        }

        toolCallHistory.append(contentsOf: agentToolCallSignatures(completion.toolCalls))
        let loopDetected = detectsRepeatedAgentToolCalls(toolCallHistory)

        if let content = completion.content, !content.isEmpty {
          await progressReporter?.report(
            .textReceived(iteration: iteration, text: content, isFinal: false)
          )
        }

        conversation.append(
          LLMMessage(role: .assistant, content: completion.content, toolCalls: completion.toolCalls)
        )
        var terminalOutput: AgentExecutionOutput?
        for (callIndex, call) in completion.toolCalls.enumerated() {
          try Task.checkCancellation()
          await transcriptRecorder?.recordToolCall(iteration: iteration, call: call)
          await progressReporter?.report(
            .toolStarted(iteration: iteration, callID: call.id, tool: call.tool)
          )
          guard
            !excludedTools.contains(call.tool)
              || BuiltInPromptCatalog.structuralTools.contains(call.tool)
          else {
            throw AgentExecutionError.toolUnavailable(call.tool)
          }
          let registration = try registry.registration(for: call.tool)
          let requiresPermission = try await registration.requiresPermission(
            call.arguments,
            currentContext
          )
          var decision = AgentPermissionPolicy.decision(
            for: call.tool,
            requiresPermission: requiresPermission,
            settings: permissionSettings,
            writePermissionGrantedForRun: writePermissionGrantedForRun,
            allToolsGrantedForRun: allToolsGrantedForRun
          )
          if decision == .needsApproval {
            guard let permissionRequester else {
              throw AgentExecutionError.approvalUnavailable(call.tool)
            }
            switch await permissionRequester.requestPermission(
              AgentPermissionRequest(tool: call.tool, arguments: call.arguments)
            ) {
            case .deny:
              decision = .denied
            case .allowOnce:
              decision = .allowed
            case .allowForRun:
              writePermissionGrantedForRun = true
              decision = .allowed
            case .allowAllToolsForRun:
              writePermissionGrantedForRun = true
              allToolsGrantedForRun = true
              decision = .allowed
            case .allowAlways:
              decision = .allowed
            }
          }
          try Task.checkCancellation()

          let result: AgentToolResult
          if decision == .allowed {
            do {
              result = try await registration.execute(call.arguments, currentContext)
            } catch is CancellationError {
              throw CancellationError()
            } catch {
              result = AgentToolResult(
                errorMessage: "Tool execution failed.",
                errorCode: "EXECUTION_ERROR"
              )
            }
          } else {
            result = AgentToolResult(
              errorMessage: "Permission denied for \(call.tool.wireName).",
              errorCode: "PERMISSION_DENIED"
            )
          }
          try Task.checkCancellation()

          if !result.isError {
            currentContext.createdPageIds.formUnion(result.createdPageIds)
            if requiresPermission {
              usedWriteTools = true
            }
            if requiresPermission,
              (permissionSettings.promptMode ?? permissionSettings.globalMode) != .alwaysAsk
            {
              writePermissionGrantedForRun = true
            }
            guard Self.isValid(result.completion, for: call.tool) else {
              throw AgentExecutionError.invalidToolResult(call.tool)
            }
          }
          let resultContent = try result.modelContent()
          await transcriptRecorder?.recordToolResult(
            iteration: iteration,
            callID: call.id,
            result: resultContent
          )
          let providerResult =
            loopDetected && callIndex == completion.toolCalls.count - 1
            ? resultContent + "\n\n" + Self.loopDetectionHint
            : resultContent
          conversation.append(
            LLMMessage(role: .tool, content: providerResult, toolCallId: call.id)
          )
          await progressReporter?.report(
            .toolCompleted(
              iteration: iteration,
              callID: call.id,
              tool: call.tool,
              isError: result.isError
            )
          )

          if !result.isError, terminalOutput == nil {
            if let output = result.completion {
              terminalOutput = output
            } else if call.tool == .setDocumentTitle,
              let title = result.data?.objectValue?["title"]?.stringValue
            {
              if let content = completion.content, !content.isEmpty {
                terminalOutput = .document(title: title, content: content)
              } else {
                pendingDocumentTitle = title
              }
            } else if call.arguments["taskComplete"] == .bool(true) {
              let requestedMessage = call.arguments["taskCompleteMessage"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
              terminalOutput = .withoutDocument(
                message: requestedMessage.flatMap { $0.isEmpty ? nil : $0 }
                  ?? completion.content
                  ?? "Task completed."
              )
            }
          }
        }
        if let terminalOutput {
          let result = AgentExecutionResult(
            output: terminalOutput,
            usage: LLMUsage(
              inputTokens: inputTokens,
              outputTokens: outputTokens,
              cacheCreationTokens: cacheCreationTokens,
              cacheReadTokens: cacheReadTokens
            ),
            iterationCount: iteration,
            usedWriteTools: usedWriteTools
          )
          await progressReporter?.report(.completed(result))
          return result
        }
        if loopDetected {
          toolCallHistory.removeAll(keepingCapacity: true)
        }
      }

      guard let iterationIncrement,
        let iterationContinuationRequester,
        await iterationContinuationRequester.shouldContinueAfterIterationLimit(
          currentIteration: iteration,
          increment: iterationIncrement
        )
      else {
        throw AgentExecutionError.maximumIterationsReached(iteration)
      }
      let nextLimit = iteration.addingReportingOverflow(iterationIncrement)
      iterationLimit = nextLimit.overflow ? nil : nextLimit.partialValue
    }
  }

  /** Performs one provider call while attaching a run-scoped transport transcript reporter. */
  private func complete(
    _ request: LLMCompletionRequest,
    iteration: Int
  ) async throws -> LLMCompletion {
    guard let transcriptRecorder else {
      return try await client.complete(request)
    }
    if let reportingClient = client as? any LLMTransportTranscriptCompleting {
      return try await reportingClient.complete(
        request,
        transcriptReporter: LLMTransportTranscriptReporter { event in
          await transcriptRecorder.recordTransportEvent(
            iteration: iteration,
            event: event
          )
        }
      )
    }
    do {
      return try await client.complete(request)
    } catch is CancellationError {
      await transcriptRecorder.recordTransportEvent(
        iteration: iteration,
        event: .failure("ERROR: Cancelled")
      )
      throw CancellationError()
    } catch {
      await transcriptRecorder.recordTransportEvent(
        iteration: iteration,
        event: .failure("ERROR: Provider call failed")
      )
      throw error
    }
  }

  /** Validates typed terminal output against Android structural-tool semantics. */
  private static func isValid(
    _ output: AgentExecutionOutput?,
    for tool: AgentTool
  ) -> Bool {
    switch (tool, output) {
    case (.finishWithoutDocument, .withoutDocument):
      return true
    case (.finishWithStudyPad, .studyPad):
      return true
    case (.finishWithMyDocumentPage, .myDocumentPage):
      return true
    case (.setDocumentTitle, .document), (.setDocumentTitle, .withoutDocument),
      (.setDocumentTitle, nil):
      return true
    case (_, nil):
      return !BuiltInPromptCatalog.structuralTools.contains(tool)
    default:
      return false
    }
  }
}
