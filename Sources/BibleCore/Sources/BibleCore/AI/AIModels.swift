import Foundation
import SwiftData
import SwordKit

/**
 Wire formats supported by Android's v23 AI provider configuration.

 Raw values intentionally match `ApiFormat` in Android `LlmUtils.kt`.
 */
public enum APIFormat: String, Codable, CaseIterable, Sendable {
    /// OpenAI Chat Completions-compatible JSON.
    case openAI = "OPENAI"

    /// Anthropic Messages-compatible JSON.
    case anthropic = "ANTHROPIC"
}

/**
 Known Android AI providers plus the user-defined endpoint fallback.

 Raw values are durable provider identifiers. Unknown persisted provider identifiers resolve to
 `custom` through `LLMProviderConfig.provider` so removed Android providers remain editable.
 */
public enum LLMProvider: String, Codable, CaseIterable, Sendable {
    /// Google Gemini's OpenAI-compatible endpoint.
    case gemini = "GEMINI"

    /// OpenAI's Chat Completions endpoint.
    case openAI = "OPENAI"

    /// Anthropic's Messages endpoint.
    case anthropic = "ANTHROPIC"

    /// xAI's OpenAI-compatible endpoint.
    case xAI = "XAI"

    /// Mistral's OpenAI-compatible endpoint.
    case mistral = "MISTRAL"

    /// DeepSeek's OpenAI-compatible endpoint.
    case deepSeek = "DEEPSEEK"

    /// Groq's OpenAI-compatible endpoint.
    case groq = "GROQ"

    /// Alibaba DashScope's OpenAI-compatible endpoint.
    case alibaba = "ALIBABA"

    /// OpenRouter's OpenAI-compatible endpoint.
    case openRouter = "OPENROUTER"

    /// A user-supplied endpoint and API format.
    case custom = "CUSTOM"

    /// Android's canonical base endpoint for a known provider.
    public var endpoint: URL? {
        switch self {
        case .gemini:
            return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")
        case .openAI:
            return URL(string: "https://api.openai.com/v1")
        case .anthropic:
            return URL(string: "https://api.anthropic.com/v1")
        case .xAI:
            return URL(string: "https://api.x.ai/v1")
        case .mistral:
            return URL(string: "https://api.mistral.ai/v1")
        case .deepSeek:
            return URL(string: "https://api.deepseek.com/v1")
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1")
        case .alibaba:
            return URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")
        case .openRouter:
            return URL(string: "https://openrouter.ai/api/v1")
        case .custom:
            return nil
        }
    }

    /// Android's canonical wire format for the provider.
    public var apiFormat: APIFormat {
        self == .anthropic ? .anthropic : .openAI
    }

    /// Whether Android enables explicit Anthropic-style cache breakpoints for this provider.
    public var supportsCacheControl: Bool {
        self == .openRouter
    }
}

/**
 UI surfaces where a prompt can be offered.

 Raw values match Android `PromptContext` serialization and CSV prompt packs.
 */
public enum PromptContext: String, Codable, CaseIterable, Sendable {
    /// A selected Bible verse range.
    case verseSelection = "VERSE_SELECTION"

    /// A free-form text selection.
    case textSelection = "TEXT_SELECTION"

    /// The active window's action menu.
    case windowMenu = "WINDOW_MENU"

    /// The workspace-level action menu.
    case workspaceMenu = "WORKSPACE_MENU"

    /// A bookmark, study-pad, or My Documents note editor.
    case noteEditor = "NOTE_EDITOR"
}

/**
 Permission modes applied before an agent invokes a mutating tool.

 Raw values match Android `PermissionMode`; read tools remain permission-free unless a host adapter
 deliberately applies a stronger policy.
 */
public enum AIPermissionMode: String, Codable, CaseIterable, Sendable {
    /// Ask before each write unless the current invocation already has an explicit grant.
    case alwaysAsk = "ALWAYS_ASK"

    /// Ask once and reuse the grant for subsequent writes in the same run.
    case askOncePerRun = "ASK_ONCE_PER_RUN"

    /// Allow writes without a dialog unless a stronger deny rule applies.
    case allowAll = "ALLOW_ALL"

    /// Deny writes; the global form is an absolute safety switch.
    case denyAll = "DENY_ALL"
}

/**
 Note-editor destinations supported by Android text-transformation prompts.
 */
public enum NoteEditorEntityType: String, Codable, CaseIterable, Sendable {
    /// A Bible or generic-book bookmark note.
    case bookmarkNote = "BOOKMARK_NOTE"

    /// A StudyPad text entry.
    case studyPadText = "STUDYPAD_TEXT"

    /// A My Documents page.
    case myDocumentPage = "MY_DOCUMENT_PAGE"
}

/**
 Complete Android agent-tool vocabulary.

 Each case carries the exact database/CSV raw value. `wireName` supplies Android's lower-camel
 function name, while `access` and `category` let permission and registration logic retain the
 semantic distinction between reads, writes, and structural completion tools.
 */
public enum AgentTool: String, Codable, CaseIterable, Sendable {
    /// Reads verse content from an installed Bible.
    case getVerseContent = "GET_VERSE_CONTENT"
    /// Searches installed Bibles.
    case searchBible = "SEARCH_BIBLE"
    /// Searches indexed Strong's numbers.
    case searchByStrongs = "SEARCH_BY_STRONGS"
    /// Reads commentary content for a verse range.
    case getCommentaries = "GET_COMMENTARIES"
    /// Reads a dictionary entry.
    case getDictionaryEntry = "GET_DICTIONARY_ENTRY"
    /// Finds bookmarks intersecting a verse.
    case getBookmarksForVerse = "GET_BOOKMARKS_FOR_VERSE"
    /// Finds bookmarks assigned to a label.
    case getBookmarksWithLabel = "GET_BOOKMARKS_WITH_LABEL"
    /// Lists bookmark labels.
    case getAllLabels = "GET_ALL_LABELS"
    /// Reads StudyPad content.
    case getStudyPadContent = "GET_STUDY_PAD_CONTENT"
    /// Searches StudyPads.
    case searchStudyPads = "SEARCH_STUDY_PADS"
    /// Lists installed documents.
    case getInstalledDocuments = "GET_INSTALLED_DOCUMENTS"
    /// Lists My Documents collections.
    case getMyDocuments = "GET_MY_DOCUMENTS"
    /// Lists pages in a My Documents collection.
    case getMyDocumentPages = "GET_MY_DOCUMENT_PAGES"
    /// Lists keys in a general-book module.
    case getGenBookKeys = "GET_GENBOOK_KEYS"
    /// Reads content from a general-book module.
    case getGenBookContent = "GET_GENBOOK_CONTENT"
    /// Lists workspace windows.
    case getWindows = "GET_WINDOWS"
    /// Creates a Bible or generic bookmark.
    case createBookmark = "CREATE_BOOKMARK"
    /// Adds a note to a bookmark.
    case addBookmarkNote = "ADD_BOOKMARK_NOTE"
    /// Replaces an existing bookmark note.
    case updateBookmarkNote = "UPDATE_BOOKMARK_NOTE"
    /// Creates a bookmark label.
    case createLabel = "CREATE_LABEL"
    /// Assigns a label to a bookmark.
    case addLabelToBookmark = "ADD_LABEL_TO_BOOKMARK"
    /// Deletes a bookmark.
    case deleteBookmark = "DELETE_BOOKMARK"
    /// Deletes a label.
    case deleteLabel = "DELETE_LABEL"
    /// Removes a label assignment from a bookmark.
    case removeLabelFromBookmark = "REMOVE_LABEL_FROM_BOOKMARK"
    /// Adds an entry to a StudyPad.
    case addStudyPadEntry = "ADD_STUDY_PAD_ENTRY"
    /// Replaces a StudyPad text entry.
    case updateStudyPadTextEntry = "UPDATE_STUDYPAD_TEXT_ENTRY"
    /// Creates a StudyPad.
    case createStudyPad = "CREATE_STUDY_PAD"
    /// Creates a My Documents collection.
    case createMyDocument = "CREATE_MY_DOCUMENT"
    /// Adds a page to My Documents.
    case addMyDocumentPage = "ADD_MY_DOCUMENT_PAGE"
    /// Replaces a My Documents page.
    case editMyDocumentPage = "EDIT_MY_DOCUMENT_PAGE"
    /// Deletes a My Documents page.
    case deleteMyDocumentPage = "DELETE_MY_DOCUMENT_PAGE"
    /// Creates a workspace window.
    case createWindow = "CREATE_WINDOW"
    /// Mutates window layout or lifecycle state.
    case manageWindow = "MANAGE_WINDOW"
    /// Changes the document displayed by a window.
    case setWindowDocument = "SET_WINDOW_DOCUMENT"
    /// Sets the title of agent-created output.
    case setDocumentTitle = "SET_DOCUMENT_TITLE"
    /// Completes a run with StudyPad output.
    case finishWithStudyPad = "FINISH_WITH_STUDY_PAD"
    /// Completes a run with My Documents output.
    case finishWithMyDocumentPage = "FINISH_WITH_MY_DOCUMENT_PAGE"
    /// Completes a run without document output.
    case finishWithoutDocument = "FINISH_WITHOUT_DOCUMENT"

    /** Tool access classification used by permission routing. */
    public enum Access: Sendable {
        /// The tool only reads app data.
        case read
        /// The tool mutates app data.
        case write
        /// The tool terminates or labels an agent run and must remain available structurally.
        case structural
    }

    /** UI grouping shared with Android's tool permission screen. */
    public enum Category: String, Sendable {
        /// Bible content and search operations.
        case bibleSearch
        /// Bookmark operations.
        case bookmarks
        /// Label operations.
        case labels
        /// StudyPad operations.
        case studyPads
        /// My Documents operations.
        case myDocuments
        /// General-book operations.
        case generalBooks
        /// Workspace-window operations.
        case windows
    }

    /// Lower-camel function name used by both supported LLM APIs.
    public var wireName: String {
        let components = rawValue.lowercased().split(separator: "_")
        guard let first = components.first else { return "" }
        return String(first) + components.dropFirst().map { $0.capitalized }.joined()
    }

    /// Resolves a lower-camel function name without accepting aliases or partial matches.
    public init?(wireName: String) {
        guard let match = Self.allCases.first(where: { $0.wireName == wireName }) else {
            return nil
        }
        self = match
    }

    /// Semantic access level used by permission checks and complete-registry validation.
    public var access: Access {
        switch self {
        case .getVerseContent, .searchBible, .searchByStrongs, .getCommentaries,
             .getDictionaryEntry, .getBookmarksForVerse, .getBookmarksWithLabel,
             .getAllLabels, .getStudyPadContent, .searchStudyPads, .getInstalledDocuments,
             .getMyDocuments, .getMyDocumentPages, .getGenBookKeys, .getGenBookContent,
             .getWindows:
            return .read
        case .setDocumentTitle, .finishWithStudyPad, .finishWithMyDocumentPage,
             .finishWithoutDocument:
            return .structural
        default:
            return .write
        }
    }

    /// Android-compatible permission-screen category.
    public var category: Category {
        switch self {
        case .getVerseContent, .searchBible, .searchByStrongs, .getCommentaries,
             .getDictionaryEntry:
            return .bibleSearch
        case .getBookmarksForVerse, .getBookmarksWithLabel, .createBookmark,
             .addBookmarkNote, .updateBookmarkNote, .deleteBookmark:
            return .bookmarks
        case .getAllLabels, .createLabel, .addLabelToBookmark, .deleteLabel,
             .removeLabelFromBookmark:
            return .labels
        case .getStudyPadContent, .searchStudyPads, .addStudyPadEntry,
             .updateStudyPadTextEntry, .createStudyPad, .finishWithStudyPad:
            return .studyPads
        case .getMyDocuments, .getMyDocumentPages, .createMyDocument,
             .addMyDocumentPage, .editMyDocumentPage, .deleteMyDocumentPage,
             .setDocumentTitle, .finishWithMyDocumentPage, .finishWithoutDocument:
            return .myDocuments
        case .getInstalledDocuments, .getGenBookKeys, .getGenBookContent:
            return .generalBooks
        case .getWindows, .createWindow, .manageWindow, .setWindowDocument:
            return .windows
        }
    }
}

/**
 Persists non-secret provider configuration from Android `LlmProviderConfig`.

 Credentials are intentionally absent. `AICredentialStore` stores them under the provider UUID in
 device-only Keychain state, so SwiftData, CloudKit, and device backups cannot contain API keys.
 */
@Model
public final class LLMProviderConfig {
    /// Stable provider configuration identity.
    public var id: UUID = UUID()

    /// Raw Android `LlmProvider` name, preserving unknown historical values.
    public var providerType: String = LLMProvider.custom.rawValue

    /// User-visible provider name.
    public var displayName: String = ""

    /// Custom base endpoint; known providers use their typed canonical endpoint.
    public var endpoint: String?

    /// Custom wire format raw value; known providers use their typed canonical format.
    public var apiFormatRawValue: String?

    /// Display ordering shared with Android.
    public var orderNumber: Int = 0

    /// Resolved provider, falling back to `.custom` for removed or unknown identifiers.
    public var provider: LLMProvider {
        LLMProvider(rawValue: providerType) ?? .custom
    }

    /// Explicit custom format or the known provider's canonical format.
    public var apiFormat: APIFormat {
        if provider == .custom {
            return apiFormatRawValue.flatMap(APIFormat.init(rawValue:)) ?? .openAI
        }
        return provider.apiFormat
    }

    /// Explicit custom endpoint or the known provider's canonical endpoint.
    public var resolvedEndpoint: URL? {
        if provider == .custom {
            return endpoint.flatMap(URL.init(string:))
        }
        return provider.endpoint
    }

    /**
     Creates a non-secret provider row.

     - Parameters:
       - id: Stable provider identity.
       - provider: Known provider or custom endpoint marker.
       - displayName: User-visible name.
       - endpoint: Base URL used only by custom providers.
       - apiFormat: Wire format used only by custom providers.
       - orderNumber: Display order.
     - Side effects: none; insertion and saving belong to `AISettingsStore`.
     - Failure modes: Invalid endpoint strings remain stored but resolve to `nil` and are rejected by
       the HTTP adapter before network I/O.
     */
    public init(
        id: UUID = UUID(),
        provider: LLMProvider,
        displayName: String,
        endpoint: String? = nil,
        apiFormat: APIFormat? = nil,
        orderNumber: Int = 0
    ) {
        self.id = id
        providerType = provider.rawValue
        self.displayName = displayName
        self.endpoint = endpoint
        apiFormatRawValue = apiFormat?.rawValue
        self.orderNumber = orderNumber
    }
}

/**
 Persists one configured model and its Android-compatible pricing metadata.
 */
@Model
public final class LLMConfiguredModel {
    /// Stable configured-model identity.
    public var id: UUID = UUID()
    /// Owning provider configuration identity.
    public var providerConfigId: UUID = UUID()
    /// Model identifier sent verbatim to the provider.
    public var modelId: String = ""
    /// Display ordering within the provider.
    public var orderNumber: Int = 0
    /// Input price in USD per million tokens.
    public var inputPricePerMillion: Double = 0
    /// Output price in USD per million tokens.
    public var outputPricePerMillion: Double = 0
    /// Cache-creation price in USD per million tokens.
    public var cacheCreationPricePerMillion: Double = 0
    /// Cache-read price in USD per million tokens.
    public var cacheReadPricePerMillion: Double = 0

    /** Creates a configured model row without saving it. */
    public init(
        id: UUID = UUID(),
        providerConfigId: UUID,
        modelId: String,
        orderNumber: Int = 0,
        inputPricePerMillion: Double = 0,
        outputPricePerMillion: Double = 0,
        cacheCreationPricePerMillion: Double = 0,
        cacheReadPricePerMillion: Double = 0
    ) {
        self.id = id
        self.providerConfigId = providerConfigId
        self.modelId = modelId
        self.orderNumber = orderNumber
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cacheCreationPricePerMillion = cacheCreationPricePerMillion
        self.cacheReadPricePerMillion = cacheReadPricePerMillion
    }
}

/** Persists a user-created prompt category. Built-in categories remain code-owned. */
@Model
public final class PromptCategory {
    /// Stable category identity.
    public var id: UUID = UUID()
    /// User-visible category name.
    public var name: String = ""
    /// Display order before the alphabetical tie-breaker.
    public var orderNumber: Int = 0
    /// Whether actions in this category are hidden.
    public var hidden: Bool = false

    /** Creates a category row without saving it. */
    public init(id: UUID = UUID(), name: String, orderNumber: Int = 0, hidden: Bool = false) {
        self.id = id
        self.name = name
        self.orderNumber = orderNumber
        self.hidden = hidden
    }
}

/**
 Persists an editable Android-compatible agent prompt.

 Typed sets are encoded as deterministic JSON arrays, matching Android's Room converters while
 keeping the SwiftData schema composed of CloudKit-native scalar fields. A `nil` tool set remains
 distinct from an explicitly empty set, preserving Android's inheritance semantics.
 */
@Model
public final class AgentPrompt {
    /// Stable prompt identity.
    public var id: UUID = UUID()
    /// User-visible prompt name.
    public var name: String = ""
    /// Optional user-visible explanation.
    public var promptDescription: String?
    /// Instruction template sent to the agent.
    public var promptTemplate: String = ""
    /// Serialized `PromptContext` set.
    public var showInRawValue: String = ""
    /// Display ordering.
    public var orderNumber: Int = 0
    /// Creation time in Android epoch-millisecond form.
    public var createdAtMilliseconds: Int64 = 0
    /// Whether full context participates in cache identity.
    public var strictContextMatching: Bool = true
    /// Optional per-prompt permission-mode raw value.
    public var permissionModeRawValue: String?
    /// Optional serialized allow set; `nil` inherits global rules.
    public var allowedToolsRawValue: String?
    /// Optional serialized deny set; `nil` inherits global rules.
    public var deniedToolsRawValue: String?
    /// Optional configured-model override.
    public var configuredModelId: UUID?
    /// Android's persisted `editBeforeRun` behavior.
    public var specifyBeforeRun: Bool = false
    /// Whether results remain only in the agent log.
    public var noDocumentCreation: Bool = false
    /// Optional iteration cap; zero means unlimited.
    public var maxIterations: Int?
    /// Whether installed-document inventory is included automatically.
    public var autoIncludeDocuments: Bool = false
    /// Whether commentary content is included automatically.
    public var autoIncludeCommentaries: Bool = false
    /// Whether the prompt is visible only for Bible documents.
    public var bibleOnly: Bool = false
    /// Whether the prompt performs a direct text transformation without tools.
    public var isTextTransformation: Bool = false
    /// Optional user or add-on category identity.
    public var categoryId: UUID?

    /// Typed contexts reconstructed from durable raw values.
    public var showIn: Set<PromptContext> {
        get { AIModelValueCodec.decodeSet(showInRawValue, as: PromptContext.self) }
        set { showInRawValue = AIModelValueCodec.encodeSet(newValue) }
    }

    /// Typed per-prompt permission mode.
    public var permissionMode: AIPermissionMode? {
        get { permissionModeRawValue.flatMap(AIPermissionMode.init(rawValue:)) }
        set { permissionModeRawValue = newValue?.rawValue }
    }

    /// Typed allow-set override, preserving `nil` versus empty.
    public var allowedTools: Set<AgentTool>? {
        get { allowedToolsRawValue.map { AIModelValueCodec.decodeSet($0, as: AgentTool.self) } }
        set { allowedToolsRawValue = newValue.map(AIModelValueCodec.encodeSet) }
    }

    /// Typed deny-set override, preserving `nil` versus empty.
    public var deniedTools: Set<AgentTool>? {
        get { deniedToolsRawValue.map { AIModelValueCodec.decodeSet($0, as: AgentTool.self) } }
        set { deniedToolsRawValue = newValue.map(AIModelValueCodec.encodeSet) }
    }

    /**
     Creates an editable prompt row without saving it.

     Inputs mirror Android v23, including the `specifyBeforeRun` property stored there under
     `editBeforeRun`. Construction has no side effects and cannot fail.
     */
    public init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        promptTemplate: String,
        showIn: Set<PromptContext> = [],
        orderNumber: Int = 0,
        createdAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        strictContextMatching: Bool = true,
        permissionMode: AIPermissionMode? = nil,
        allowedTools: Set<AgentTool>? = nil,
        deniedTools: Set<AgentTool>? = nil,
        configuredModelId: UUID? = nil,
        specifyBeforeRun: Bool = false,
        noDocumentCreation: Bool = false,
        maxIterations: Int? = nil,
        autoIncludeDocuments: Bool = false,
        autoIncludeCommentaries: Bool = false,
        bibleOnly: Bool = false,
        isTextTransformation: Bool = false,
        categoryId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        promptDescription = description
        self.promptTemplate = promptTemplate
        showInRawValue = AIModelValueCodec.encodeSet(showIn)
        self.orderNumber = orderNumber
        self.createdAtMilliseconds = createdAtMilliseconds
        self.strictContextMatching = strictContextMatching
        permissionModeRawValue = permissionMode?.rawValue
        allowedToolsRawValue = allowedTools.map(AIModelValueCodec.encodeSet)
        deniedToolsRawValue = deniedTools.map(AIModelValueCodec.encodeSet)
        self.configuredModelId = configuredModelId
        self.specifyBeforeRun = specifyBeforeRun
        self.noDocumentCreation = noDocumentCreation
        self.maxIterations = maxIterations
        self.autoIncludeDocuments = autoIncludeDocuments
        self.autoIncludeCommentaries = autoIncludeCommentaries
        self.bibleOnly = bibleOnly
        self.isTextTransformation = isTextTransformation
        self.categoryId = categoryId
    }

    /**
     Produces a detached value copy while preserving the configured-model identity.

     - Returns: A new unmanaged prompt with every behavior field copied.
     - Side effects: none.
     - Failure modes: none.
     */
    public func detachedCopy() -> AgentPrompt {
        detachedCopy(configuredModelId: configuredModelId)
    }

    /**
     Produces a detached value copy with an explicit configured-model replacement.

     - Parameter configuredModelId: Replacement model identity, including nil to clear it.
     - Returns: A new unmanaged prompt with every other behavior field copied.
     - Side effects: none.
     - Failure modes: none.
     */
    public func detachedCopy(configuredModelId: UUID?) -> AgentPrompt {
        AgentPrompt(
            id: id,
            name: name,
            description: promptDescription,
            promptTemplate: promptTemplate,
            showIn: showIn,
            orderNumber: orderNumber,
            createdAtMilliseconds: createdAtMilliseconds,
            strictContextMatching: strictContextMatching,
            permissionMode: permissionMode,
            allowedTools: allowedTools,
            deniedTools: deniedTools,
            configuredModelId: configuredModelId,
            specifyBeforeRun: specifyBeforeRun,
            noDocumentCreation: noDocumentCreation,
            maxIterations: maxIterations,
            autoIncludeDocuments: autoIncludeDocuments,
            autoIncludeCommentaries: autoIncludeCommentaries,
            bibleOnly: bibleOnly,
            isTextTransformation: isTextTransformation,
            categoryId: categoryId
        )
    }
}

/**
 Android-compatible set of AI-excluded document initials with Java UTF-16 identity.

 Swift `Set<String>` merges canonically equivalent composed/decomposed spellings, while Java
 `HashSet<String>` uses exact UTF-16 `String.equals`. This value keeps a sorted exact-identity array
 so both spellings can coexist, mutations are set-like, equality is order-insensitive, and persisted
 JSON remains deterministic without changing Android's raw string-array schema.
 */
public struct AIExcludedDocumentIdentities: Equatable, Sendable, ExpressibleByArrayLiteral, Sequence {
    /// Deterministic storage sorted by unsigned Java UTF-16 code-unit order.
    private var storage: [String]

    /** Creates a de-duplicated, deterministic exact-identity collection. */
    public init<S: Sequence>(_ values: S) where S.Element == String {
        var seen = Set<SwordJavaExactStringIdentity>()
        storage = values.filter {
            seen.insert(SwordJavaExactStringIdentity($0)).inserted
        }.sorted(by: Self.javaUTF16Precedes)
    }

    /** Creates a collection from an array literal without Swift canonical normalization. */
    public init(arrayLiteral elements: String...) {
        self.init(elements)
    }

    /// Number of Java-exact identities.
    public var count: Int { storage.count }

    /// Whether no document identities are excluded.
    public var isEmpty: Bool { storage.isEmpty }

    /// Deterministically ordered values used by Android-compatible JSON serialization.
    public var values: [String] { storage }

    /** Returns whether one exact Java UTF-16 identity is present. */
    public func contains(_ value: String) -> Bool {
        let identity = SwordJavaExactStringIdentity(value)
        return storage.contains { SwordJavaExactStringIdentity($0) == identity }
    }

    /** Inserts one Java-exact identity and restores deterministic serialization order. */
    @discardableResult
    public mutating func insert(_ value: String) -> Bool {
        guard !contains(value) else { return false }
        storage.append(value)
        storage.sort(by: Self.javaUTF16Precedes)
        return true
    }

    /** Removes only the Java-exact identity supplied by the caller. */
    @discardableResult
    public mutating func remove(_ value: String) -> Bool {
        let identity = SwordJavaExactStringIdentity(value)
        guard let index = storage.firstIndex(where: {
            SwordJavaExactStringIdentity($0) == identity
        }) else { return false }
        storage.remove(at: index)
        return true
    }

    /** Iterates deterministic Java-exact values without exposing mutable backing storage. */
    public func makeIterator() -> IndexingIterator<[String]> {
        storage.makeIterator()
    }

    /** Compares deterministic storage with Java exactness rather than Swift normalization. */
    public static func == (
        lhs: AIExcludedDocumentIdentities,
        rhs: AIExcludedDocumentIdentities
    ) -> Bool {
        lhs.storage.count == rhs.storage.count
            && zip(lhs.storage, rhs.storage).allSatisfy {
                SwordJavaExactStringIdentity($0.0) == SwordJavaExactStringIdentity($0.1)
            }
    }

    /** Orders strings lexicographically by unsigned Java UTF-16 code units. */
    private static func javaUTF16Precedes(_ lhs: String, _ rhs: String) -> Bool {
        SwordJavaExactStringIdentity(lhs).utf16CodeUnits.lexicographicallyPrecedes(
            SwordJavaExactStringIdentity(rhs).utf16CodeUnits
        )
    }
}

/** Persists Android's singleton global AI settings in CloudKit-capable user data. */
@Model
public final class GlobalAISettings {
    /// Android's cross-device singleton identity.
    public static let singletonID = UUID(uuidString: "a1000000-0000-0000-0000-000000000001")!

    /// Stable singleton primary identity.
    public var id: UUID = GlobalAISettings.singletonID
    /// Optional global permission-mode raw value.
    public var agentPermissionModeRawValue: String?
    /// Optional global allow set.
    public var permanentlyAllowedToolsRawValue: String?
    /// Optional global deny set.
    public var permanentlyDeniedToolsRawValue: String?
    /// Serialized document initials excluded from AI access.
    public var aiExcludedDocumentsRawValue: String = ""
    /// Commentary response-token ceiling.
    public var commentaryMaxResponseTokens: Int = 15_000
    /// Serialized hidden built-in prompt IDs.
    public var hiddenBuiltInPromptsRawValue: String = ""
    /// Global agent iteration cap; zero means unlimited.
    public var maxIterations: Int = 10
    /// Serialized commentary initials disabled for automatic inclusion.
    public var commentaryDeselectedRawValue: String = ""
    /// Global configured-model identity.
    public var defaultModelId: UUID?
    /// Optional BCP 47 response-language tag.
    public var aiLanguage: String?
    /// Whether every prompt without an explicit model asks before execution.
    public var askModelBeforeRun: Bool = false
    /// Whether the AI disclaimer has been accepted.
    public var aiDisclaimerAccepted: Bool = false
    /// Serialized hidden built-in category IDs.
    public var hiddenBuiltInCategoriesRawValue: String = ""
    /// Optional custom agent system prompt.
    public var customAgentSystemPrompt: String?
    /// Optional custom direct-transformation system prompt.
    public var customTextTransformationSystemPrompt: String?
    /// Serialized favorite prompt IDs.
    public var favoritePromptsRawValue: String = ""
    /// Raw-log retention in days; `nil` disables automatic deletion.
    public var rawLogRetentionDays: Int? = 30
    /// Whether successful completion hides the agent log automatically.
    public var autoHideAgentLogOnCompletion: Bool = false

    /// Typed global permission mode, defaulting to Android's conservative `alwaysAsk` behavior.
    public var agentPermissionMode: AIPermissionMode? {
        get { agentPermissionModeRawValue.flatMap(AIPermissionMode.init(rawValue:)) }
        set { agentPermissionModeRawValue = newValue?.rawValue }
    }

    /// Typed global allow set, preserving `nil` inheritance state.
    public var permanentlyAllowedTools: Set<AgentTool>? {
        get { permanentlyAllowedToolsRawValue.map { AIModelValueCodec.decodeSet($0, as: AgentTool.self) } }
        set { permanentlyAllowedToolsRawValue = newValue.map(AIModelValueCodec.encodeSet) }
    }

    /// Typed global deny set, preserving `nil` inheritance state.
    public var permanentlyDeniedTools: Set<AgentTool>? {
        get { permanentlyDeniedToolsRawValue.map { AIModelValueCodec.decodeSet($0, as: AgentTool.self) } }
        set { permanentlyDeniedToolsRawValue = newValue.map(AIModelValueCodec.encodeSet) }
    }

    /// Typed excluded-document initials retaining Java-distinct Unicode spellings.
    public var aiExcludedDocuments: AIExcludedDocumentIdentities {
        get { AIModelValueCodec.decodeExactStrings(aiExcludedDocumentsRawValue) }
        set { aiExcludedDocumentsRawValue = AIModelValueCodec.encodeExactStrings(newValue) }
    }

    /// Typed hidden built-in prompt IDs.
    public var hiddenBuiltInPrompts: Set<UUID> {
        get { AIModelValueCodec.decodeUUIDs(hiddenBuiltInPromptsRawValue) }
        set { hiddenBuiltInPromptsRawValue = AIModelValueCodec.encodeUUIDs(newValue) }
    }

    /// Typed hidden built-in category IDs.
    public var hiddenBuiltInCategories: Set<UUID> {
        get { AIModelValueCodec.decodeUUIDs(hiddenBuiltInCategoriesRawValue) }
        set { hiddenBuiltInCategoriesRawValue = AIModelValueCodec.encodeUUIDs(newValue) }
    }

    /// Typed favorite prompt IDs.
    public var favoritePrompts: Set<UUID> {
        get { AIModelValueCodec.decodeUUIDs(favoritePromptsRawValue) }
        set { favoritePromptsRawValue = AIModelValueCodec.encodeUUIDs(newValue) }
    }

    /** Creates Android's singleton settings row with v23 defaults. */
    public init(id: UUID = GlobalAISettings.singletonID) {
        self.id = id
    }
}

/**
 Persists one device's cumulative model usage so cross-device sums avoid last-writer loss.
 */
@Model
public final class LLMUsageRecord {
    /// Stable usage-row identity.
    public var id: UUID = UUID()
    /// Configured model being measured.
    public var configuredModelId: UUID = UUID()
    /// Stable device identifier; it is not a credential.
    public var deviceId: String = ""
    /// Non-cached input tokens.
    public var inputTokens: Int64 = 0
    /// Output tokens.
    public var outputTokens: Int64 = 0
    /// Cache-creation input tokens.
    public var cacheCreationTokens: Int64 = 0
    /// Cache-read input tokens.
    public var cacheReadTokens: Int64 = 0
    /// Cumulative estimated cost in US dollars.
    public var estimatedCostUSD: Double = 0

    /** Creates an unsaved cumulative usage row. */
    public init(id: UUID = UUID(), configuredModelId: UUID, deviceId: String) {
        self.id = id
        self.configuredModelId = configuredModelId
        self.deviceId = deviceId
    }
}

/** Persists a model override for a code-owned built-in prompt. */
@Model
public final class BuiltInPromptOverride {
    /// Built-in prompt identity being overridden.
    public var id: UUID = UUID()
    /// Configured model override; `nil` restores global model resolution.
    public var configuredModelId: UUID?

    /** Creates an unsaved built-in override row. */
    public init(id: UUID, configuredModelId: UUID? = nil) {
        self.id = id
        self.configuredModelId = configuredModelId
    }
}

/**
 Stores one device-local raw LLM log matching Android v23.

 The compressed or plain log payload is deliberately registered only in the local SwiftData
 configuration. Provider credentials are never accepted by this model.
 */
@Model
public final class LLMRawLogRecord {
    /// Stable log identity.
    public var id: UUID = UUID()
    /// Optional originating prompt identity.
    public var promptId: UUID?
    /// Prompt name retained after prompt deletion.
    public var promptName: String = ""
    /// Prompt description retained after prompt deletion.
    public var promptDescription: String?
    /// Optional configured-model identity.
    public var configuredModelId: UUID?
    /// Model name retained after model deletion.
    public var modelName: String = ""
    /// Provider raw value retained after provider deletion.
    public var providerType: String = ""
    /// Event time in Android epoch-millisecond form.
    public var timestampMilliseconds: Int64 = 0
    /// Total input tokens across the run.
    public var totalInputTokens: Int64 = 0
    /// Total output tokens across the run.
    public var totalOutputTokens: Int64 = 0
    /// Estimated run cost in US dollars.
    public var estimatedCostUSD: Double = 0
    /// Formatted raw log bytes; callers may gzip before insertion.
    public var logData: Data = Data()
    /// Number of model iterations in the run.
    public var iterationCount: Int = 0
    /// Whether the run ended with an error or cancellation.
    public var wasError: Bool = false

    /** Creates an unsaved local raw-log row. */
    public init(
        id: UUID = UUID(),
        promptId: UUID? = nil,
        promptName: String = "",
        promptDescription: String? = nil,
        configuredModelId: UUID? = nil,
        modelName: String = "",
        providerType: String = "",
        timestampMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        totalInputTokens: Int64 = 0,
        totalOutputTokens: Int64 = 0,
        estimatedCostUSD: Double = 0,
        logData: Data,
        iterationCount: Int = 0,
        wasError: Bool = false
    ) {
        self.id = id
        self.promptId = promptId
        self.promptName = promptName
        self.promptDescription = promptDescription
        self.configuredModelId = configuredModelId
        self.modelName = modelName
        self.providerType = providerType
        self.timestampMilliseconds = timestampMilliseconds
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.logData = logData
        self.iterationCount = iterationCount
        self.wasError = wasError
    }
}

/**
 Declares the only supported SwiftData placement for AI models.

 Cloud-syncable rows mirror Android's syncable AI settings database. Raw logs remain device-local.
 Credentials are structurally excluded because `AICredentialStore` is not a `PersistentModel`.
 */
public enum AIModelRegistration {
    /// Models that belong in the app's CloudKit-capable user-data configuration.
    public static var cloudSyncableModels: [any PersistentModel.Type] {
        [
            LLMProviderConfig.self,
            LLMConfiguredModel.self,
            AgentPrompt.self,
            PromptCategory.self,
            GlobalAISettings.self,
            LLMUsageRecord.self,
            BuiltInPromptOverride.self,
        ]
    }

    /// Models that must remain in the device-local SwiftData configuration.
    public static var localOnlyModels: [any PersistentModel.Type] {
        [LLMRawLogRecord.self]
    }
}

/** Scalar encoding helpers that preserve Android set semantics without transformable fields. */
private enum AIModelValueCodec {
    /** Encodes raw-representable values as a stable JSON string array. */
    static func encodeSet<Value: RawRepresentable>(_ values: Set<Value>) -> String
    where Value.RawValue == String {
        encodeStrings(Set(values.map(\.rawValue)))
    }

    /** Decodes known JSON raw values and ignores values introduced by a newer Android build. */
    static func decodeSet<Value: RawRepresentable & Hashable>(
        _ value: String,
        as type: Value.Type
    ) -> Set<Value> where Value.RawValue == String {
        Set(decodeStrings(value).compactMap(Value.init(rawValue:)))
    }

    /** Encodes arbitrary strings using JSON so commas and Unicode round-trip safely. */
    static func encodeStrings(_ values: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(values.sorted()) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /** Decodes JSON string sets, returning an empty set for malformed historical data. */
    static func decodeStrings(_ value: String) -> Set<String> {
        guard let data = value.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values)
    }

    /** Encodes AI document exclusions in stable Java UTF-16 order without canonical collapsing. */
    static func encodeExactStrings(_ values: AIExcludedDocumentIdentities) -> String {
        guard let data = try? JSONEncoder().encode(values.values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /** Decodes AI document exclusions while retaining Java-distinct Unicode spellings. */
    static func decodeExactStrings(_ value: String) -> AIExcludedDocumentIdentities {
        guard let data = value.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return AIExcludedDocumentIdentities(values)
    }

    /** Encodes UUID sets as stable lowercase JSON strings. */
    static func encodeUUIDs(_ values: Set<UUID>) -> String {
        encodeStrings(Set(values.map { $0.uuidString.lowercased() }))
    }

    /** Decodes UUID sets, ignoring malformed identifiers. */
    static func decodeUUIDs(_ value: String) -> Set<UUID> {
        Set(decodeStrings(value).compactMap(UUID.init(uuidString:)))
    }
}
