import {beforeEach, describe, expect, it, vi} from "vitest";
import {ref} from "vue";
import {useAndroid} from "@/composables/android";
import {useConfig} from "@/composables/config";

describe("AI native bridge payloads", () => {
    beforeEach(() => {
        window.bibleView = {};
        window.bibleViewDebug = {};
    });

    /**
     * Verifies selection and note-editor wrappers preserve exact Android argument order and JSON.
     *
     * The setup installs only the native methods under test and calls the public composable API.
     * Bible and generic source identity, the negative missing-end sentinel, empty selected text,
     * and editor content must reach native code unchanged. The test has no DOM or network effects.
     */
    it("forwards exact selection and note-editor action payloads", () => {
        const native = {
            llmAction: vi.fn(),
            llmActionGeneric: vi.fn(),
            noteEditorLlmAction: vi.fn(),
        };
        window.android = native as never;
        const {config} = useConfig(ref("bible"));
        const bridge = useAndroid({bookmarks: ref([])}, config);

        bridge.llmAction("KJV", 101, undefined, "");
        bridge.llmActionGeneric("COMM.Dict", "entry/alpha?x=1", 3, 7, "selected");
        bridge.noteEditorLlmAction("BOOKMARK_NOTE", "bookmark-id", "before", "MARKDOWN");

        expect(native.llmAction).toHaveBeenCalledWith("KJV", 101, -1, "");
        expect(native.llmActionGeneric).toHaveBeenCalledWith(
            "COMM.Dict",
            "entry/alpha?x=1",
            3,
            7,
            "selected",
        );
        expect(JSON.parse(native.noteEditorLlmAction.mock.calls[0][0])).toEqual({
            entityType: "BOOKMARK_NOTE",
            entityId: "bookmark-id",
            currentText: "before",
            contentType: "MARKDOWN",
        });
    });

    /**
     * Verifies scoped help, source-prompt navigation, and page-choice wrappers use dedicated calls.
     *
     * The expected result is one allowlisted-scope call, one exact UUID call, and marker JSON that
     * retains punctuation-sensitive keys. Calling generic `helpDialog` would expose an arbitrary
     * content path and fails this test. No native UI or persistence is invoked.
     */
    it("routes help and generated-document navigation through dedicated methods", () => {
        const native = {
            helpDialog: vi.fn(),
            showHelpDialog: vi.fn(),
            openPromptEditor: vi.fn(),
            openAiDocPageChooser: vi.fn(),
        };
        window.android = native as never;
        const {config} = useConfig(ref("bible"));
        const bridge = useAndroid({bookmarks: ref([])}, config);
        const promptId = "a1000000-0000-0000-0000-000000000099";

        bridge.showHelpDialog("memorize");
        bridge.openPromptEditor(promptId);
        bridge.openAiDocPageChooser([
            {title: "First", documentInitials: "AI.Documents", pageKey: "page:key/42"},
            {title: "Second", documentInitials: "AI.Documents", pageKey: "page/key/43"},
        ]);

        expect(native.showHelpDialog).toHaveBeenCalledWith("memorize");
        expect(native.helpDialog).not.toHaveBeenCalled();
        expect(native.openPromptEditor).toHaveBeenCalledWith(promptId);
        expect(JSON.parse(native.openAiDocPageChooser.mock.calls[0][0])).toEqual([
            {title: "First", documentInitials: "AI.Documents", pageKey: "page:key/42"},
            {title: "Second", documentInitials: "AI.Documents", pageKey: "page/key/43"},
        ]);
    });
});
