import BibleCore
import CryptoKit
import Foundation
import XCTest
@testable import BibleUI

/**
 Protects the Android AI system resources and initial message-composition contract.

 Resource digests come from detached Android `origin/current-stable` commit `0f3b85823`. The agent
 reference digest removes Android's four trailing ASCII spaces because this repository rejects
 trailing whitespace; the test still hashes the bundled iOS resources byte-for-byte. Tests use pure
 unmanaged prompt/context values and perform no persistence, network, or installed-module I/O. A
 failure means the provider can receive materially different safety, citation, source-selection,
 note-writeback, or selected-content instructions on iOS.
 */
final class AIReaderMessageCompositionParityTests: XCTestCase {
    /**
     Verifies both bundled system resources remain content-identical to Android's audited resources.

     The expected agent digest was calculated after deleting Android's four trailing ASCII spaces;
     iOS bytes are not normalized here. The assertion therefore catches new tabs, Markdown-significant
     double spaces, omissions, line-break changes, and punctuation drift, while representative clauses
     keep a digest failure actionable. Failure requires an intentional cross-platform resource update,
     not an iOS-only prompt edit.
     */
    func testBundledSystemResourcesMatchAndroidStableDigests() throws {
        let prompts = try AIReaderSystemPromptLoader.load()

        XCTAssertEqual(Self.sha256(prompts.agent), "b7c20e8611c1ec14a4ec0b3bb3928a86c62b53015d3e849f55678f0b4a9e7a3a")
        XCTAssertEqual(Self.sha256(prompts.transformation), "e1d4d6e2cccbf3a18530087241e27f9e9c71819fd0d89e09693b0cd01d4449c7")
        XCTAssertTrue(prompts.agent.contains("Your response IS the document. Write it as a standalone article"))
        XCTAssertTrue(prompts.agent.contains("EFFICIENCY - taskComplete flag:"))
        XCTAssertTrue(prompts.agent.contains("EVERY Bible reference in your response MUST be a clickable link"))
        XCTAssertTrue(prompts.agent.contains("appending an anchor fragment #oSTART-END"))
        XCTAssertTrue(prompts.transformation.contains("CRITICAL — Preserve formatting:"))
    }

    /**
     Verifies ordinary system composition reproduces Android's contextual source and writeback lines.

     The test includes every newly supplied reference-document class and a bookmark note target.
     Failure means the model could search the wrong Bible, guess a dictionary, or use the wrong note
     mutation tool despite the host resolving authoritative installed-document metadata.
     */
    func testSystemMessageIncludesAndroidSearchDictionaryAndBookmarkWritebackContext() throws {
        let prompt = Self.prompt()
        let context = AgentExecutionContext(
            promptId: prompt.id,
            verseReference: "John.3.16",
            activeDocumentInitials: "KJV",
            activeLabelId: Self.labelID,
            selectionStartOffset: 4,
            selectionEndOffset: 11,
            noteEditorEntityType: .bookmarkNote,
            noteEditorEntityId: Self.entityID.uuidString,
            noteEditorContentType: "MARKDOWN",
            workspaceWindowsSummary: "Window 1: KJV at John.3.16\n",
            noDocumentCreation: true
        )
        let messages = AIReaderMessageComposer.messages(
            Self.input(
                prompt: prompt,
                context: context,
                defaultSearchBible: .init(initials: "ESV2011", language: "English"),
                preferredStrongsHebrew: "StrongsHebrew",
                preferredStrongsGreek: "StrongsGreek",
                preferredGreekMorphology: "Robinson"
            )
        )
        let system = try XCTUnwrap(messages.first?.content)

        XCTAssertEqual(
            system,
            """
            Base system prompt in Finnish
            Current active document: KJV
            Selected verse reference: John.3.16
            Default search Bible (for searchBible tool): ESV2011 (English)
            The user has highlighted specific text within a verse. Character offsets (startOffset/endOffset) are provided — these are character positions from the start of the verse text in the current translation (KJV). Use createBookmark with startOffset, endOffset, and bookInitials to create a sub-verse bookmark covering exactly the highlighted text, or adjust the offsets as needed.
            Active label/StudyPad ID: 10000000-0000-0000-0000-000000000001

            IMPORTANT: This prompt is configured for action-only mode (no document creation). Do NOT call setDocumentTitle. When you are done, call finishWithoutDocument with a brief summary of what you did. Any text output will appear only in the activity log.

            --- Note Editor Context ---
            Entity type: BOOKMARK_NOTE
            Entity ID: 20000000-0000-0000-0000-000000000002
            Content type: MARKDOWN
            Use updateBookmarkNote with this bookmark ID to save changes.

            --- Current Workspace ---
            Window 1: KJV at John.3.16

            Preferred reference dictionaries:
            - Strong's Hebrew: StrongsHebrew
            - Strong's Greek: StrongsGreek
            - Greek morphology: Robinson

            """
        )
    }

    /**
     Verifies prompt tool restrictions suppress only Android's default-search advisory.

     Failure means a model could be instructed to call a tool excluded by the selected prompt, or
     unrelated preferred-reference context could disappear with that restriction.
     */
    func testSystemMessageOmitsDefaultSearchBibleWhenPromptExcludesSearchTool() throws {
        let prompt = Self.prompt(allowedTools: [.getVerseContent])
        let messages = AIReaderMessageComposer.messages(
            Self.input(
                prompt: prompt,
                context: AgentExecutionContext(promptId: prompt.id),
                defaultSearchBible: .init(initials: "KJV", language: nil),
                preferredStrongsGreek: "StrongsGreek"
            )
        )
        let system = try XCTUnwrap(messages.first?.content)

        XCTAssertFalse(system.contains("Default search Bible"))
        XCTAssertTrue(system.contains("- Strong's Greek: StrongsGreek"))
    }

    /**
     Verifies every Android note-editor destination names its exact mutation tool.

     Failure means a transformation can be generated correctly but never committed to its captured
     bookmark, StudyPad entry, or My Documents page.
     */
    func testSystemMessageSelectsExactWriteToolForEveryNoteEditorDestination() throws {
        let contracts: [(NoteEditorEntityType, String)] = [
            (.bookmarkNote, "Use updateBookmarkNote with this bookmark ID to save changes."),
            (.studyPadText, "Use updateStudyPadTextEntry with this entry ID to save changes."),
            (.myDocumentPage, "Use editMyDocumentPage with this page ID to save changes."),
        ]

        for (entityType, instruction) in contracts {
            let prompt = Self.prompt()
            let context = AgentExecutionContext(
                promptId: prompt.id,
                noteEditorEntityType: entityType,
                noteEditorEntityId: Self.entityID.uuidString,
                noteEditorContentType: "MARKDOWN"
            )
            let system = try XCTUnwrap(
                AIReaderMessageComposer.messages(Self.input(prompt: prompt, context: context)).first?.content
            )

            XCTAssertTrue(system.contains(instruction), entityType.rawValue)
        }
    }

    /**
     Verifies analytical selected OSIS becomes semantic text with stable existing sentence anchors.

     The fixture exercises headings, BVA anchors, module-qualified links, hidden reader metadata,
     footnotes, and paragraph normalization. Failure breaks source-citation URLs or leaks raw OSIS and
     metadata into provider context.
     */
    func testAnalyticalPromptConvertsSelectedOSISWithAndroidAnchors() throws {
        let source = """
        <div><title><BVA ordinal="0">Commentary Title</BVA></title><p><BVA ordinal="1">First sentence.</BVA><reference osisRef="My Commentary:Matt.5.3">Matt 5:3</reference><x-hidden>secret</x-hidden><note>Footnote</note></p></div>
        """
        let prompt = Self.prompt()
        let context = AgentExecutionContext(promptId: prompt.id, selectedContent: source)
        let user = try XCTUnwrap(
            AIReaderMessageComposer.messages(Self.input(prompt: prompt, context: context)).last?.content
        )

        XCTAssertEqual(
            user,
            "Prompt body\n\n--- Context ---\n## [§0] Commentary Title\n\n[§1] First sentence.[Matt 5:3](sword://My%20Commentary/Matt.5.3) [Footnote: Footnote]"
        )
        XCTAssertFalse(user.contains("secret"))
        XCTAssertFalse(user.contains("<BVA"))
    }

    /**
     Verifies the converter's complete semantic element vocabulary against Android's fixture outputs.

     A table-driven contract covers verse numbering, emphasis, poetry, lists, tables, references,
     invisible metadata, and whitespace normalization. Failure identifies a structural branch where
     provider context no longer matches `OsisToPlainText` even if the main anchor scenario still works.
     */
    func testSelectedOSISConverterMatchesAndroidSemanticFixtures() throws {
        let fixtures: [(name: String, source: String, anchors: Bool, expected: String)] = [
            (
                "verse",
                #"<div><verse osisID="Gen.1.1"><w lemma="strong:H07225">In</w> the beginning</verse></div>"#,
                false,
                "1. In the beginning"
            ),
            ("title", "<div><title>The Beatitudes</title></div>", false, "## The Beatitudes"),
            (
                "footnote",
                "<div>text<note>Some manuscripts read X</note>more</div>",
                false,
                "text [Footnote: Some manuscripts read X]more"
            ),
            ("transchange", #"<div><transChange type="added">was</transChange></div>"#, false, "*was*"),
            ("quote", #"<div><q marker="&#x2018;">word</q></div>"#, false, "‘word"),
            (
                "hidden metadata",
                #"<div>before<milestone type="x-strongsMarkup"/><chapter osisID="Gen.1"/><x-custom>hidden</x-custom>after</div>"#,
                false,
                "beforeafter"
            ),
            ("poetry", "<div><l>line 1</l><l>line 2</l></div>", false, "line 1\nline 2"),
            ("bold", #"<div><hi type="bold">important</hi></div>"#, false, "**important**"),
            ("italic", #"<div><hi type="italic">emphasis</hi></div>"#, false, "*emphasis*"),
            (
                "paragraphs",
                "<div><p>First paragraph.</p><p>Second paragraph.</p></div>",
                false,
                "First paragraph.\n\nSecond paragraph."
            ),
            (
                "unqualified reference",
                #"<div>see <reference osisRef="Matt.5.3">Matt 5:3</reference></div>"#,
                false,
                "see [Matt 5:3](sword:///Matt.5.3)"
            ),
            (
                "reference without target",
                "<div>see <reference>Matt 5:3</reference></div>",
                false,
                "see Matt 5:3"
            ),
            (
                "list",
                "<div><list><item>Apple</item><item>Banana</item><item>Cherry</item></list></div>",
                false,
                "- Apple\n- Banana\n- Cherry"
            ),
            (
                "table",
                "<div><table><row><cell>Name</cell><cell>Value</cell></row><row><cell>A</cell><cell>1</cell></row></table></div>",
                false,
                "Name Value\n\nA 1"
            ),
            (
                "anchors",
                #"<div><p><BVA ordinal="0">First sentence.</BVA><BVA ordinal="1">Second sentence.</BVA></p></div>"#,
                true,
                "[§0] First sentence.[§1] Second sentence."
            ),
        ]

        for fixture in fixtures {
            XCTAssertEqual(
                AIReaderSelectedContentConverter.plainText(
                    from: fixture.source,
                    injectAnchors: fixture.anchors
                ),
                fixture.expected,
                fixture.name
            )
        }
    }

    /**
     Verifies transformations retain semantic markup but never inject analytical citation anchors.

     Android uses the minimal transformation system prompt and suppresses `[§N]` markers so ordinals
     cannot be mistaken for user text. Failure changes the transformed document or exposes unrelated
     reader/system context.
     */
    func testTransformationPromptConvertsSelectedOSISWithoutAnchorsOrExtraSystemContext() throws {
        let prompt = Self.prompt(isTextTransformation: true)
        let context = AgentExecutionContext(
            promptId: prompt.id,
            selectedContent: "<div><p><BVA ordinal=\"7\"><hi type=\"bold\">Translate me</hi></BVA></p></div>",
            activeDocumentInitials: "KJV",
            workspaceWindowsSummary: "Must not appear"
        )
        let messages = AIReaderMessageComposer.messages(Self.input(prompt: prompt, context: context))

        XCTAssertEqual(messages.first?.content, "Transformation system prompt in Finnish\n")
        XCTAssertEqual(messages.last?.content, "Prompt body\n\n--- Context ---\n**Translate me**")
        XCTAssertFalse(messages.last?.content?.contains("[§7]") == true)
    }

    /**
     Verifies malformed selected content follows Android's lossless raw-content fallback.

     Failure means a transient or legacy malformed fragment could be silently truncated, preventing
     the model from seeing the source text the user selected.
     */
    func testMalformedSelectedContentFallsBackToOriginalValue() throws {
        let prompt = Self.prompt()
        let malformed = "<div><p>Still visible"
        let context = AgentExecutionContext(promptId: prompt.id, selectedContent: malformed)
        let user = try XCTUnwrap(
            AIReaderMessageComposer.messages(Self.input(prompt: prompt, context: context)).last?.content
        )

        XCTAssertEqual(user, "Prompt body\n\n--- Context ---\n\(malformed)")
    }

    /** Creates a detached prompt with the exact behavior switches needed by one test. */
    private static func prompt(
        allowedTools: Set<AgentTool>? = nil,
        isTextTransformation: Bool = false
    ) -> AgentPrompt {
        AgentPrompt(
            id: UUID(),
            name: "Contract prompt",
            promptTemplate: "Prompt body",
            allowedTools: allowedTools,
            isTextTransformation: isTextTransformation
        )
    }

    /** Creates a pure composer input with stable custom base prompts and optional reference context. */
    private static func input(
        prompt: AgentPrompt,
        context: AgentExecutionContext,
        defaultSearchBible: AIReaderMessageComposer.SearchBible? = nil,
        preferredStrongsHebrew: String? = nil,
        preferredStrongsGreek: String? = nil,
        preferredGreekMorphology: String? = nil
    ) -> AIReaderMessageComposer.Input {
        AIReaderMessageComposer.Input(
            prompt: prompt,
            context: context,
            appLanguage: "Finnish",
            agentSystemPrompt: "Base system prompt in {{APP_LANGUAGE}}\n",
            transformationSystemPrompt: "Transformation system prompt in {{APP_LANGUAGE}}\n",
            installedDocuments: nil,
            commentaryEntries: nil,
            defaultSearchBible: defaultSearchBible,
            preferredStrongsHebrew: preferredStrongsHebrew,
            preferredStrongsGreek: preferredStrongsGreek,
            preferredGreekMorphology: preferredGreekMorphology
        )
    }

    /** Returns the lowercase SHA-256 digest of the exact UTF-8 prompt bytes. */
    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Stable label identity used by exact system-message assertions.
    private static let labelID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    /// Stable note destination identity used by exact system-message assertions.
    private static let entityID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
}
