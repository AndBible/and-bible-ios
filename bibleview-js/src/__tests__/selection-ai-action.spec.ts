/*
 * Copyright (c) 2026 Sykerö Software / Tuomas Airaksinen and the AndBible contributors.
 *
 * This file is part of AndBible: Bible Study (http://github.com/AndBible/and-bible).
 *
 * AndBible is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software Foundation,
 * either version 3 of the License, or (at your option) any later version.
 */

import {flushPromises, mount, VueWrapper} from "@vue/test-utils";
import {ref} from "vue";
import {afterEach, describe, expect, it, vi} from "vitest";

import AmbiguousActionButtons from "@/components/AmbiguousActionButtons.vue";
import type {SelectionInfo} from "@/types/common";
import {
    androidKey,
    appSettingsKey,
    calculatedConfigKey,
    configKey,
    keyboardKey,
    locateTopKey,
    modalKey,
    stringsKey,
} from "@/types/constants";

/** Native AI methods recorded by the selection-action harness without invoking WKWebView. */
type SelectionBridgeSpies = {
    llmAction: ReturnType<typeof vi.fn>
    llmActionGeneric: ReturnType<typeof vi.fn>
}

/**
 * Mounts the selection action component with deterministic native and reactive dependencies.
 *
 * @param selectionInfo Exact Bible or generic source metadata supplied by the selection modal.
 * @param options Provider-row readiness, category disable lists, and localized-label overrides.
 * @returns The mounted wrapper and isolated native bridge spies used for payload assertions.
 * @remarks Mounting creates only jsdom nodes and Vue reactive state. Each caller unmounts when it
 * creates more than one wrapper; Vitest tears down the remaining wrapper DOM after the test. The
 * helper performs no persistence, network, timer, or real native bridge work and cannot throw.
 */
function mountSelectionActions(
    selectionInfo: SelectionInfo,
    options: {
        configured?: boolean
        disabledBibleButtons?: string[]
        disabledGenericButtons?: string[]
        label?: string
    } = {},
): {wrapper: VueWrapper, android: SelectionBridgeSpies} {
    const android: SelectionBridgeSpies = {
        llmAction: vi.fn(),
        llmActionGeneric: vi.fn(),
    };
    const closeModals = vi.fn();

    const wrapper = mount(AmbiguousActionButtons, {
        props: {selectionInfo, hasActions: true},
        global: {
            provide: {
                [androidKey]: android,
                [appSettingsKey]: {
                    llmConfigured: options.configured ?? true,
                    llmActionLabel: options.label ?? "AI actions",
                    disableBibleModalButtons: options.disabledBibleButtons ?? [],
                    disableGenericModalButtons: options.disabledGenericButtons ?? [],
                    enabledExperimentalFeatures: [],
                },
                [calculatedConfigKey]: ref({topOffset: 0, topMargin: 0, marginLeft: 0, marginRight: 0}),
                [configKey]: {},
                [keyboardKey]: {
                    setupKeyboardListener: vi.fn(),
                },
                [locateTopKey]: ref(true),
                [modalKey]: {
                    closeModals,
                },
                [stringsKey]: {
                    addBookmark: "Bookmark",
                    verseNote: "Note",
                    verseNoteLong: "Add note",
                    verseShare: "Share",
                    verseShareLong: "Share selection",
                    verseMyNotes: "My notes",
                    verseCompare: "Compare",
                    verseCompareLong: "Compare selection",
                    verseMemorize: "Memorize",
                    verseMemorizeLong: "Memorize selection",
                    verseSpeak: "Speak",
                    verseParagraphBreak: "Paragraph",
                    verseParagraphBreakLong: "Insert paragraph break",
                    more: "More",
                },
            },
            stubs: {
                FontAwesomeIcon: true,
                FontAwesomeLayers: true,
            },
        },
    });

    return {wrapper, android};
}

/**
 * Resolves the AI action across both direct and responsive-overflow menu layouts.
 *
 * @param wrapper Mounted selection action component.
 * @returns The AI action wrapper, including a non-existent wrapper when visibility fails closed.
 * @remarks Flushes Vue's deterministic microtask queue and may click the local More control. It
 * performs no native bridge call and has no timing or network dependency.
 */
async function findAIAction(wrapper: VueWrapper) {
    await flushPromises();
    let action = wrapper.find('[data-selection-action="LLM_ACTION"]');
    if (!action.exists()) {
        const more = wrapper.find('[aria-label="More"]');
        if (more.exists()) {
            await more.trigger("click");
            await flushPromises();
            action = wrapper.find('[data-selection-action="LLM_ACTION"]');
        }
    }
    return action;
}

/** Exact multi-verse Bible selection used to detect module, range, or text substitution. */
const bibleSelection: SelectionInfo = {
    verseInfo: {
        ordinal: 101,
        osisID: "Gen.1.1",
        book: "Gen",
        chapter: 1,
        verse: 1,
        v11n: "KJVA",
        showStack: [],
        bookInitials: "KJV",
        bibleBookName: "Genesis",
    },
    ordinalInfo: null,
    startOrdinal: 101,
    endOrdinal: 103,
};

/** Exact punctuation-bearing generic selection used to detect document-key normalization. */
const genericSelection: SelectionInfo = {
    verseInfo: null,
    ordinalInfo: {
        bookInitials: "COMM.Dict",
        osisRef: "entry/alpha?x=1",
        ordinal: 7,
    },
    startOrdinal: 7,
    endOrdinal: 9,
};

afterEach(() => {
    vi.restoreAllMocks();
});

describe("selection AI action reachability", () => {
    /**
     * Verifies Bible selection routing preserves Android's exact four-argument payload.
     *
     * A configured native state exposes a keyboard-addressable, native-localized action. Activating
     * it captures the current highlighted text before closing and routes module initials plus the
     * inclusive verse ordinal range only through `llmAction`. No generic bridge call may occur.
     */
    it("routes a configured Bible selection with exact ordinals and highlighted text", async () => {
        vi.spyOn(window, "getSelection").mockReturnValue({
            toString: () => "In the beginning\nGod",
        } as Selection);
        const {wrapper, android} = mountSelectionActions(bibleSelection, {
            label: "Localized AI action",
        });

        const action = await findAIAction(wrapper);
        expect(action.exists()).toBe(true);
        expect(action.attributes("role")).toBe("button");
        expect(action.attributes("tabindex")).toBe("0");
        expect(action.attributes("aria-label")).toBe("Localized AI action");

        await action.trigger("keydown", {key: "Enter"});

        expect(android.llmAction).toHaveBeenCalledOnce();
        expect(android.llmAction).toHaveBeenCalledWith(
            "KJV",
            101,
            103,
            "In the beginning\nGod",
        );
        expect(android.llmActionGeneric).not.toHaveBeenCalled();
        expect(wrapper.emitted("close")).toHaveLength(1);
    });

    /**
     * Verifies generic selections retain the exact document key and local ordinal range.
     *
     * The fixture uses punctuation in the key to catch normalization or current-page substitution.
     * An empty browser selection remains an intentional empty string, matching Android's bridge.
     */
    it("routes a configured generic selection without losing its document key", async () => {
        vi.spyOn(window, "getSelection").mockReturnValue({toString: () => ""} as Selection);
        const {wrapper, android} = mountSelectionActions(genericSelection);

        const action = await findAIAction(wrapper);
        expect(action.exists()).toBe(true);
        await action.trigger("click");

        expect(android.llmActionGeneric).toHaveBeenCalledOnce();
        expect(android.llmActionGeneric).toHaveBeenCalledWith(
            "COMM.Dict",
            "entry/alpha?x=1",
            7,
            9,
            "",
        );
        expect(android.llmAction).not.toHaveBeenCalled();
    });

    /**
     * Verifies native configuration and per-category button preferences both fail closed.
     *
     * The action must be absent before any provider row exists and must remain absent when the user
     * disables `LLM_ACTION` for the active category. Hidden actions cannot emit either bridge call.
     */
    it("hides the action when AI is unconfigured or disabled for the category", async () => {
        const unconfigured = mountSelectionActions(bibleSelection, {configured: false});
        expect((await findAIAction(unconfigured.wrapper)).exists()).toBe(false);
        expect(unconfigured.android.llmAction).not.toHaveBeenCalled();
        unconfigured.wrapper.unmount();

        const bibleDisabled = mountSelectionActions(bibleSelection, {
            disabledBibleButtons: ["LLM_ACTION"],
        });
        expect((await findAIAction(bibleDisabled.wrapper)).exists()).toBe(false);
        bibleDisabled.wrapper.unmount();

        const genericDisabled = mountSelectionActions(genericSelection, {
            disabledGenericButtons: ["LLM_ACTION"],
        });
        expect((await findAIAction(genericDisabled.wrapper)).exists()).toBe(false);
    });
});
