import BibleCore
import Foundation
import XCTest
@testable import BibleUI

/**
 Protects configured AI Settings prompt-list behavior against Android's `AiSettingsActivity`.

 Fixtures are detached SwiftData model values only. The suite performs no persistence, module,
 document-picker, network, credential, or filesystem side effects.
 */
@MainActor
final class AIPromptManagementBehaviorTests: XCTestCase {
    /**
     Verifies Android's complete grouping pipeline and category order.

     Setup includes a favorite visible built-in, a favorite hidden built-in, uncategorized and orphaned
     user prompts, a hidden user category, a hidden populated built-in category, an empty user category,
     and an empty built-in category. The expected result is Favorites, Uncategorized, then stable
     `orderNumber` categories; hidden built-ins and empty built-in categories are absent, while the
     empty user category remains. Failure means configured iOS AI Settings has drifted from
     `AiSettingsActivity.loadPrompts()` or its expandable-list initialization.
     */
    func testGroupsMatchAndroidOrderingFilteringAndEmptyCategoryRules() {
        let hiddenUserCategory = PromptCategory(name: "Hidden user", orderNumber: 1, hidden: true)
        let populatedBuiltInCategory = PromptCategory(
            id: BuiltInPromptCatalog.studyCategoryID,
            name: "Study",
            orderNumber: 2
        )
        let emptyUserCategory = PromptCategory(name: "Empty user", orderNumber: 3)
        let emptyBuiltInCategory = PromptCategory(
            id: BuiltInPromptCatalog.notesCategoryID,
            name: "Notes",
            orderNumber: 4
        )

        let favoriteBuiltIn = makePrompt(
            name: "Visible favorite",
            categoryID: populatedBuiltInCategory.id
        )
        let hiddenBuiltIn = makePrompt(
            name: "Hidden favorite",
            categoryID: populatedBuiltInCategory.id
        )
        let uncategorized = makePrompt(name: "Uncategorized")
        let orphaned = makePrompt(name: "Orphaned", categoryID: UUID())
        let hiddenCategoryPrompt = makePrompt(
            name: "Hidden category prompt",
            categoryID: hiddenUserCategory.id
        )
        let entries = [
            ResolvedAgentPrompt(prompt: favoriteBuiltIn, origin: .builtIn),
            ResolvedAgentPrompt(prompt: hiddenBuiltIn, origin: .builtIn),
            ResolvedAgentPrompt(prompt: uncategorized, origin: .user),
            ResolvedAgentPrompt(prompt: orphaned, origin: .user),
            ResolvedAgentPrompt(prompt: hiddenCategoryPrompt, origin: .user),
        ]

        let groups = AIPromptManagementBehavior.groups(
            entries: entries,
            categories: [
                populatedBuiltInCategory,
                emptyBuiltInCategory,
                hiddenUserCategory,
                emptyUserCategory,
            ],
            favoriteIDs: [favoriteBuiltIn.id, hiddenBuiltIn.id],
            hiddenBuiltInPromptIDs: [hiddenBuiltIn.id],
            hiddenBuiltInCategoryIDs: [populatedBuiltInCategory.id]
        )

        XCTAssertEqual(groups.map(\.id), [
            .favorites,
            .uncategorized,
            .category(hiddenUserCategory.id),
            .category(populatedBuiltInCategory.id),
            .category(emptyUserCategory.id),
        ])
        XCTAssertEqual(groups[0].entries.map(\.prompt.id), [favoriteBuiltIn.id])
        XCTAssertEqual(groups[1].entries.map(\.prompt.id), [uncategorized.id, orphaned.id])
        XCTAssertTrue(groups[2].isHidden)
        XCTAssertTrue(groups[3].isHidden)
        XCTAssertTrue(groups[4].entries.isEmpty)
        XCTAssertFalse(groups.contains { $0.id == .category(emptyBuiltInCategory.id) })
        XCTAssertFalse(groups.flatMap(\.entries).contains { $0.prompt.id == hiddenBuiltIn.id })
    }

    /**
     Verifies Favorites is derived after hidden built-ins are filtered.

     The only favorite fixture is a hidden built-in in an otherwise empty built-in category. No group
     should survive. Failure means iOS can expose an empty Favorites header or a hidden prompt through
     its duplicated favorite row, contrary to Android's pre-group filtering order.
     */
    func testHiddenBuiltInFavoriteDoesNotCreateFavoritesGroup() {
        let category = PromptCategory(
            id: BuiltInPromptCatalog.generalCategoryID,
            name: "General"
        )
        let prompt = makePrompt(name: "Hidden", categoryID: category.id)

        let groups = AIPromptManagementBehavior.groups(
            entries: [ResolvedAgentPrompt(prompt: prompt, origin: .builtIn)],
            categories: [category],
            favoriteIDs: [prompt.id],
            hiddenBuiltInPromptIDs: [prompt.id],
            hiddenBuiltInCategoryIDs: []
        )

        XCTAssertTrue(groups.isEmpty)
    }

    /**
     Verifies up/down movement is restricted to editable prompts sharing the source category.

     Category A and B prompts are interleaved in the input to represent global SwiftData ordering.
     Moving the first A prompt down must swap the two adjacent A values without renumbering a third A
     sibling or either B prompt. Boundary checks must return no target. Failure means one category's
     command can reorder prompts displayed under another Android group or rewrite unrelated values.
     */
    func testPromptMovementReordersOnlyCategorySiblings() {
        let categoryA = UUID()
        let categoryB = UUID()
        let firstA = makePrompt(name: "A1", categoryID: categoryA, orderNumber: 10)
        let firstB = makePrompt(name: "B1", categoryID: categoryB, orderNumber: 50)
        let secondA = makePrompt(name: "A2", categoryID: categoryA, orderNumber: 30)
        let secondB = makePrompt(name: "B2", categoryID: categoryB, orderNumber: 60)
        let thirdA = makePrompt(name: "A3", categoryID: categoryA, orderNumber: 80)
        let prompts = [firstA, firstB, secondA, secondB, thirdA]

        XCTAssertNil(AIPromptManagementBehavior.siblingMoveTargetID(
            promptID: firstA.id,
            offset: -1,
            prompts: prompts
        ))
        XCTAssertEqual(AIPromptManagementBehavior.siblingMoveTargetID(
            promptID: firstA.id,
            offset: 1,
            prompts: prompts
        ), secondA.id)
        XCTAssertNil(AIPromptManagementBehavior.siblingMoveTargetID(
            promptID: thirdA.id,
            offset: 1,
            prompts: prompts
        ))

        XCTAssertTrue(AIPromptManagementBehavior.movePrompt(
            promptID: firstA.id,
            offset: 1,
            prompts: prompts
        ))
        XCTAssertEqual(secondA.orderNumber, 10)
        XCTAssertEqual(firstA.orderNumber, 30)
        XCTAssertEqual(thirdA.orderNumber, 80)
        XCTAssertEqual(firstB.orderNumber, 50)
        XCTAssertEqual(secondB.orderNumber, 60)
    }

    /**
     Verifies exported prompt CSV uses Android's exact columns and survives quoted multiline parsing.

     The fixture exercises semicolons, quotes, newlines, typed sets, UUIDs, UTC creation time, and a
     punctuated category name. Shared parser and metadata-decoder round trips are the evidence that
     both editable iOS import and Android import can consume the file. Failure means the configured
     toolbar's export action emits a structurally incompatible prompt CSV. No file is written.
     */
    func testPromptCSVExportMatchesAndroidHeadersAndRoundTripsCategoryMetadata() throws {
        let category = PromptCategory(name: "Study; \"Notes\"")
        let promptID = UUID(uuidString: "59d65e07-3427-46a8-9d9d-36bf5a13cb40")!
        let modelID = UUID(uuidString: "e2e556de-d2e7-4010-966a-334b0f9c1667")!
        let prompt = AgentPrompt(
            id: promptID,
            name: "One; \"Two\"",
            description: "First line\nSecond line",
            promptTemplate: "Explain; then apply",
            showIn: [.verseSelection, .windowMenu],
            orderNumber: 7,
            createdAtMilliseconds: 0,
            strictContextMatching: false,
            permissionMode: .askOncePerRun,
            allowedTools: [.getVerseContent, .createBookmark],
            deniedTools: [.deleteBookmark],
            configuredModelId: modelID,
            bibleOnly: true,
            categoryId: category.id
        )

        let data = AIPromptCSVEncoder.encode(prompts: [prompt], categories: [category])
        let source = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(source.split(separator: "\n", maxSplits: 1).first.map(String.init),
                       AIPromptCSVEncoder.headers.joined(separator: ";"))
        XCTAssertTrue(source.contains(#""One; ""Two""""#))

        let parsed = try XCTUnwrap(PromptCSVParser.parse(data: data).first)
        XCTAssertEqual(parsed.id, promptID)
        XCTAssertEqual(parsed.name, prompt.name)
        XCTAssertEqual(parsed.promptDescription, prompt.promptDescription)
        XCTAssertEqual(parsed.promptTemplate, prompt.promptTemplate)
        XCTAssertEqual(parsed.showIn, prompt.showIn)
        XCTAssertEqual(parsed.permissionMode, prompt.permissionMode)
        XCTAssertEqual(parsed.allowedTools, prompt.allowedTools)
        XCTAssertEqual(parsed.deniedTools, prompt.deniedTools)
        XCTAssertEqual(parsed.configuredModelId, modelID)
        XCTAssertEqual(parsed.createdAtMilliseconds, 0)
        XCTAssertTrue(parsed.bibleOnly)
        XCTAssertEqual(
            try AIPromptCSVCategoryMetadataDecoder.categoryNames(from: data),
            [category.name]
        )
    }

    /**
     Verifies PromptEditActivity's exact toolbar action matrix for new, user, built-in, and add-on prompts.

     A failure means iOS exposes a mutation Android hides, omits Save for a built-in model override,
     or fails to keep Available tools and Help on every loaded editor source.
     */
    func testEditorToolbarActionsMatchAndroidSourceVisibility() {
        let promptID = UUID()

        XCTAssertEqual(
            AIPromptEditorBehavior.toolbarActions(origin: .user, promptID: nil, isLoaded: true),
            [.save, .availableTools, .help]
        )
        XCTAssertEqual(
            AIPromptEditorBehavior.toolbarActions(origin: .user, promptID: promptID, isLoaded: true),
            [.save, .delete, .copyToCustomize, .availableTools, .help]
        )
        XCTAssertEqual(
            AIPromptEditorBehavior.toolbarActions(origin: .builtIn, promptID: promptID, isLoaded: true),
            [.save, .copyToCustomize, .availableTools, .help]
        )
        XCTAssertEqual(
            AIPromptEditorBehavior.toolbarActions(
                origin: .swordPack(moduleName: "Pack"),
                promptID: promptID,
                isLoaded: true
            ),
            [.copyToCustomize, .availableTools, .help]
        )
        XCTAssertTrue(
            AIPromptEditorBehavior.toolbarActions(
                origin: .builtIn,
                promptID: promptID,
                isLoaded: false
            ).isEmpty
        )
    }

    /**
     Verifies draft comparison follows Android ownership and never treats a built-in model pick as saved.

     The initial snapshot represents persisted state. A user field change must be dirty, an add-on is
     always read-only, and a built-in becomes dirty only when its editable model draft changes. Failure
     indicates Back can discard user work silently or built-in selection is bypassing explicit Save.
     */
    func testEditorDirtyStateUsesCapturedDraftAndBuiltInModelBoundary() {
        let modelID = UUID()
        let initial = AIPromptEditorDraftSnapshot(name: "Original", template: "Template")
        var changedName = initial
        changedName.name = "Changed"
        var changedModel = initial
        changedModel.modelID = modelID

        XCTAssertFalse(AIPromptEditorBehavior.isDirty(
            origin: .user,
            initial: initial,
            current: initial
        ))
        XCTAssertTrue(AIPromptEditorBehavior.isDirty(
            origin: .user,
            initial: initial,
            current: changedName
        ))
        XCTAssertFalse(AIPromptEditorBehavior.isDirty(
            origin: .builtIn,
            initial: initial,
            current: changedName
        ))
        XCTAssertTrue(AIPromptEditorBehavior.isDirty(
            origin: .builtIn,
            initial: initial,
            current: changedModel
        ))
        XCTAssertFalse(AIPromptEditorBehavior.isDirty(
            origin: .swordPack(moduleName: "Pack"),
            initial: initial,
            current: changedModel
        ))
    }

    /**
     Verifies the editor applies Android's dependent controls for Bible-only and transformation prompts.

     The source contract is `PromptEditActivity.updateBibleOnlyDependentState()`, which clears
     Workspace and Note Editor, plus `updateTextTransformationDependentState()`, which removes the
     Permissions tab and four irrelevant Advanced rows. Failure means iOS can persist a combination
     Android prevents or expose settings Android deliberately hides. The test has no side effects.
     */
    func testEditorDependentVisibilityAndContextRulesMatchAndroid() {
        let allContexts = Set(PromptContext.allCases)

        XCTAssertEqual(
            AIPromptEditorBehavior.normalizedContexts(allContexts, bibleOnly: true),
            [.verseSelection, .textSelection, .windowMenu]
        )
        XCTAssertEqual(
            AIPromptEditorBehavior.normalizedContexts(allContexts, bibleOnly: false),
            allContexts
        )
        XCTAssertEqual(
            AIPromptEditorBehavior.visibleTabs(isTextTransformation: false),
            [.prompt, .permissions, .advanced]
        )
        XCTAssertEqual(
            AIPromptEditorBehavior.visibleTabs(isTextTransformation: true),
            [.prompt, .advanced]
        )
        XCTAssertEqual(
            AIPromptEditorBehavior.visibleAdvancedFields(isTextTransformation: false),
            AIPromptAdvancedField.allCases
        )
        XCTAssertEqual(
            AIPromptEditorBehavior.visibleAdvancedFields(isTextTransformation: true),
            [.model, .strictContextMatching, .specifyBeforeRun]
        )
    }

    /**
     Verifies long-press prompt and category lists expose Android's ordered source-appropriate actions.

     The policy is independent of SwiftUI presentation so a failure directly identifies action-list
     drift: read-only add-ons may only copy, built-ins may hide/copy, and built-in categories may only
     change visibility.
     */
    func testLongPressActionListsMatchAndroidOrderingAndVisibility() {
        XCTAssertEqual(
            AIPromptDialogBehavior.promptActions(
                origin: .user,
                canMoveUp: true,
                canMoveDown: false
            ),
            [.copy, .moveUp, .moveToCategory, .delete]
        )
        XCTAssertEqual(
            AIPromptDialogBehavior.promptActions(
                origin: .builtIn,
                canMoveUp: true,
                canMoveDown: true
            ),
            [.hide, .copy]
        )
        XCTAssertEqual(
            AIPromptDialogBehavior.promptActions(
                origin: .swordPack(moduleName: "Pack"),
                canMoveUp: true,
                canMoveDown: true
            ),
            [.copy]
        )
        XCTAssertEqual(
            AIPromptDialogBehavior.categoryActions(
                isBuiltIn: false,
                isHidden: false,
                canMoveUp: false,
                canMoveDown: true
            ),
            [.moveDown, .hide, .rename, .delete]
        )
        XCTAssertEqual(
            AIPromptDialogBehavior.categoryActions(
                isBuiltIn: true,
                isHidden: true,
                canMoveUp: true,
                canMoveDown: true
            ),
            [.show]
        )
    }

    /**
     Verifies ToolInfoActivity parity covers every typed tool exactly once and groups structural tools
     with non-permission tools. Failure means the pushed Available tools screen omits or misclassifies
     a registered Android tool; the test performs no registry execution or persistence.
     */
    func testToolInfoGroupsEveryToolByPermissionRequirement() {
        let readTools = AIPromptToolInfoBehavior.tools(requiringPermission: false)
        let writeTools = AIPromptToolInfoBehavior.tools(requiringPermission: true)

        XCTAssertEqual(Set(readTools).intersection(writeTools), [])
        XCTAssertEqual(Set(readTools + writeTools), Set(AgentTool.allCases))
        XCTAssertTrue(readTools.contains(.finishWithoutDocument))
        XCTAssertTrue(writeTools.contains(.createBookmark))
        XCTAssertFalse(writeTools.contains(.finishWithStudyPad))
    }

    /**
     Builds a detached user-prompt fixture with deterministic required fields.

     - Parameters:
       - name: Human-readable identity used by assertions.
       - categoryID: Optional effective category assignment.
       - orderNumber: Initial global order value.
     - Returns: Unsaved `AgentPrompt` with no external side effects.
     - Failure modes: Construction cannot fail.
     */
    private func makePrompt(
        name: String,
        categoryID: UUID? = nil,
        orderNumber: Int = 0
    ) -> AgentPrompt {
        AgentPrompt(
            name: name,
            promptTemplate: "Template for \(name)",
            orderNumber: orderNumber,
            categoryId: categoryID
        )
    }
}
