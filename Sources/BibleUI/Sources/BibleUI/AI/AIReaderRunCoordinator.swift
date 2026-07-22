// AIReaderRunCoordinator.swift -- Android-compatible reader AI execution lifecycle

import BibleCore
import BibleView
import Foundation
import Observation
import SwiftData
import SwordKit

/// One configured model displayed before an Android-compatible AI run.
struct AIReaderModelChoice: Identifiable, Equatable {
  let id: UUID
  let title: String
  let isDefault: Bool
}

/// One bounded, credential-free line in the native agent activity view.
struct AIReaderRunLogEntry: Identifiable, Equatable {
  enum Kind: Equatable {
    case information
    case action
    case response
    case failure
  }

  let id: UUID
  let kind: Kind
  let message: String

  init(kind: Kind, message: String) {
    id = UUID()
    self.kind = kind
    self.message = String(message.prefix(500))
  }
}

/// Concrete write request suspended while the user chooses an Android permission grant.
struct AIReaderPendingPermission: Identifiable, Equatable {
  let id: UUID
  let request: AgentPermissionRequest
  let toolTitle: String
  let toolDescription: String
  let actionDescription: String?
}

/// One capped run suspended while the user decides whether another iteration block should run.
struct AIReaderPendingIterationContinuation: Identifiable, Equatable {
  let id: UUID
  let currentIteration: Int
  let increment: Int
}

/// Native presentation routes owned by one pane's AI coordinator.
enum AIReaderPresentationRoute: Identifiable {
  case promptChooser(UUID)
  case promptPreparation(UUID)
  case run(UUID)
  case regeneration(UUID)
  case documentChooser(UUID)
  case promptEditor(UUID, promptID: UUID)

  var id: UUID {
    switch self {
    case .promptChooser(let id), .promptPreparation(let id), .run(let id),
      .regeneration(let id), .documentChooser(let id), .promptEditor(let id, _):
      return id
    }
  }
}

/// Stable reader-level failures that never reflect credentials, provider bodies, or raw prompts.
enum AIReaderRunError: Error, LocalizedError, Equatable {
  case noWorkspace
  case runAlreadyActive
  case promptUnavailable
  case noPromptActions
  case modelUnavailable
  case missingCredential
  case invalidProviderConfiguration
  case sourceUnavailable
  case emptyTransformation
  case textTargetChanged
  case persistenceFailed
  case maximumIterationsReached(Int)
  case executionFailed

  var errorDescription: String? {
    switch self {
    case .noWorkspace:
      return String(localized: "llm_error_unknown", defaultValue: "Unknown error")
    case .runAlreadyActive:
      return String(
        localized: "agent_already_running",
        defaultValue: "An AI agent is already running. Please wait or stop it first."
      )
    case .promptUnavailable:
      return String(
        localized: "ai_regenerate_prompt_not_found",
        defaultValue:
          "Cannot regenerate: the original prompt was not found. It may have been deleted."
      )
    case .noPromptActions:
      return String(localized: "llm_error_unknown", defaultValue: "Unknown error")
    case .modelUnavailable:
      return String(
        localized: "agent_log_model_not_configured", defaultValue: "No model configured")
    case .missingCredential:
      return String(localized: "ai_provider_api_key_not_set", defaultValue: "API key not set")
    case .invalidProviderConfiguration:
      return String(localized: "llm_error_unknown", defaultValue: "Unknown error")
    case .sourceUnavailable:
      return String(localized: "error_no_content", defaultValue: "No content for selected verse")
    case .emptyTransformation:
      return String(localized: "llm_error_unknown", defaultValue: "Unknown error")
    case .textTargetChanged:
      return String(localized: "error_occurred", defaultValue: "An error has occurred")
    case .persistenceFailed:
      return String(localized: "error_occurred", defaultValue: "An error has occurred")
    case .maximumIterationsReached(let count):
      return String(
        format: String(
          localized: "llm_error_max_iterations",
          defaultValue: "Maximum iterations (%1$d) reached without completion"
        ),
        count
      )
    case .executionFailed:
      return String(localized: "error_occurred", defaultValue: "An error has occurred")
    }
  }
}

/** Process-wide workspace gate matching Android's one active agent session per workspace. */
actor AIReaderWorkspaceRunGate {
  static let shared = AIReaderWorkspaceRunGate()

  private var runsByWorkspace: [UUID: UUID] = [:]

  /// Claims a workspace only when no other run owns it.
  func acquire(workspaceID: UUID, runID: UUID) -> Bool {
    guard runsByWorkspace[workspaceID] == nil else { return false }
    runsByWorkspace[workspaceID] = runID
    return true
  }

  /// Releases only the matching run so a stale completion cannot clear a newer owner.
  func release(workspaceID: UUID, runID: UUID) {
    guard runsByWorkspace[workspaceID] == runID else { return }
    runsByWorkspace.removeValue(forKey: workspaceID)
  }
}

/// Sendable permission boundary that forwards one request to the main-actor coordinator.
private struct AIReaderPermissionRequester: AgentPermissionRequesting {
  let operation: @Sendable (AgentPermissionRequest) async -> AgentPermissionGrant

  func requestPermission(_ request: AgentPermissionRequest) async -> AgentPermissionGrant {
    await operation(request)
  }
}

/// Sendable progress boundary that forwards ordered events to the main-actor coordinator.
private struct AIReaderProgressReporter: AgentExecutionProgressReporting {
  let operation: @Sendable (AgentExecutionProgress) async -> Void

  func report(_ progress: AgentExecutionProgress) async {
    await operation(progress)
  }
}

/// Sendable iteration boundary that forwards one cap decision to the main-actor coordinator.
private struct AIReaderIterationContinuationRequester: AgentIterationContinuationRequesting {
  let operation: @Sendable (Int, Int) async -> Bool

  func shouldContinueAfterIterationLimit(
    currentIteration: Int,
    increment: Int
  ) async -> Bool {
    await operation(currentIteration, increment)
  }
}

/// Immutable inputs retained for one prompt launch or page regeneration.
private struct AIReaderRunLaunch {
  let entry: ResolvedAgentPrompt
  let request: AIReaderActionRequest
  let userSpecification: String?
  let previousResponse: String?
  let additionalInstructions: String?
  let modelOverrideID: UUID?
  let skipCache: Bool
  let regeneration: AIReaderRegenerationLaunch?
}

/// Regeneration inputs retained until a reader-visible transient document is presented.
private struct AIReaderRegenerationLaunch {
  /// Existing successful generated page used for source context and previous response.
  let sourcePageID: UUID
  /// Whether successful completion removes the prior generated page.
  let replacesSourcePage: Bool
}

/// Immutable execution inputs prepared before any pane-visible running state is published.
private struct AIReaderPreparedRun {
  /// Original prompt launch contract.
  let launch: AIReaderRunLaunch
  /// Provider/tool context composed before cache lookup.
  let context: AgentExecutionContext
  /// Stable cache projection of the provider/tool context.
  let cacheContext: CacheableContext
  /// Validated regeneration state, absent for ordinary prompt launches.
  let regeneration: AIReaderPreparedRegeneration?
}

/// Validated source and replacement policy for one active regeneration.
private struct AIReaderPreparedRegeneration {
  /// Prior successful page that owns the regeneration context and target collection.
  let sourcePageID: UUID
  /// Whether the prior successful page is removed after final content commits.
  let replacesSourcePage: Bool
}

/// Reader-local AI document state that must never enter My Documents persistence or remote sync.
struct AIReaderTransientDocument: Equatable {
  enum Severity: Equatable {
    case normal
    case error
  }

  let message: String
  let severity: Severity
}

/// Result of Android-ordered cache and local-pane preflight evaluation.
enum AIReaderRunPreflightDecision: Equatable {
  /// A matching page should open without showing the activity surface or checking local run state.
  case openCachedPage(AIGeneratedPageLocation)
  /// No cache hit exists and the pane can begin execution.
  case beginExecution
  /// No cache hit exists but this pane already owns an active run.
  case localRunAlreadyActive
}

/**
 Evaluates cache reuse before consulting pane-local execution state, matching Android.

 Android builds the cache context and calls `findCachedPage` before `getOrCreateSession` and its
 `isRunning` check. Keeping that order allows a cache hit to navigate immediately even while a
 local activity surface exists, and prevents a hit from flashing a running sheet.
 */
enum AIReaderRunPreflight {
  /**
   Resolves one launch disposition with observable dependency ordering.

   - Parameters:
     - skipCache: True for regeneration, where Android always executes a fresh request.
     - cachedPage: Cache lookup closure; not called when cache is skipped.
     - isLocalRunActive: Pane-state closure evaluated only after a cache miss/skip.
   - Returns: Cached navigation, execution, or local-run rejection.
   - Side effects: Invokes the supplied closures in the documented order.
   - Throws: Propagates cache persistence/context failures without consulting pane state.
   - Note: The synchronous contract keeps SwiftData cache lookup on the coordinator's main actor.
   */
  static func decide(
    skipCache: Bool,
    cachedPage: () throws -> AIGeneratedPageLocation?,
    isLocalRunActive: () -> Bool
  ) throws -> AIReaderRunPreflightDecision {
    if !skipCache, let page = try cachedPage() {
      return .openCachedPage(page)
    }
    return isLocalRunActive() ? .localRunAlreadyActive : .beginExecution
  }
}

/** Builds one run's provider messages from the live Android reference environment. */
enum AIReaderRunMessageAssembler {
  /**
   Invokes the host-owned environment provider and forwards every resolved field to composition.

   - Parameters:
     - prompt: Effective prompt and tool policy.
     - context: Immutable reader context captured for this run.
     - appLanguage: Android-compatible AI display language.
     - agentSystemPrompt: Effective ordinary-agent system prompt.
     - transformationSystemPrompt: Effective text-transformation system prompt.
     - installedDocuments: Optional serialized installed-document prefetch.
     - commentaryEntries: Optional serialized commentary prefetch.
     - referenceEnvironmentProvider: Main-actor resolver for live search and dictionary defaults.
   - Returns: Exactly the provider messages produced by `AIReaderMessageComposer`.
   - Side effects: Invokes `referenceEnvironmentProvider` once per message assembly.
   - Failure modes: None; unavailable reference defaults remain absent from the system message.
   */
  @MainActor
  static func messages(
    prompt: AgentPrompt,
    context: AgentExecutionContext,
    appLanguage: String,
    agentSystemPrompt: String,
    transformationSystemPrompt: String,
    installedDocuments: String?,
    commentaryEntries: String?,
    referenceEnvironmentProvider: @MainActor () ->
      AIReaderReferenceEnvironmentResolver.Environment
  ) -> [LLMMessage] {
    let environment = referenceEnvironmentProvider()
    return AIReaderMessageComposer.messages(
      AIReaderMessageComposer.Input(
        prompt: prompt,
        context: context,
        appLanguage: appLanguage,
        agentSystemPrompt: agentSystemPrompt,
        transformationSystemPrompt: transformationSystemPrompt,
        installedDocuments: installedDocuments,
        commentaryEntries: commentaryEntries,
        defaultSearchBible: environment.defaultSearchBible,
        preferredStrongsHebrew: environment.preferredStrongsHebrew,
        preferredStrongsGreek: environment.preferredStrongsGreek,
        preferredGreekMorphology: environment.preferredGreekMorphology
      )
    )
  }
}

/** Mirrors Android's model-picker default-selection availability for every prompt source. */
enum AIReaderPromptModelSelectionPolicy {
  /**
   Returns whether the picker may offer to persist its selected model for a prompt source.

   Repository persistence remains source-aware. The coordinator must expose the option for SWORD
   add-ons because Android does; `PromptRepository` owns whether and how that override is stored.

   - Parameter origin: Effective prompt ownership resolved by `PromptRepository`.
   - Returns: `true` for built-in, SWORD add-on, and user prompts.
   - Side effects: None.
   - Failure modes: None; persistence errors are handled when the user starts the run.
   */
  static func allowsPersistingSelection(for origin: PromptOrigin) -> Bool {
    switch origin {
    case .builtIn, .swordPack, .user:
      return true
    }
  }
}

/**
 Owns prompt selection, execution, permission suspension, cache routing, and terminal output.

 The coordinator is pane-scoped for presentation but uses a process-wide workspace gate. Every
 terminal mutation checks the active run identity, preventing a cancelled or superseded task from
 saving a page, replacing note text, or navigating a reader after its result became stale.
 */
@MainActor
@Observable
final class AIReaderRunCoordinator {
  private static let maximumLogEntries = 250

  var presentation: AIReaderPresentationRoute?
  private(set) var promptGroups: [AIReaderPromptGroup] = []
  private(set) var modelChoices: [AIReaderModelChoice] = []
  private(set) var selectedPrompt: ResolvedAgentPrompt?
  private(set) var promptRequiresSpecification = false
  private(set) var promptRequiresModel = false
  private(set) var canPersistPromptModel = false
  var userSpecification = ""
  var selectedModelID: UUID?
  var persistSelectedModel = false

  private(set) var runTitle = ""
  private(set) var runLog: [AIReaderRunLogEntry] = []
  private(set) var isRunning = false
  private(set) var runCompleted = false
  private(set) var pendingPermission: AIReaderPendingPermission?
  private(set) var pendingIterationContinuation: AIReaderPendingIterationContinuation?
  private(set) var failureMessage: String?

  private(set) var regenerationContext: MyDocumentAIPageActionContext?
  var regenerationInstructions = ""
  var regenerationKeepsPrevious = false
  var regenerationIsFresh = false
  var regenerationModelID: UUID?
  private(set) var regenerationRequiresModel = false

  private(set) var documentMarkers: [AIDocumentPageMarker] = []
  private(set) var promptEditorID: UUID?

  private let settingsStore: AISettingsStore
  private let modelContext: ModelContext
  private let promptRepository: PromptRepository
  private let modelResolver: AIModelResolver
  private let client: any LLMCompleting
  private let domain: any BibleUIAgentToolExecuting
  private let generatedPageStore: AIGeneratedPageStore
  private let textTargetStore: AITextTargetStore
  private let myDocumentStore: MyDocumentStore
  private let runGate: AIReaderWorkspaceRunGate
  private let referenceEnvironmentProvider:
    @MainActor () -> AIReaderReferenceEnvironmentResolver.Environment
  private let isInstalledBible: (String) -> Bool
  private let openMyDocument: (String, String) -> Void
  private let openStudyPad: (UUID, UUID?) -> Void
  private let showTransientDocument: (AIReaderTransientDocument) -> Void
  private let showToast: (String) -> Void

  @ObservationIgnored private var actionRequest: AIReaderActionRequest?
  @ObservationIgnored private var regenerationWorkspaceID: UUID?
  @ObservationIgnored private var regenerationWindowID: UUID?
  @ObservationIgnored private var activeRunID: UUID?
  @ObservationIgnored private var activeTask: Task<Void, Never>?
  @ObservationIgnored private var permissionContinuation:
    CheckedContinuation<AgentPermissionGrant, Never>?
  @ObservationIgnored private var iterationContinuation: CheckedContinuation<Bool, Never>?
  @ObservationIgnored private var runTelemetryService: LLMRunTelemetryService?

  /**
   Creates one pane coordinator over explicit app-domain and presentation boundaries.

   - Parameters:
     - modelContext: Main-actor SwiftData context owning AI settings and My Documents.
     - swordManager: Installed SWORD source used by prompt-pack discovery.
     - domain: Typed Android-compatible tool execution boundary.
     - myDocumentStore: Existing My Documents query and regeneration source store.
     - textTargetBacking: Host backing for note and text-transformation targets.
     - client: Provider-neutral LLM completion client.
     - credentialStore: Credential lookup boundary used by model resolution.
     - runGate: Process-wide workspace execution gate.
     - referenceEnvironmentProvider: Live search-Bible and reference-dictionary defaults. The empty
       default keeps construction testable until the pane injects installed-module state.
     - isInstalledBible: Exact installed-Bible predicate used by regeneration validation.
     - openMyDocument: Reader navigation boundary for generated My Documents pages.
     - openStudyPad: Reader navigation boundary for generated StudyPad results.
     - showTransientDocument: Reader-local loading and terminal state presentation.
     - showToast: Credential-free transient failure and completion presentation.
   - Side effects: Retains services only; no prompt, Keychain, database, or network access occurs.
   - Failure modes: Registry construction is deferred to a run and appears as a safe execution
     failure if the complete tool contract is unavailable.
   */
  init(
    modelContext: ModelContext,
    swordManager: SwordManager,
    domain: any BibleUIAgentToolExecuting,
    myDocumentStore: MyDocumentStore,
    textTargetBacking: any AITextTargetBacking,
    client: any LLMCompleting = LLMHTTPClient(),
    credentialStore: AICredentialStore = .keychain(),
    runGate: AIReaderWorkspaceRunGate = .shared,
    referenceEnvironmentProvider: @escaping @MainActor () ->
      AIReaderReferenceEnvironmentResolver.Environment = {
        AIReaderReferenceEnvironmentResolver.Environment(
          defaultSearchBible: nil,
          preferredStrongsHebrew: nil,
          preferredStrongsGreek: nil,
          preferredGreekMorphology: nil
        )
      },
    isInstalledBible: @escaping (String) -> Bool,
    openMyDocument: @escaping (String, String) -> Void,
    openStudyPad: @escaping (UUID, UUID?) -> Void,
    showTransientDocument: @escaping (AIReaderTransientDocument) -> Void,
    showToast: @escaping (String) -> Void
  ) {
    let settingsStore = AISettingsStore(modelContext: modelContext)
    self.settingsStore = settingsStore
    self.modelContext = modelContext
    promptRepository = PromptRepository(
      settingsStore: settingsStore,
      packProvider: SwordPromptPackProvider(swordManager: swordManager)
    )
    modelResolver = AIModelResolver(
      settingsStore: settingsStore,
      credentialStore: credentialStore
    )
    self.client = client
    self.domain = domain
    generatedPageStore = AIGeneratedPageStore(modelContext: modelContext)
    textTargetStore = AITextTargetStore(backing: textTargetBacking)
    self.myDocumentStore = myDocumentStore
    self.runGate = runGate
    self.referenceEnvironmentProvider = referenceEnvironmentProvider
    self.isInstalledBible = isInstalledBible
    self.openMyDocument = openMyDocument
    self.openStudyPad = openStudyPad
    self.showTransientDocument = showTransientDocument
    self.showToast = showToast
  }

  /** Loads and presents every action valid for the captured reader context. */
  func presentActions(for request: AIReaderActionRequest) {
    do {
      let entries = try promptRepository.allPrompts()
      let categories = try promptRepository.allCategories()
      let settings = try settingsStore.globalSettings()
      let groups = AIReaderPromptCatalog.groups(
        entries: entries,
        categories: categories,
        favoriteIDs: settings.favoritePrompts,
        hiddenCategoryIDs: settings.hiddenBuiltInCategories,
        context: request.promptContext,
        documentCategory: request.documentCategory
      )
      guard !groups.isEmpty else { throw AIReaderRunError.noPromptActions }
      actionRequest = request
      promptGroups = groups
      failureMessage = nil
      presentation = .promptChooser(UUID())
    } catch {
      presentFailure(error)
    }
  }

  /** Selects an action and either starts it or presents its required pre-run inputs. */
  func selectPrompt(_ entry: ResolvedAgentPrompt) {
    guard actionRequest != nil else {
      presentFailure(AIReaderRunError.sourceUnavailable)
      return
    }
    do {
      let settings = try settingsStore.globalSettings()
      selectedPrompt = entry
      promptRequiresSpecification = entry.prompt.specifyBeforeRun
      promptRequiresModel = settings.askModelBeforeRun && entry.prompt.configuredModelId == nil
      canPersistPromptModel = AIReaderPromptModelSelectionPolicy.allowsPersistingSelection(
        for: entry.origin
      )
      modelChoices = try configuredModelChoices(defaultID: settings.defaultModelId)
      userSpecification = ""
      selectedModelID =
        promptRequiresModel ? settings.defaultModelId ?? modelChoices.first?.id : nil
      persistSelectedModel = false

      if promptRequiresSpecification || promptRequiresModel {
        presentation = .promptPreparation(UUID())
      } else {
        startSelectedPrompt()
      }
    } catch {
      presentFailure(error)
    }
  }

  /** Starts the prepared prompt after validating Android's specification and model requirements. */
  func startSelectedPrompt() {
    guard let entry = selectedPrompt, let request = actionRequest else {
      presentFailure(AIReaderRunError.promptUnavailable)
      return
    }
    let specification = userSpecification.trimmingCharacters(in: .whitespacesAndNewlines)
    if promptRequiresSpecification && specification.isEmpty { return }
    if promptRequiresModel && selectedModelID == nil {
      presentFailure(AIReaderRunError.modelUnavailable)
      return
    }

    do {
      if persistSelectedModel, canPersistPromptModel, let selectedModelID {
        try promptRepository.setConfiguredModel(
          promptID: entry.prompt.id,
          modelID: selectedModelID
        )
      }
    } catch {
      presentFailure(error)
      return
    }

    start(
      AIReaderRunLaunch(
        entry: entry,
        request: request,
        userSpecification: specification.isEmpty ? nil : specification,
        previousResponse: nil,
        additionalInstructions: nil,
        modelOverrideID: selectedModelID,
        skipCache: false,
        regeneration: nil
      )
    )
  }

  /** Presents Android's regenerate options for one validated generated page. */
  func presentRegeneration(
    _ context: MyDocumentAIPageActionContext,
    workspaceID: UUID?,
    windowID: UUID?
  ) {
    do {
      guard try promptRepository.entryById(context.sourcePromptId) != nil else {
        throw AIReaderRunError.promptUnavailable
      }
      let settings = try settingsStore.globalSettings()
      let prompt = try promptRepository.promptById(context.sourcePromptId)
      modelChoices = try configuredModelChoices(defaultID: settings.defaultModelId)
      regenerationContext = context
      regenerationWorkspaceID = workspaceID
      regenerationWindowID = windowID
      regenerationInstructions = ""
      regenerationKeepsPrevious = false
      regenerationIsFresh = false
      regenerationRequiresModel = settings.askModelBeforeRun && prompt?.configuredModelId == nil
      regenerationModelID =
        regenerationRequiresModel
        ? settings.defaultModelId ?? modelChoices.first?.id
        : nil
      failureMessage = nil
      presentation = .regeneration(UUID())
    } catch {
      presentFailure(error)
    }
  }

  /** Reconstructs persisted cache context and starts a cache-bypassing regeneration. */
  func startRegeneration() {
    guard let pageContext = regenerationContext else {
      presentFailure(AIReaderRunError.sourceUnavailable)
      return
    }
    if regenerationRequiresModel && regenerationModelID == nil {
      presentFailure(AIReaderRunError.modelUnavailable)
      return
    }

    do {
      guard let entry = try promptRepository.entryById(pageContext.sourcePromptId) else {
        throw AIReaderRunError.promptUnavailable
      }
      guard let sourceJSON = pageContext.sourceContext,
        let sourceData = sourceJSON.data(using: .utf8),
        let source = try? JSONDecoder().decode(CacheableContext.self, from: sourceData),
        let startOrdinal = pageContext.kjvOrdinalStart ?? source.kjvOrdinalStart,
        let endOrdinal = pageContext.kjvOrdinalEnd ?? source.kjvOrdinalEnd,
        JSwordKJVAVersification.verseReference(ordinal: startOrdinal) != nil,
        JSwordKJVAVersification.verseReference(ordinal: endOrdinal) != nil
      else {
        throw AIReaderRunError.sourceUnavailable
      }
      guard
        let sourceInitials = source.activeDocumentInitials
          ?? pageContext.sourceBookInitials,
        isInstalledBible(sourceInitials)
      else {
        throw AIReaderRunError.sourceUnavailable
      }
      let page = myDocumentStore.page(pageId: pageContext.pageId)
      let previous = regenerationIsFresh ? nil : page?.pageContent?.content
      let request = AIReaderActionRequest(
        promptContext: .verseSelection,
        documentCategory: .bible,
        workspaceID: regenerationWorkspaceID,
        windowID: regenerationWindowID,
        activeDocumentInitials: sourceInitials,
        sourceBookKey: source.sourceBookKey ?? pageContext.sourceBookKey,
        sourceOrdinalStart: nil,
        sourceOrdinalEnd: nil,
        kjvaOrdinalStart: startOrdinal,
        kjvaOrdinalEnd: endOrdinal,
        verseReference: AIReaderActionRequest.verseReference(
          start: startOrdinal,
          end: endOrdinal
        ),
        selectedContent: source.selectedContent,
        selectedText: source.selectedText,
        highlightedText: source.highlightedText,
        selectionStartOffset: source.selectionStartOffset,
        selectionEndOffset: source.selectionEndOffset,
        textTarget: nil,
        noteEditorContent: nil,
        noteEditorContentType: nil,
        workspaceWindowsSummary: nil
      )
      let instructions =
        regenerationInstructions
        .trimmingCharacters(in: .whitespacesAndNewlines)
      start(
        AIReaderRunLaunch(
          entry: entry,
          request: request,
          userSpecification: source.userSpecification,
          previousResponse: previous,
          additionalInstructions: instructions.isEmpty ? nil : instructions,
          modelOverrideID: regenerationModelID,
          skipCache: true,
          regeneration: AIReaderRegenerationLaunch(
            sourcePageID: pageContext.pageId,
            replacesSourcePage: !regenerationKeepsPrevious
          )
        )
      )
    } catch {
      presentFailure(error)
    }
  }

  /** Opens one marker directly or presents Android's chooser for multiple destinations. */
  func presentDocumentMarkers(_ markers: [AIDocumentPageMarker]) {
    guard !markers.isEmpty else { return }
    if markers.count == 1, let marker = markers.first {
      openMyDocument(marker.documentInitials, marker.pageKey)
      return
    }
    documentMarkers = markers
    presentation = .documentChooser(UUID())
  }

  /** Opens one exact marker selected in the native chooser. */
  func openDocumentMarker(_ marker: AIDocumentPageMarker) {
    presentation = nil
    openMyDocument(marker.documentInitials, marker.pageKey)
  }

  /** Presents one source prompt through the existing source-aware editor. */
  func presentPromptEditor(_ promptID: UUID) {
    guard (try? promptRepository.entryById(promptID)) != nil else {
      presentFailure(AIReaderRunError.promptUnavailable)
      return
    }
    promptEditorID = promptID
    presentation = .promptEditor(UUID(), promptID: promptID)
  }

  /** Cancels the active network/tool run and rejects any suspended user decision. */
  func cancelRun() {
    activeTask?.cancel()
    answerPermission(.deny)
    answerIterationContinuation(false)
  }

  /** Applies a permission choice, persisting Android's permanent grant before continuation. */
  func answerPermission(_ grant: AgentPermissionGrant) {
    guard let continuation = permissionContinuation else { return }
    var resolvedGrant = grant
    if grant == .allowAlways, let tool = pendingPermission?.request.tool {
      do {
        let settings = try settingsStore.globalSettings()
        var allowed = settings.permanentlyAllowedTools ?? []
        var denied = settings.permanentlyDeniedTools ?? []
        allowed.insert(tool)
        denied.remove(tool)
        settings.permanentlyAllowedTools = allowed
        settings.permanentlyDeniedTools = denied
        try settingsStore.save()
      } catch {
        appendLog(
          .failure, String(localized: "error_occurred", defaultValue: "An error has occurred"))
        resolvedGrant = .deny
      }
    }
    permissionContinuation = nil
    pendingPermission = nil
    continuation.resume(returning: resolvedGrant)
  }

  /** Resumes a capped run with the user's explicit continue-or-stop decision. */
  func answerIterationContinuation(_ shouldContinue: Bool) {
    guard let continuation = iterationContinuation else { return }
    iterationContinuation = nil
    pendingIterationContinuation = nil
    continuation.resume(returning: shouldContinue)
  }

  /** Dismisses a completed session while preserving Android's running-task visibility. */
  func dismissCompletedRun() {
    guard !isRunning else { return }
    presentation = nil
  }

  /**
   Performs Android-ordered cache preflight, then starts one pane-visible execution on a miss.

   - Parameter launch: Immutable prompt/regeneration inputs.
   - Side effects: Reads the generated-page cache before pane state, may navigate directly to a
     cache hit, may present a transient regeneration document, and starts one child task on a miss.
   - Failure modes: Cache or regeneration-source validation failures are presented without
     publishing running state. A local active run is rejected only after cache preflight misses.
   - Important: This method is main-actor isolated; no visible running state exists on a cache hit.
   */
  private func start(_ launch: AIReaderRunLaunch) {
    let prompt = launch.entry.prompt
    let context = launch.request.executionContext(
      prompt: prompt,
      userSpecification: launch.userSpecification,
      previousResponse: launch.previousResponse,
      additionalInstructions: launch.additionalInstructions
    )
    let cacheContext = CacheableContext(context: context)

    let decision: AIReaderRunPreflightDecision
    do {
      decision = try AIReaderRunPreflight.decide(
        skipCache: launch.skipCache,
        cachedPage: {
          try generatedPageStore.cachedPage(for: prompt, context: cacheContext)
        },
        isLocalRunActive: { isRunning }
      )
    } catch {
      presentFailure(error)
      return
    }

    switch decision {
    case .openCachedPage(let cached):
      presentation = nil
      openMyDocument(cached.documentInitials, cached.pageKey)
      return
    case .localRunAlreadyActive:
      presentFailure(AIReaderRunError.runAlreadyActive)
      return
    case .beginExecution:
      break
    }

    let preparedRegeneration: AIReaderPreparedRegeneration?
    do {
      if let regeneration = launch.regeneration {
        try generatedPageStore.validateRegenerationSource(
          sourcePageID: regeneration.sourcePageID
        )
        preparedRegeneration = AIReaderPreparedRegeneration(
          sourcePageID: regeneration.sourcePageID,
          replacesSourcePage: regeneration.replacesSourcePage
        )
        presentation = nil
        showTransientDocument(
          AIReaderTransientDocument(
            message: String(
              localized: "ai_document_regenerating",
              defaultValue: "Regenerating AI document…"
            ),
            severity: .normal
          )
        )
      } else {
        preparedRegeneration = nil
      }
    } catch {
      presentFailure(error)
      return
    }

    let preparedRun = AIReaderPreparedRun(
      launch: launch,
      context: context,
      cacheContext: cacheContext,
      regeneration: preparedRegeneration
    )
    let runID = UUID()
    activeRunID = runID
    runTitle = prompt.name
    runLog = []
    failureMessage = nil
    isRunning = true
    runCompleted = false
    presentation = .run(runID)
    activeTask = Task { [weak self] in
      guard let self else { return }
      await self.execute(preparedRun, runID: runID)
    }
  }

  /** Executes one cache-miss launch through workspace claim and exact terminal routing. */
  private func execute(_ preparedRun: AIReaderPreparedRun, runID: UUID) async {
    let launch = preparedRun.launch
    let workspaceID = launch.request.workspaceID
    guard let workspaceID else {
      finishFailure(AIReaderRunError.noWorkspace, preparedRun: preparedRun, runID: runID)
      return
    }

    do {
      guard await runGate.acquire(workspaceID: workspaceID, runID: runID) else {
        throw AIReaderRunError.runAlreadyActive
      }
      do {
        try await executeClaimedRun(preparedRun, runID: runID)
        await runGate.release(workspaceID: workspaceID, runID: runID)
      } catch {
        await runGate.release(workspaceID: workspaceID, runID: runID)
        throw error
      }
    } catch is CancellationError {
      finishCancellation(preparedRun: preparedRun, runID: runID)
    } catch let error as AIReaderRunError {
      finishFailure(error, preparedRun: preparedRun, runID: runID)
    } catch let error as AIModelResolutionError {
      switch error {
      case .noConfiguredModel:
        finishFailure(.modelUnavailable, preparedRun: preparedRun, runID: runID)
      case .missingCredential:
        finishFailure(.missingCredential, preparedRun: preparedRun, runID: runID)
      case .providerNotFound, .invalidEndpoint:
        finishFailure(.invalidProviderConfiguration, preparedRun: preparedRun, runID: runID)
      }
    } catch let error as AITextTargetStoreError {
      let mapped: AIReaderRunError =
        error == .staleContent
        ? .textTargetChanged
        : .sourceUnavailable
      finishFailure(mapped, preparedRun: preparedRun, runID: runID)
    } catch let error as AgentExecutionError {
      if case .maximumIterationsReached(let count) = error {
        finishFailure(
          .maximumIterationsReached(count),
          preparedRun: preparedRun,
          runID: runID
        )
      } else {
        finishFailure(.executionFailed, preparedRun: preparedRun, runID: runID)
      }
    } catch {
      finishFailure(
        AIReaderRunError.executionFailed,
        preparedRun: preparedRun,
        runID: runID
      )
    }
  }

  /** Performs one claimed workspace run while retaining any prior regeneration source page. */
  private func executeClaimedRun(
    _ preparedRun: AIReaderPreparedRun,
    runID: UUID
  ) async throws {
    try Task.checkCancellation()
    guard activeRunID == runID else { throw CancellationError() }

    let launch = preparedRun.launch
    let context = preparedRun.context
    let prompt = launch.entry.prompt
    let model = try modelResolver.resolve(
      configuredModelId: launch.modelOverrideID ?? prompt.configuredModelId
    )
    let settings = try settingsStore.globalSettings()
    let permissions = AgentPermissionSettings(
      globalMode: settings.agentPermissionMode ?? .alwaysAsk,
      permanentlyAllowedTools: settings.permanentlyAllowedTools ?? [],
      permanentlyDeniedTools: settings.permanentlyDeniedTools ?? [],
      promptAllowedTools: launch.entry.origin == .builtIn ? nil : prompt.allowedTools,
      promptDeniedTools: prompt.deniedTools,
      promptMode: prompt.permissionMode
    )
    let excluded = AgentToolVisibilityPolicy.excludedTools(
      permanentlyDeniedTools: settings.permanentlyDeniedTools ?? [],
      promptDeniedTools: prompt.deniedTools,
      promptAvailableTools: prompt.allowedTools,
      isTextTransformation: prompt.isTextTransformation
    )
    let systemPrompts = try AIReaderSystemPromptLoader.load()
    let installedDocuments = try await prefetchInstalledDocuments(
      prompt: prompt,
      context: context
    )
    let commentaryEntries = try await prefetchCommentaries(
      prompt: prompt,
      context: context,
      deselected: Self.decodeStringSet(settings.commentaryDeselectedRawValue)
    )
    let messages = AIReaderRunMessageAssembler.messages(
      prompt: prompt,
      context: context,
      appLanguage: Self.aiDisplayLanguage(settings.aiLanguage),
      agentSystemPrompt: Self.nonblank(settings.customAgentSystemPrompt)
        ?? systemPrompts.agent,
      transformationSystemPrompt: Self.nonblank(settings.customTextTransformationSystemPrompt)
        ?? systemPrompts.transformation,
      installedDocuments: installedDocuments,
      commentaryEntries: commentaryEntries,
      referenceEnvironmentProvider: referenceEnvironmentProvider
    )
    let textSnapshot: AITextTargetSnapshot?
    if let textTarget = launch.request.textTarget {
      textSnapshot = try await textTargetStore.capture(textTarget)
    } else {
      textSnapshot = nil
    }
    let registry = try AgentToolRegistry(
      dispatcher: BibleUIAgentToolDispatcher(domain: domain)
    )
    let permissionRequester = AIReaderPermissionRequester { [weak self] request in
      guard let self else { return .deny }
      return await self.requestPermission(request, runID: runID)
    }
    let progressReporter = AIReaderProgressReporter { [weak self] progress in
      if case .providerCompleted(_, let usage) = progress {
        await self?.recordUsage(
          usage,
          configuredModelID: model.configuredModelId,
          runID: runID
        )
      }
      await self?.receive(progress, runID: runID)
    }
    let iterationContinuationRequester = AIReaderIterationContinuationRequester {
      [weak self] currentIteration, increment in
      guard let self else { return false }
      return await self.requestIterationContinuation(
        currentIteration: currentIteration,
        increment: increment,
        runID: runID
      )
    }
    let transcriptRecorder = AgentExecutionTranscriptRecorder()
    let executor = AgentExecutionCoordinator(
      client: client,
      registry: registry,
      permissionRequester: permissionRequester,
      progressReporter: progressReporter,
      iterationContinuationRequester: iterationContinuationRequester,
      transcriptRecorder: transcriptRecorder
    )
    do {
      let result = try await executor.execute(
        model: model,
        messages: messages,
        context: context,
        permissionSettings: permissions,
        excludedTools: excluded,
        maximumIterations: prompt.maxIterations ?? settings.maxIterations
      )
      try Task.checkCancellation()
      guard activeRunID == runID else { throw CancellationError() }
      try await routeResult(
        result,
        preparedRun: preparedRun,
        model: model,
        textSnapshot: textSnapshot
      )
      await persistTelemetry(
        transcriptRecorder,
        prompt: prompt,
        model: model,
        outcome: .completed
      )
      finishSuccess(
        runID: runID,
        autoHide: settings.autoHideAgentLogOnCompletion
      )
    } catch is CancellationError {
      await persistTelemetry(
        transcriptRecorder,
        prompt: prompt,
        model: model,
        outcome: .cancelled
      )
      throw CancellationError()
    } catch {
      await persistTelemetry(
        transcriptRecorder,
        prompt: prompt,
        model: model,
        outcome: .failed
      )
      throw error
    }
  }

  /** Records one billable provider response immediately, matching Android's per-call accounting. */
  private func recordUsage(
    _ usage: LLMUsage,
    configuredModelID: UUID,
    runID: UUID
  ) {
    guard activeRunID == runID, usage.totalTokens > 0 else { return }
    _ = try? telemetryService().recordUsage(
      LLMUsageSample(configuredModelID: configuredModelID, usage: usage)
    )
  }

  /** Persists one terminal transcript without allowing diagnostics to replace the run outcome. */
  private func persistTelemetry(
    _ recorder: AgentExecutionTranscriptRecorder,
    prompt: AgentPrompt,
    model: ResolvedLLMModel,
    outcome: LLMRunOutcome
  ) async {
    let transcript = await recorder.transcript()
    let providerType =
      (try? settingsStore.provider(id: model.providerConfigId))?.providerType
      ?? ""
    _ = try? telemetryService().persistRawLog(
      transcript: transcript,
      metadata: LLMRunMetadata(
        promptID: prompt.id,
        promptName: prompt.name,
        promptDescription: prompt.promptDescription,
        configuredModelID: model.configuredModelId,
        modelName: model.modelId,
        providerType: providerType,
        outcome: outcome
      )
    )
  }

  /** Lazily creates the per-pane telemetry facade and performs Android's one-time cleanup work. */
  private func telemetryService() -> LLMRunTelemetryService {
    if let runTelemetryService { return runTelemetryService }
    let deviceID = RemoteSyncSettingsStore(
      settingsStore: SettingsStore(modelContext: modelContext)
    ).deviceIdentifier()
    let service = LLMRunTelemetryService(settingsStore: settingsStore, deviceID: deviceID)
    _ = try? service.deleteExpiredRawLogs()
    runTelemetryService = service
    return service
  }

  /** Suspends the tool loop until the visible permission request receives a response. */
  private func requestPermission(
    _ request: AgentPermissionRequest,
    runID: UUID
  ) async -> AgentPermissionGrant {
    guard activeRunID == runID, !Task.isCancelled else { return .deny }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        permissionContinuation = continuation
        let definition = AndroidAgentToolDefinitionCatalog.definition(for: request.tool)
        pendingPermission = AIReaderPendingPermission(
          id: UUID(),
          request: request,
          toolTitle: AIPermissionPresentation.title(for: request.tool),
          toolDescription: definition.description,
          actionDescription: Self.permissionActionDescription(request.arguments)
        )
        appendLog(
          .action, String(localized: "agent_permission_title", defaultValue: "Agent Permission"))
      }
    } onCancel: { [weak self] in
      Task { @MainActor in self?.answerPermission(.deny) }
    }
  }

  /** Suspends a capped run until the visible activity sheet receives a continue decision. */
  private func requestIterationContinuation(
    currentIteration: Int,
    increment: Int,
    runID: UUID
  ) async -> Bool {
    guard activeRunID == runID, !Task.isCancelled else { return false }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        iterationContinuation = continuation
        pendingIterationContinuation = AIReaderPendingIterationContinuation(
          id: UUID(),
          currentIteration: currentIteration,
          increment: increment
        )
        appendLog(
          .action,
          String(localized: "llm_continue_iterations_title", defaultValue: "Continue?")
        )
      }
    } onCancel: { [weak self] in
      Task { @MainActor in self?.answerIterationContinuation(false) }
    }
  }

  /** Converts ordered core progress into a bounded, credential-free activity log. */
  private func receive(_ progress: AgentExecutionProgress, runID: UUID) {
    guard activeRunID == runID else { return }
    switch progress {
    case .started(_):
      appendLog(
        .information,
        String(
          format: String(localized: "agent_log_executing", defaultValue: "Executing: %@"),
          runTitle
        )
      )
    case .iterationStarted(let number):
      appendLog(
        .information,
        String(
          format: String(localized: "agent_log_iteration", defaultValue: "Iteration %d"), number))
    case .providerCompleted(_, let usage):
      appendLog(
        .information,
        String(
          format: String(localized: "raw_log_item_tokens", defaultValue: "%1$@ in / %2$@ out"),
          String(usage.inputTokens),
          String(usage.outputTokens)
        )
      )
    case .toolStarted(_, _, let tool):
      appendLog(.action, AIPermissionPresentation.title(for: tool))
    case .toolCompleted(_, _, let tool, let isError):
      appendLog(
        isError ? .failure : .information,
        isError
          ? String(
            format: String(localized: "agent_log_tool_failed", defaultValue: "Tool %@ failed"),
            AIPermissionPresentation.title(for: tool)
          )
          : AIPermissionPresentation.title(for: tool)
      )
    case .textReceived(_, let text, let isFinal):
      let normalized = BibleUIAgentToolRequestParser.normalizeModelText(text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !normalized.isEmpty {
        appendLog(isFinal ? .response : .information, normalized)
      }
    case .completed:
      appendLog(.information, String(localized: "agent_log_completed", defaultValue: "Completed"))
    }
  }

  /** Routes one typed terminal result without treating destinations as ordinary text. */
  private func routeResult(
    _ result: AgentExecutionResult,
    preparedRun: AIReaderPreparedRun,
    model: ResolvedLLMModel,
    textSnapshot: AITextTargetSnapshot?
  ) async throws {
    let launch = preparedRun.launch
    let prompt = launch.entry.prompt
    let normalizedContent = BibleUIAgentToolRequestParser.normalizeModelText(result.content)

    if prompt.isTextTransformation, let target = launch.request.textTarget {
      guard preparedRun.regeneration == nil else {
        throw AIReaderRunError.executionFailed
      }
      guard !normalizedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AIReaderRunError.emptyTransformation
      }
      guard let textSnapshot else { throw AIReaderRunError.sourceUnavailable }
      _ = try await textTargetStore.write(
        content: normalizedContent,
        to: target,
        capturedInputDigest: textSnapshot.capturedInputDigest
      )
      showToast(String(localized: "llm_note_updated", defaultValue: "Note updated"))
      return
    }

    switch result.output {
    case .text:
      if prompt.noDocumentCreation {
        guard preparedRun.regeneration == nil else {
          throw AIReaderRunError.executionFailed
        }
        return
      }
      let title = AIReaderGeneratedTitle.title(
        response: normalizedContent,
        promptName: prompt.name,
        verseReference: launch.request.verseReference
      )
      let location = try persistGeneratedDocument(
        content: normalizedContent,
        title: title,
        result: result,
        model: model,
        preparedRun: preparedRun
      )
      openMyDocument(location.documentInitials, location.pageKey)
    case .document(let title, _):
      let location = try persistGeneratedDocument(
        content: normalizedContent,
        title: BibleUIAgentToolRequestParser.stripMarkdown(from: title),
        result: result,
        model: model,
        preparedRun: preparedRun
      )
      openMyDocument(location.documentInitials, location.pageKey)
    case .withoutDocument(let message):
      guard preparedRun.regeneration == nil else {
        throw AIReaderRunError.executionFailed
      }
      showToast(message)
    case .studyPad(let labelID, let entryID, let message):
      guard preparedRun.regeneration == nil else {
        throw AIReaderRunError.executionFailed
      }
      openStudyPad(labelID, entryID)
      showToast(message)
    case .myDocumentPage(let initials, let pageKey, let message):
      guard preparedRun.regeneration == nil else {
        throw AIReaderRunError.executionFailed
      }
      openMyDocument(initials, pageKey)
      showToast(message)
    }
  }

  /**
   Persists one document-producing result through ordinary save or regeneration replacement.

   - Parameters:
     - content: Normalized model response body.
     - title: Android-normalized generated title.
     - result: Terminal result carrying write-tool usage.
     - model: Resolved provider model persisted in cache metadata.
     - preparedRun: Prepared cache context and optional validated regeneration source.
   - Returns: New completed generated-page location.
   - Side effects: Commits the page/cache graph; regeneration may remove its prior result atomically.
   - Throws: Generated-page persistence and context serialization failures.
   */
  private func persistGeneratedDocument(
    content: String,
    title: String,
    result: AgentExecutionResult,
    model: ResolvedLLMModel,
    preparedRun: AIReaderPreparedRun
  ) throws -> AIGeneratedPageLocation {
    let promptID = preparedRun.launch.entry.prompt.id
    if let regeneration = preparedRun.regeneration {
      return try generatedPageStore.completeRegeneration(
        sourcePageID: regeneration.sourcePageID,
        replacesSourcePage: regeneration.replacesSourcePage,
        content: content,
        title: title,
        promptID: promptID,
        context: preparedRun.cacheContext,
        usedWriteTools: result.usedWriteTools,
        sourceModelName: model.modelId
      )
    }
    return try generatedPageStore.save(
      content: content,
      title: title,
      promptID: promptID,
      context: preparedRun.cacheContext,
      usedWriteTools: result.usedWriteTools,
      sourceModelName: model.modelId
    )
  }

  /** Auto-includes Android's getInstalledDocuments result when requested by the prompt. */
  private func prefetchInstalledDocuments(
    prompt: AgentPrompt,
    context: AgentExecutionContext
  ) async throws -> String? {
    guard prompt.autoIncludeDocuments else { return nil }
    do {
      return try await domain.execute(.getInstalledDocuments(category: nil), context: context)
        .modelContent()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return nil
    }
  }

  /** Auto-includes allowed commentary data for an exact selected KJVA reference. */
  private func prefetchCommentaries(
    prompt: AgentPrompt,
    context: AgentExecutionContext,
    deselected: Set<String>
  ) async throws -> String? {
    guard prompt.autoIncludeCommentaries, let reference = context.verseReference else {
      return nil
    }
    do {
      let allowed = try await domain.execute(
        .getInstalledDocuments(category: .commentary),
        context: context
      )
      let initials =
        allowed.data?.objectValue?["documents"]?.arrayValue?
        .compactMap { $0.objectValue?["initials"]?.stringValue }
        .filter { !deselected.contains($0) } ?? []
      guard !initials.isEmpty else { return nil }
      return try await domain.execute(
        .getCommentaries(
          verseReference: reference,
          commentaries: initials,
          format: .text
        ),
        context: context
      ).modelContent()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return nil
    }
  }

  /** Returns configured models with Android's default-first display ordering. */
  private func configuredModelChoices(defaultID: UUID?) throws -> [AIReaderModelChoice] {
    let providers = Dictionary(
      uniqueKeysWithValues: try settingsStore.providers().map {
        ($0.id, $0.displayName)
      })
    return try settingsStore.allModels()
      .sorted {
        if ($0.id == defaultID) != ($1.id == defaultID) { return $0.id == defaultID }
        return $0.modelId.localizedCaseInsensitiveCompare($1.modelId) == .orderedAscending
      }
      .map {
        let provider = providers[$0.providerConfigId] ?? "?"
        return AIReaderModelChoice(
          id: $0.id,
          title: "\($0.modelId) - \(provider)\($0.id == defaultID ? " *" : "")",
          isDefault: $0.id == defaultID
        )
      }
  }

  /** Records one bounded line and drops the oldest row after the Android-style activity cap. */
  private func appendLog(_ kind: AIReaderRunLogEntry.Kind, _ message: String) {
    runLog.append(AIReaderRunLogEntry(kind: kind, message: message))
    if runLog.count > Self.maximumLogEntries {
      runLog.removeFirst(runLog.count - Self.maximumLogEntries)
    }
  }

  /** Marks one current run complete and optionally hides its activity surface. */
  private func finishSuccess(runID: UUID, autoHide: Bool) {
    guard activeRunID == runID else { return }
    isRunning = false
    runCompleted = true
    activeTask = nil
    activeRunID = nil
    if autoHide { presentation = nil }
  }

  /**
   Marks one current run cancelled and replaces any transient loading document with cancellation.

   - Parameters:
     - preparedRun: Prepared run containing optional regeneration presentation state.
     - runID: Active-run identity used to reject stale cancellation callbacks.
   - Side effects: Resolves suspended decisions, may present a reader-local cancellation document,
     and clears active pane state.
   - Failure modes: None; transient presentation does not mutate persistence or sync state.
   */
  private func finishCancellation(preparedRun: AIReaderPreparedRun, runID: UUID) {
    guard activeRunID == runID else { return }
    let suspendedPermission = permissionContinuation
    permissionContinuation = nil
    pendingPermission = nil
    suspendedPermission?.resume(returning: .deny)
    let suspendedIteration = iterationContinuation
    iterationContinuation = nil
    pendingIterationContinuation = nil
    suspendedIteration?.resume(returning: false)
    let message = String(localized: "agent_log_cancelled", defaultValue: "Cancelled")
    presentRegenerationTerminalDocument(
      preparedRun: preparedRun,
      message: message,
      severity: .normal
    )
    appendLog(.information, message)
    isRunning = false
    runCompleted = true
    activeTask = nil
    activeRunID = nil
  }

  /**
   Marks one current run failed through a stable message and transient regeneration failure page.

   - Parameters:
     - error: Credential-free reader failure.
     - preparedRun: Prepared run containing optional regeneration presentation state.
     - runID: Active-run identity used to reject stale terminal callbacks.
   - Side effects: Resolves suspended decisions, may present a reader-local failure document, logs the
     failure, and clears active pane state.
   - Failure modes: None; transient presentation does not mutate persistence or sync state.
   */
  private func finishFailure(
    _ error: AIReaderRunError,
    preparedRun: AIReaderPreparedRun,
    runID: UUID
  ) {
    guard activeRunID == runID else { return }
    let suspendedPermission = permissionContinuation
    permissionContinuation = nil
    pendingPermission = nil
    suspendedPermission?.resume(returning: .deny)
    let suspendedIteration = iterationContinuation
    iterationContinuation = nil
    pendingIterationContinuation = nil
    suspendedIteration?.resume(returning: false)
    let message = error.localizedDescription
    presentRegenerationTerminalDocument(
      preparedRun: preparedRun,
      message: message,
      severity: .error
    )
    failureMessage = message
    appendLog(.failure, message)
    isRunning = false
    runCompleted = true
    activeTask = nil
    activeRunID = nil
  }

  /**
   Replaces an active regeneration loading state with a reader-local terminal document.

   - Parameters:
     - preparedRun: Run whose regeneration state may be absent.
     - message: Credential-free terminal body.
     - severity: Vue error-document severity for cancellation or failure.
   - Side effects: Invokes the transient reader presentation boundary only for regeneration.
   - Failure modes: None; the prior successful page remains persisted and cacheable.
   */
  private func presentRegenerationTerminalDocument(
    preparedRun: AIReaderPreparedRun,
    message: String,
    severity: AIReaderTransientDocument.Severity
  ) {
    guard preparedRun.regeneration != nil else { return }
    showTransientDocument(AIReaderTransientDocument(message: message, severity: severity))
  }

  /** Presents a safe failure through toast and the current native route. */
  private func presentFailure(_ error: Error) {
    let message =
      (error as? AIReaderRunError)?.localizedDescription
      ?? AIReaderRunError.executionFailed.localizedDescription
    failureMessage = message
    showToast(message)
  }

  /** Resolves Android's AI response-language display name in that language. */
  private static func aiDisplayLanguage(_ languageTag: String?) -> String {
    let identifier = nonblank(languageTag) ?? Locale.current.identifier
    let locale = Locale(identifier: identifier)
    let languageCode = locale.language.languageCode?.identifier
    return languageCode.flatMap { locale.localizedString(forLanguageCode: $0) }
      ?? languageCode
      ?? identifier
  }

  /** Normalizes optional user settings without erasing meaningful internal whitespace. */
  private static func nonblank(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.flatMap { $0.isEmpty ? nil : $0 }
  }

  /** Decodes Android-backed JSON string sets and fails closed on malformed settings. */
  private static func decodeStringSet(_ value: String) -> Set<String> {
    guard let data = value.data(using: .utf8),
      let values = try? JSONDecoder().decode([String].self, from: data)
    else {
      return []
    }
    return Set(values)
  }

  /** Produces a bounded, sorted argument summary for the permission dialog. */
  private static func permissionActionDescription(
    _ arguments: [String: JSONValue]
  ) -> String? {
    guard !arguments.isEmpty,
      let data = try? JSONValue.object(arguments).encodedData()
    else { return nil }
    return String(String(decoding: data, as: UTF8.self).prefix(1_000))
  }
}

/// Android's generated-title extraction and Markdown normalization contract.
enum AIReaderGeneratedTitle {
  /** Extracts a Markdown H1, then falls back to prompt name plus selected reference. */
  static func title(response: String, promptName: String, verseReference: String?) -> String {
    let range = NSRange(response.startIndex..<response.endIndex, in: response)
    let pattern = #"^\s*#\s+(.+?)\s*(?:\n|$)"#
    if let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
      let match = expression.firstMatch(in: response, range: range),
      let titleRange = Range(match.range(at: 1), in: response)
    {
      let title = BibleUIAgentToolRequestParser.stripMarkdown(
        from: String(response[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
      )
      if !title.isEmpty { return String(title.prefix(80)) }
    }
    let fallback = promptName + (verseReference.map { ": \($0)" } ?? "")
    return String(fallback.prefix(80))
  }
}
