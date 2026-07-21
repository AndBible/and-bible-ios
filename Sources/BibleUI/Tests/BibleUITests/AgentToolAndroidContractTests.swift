import BibleCore
import CryptoKit
import Foundation
import XCTest
@testable import BibleUI

/**
 Protects the complete Android agent-tool registry, checked-in schemas, typed dispatch, terminal
 outputs, and invocation-specific permission behavior.

 The expected schema digests and required/property sets were derived from detached Android
 `origin/current-stable` commit `0f3b85823`. Deterministic actors avoid app state and network I/O.
 */
final class AgentToolAndroidContractTests: XCTestCase {
    /**
     Verifies all 38 registry closures decode and execute as distinct typed requests.

     Failure means a registered Android tool is missing, collapsed into another command, or no
     longer reaches the domain execution boundary with its own typed identity.
     */
    func testCompleteRegistryExecutesEveryTypedAndroidTool() async throws {
        let domain = RecordingBibleUIAgentDomain()
        let registry = try AgentToolRegistry(
            dispatcher: BibleUIAgentToolDispatcher(domain: domain)
        )
        let context = AgentExecutionContext(promptId: Self.promptID)

        for tool in AgentTool.allCases {
            let registration = try registry.registration(for: tool)
            let result = try await registration.execute(
                try Self.validArguments(for: tool),
                context
            )
            XCTAssertFalse(result.isError, tool.rawValue)
        }

        let requests = await domain.recordedRequests()
        XCTAssertEqual(requests.count, 38)
        XCTAssertEqual(requests.map(\.tool), AgentTool.allCases)
    }

    /**
     Verifies provider definitions exactly match Android descriptions and parameter schemas.

     Each digest covers the full description and schema JSON. Explicit property and required sets
     make schema failures actionable instead of exposing only a changed digest.
     */
    func testDefinitionsMatchStableAndroidSchemasAndRequiredParameters() throws {
        let registry = try AgentToolRegistry(
            dispatcher: BibleUIAgentToolDispatcher(domain: RecordingBibleUIAgentDomain())
        )
        XCTAssertEqual(Self.contracts.count, 38)
        XCTAssertEqual(Self.definitionDigests.count, 38)

        for tool in AgentTool.allCases {
            let definition = try registry.registration(for: tool).definition
            let properties = try XCTUnwrap(
                definition.parameters["properties"]?.objectValue,
                tool.rawValue
            )
            let required = Set(
                definition.parameters["required"]?.arrayValue?
                    .compactMap(\.stringValue) ?? []
            )
            let expected = try XCTUnwrap(Self.contracts[tool], tool.rawValue)
            XCTAssertEqual(Set(properties.keys), expected.properties, tool.rawValue)
            XCTAssertEqual(required, expected.required, tool.rawValue)
            XCTAssertEqual(
                try Self.definitionDigest(definition),
                Self.definitionDigests[tool],
                tool.rawValue
            )
        }
    }

    /**
     Verifies Android's coarse access classes and dynamic My Documents exceptions.

     Failure means reads or structural completion could prompt for write approval, ordinary writes
     could bypass approval, or AI Documents identity precedence could diverge from Android.
     */
    func testPermissionRoutingMatchesReadWriteStructuralAndAIDocumentBehavior() async throws {
        let domain = RecordingBibleUIAgentDomain(aiDocumentIDs: [Self.aiDocumentID])
        let registry = try AgentToolRegistry(
            dispatcher: BibleUIAgentToolDispatcher(domain: domain)
        )
        let context = AgentExecutionContext(promptId: Self.promptID)

        for tool in AgentTool.allCases {
            let requiresPermission = try await registry.registration(for: tool).requiresPermission(
                try Self.validArguments(for: tool),
                context
            )
            XCTAssertEqual(requiresPermission, tool.access == .write, tool.rawValue)
        }

        let addPage = try registry.registration(for: .addMyDocumentPage)
        let pageValues: [String: JSONValue] = [
            "title": .string("Title"),
            "content": .string("Body"),
        ]
        let omittedTarget = try await addPage.requiresPermission(pageValues, context)
        let explicitAIInitials = try await addPage.requiresPermission(
            pageValues.merging([
                "documentId": .string(Self.otherDocumentID.uuidString),
                "initials": .string(MyDocumentManagementSession.aiDocumentsInitials),
            ]) { _, new in new },
            context
        )
        let aiIDWithConflictingInitials = try await addPage.requiresPermission(
            pageValues.merging([
                "documentId": .string(Self.aiDocumentID.uuidString),
                "initials": .string("CONFLICTING"),
            ]) { _, new in new },
            context
        )
        let ordinaryDocument = try await addPage.requiresPermission(
            pageValues.merging([
                "documentId": .string(Self.otherDocumentID.uuidString),
            ]) { _, new in new },
            context
        )
        XCTAssertTrue(omittedTarget)
        XCTAssertFalse(explicitAIInitials)
        XCTAssertFalse(aiIDWithConflictingInitials)
        XCTAssertTrue(ordinaryDocument)
    }

    /**
     Verifies a created page is reported by execution and can be edited without another approval.

     A different page remains permission-gated. Failure would break Android's per-run ownership
     rule or allow unrelated My Documents pages to inherit that exemption.
     */
    func testCreatedPageOwnershipRelaxesOnlyMatchingEditPermission() async throws {
        let domain = RecordingBibleUIAgentDomain()
        let registry = try AgentToolRegistry(
            dispatcher: BibleUIAgentToolDispatcher(domain: domain)
        )
        let baseContext = AgentExecutionContext(promptId: Self.promptID)
        let created = try await registry.registration(for: .addMyDocumentPage).execute(
            try Self.validArguments(for: .addMyDocumentPage),
            baseContext
        )
        XCTAssertEqual(created.createdPageIds, [Self.createdPageID])

        let ownedContext = AgentExecutionContext(
            promptId: Self.promptID,
            createdPageIds: created.createdPageIds
        )
        let edit = try registry.registration(for: .editMyDocumentPage)
        let ownedPage = try await edit.requiresPermission([
            "pageId": .string(Self.createdPageID.uuidString),
            "title": .string("Owned"),
        ], ownedContext)
        let otherPage = try await edit.requiresPermission([
            "pageId": .string(Self.otherPageID.uuidString),
            "title": .string("Other"),
        ], ownedContext)
        XCTAssertFalse(ownedPage)
        XCTAssertTrue(otherPage)
    }

    /**
     Verifies every structural terminal result retains its Android-shaped data and typed output.

     Failure means successful finish tools could loop back to the model or lose their destination,
     while title-only output could be mistaken for a finished document.
     */
    func testStructuralToolsReturnEveryTerminalOutput() async throws {
        let registry = try AgentToolRegistry(
            dispatcher: BibleUIAgentToolDispatcher(domain: RecordingBibleUIAgentDomain())
        )
        let context = AgentExecutionContext(promptId: Self.promptID)

        let title = try await registry.registration(for: .setDocumentTitle).execute(
            ["title": .string("**Exact** title")],
            context
        )
        XCTAssertNil(title.completion)
        XCTAssertEqual(title.data?.objectValue?["title"], .string("Exact title"))

        let studyPad = try await registry.registration(for: .finishWithStudyPad).execute(
            try Self.validArguments(for: .finishWithStudyPad),
            context
        )
        XCTAssertEqual(
            studyPad.completion,
            .studyPad(
                labelId: Self.labelID,
                scrollToEntryId: Self.entryID,
                message: "StudyPad ready"
            )
        )

        let myDocument = try await registry.registration(for: .finishWithMyDocumentPage).execute(
            try Self.validArguments(for: .finishWithMyDocumentPage),
            context
        )
        XCTAssertEqual(
            myDocument.completion,
            .myDocumentPage(
                documentInitials: MyDocumentManagementSession.aiDocumentsInitials,
                pageKey: "page_\(Self.createdPageID.uuidString.lowercased())",
                message: "Page ready"
            )
        )

        let withoutDocument = try await registry.registration(for: .finishWithoutDocument).execute(
            try Self.validArguments(for: .finishWithoutDocument),
            context
        )
        XCTAssertEqual(
            withoutDocument.completion,
            .withoutDocument(message: "No document needed")
        )
    }

    private struct DefinitionContract {
        let properties: Set<String>
        let required: Set<String>
    }

    private static let promptID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let labelID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private static let bookmarkID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    private static let entryID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
    private static let aiDocumentID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
    private static let otherDocumentID = UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
    fileprivate static let createdPageID = UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
    private static let otherPageID = UUID(uuidString: "80000000-0000-0000-0000-000000000008")!
    private static let windowID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!

    /** Returns one parser-valid invocation for each exact Android tool. */
    private static func validArguments(for tool: AgentTool) throws -> [String: JSONValue] {
        switch tool {
        case .getVerseContent:
            return ["book": .string("KJV"), "verseRef": .string("John.3.16")]
        case .searchBible:
            return ["query": .string("love"), "books": .array([.string("KJV")])]
        case .searchByStrongs:
            return ["strongsNumber": .string("H7225"), "book": .string("KJV")]
        case .getCommentaries:
            return [
                "verseRef": .string("John.3.16"),
                "commentaries": .array([.string("MHC")]),
            ]
        case .getDictionaryEntry:
            return ["dictionary": .string("StrongsGreek"), "key": .string("G26")]
        case .getBookmarksForVerse:
            return ["verseRef": .string("John.3.16")]
        case .getBookmarksWithLabel:
            return [
                "labelId": .string(labelID.uuidString),
                "fields": .array([.string("verseRange"), .string("notes")]),
            ]
        case .getAllLabels:
            return [:]
        case .getStudyPadContent:
            return ["labelId": .string(labelID.uuidString), "mode": .string("page")]
        case .searchStudyPads:
            return ["query": .string("grace")]
        case .getInstalledDocuments:
            return ["category": .string("BIBLE")]
        case .getMyDocuments:
            return [:]
        case .getMyDocumentPages:
            return ["initials": .string(MyDocumentManagementSession.aiDocumentsInitials)]
        case .getGenBookKeys:
            return ["book": .string("Pilgrim")]
        case .getGenBookContent:
            return ["book": .string("Pilgrim"), "key": .string("chapter-1")]
        case .getWindows:
            return [:]
        case .createBookmark:
            return [
                "verseRef": .string("John.3.16"),
                "note": .string("Loved the world"),
                "labelIds": .array([.string(labelID.uuidString)]),
                "primaryLabelId": .string(labelID.uuidString),
                "startOffset": .number(0),
                "endOffset": .number(4),
            ]
        case .addBookmarkNote:
            return ["bookmarkId": .string(bookmarkID.uuidString), "note": .string("Note")]
        case .updateBookmarkNote:
            return ["bookmarkId": .string(bookmarkID.uuidString), "note": .string("Updated")]
        case .createLabel:
            return ["name": .string("Research"), "color": .number(0xFF00AA)]
        case .addLabelToBookmark, .removeLabelFromBookmark:
            return [
                "bookmarkId": .string(bookmarkID.uuidString),
                "labelId": .string(labelID.uuidString),
            ]
        case .deleteBookmark:
            return ["bookmarkId": .string(bookmarkID.uuidString)]
        case .deleteLabel:
            return ["labelId": .string(labelID.uuidString)]
        case .addStudyPadEntry:
            return ["labelId": .string(labelID.uuidString), "text": .string("Entry")]
        case .updateStudyPadTextEntry:
            return ["entryId": .string(entryID.uuidString), "text": .string("Updated entry")]
        case .createStudyPad:
            return [
                "name": .string("Study"),
                "items": .array([.object([
                    "type": .string("text"),
                    "text": .string("First entry"),
                ])]),
            ]
        case .createMyDocument:
            return ["name": .string("Research Notes")]
        case .addMyDocumentPage:
            return ["title": .string("Page"), "content": .string("Body")]
        case .editMyDocumentPage:
            return ["pageId": .string(otherPageID.uuidString), "title": .string("Revised")]
        case .deleteMyDocumentPage:
            return ["pageId": .string(otherPageID.uuidString)]
        case .createWindow:
            return [:]
        case .manageWindow:
            return ["windowId": .string(windowID.uuidString), "action": .string("MINIMIZE")]
        case .setWindowDocument:
            return ["windowId": .string(windowID.uuidString), "documentInitials": .string("KJV")]
        case .setDocumentTitle:
            return ["title": .string("Generated title")]
        case .finishWithStudyPad:
            return [
                "labelId": .string(labelID.uuidString),
                "scrollToEntryId": .string(entryID.uuidString),
                "message": .string("StudyPad ready"),
            ]
        case .finishWithMyDocumentPage:
            return [
                "pageId": .string(createdPageID.uuidString),
                "message": .string("Page ready"),
            ]
        case .finishWithoutDocument:
            return ["message": .string("No document needed")]
        }
    }

    /** Computes a canonical digest over the complete Android-facing definition payload. */
    private static func definitionDigest(_ definition: LLMToolDefinition) throws -> String {
        let payload = JSONValue.object([
            "description": .string(definition.description),
            "parameters": .object(definition.parameters),
        ])
        return SHA256.hash(data: try payload.encodedData())
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static let contracts: [AgentTool: DefinitionContract] = [
        .getVerseContent: .init(properties: ["book", "verseRef", "format"], required: ["book", "verseRef"]),
        .searchBible: .init(properties: ["query", "books", "maxResults", "offset"], required: ["query"]),
        .searchByStrongs: .init(properties: ["strongsNumber", "book", "maxResults", "offset"], required: ["strongsNumber"]),
        .getCommentaries: .init(properties: ["verseRef", "commentaries", "format"], required: ["verseRef"]),
        .getDictionaryEntry: .init(properties: ["dictionary", "key", "format"], required: ["dictionary", "key"]),
        .getBookmarksForVerse: .init(properties: ["verseRef"], required: ["verseRef"]),
        .getBookmarksWithLabel: .init(properties: ["labelId", "maxResults", "fields"], required: ["labelId"]),
        .getAllLabels: .init(properties: [], required: []),
        .getStudyPadContent: .init(properties: ["labelId", "mode", "offset", "limit"], required: ["labelId"]),
        .searchStudyPads: .init(properties: ["query"], required: ["query"]),
        .getInstalledDocuments: .init(properties: ["category"], required: []),
        .getMyDocuments: .init(properties: [], required: []),
        .getMyDocumentPages: .init(properties: ["documentId", "initials", "includeContent"], required: []),
        .getGenBookKeys: .init(properties: ["book", "offset", "limit"], required: ["book"]),
        .getGenBookContent: .init(properties: ["book", "key", "format"], required: ["book", "key"]),
        .getWindows: .init(properties: [], required: []),
        .createBookmark: .init(properties: ["verseRef", "note", "noteContentType", "labelIds", "primaryLabelId", "bookInitials", "startOffset", "endOffset"], required: ["verseRef"]),
        .addBookmarkNote: .init(properties: ["bookmarkId", "note", "contentType"], required: ["bookmarkId", "note"]),
        .updateBookmarkNote: .init(properties: ["bookmarkId", "note"], required: ["bookmarkId", "note"]),
        .createLabel: .init(properties: ["name", "color"], required: ["name"]),
        .addLabelToBookmark: .init(properties: ["bookmarkId", "labelId"], required: ["bookmarkId", "labelId"]),
        .deleteBookmark: .init(properties: ["bookmarkId"], required: ["bookmarkId"]),
        .deleteLabel: .init(properties: ["labelId", "deleteOrphanedBookmarks"], required: ["labelId"]),
        .removeLabelFromBookmark: .init(properties: ["bookmarkId", "labelId"], required: ["bookmarkId", "labelId"]),
        .addStudyPadEntry: .init(properties: ["labelId", "text", "contentType", "orderNumber"], required: ["labelId", "text"]),
        .updateStudyPadTextEntry: .init(properties: ["entryId", "text"], required: ["entryId", "text"]),
        .createStudyPad: .init(properties: ["name", "color", "items"], required: ["name", "items"]),
        .createMyDocument: .init(properties: ["name", "description"], required: ["name"]),
        .addMyDocumentPage: .init(properties: ["documentId", "initials", "title", "content", "contentType"], required: ["title", "content"]),
        .editMyDocumentPage: .init(properties: ["pageId", "title", "content", "orderNumber"], required: ["pageId"]),
        .deleteMyDocumentPage: .init(properties: ["pageId"], required: ["pageId"]),
        .createWindow: .init(properties: ["documentInitials", "key", "minimized"], required: []),
        .manageWindow: .init(properties: ["windowId", "action"], required: ["windowId", "action"]),
        .setWindowDocument: .init(properties: ["windowId", "documentInitials", "key"], required: ["documentInitials"]),
        .setDocumentTitle: .init(properties: ["title"], required: ["title"]),
        .finishWithStudyPad: .init(properties: ["labelId", "scrollToEntryId", "message"], required: ["labelId", "message"]),
        .finishWithMyDocumentPage: .init(properties: ["pageId", "message"], required: ["pageId", "message"]),
        .finishWithoutDocument: .init(properties: ["message"], required: ["message"]),
    ]

    private static let definitionDigests: [AgentTool: String] = [
        .getAllLabels: "bea375fc94ca1210b5f7cee0f4e2b23486a8241cac3585994c966ce559102838",
        .getBookmarksForVerse: "0a5572c93e5fa4dc32caf512718ee9730f3b7982d063894b587b2c9f60ab19ac",
        .getBookmarksWithLabel: "c6bdd751821d662318a644f61ffa9d4291a240d14153f9c37f2152fb0db1a18b",
        .getCommentaries: "e093c3ebef1cfff749598d7ec92e0be0981e31f65546189d66f80188189ed5c2",
        .getDictionaryEntry: "02da26d7d85bfe47b4038b5b9eeecf25415bdcbee2beb763ee6e067843723373",
        .getGenBookContent: "395bf2e9b16ea58f9def684ecca760592ec69f98a48a7f8b1dd697121785fb4b",
        .getGenBookKeys: "11a0ec37c3eec4993fbf3802d2a8e5cd4a1bd041408384365a84d366387bad63",
        .getInstalledDocuments: "208b4381c9b14a4736a8e9b9a642e5deee93266954a3050d61627ca8c6dbfebd",
        .getMyDocumentPages: "de70d878b3887f9e9c0dd767d11a8cc5d744bb1f83dfabe8876e7eb29d742fbb",
        .getMyDocuments: "cd19adbb12cd7b89204457da7c483f76256f3acb763cb985c0b99fe2e34a3b3c",
        .getStudyPadContent: "37ef1f8f280b1fa9ad5b61abc1703807d75da32252d7aa0e46df38b087fa322c",
        .getVerseContent: "b846ea325d885deb075cc6f28378f9faebd5211453e387018259321339956807",
        .getWindows: "7f2fcfba5bffe2d02a071fdfacdd3c5c30b3a59f03a7caf36744688df727c208",
        .searchBible: "3d1d02dc14b263516edc7acbf27e5d39a21913b528829da31fd54c463811b414",
        .searchByStrongs: "f6f3887a7e9eb410771d4ef581b230896a9cae782860fb3f9688e51c852d3a4e",
        .searchStudyPads: "13850fdefd6b376c3d0b353ba30be779e6511fdcb3a5ff671c9f9f97b94d7306",
        .addBookmarkNote: "62c8a2e2945438436c06c29cef41967ed0bf9862070318f6d1294e3c7b950e92",
        .addLabelToBookmark: "f5453501978d6582f52344eee349091450a1874fabbc4cba629c339082b17e4f",
        .addMyDocumentPage: "f6372085cb101f7abea1522f6f1a15258b579f3edcd65e8dc28d6a3ae7b9459e",
        .addStudyPadEntry: "b770020e274dca54c535d7ceb288f052a8f500447696b5616e7de86ade65aa8d",
        .createBookmark: "b888df6c7c88c287983df0a90a8a6569596fd8a027acb5cf48b759a41ec013d6",
        .createLabel: "b75ac983c4e47689df97e4ff36d649a564c6d7bf968c39728734af14264802a9",
        .createMyDocument: "6bba2f6315b2949cbc629a3ccea1807590f86d26dfcfb8f23ae618820ee74d31",
        .createStudyPad: "e2eb5dae29e7bd6c8fe4270a2e1ffb08f9e745d97722e7c3df1f10bcd45d0577",
        .createWindow: "32cbc02677f664e6a093e17db051c915d643cd887b8eef5499644c685ec29a85",
        .deleteBookmark: "54e7d42c426ae8f890203465a9960126ccf927a9033100108fe69c50377dc82f",
        .deleteLabel: "48e3027e6e817fe76cfffce0210d86c3ad80e6f734a43670e58a3519fdeeedbc",
        .deleteMyDocumentPage: "9de0a3562460bdcc357994924e21596401e1dec015001b332b1650ad31956e84",
        .editMyDocumentPage: "6e13eb8570d4b488079a547be4de3b5bcc5ab3c95cf85f226739e18d20f95f9b",
        .finishWithMyDocumentPage: "1b60851ecca50fa877b71ef7d9d82186704bbf5eb8d4a2e532224fceca675706",
        .finishWithStudyPad: "793a003e9f3c1b5a5b6964af734d04a9fa0670db86ccd03e3ad9750cc92b003f",
        .finishWithoutDocument: "ee4f9d3dd9f2f4604d26aceb601417880870925c7c7d843816302e70570a3029",
        .manageWindow: "c119a3c23b4ed5914deee9bd8fec6dc137a229d7fdceb679f4373bd4e4a7e957",
        .removeLabelFromBookmark: "fd39e1507efa6996f51a300b01ae74fd972640324427941fdabe58d13f091b34",
        .setDocumentTitle: "c7d030aafdaef25f73c4eeee28a8cd015d312bd8472c1a7a27ae60d05a81d84f",
        .setWindowDocument: "34aae9861a067dcd7972dd43695d81c8c6fa13e5d3176d01a192e589049c4551",
        .updateBookmarkNote: "f988fbeaed829fcf342a419d57430665ea7d3526723b4b6f771494bef26fd00c",
        .updateStudyPadTextEntry: "49e4da81745ed282827da6756fc08b525f5d9cbcb5be3101f987e9a54003d4db",
    ]
}

/** Deterministic domain actor used to prove typed routing without touching app persistence. */
private actor RecordingBibleUIAgentDomain: BibleUIAgentToolExecuting {
    private var requests: [BibleUIAgentToolRequest] = []
    private let aiDocumentIDs: Set<UUID>

    init(aiDocumentIDs: Set<UUID> = []) {
        self.aiDocumentIDs = aiDocumentIDs
    }

    func execute(
        _ request: BibleUIAgentToolRequest,
        context: AgentExecutionContext
    ) async throws -> AgentToolResult {
        requests.append(request)
        switch request {
        case .addMyDocumentPage:
            return AgentToolResult(
                data: .object(["created": .bool(true)]),
                createdPageIds: [AgentToolAndroidContractTests.createdPageID]
            )
        case .setDocumentTitle(let title):
            return AgentToolResult(data: .object(["title": .string(title)]))
        case .finishWithStudyPad(let labelID, let entryID, let message):
            return AgentToolResult(
                data: .object(["finished": .bool(true)]),
                completion: .studyPad(
                    labelId: labelID,
                    scrollToEntryId: entryID,
                    message: message
                )
            )
        case .finishWithMyDocumentPage(let pageID, let message):
            return AgentToolResult(
                data: .object(["finished": .bool(true)]),
                completion: .myDocumentPage(
                    documentInitials: MyDocumentManagementSession.aiDocumentsInitials,
                    pageKey: "page_\(pageID.uuidString.lowercased())",
                    message: message
                )
            )
        case .finishWithoutDocument(let message):
            return AgentToolResult(
                data: .object(["finished": .bool(true)]),
                completion: .withoutDocument(message: message)
            )
        default:
            return AgentToolResult(data: .object(["tool": .string(request.tool.rawValue)]))
        }
    }

    func isAIDocument(documentID: UUID?, initials: String?) async -> Bool {
        if let documentID { return aiDocumentIDs.contains(documentID) }
        return initials == MyDocumentManagementSession.aiDocumentsInitials
    }

    func recordedRequests() -> [BibleUIAgentToolRequest] {
        requests
    }
}
