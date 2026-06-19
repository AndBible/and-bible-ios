/*
 * Copyright (c) 2026 Martin Denham, Tuomas Airaksinen and the AndBible contributors.
 *
 * This file is part of AndBible: Bible Study (http://github.com/AndBible/and-bible).
 *
 * AndBible is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software Foundation,
 * either version 3 of the License, or (at your option) any later version.
 *
 * AndBible is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with AndBible.
 * If not, see http://www.gnu.org/licenses/.
 */

import {mount} from "@vue/test-utils";
import {describe, expect, it, vi} from "vitest";
import {nextTick, ref} from "vue";
import {readFileSync} from "fs";

import EditableText from "@/components/EditableText.vue";
import MarkdownTextEditor from "@/components/MarkdownTextEditor.vue";
import {useConfig} from "@/composables/config";
import {
    androidKey,
    appSettingsKey,
    calculatedConfigKey,
    configKey,
    customFeaturesKey,
    exportModeKey,
    keyboardKey,
    stringsKey,
} from "@/types/constants";
import {useStrings} from "@/composables/strings";

window.bibleViewDebug = {};

/**
 * Builds the dependency injection set required by `EditableText`.
 *
 * @param notesContentType - Global Android app setting used only when the note row has no type.
 * @returns Symbol-keyed Vue provide map with reader settings and strings.
 * @remarks These tests exercise display rendering only, so bridge methods are not invoked.
 */
function editableTextProvides(notesContentType = "HTML") {
    const {config, appSettings} = useConfig(ref("bible"));
    appSettings.notesContentType = notesContentType;
    return {
        [configKey]: config,
        [appSettingsKey]: appSettings,
        [calculatedConfigKey]: ref({topOffset: 0, topMargin: 0, marginLeft: 0, marginRight: 0}),
        [stringsKey]: useStrings(),
        [androidKey]: {},
        [exportModeKey]: ref(false),
    };
}

/**
 * Builds the richer dependency set required by the Android-parity Markdown editor.
 *
 * @returns Vue provide map with reader settings, bridge stubs, keyboard state, strings, and an
 * English fallback reference parser.
 * @remarks The editor test exercises local Markdown editing controls, so bridge methods are stubs
 * unless a control explicitly requests them.
 */
function markdownEditorProvides() {
    const {config, appSettings} = useConfig(ref("bible"));
    return {
        [configKey]: config,
        [appSettingsKey]: appSettings,
        [calculatedConfigKey]: ref({topOffset: 0, topMargin: 0, marginLeft: 0, marginRight: 0}),
        [stringsKey]: useStrings(),
        [androidKey]: {
            parseRef: vi.fn(async () => ""),
            refChooserDialog: vi.fn(async () => ""),
            openDownloads: vi.fn(),
        },
        [customFeaturesKey]: {
            features: new Set(),
            parse: vi.fn(() => ""),
        },
        [keyboardKey]: {
            editorMode: ref(0),
        },
        [exportModeKey]: ref(false),
    };
}

/**
 * Protects Android note-content-type parity for rendered note display.
 *
 * Android renders explicit `MARKDOWN` note rows with Marked and DOMPurify, independent of the
 * global default. A failure means Markdown notes would appear as raw source text or unsafe HTML.
 */
describe("EditableText note content type rendering", () => {
    it("renders explicit Markdown notes and sanitizes unsafe HTML", () => {
        const wrapper = mount(EditableText, {
            props: {
                text: "**Bold** <img src=x onerror=\"alert(1)\">",
                contentType: "MARKDOWN",
            },
            global: {provide: editableTextProvides("HTML")},
        });

        expect(wrapper.find(".notes-display strong").text()).toBe("Bold");
        expect(wrapper.html()).not.toContain("onerror");
    });

    it("falls back to the global Markdown setting only when content type is nil", () => {
        const wrapper = mount(EditableText, {
            props: {
                text: "# Heading",
                contentType: null,
            },
            global: {provide: editableTextProvides("MARKDOWN")},
        });

        expect(wrapper.find(".notes-display h1").text()).toBe("Heading");
    });

    it("keeps explicit HTML notes as HTML even when the global default is Markdown", () => {
        const wrapper = mount(EditableText, {
            props: {
                text: "**Not markdown**",
                contentType: "HTML",
            },
            global: {provide: editableTextProvides("MARKDOWN")},
        });

        expect(wrapper.find(".notes-display strong").exists()).toBe(false);
        expect(wrapper.find(".notes-display").text()).toContain("**Not markdown**");
    });

    it("marks the Android-compatible display container for rendered Markdown notes", () => {
        const wrapper = mount(EditableText, {
            props: {
                text: "**Container**",
                contentType: "MARKDOWN",
            },
            global: {provide: editableTextProvides("HTML")},
        });

        expect(wrapper.find(".notes-display.markdown-notes").exists()).toBe(true);
        expect(wrapper.find(".notes-display > .markdown-notes").exists()).toBe(false);
    });

    /**
     * Protects Android CSS parity for rendered Markdown note blocks.
     *
     * Android excludes Markdown displays from the generic rich-text div margin rule and applies
     * monochrome/e-ink mixins for both light and night modes. These selectors are not observable in
     * jsdom's mounted DOM, so this checks the SFC style contract directly.
     */
    it("keeps Android Markdown note spacing and monochrome style selectors", () => {
        const source = readFileSync(`${process.cwd()}/src/components/EditableText.vue`, "utf8");

        expect(source).toContain(".notes-display:not(.markdown-notes) div");
        expect(source).toContain(".monochrome .markdown-notes");
        expect(source).toContain(".monochrome.night .markdown-notes");
    });
});

describe("MarkdownTextEditor Android parity controls", () => {
    /**
     * Protects the Android Markdown editor contract instead of accepting a plain textarea lookalike.
     *
     * Android exposes formatting controls and keyboard shortcuts that mutate Markdown source text in
     * place. This test verifies the iOS editor has the same core source-editing path for bold text.
     */
    it("wraps the selected text with Markdown bold using the Android keyboard shortcut", async () => {
        const wrapper = mount(MarkdownTextEditor, {
            props: {text: "word"},
            global: {provide: markdownEditorProvides()},
        });
        const textarea = wrapper.get("textarea").element;

        textarea.selectionStart = 0;
        textarea.selectionEnd = 4;
        await wrapper.get("textarea").trigger("keydown", {key: "b", metaKey: true});
        await nextTick();

        expect(textarea.value).toBe("**word**");
        expect(wrapper.html()).toContain("data-icon=\"heading\"");
        expect(wrapper.html()).toContain("data-icon=\"list-ul\"");
        expect(wrapper.html()).toContain("data-icon=\"book-bible\"");
    });

    /**
     * Protects the editor teardown contract for debounced Markdown source edits.
     *
     * The editor uses debounced callbacks for auto-save and undo checkpointing. Unmount must cancel
     * both timers before the final synchronous save so closed note editors cannot later mutate local
     * state or emit stale saves.
     */
    it("cancels pending debounce timers before the final unmount save", () => {
        const source = readFileSync(`${process.cwd()}/src/components/MarkdownTextEditor.vue`, "utf8");

        expect(source).toMatch(/onBeforeUnmount\(\(\) => \{\s*debouncedSave\.cancel\(\);\s*commitTyping\.cancel\(\);\s*save\(\);/s);
    });
});

describe("TextEditor Android parity sizing", () => {
    /**
     * Protects Android editor sizing parity and reachability for HTML bookmark notes.
     *
     * Android's Pell editor content starts at one line and grows with content, matching the
     * Markdown source editor's compact empty-note behavior. When iOS caps the editor to keep the
     * toolbar reachable, the content area must scroll instead of clipping longer notes.
     */
    it("does not force HTML notes into a fixed-height Pell content area and keeps overflow reachable", () => {
        const pellSource = readFileSync(`${process.cwd()}/src/lib/pell/pell.scss`, "utf8");
        const textEditorSource = readFileSync(`${process.cwd()}/src/components/TextEditor.vue`, "utf8");

        expect(pellSource).toContain("min-height: 1em");
        expect(pellSource).not.toContain("height: $pell-content-height");
        expect(pellSource).not.toContain("overflow-y: auto");
        expect(textEditorSource).not.toContain("height: inherit");
        expect(textEditorSource).toContain("overflow-y: auto");
    });
});
