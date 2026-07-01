/*
 * Copyright (c) 2026 Sykerö Software / Tuomas Airaksinen and the AndBible contributors.
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
import {afterEach, describe, expect, it, vi} from "vitest";
import {ref} from "vue";
import AmbiguousSelection from "@/components/modals/AmbiguousSelection.vue";
import {useOrdinalHighlight} from "@/composables/ordinal-highlight";
import {addEventFunction, addEventVerseInfo, EventPriorities} from "@/utils";
import {eventBus} from "@/eventbus";
import {
    androidKey,
    appSettingsKey,
    calculatedConfigKey,
    configKey,
    globalBookmarksKey,
    keyboardKey,
    modalKey,
    ordinalHighlightKey,
    stringsKey,
} from "@/types/constants";

window.bibleView = {};
window.bibleViewDebug = {};

function testBookmark(id = "bookmark-1") {
    return {
        id,
        text: "And God said",
    };
}

function mountAmbiguousSelection({bookmarks = [], appSettings = {}, config = {}} = {}) {
    const bookmarkMap = new Map(bookmarks.map(bookmark => [bookmark.id, bookmark]));

    return mount(AmbiguousSelection, {
        global: {
            provide: {
                [androidKey]: {
                    helpBookmarks: () => {},
                    reportModalState: () => {},
                    setLimitAmbiguousModalSize: () => {},
                },
                [appSettingsKey]: {
                    actionMode: false,
                    activeSince: -1000,
                    activeWindow: true,
                    limitAmbiguousModalSize: false,
                    ...appSettings,
                },
                [calculatedConfigKey]: {},
                [configKey]: {
                    showBookmarks: true,
                    ...config,
                },
                [globalBookmarksKey]: {
                    bookmarkIdsByOrdinal: new Map(),
                    bookmarkMap,
                },
                [keyboardKey]: {
                    editorMode: ref(0),
                    setupKeyboardListener: () => {},
                },
                [modalKey]: {
                    closeModals: () => {},
                    modalOpen: ref(false),
                    register: () => {},
                },
                [ordinalHighlightKey]: useOrdinalHighlight(),
                [stringsKey]: {
                    bookmarks: "Bookmarks",
                },
            },
            stubs: {
                AmbiguousActionButtons: true,
                AmbiguousSelectionBookmarkButton: {
                    props: ["bookmarkId"],
                    emits: ["selected"],
                    template: `
                        <button
                            data-test="ambiguous-bookmark-button"
                            @click="$emit('selected')"
                        >
                            {{ bookmarkId }}
                        </button>
                    `,
                },
                ModalDialog: {
                    template: "<div><slot name=\"title\"/><slot name=\"extra-buttons\"/><slot/></div>",
                },
                FontAwesomeIcon: true,
            },
        },
    });
}

afterEach(() => {
    document.body.innerHTML = "";
    vi.restoreAllMocks();
});

describe("AmbiguousSelection bookmark routing", () => {
    /**
     * Protects Android bookmark popup parity for taps on visible bookmarked verse text.
     *
     * Android assigns visible highlight ranges `VISIBLE_BOOKMARK` priority, which stays in the
     * ambiguous selection chooser when verse metadata is present. Only bookmark marker/icon taps
     * use positive priority and bypass the chooser. This prevents iOS from treating every
     * highlighted bookmark span as if the user tapped Android's marker affordance.
     */
    it("keeps a single visible bookmark highlight in the chooser when verse metadata is present", async () => {
        const bookmarkEvents = [];
        const listener = args => bookmarkEvents.push(args);
        eventBus.on("bookmark_clicked", listener);

        try {
            const bookmark = testBookmark();
            const wrapper = mountAmbiguousSelection({bookmarks: [bookmark]});
            const event = new MouseEvent("click", {
                bubbles: true,
                cancelable: true,
                clientY: 100,
            });

            addEventFunction(event, null, {
                bookmarkId: "bookmark-1",
                hidden: false,
                priority: EventPriorities.VISIBLE_BOOKMARK,
            });
            addEventVerseInfo(event, {
                bibleBookName: "Genesis",
                bookInitials: "KJV",
                chapter: 1,
                ordinal: 9,
                osisRef: "Gen.1.9",
                verse: 9,
                verseTo: "",
            });

            const handlePromise = wrapper.vm.handle(event);
            await Promise.resolve();

            expect(bookmarkEvents).toEqual([]);
            expect(wrapper.text()).toContain("Genesis 1:9");
            expect(wrapper.find("[data-test='ambiguous-bookmark-button']").exists()).toBe(true);

            await wrapper.find("[data-test='ambiguous-bookmark-button']").trigger("click");
            await handlePromise;
        } finally {
            eventBus.off("bookmark_clicked", listener);
        }
    });

    /**
     * Protects Android bookmark marker parity for direct bookmark modal opening.
     *
     * Android's marker/icon event functions use `BOOKMARK_MARKER` priority, so a single marker tap
     * opens the bookmark detail modal without first showing the generic ambiguous chooser. This
     * keeps iOS aligned with Android's marker affordance while leaving highlighted text spans in
     * the chooser path.
     */
    it("opens a single bookmark marker directly even when verse metadata is present", async () => {
        const bookmarkEvents = [];
        const listener = args => bookmarkEvents.push(args);
        eventBus.on("bookmark_clicked", listener);

        try {
            const wrapper = mountAmbiguousSelection();
            const event = new MouseEvent("click", {
                bubbles: true,
                cancelable: true,
                clientY: 100,
            });

            addEventFunction(event, null, {
                bookmarkId: "bookmark-1",
                priority: EventPriorities.BOOKMARK_MARKER,
            });
            addEventVerseInfo(event, {
                bibleBookName: "Genesis",
                bookInitials: "KJV",
                chapter: 1,
                ordinal: 9,
                osisRef: "Gen.1.9",
                verse: 9,
                verseTo: "",
            });

            await wrapper.vm.handle(event);

            expect(bookmarkEvents).toEqual([
                ["bookmark-1", {locateTop: false}],
            ]);
        } finally {
            eventBus.off("bookmark_clicked", listener);
        }
    });

    /**
     * Protects shared reader content-tap behavior while a pane is becoming active.
     *
     * Android and iOS both route verse clicks through this web handler. A physical tap can focus a
     * pane and carry verse metadata in the same bubbled event, so the activation debounce must keep
     * suppressing plain background taps without dropping explicit verse selections. Failure means a
     * legitimate first tap on verse text can be ignored instead of opening the verse chooser.
     */
    it("keeps a verse metadata tap during the activation debounce", async () => {
        vi.spyOn(performance, "now").mockReturnValue(1000);

        const wrapper = mountAmbiguousSelection({
            appSettings: {
                activeSince: 900,
                activeWindow: true,
            },
        });
        const event = new MouseEvent("click", {
            bubbles: true,
            cancelable: true,
            clientY: 100,
        });

        addEventVerseInfo(event, {
            bibleBookName: "Genesis",
            bookInitials: "KJV",
            chapter: 1,
            ordinal: 9,
            osisRef: "Gen.1.9",
            verse: 9,
            verseTo: "",
        });

        const handlePromise = wrapper.vm.handle(event);
        await Promise.resolve();

        expect(wrapper.text()).toContain("Genesis 1:9");

        wrapper.vm.cancelled();
        await handlePromise;
    });

    /**
     * Protects Android bookmark visibility parity when bookmark display is disabled.
     *
     * Android filters bookmark actions from the ambiguous chooser when `showBookmarks` is false.
     * A failure means hidden bookmark UI can still leak through the chooser even though the reader
     * has been configured not to show bookmark affordances.
     */
    it("filters bookmark chooser actions when bookmark display is disabled", async () => {
        const bookmark = testBookmark();
        const wrapper = mountAmbiguousSelection({
            bookmarks: [bookmark],
            config: {
                showBookmarks: false,
            },
        });
        const event = new MouseEvent("click", {
            bubbles: true,
            cancelable: true,
            clientY: 100,
        });

        addEventFunction(event, null, {
            bookmarkId: "bookmark-1",
            hidden: false,
            priority: EventPriorities.VISIBLE_BOOKMARK,
        });
        addEventVerseInfo(event, {
            bibleBookName: "Genesis",
            bookInitials: "KJV",
            chapter: 1,
            ordinal: 9,
            osisRef: "Gen.1.9",
            verse: 9,
            verseTo: "",
        });

        const handlePromise = wrapper.vm.handle(event);
        await Promise.resolve();

        expect(wrapper.text()).toContain("Genesis 1:9");
        expect(wrapper.find("[data-test='ambiguous-bookmark-button']").exists()).toBe(false);

        wrapper.vm.cancelled();
        await handlePromise;
    });

    /**
     * Protects Android unmanaged-link parity in the reader click classifier.
     *
     * Plain rendered links without registered event functions should be left to the browser/native
     * link path after recording a scroll anchor. The ambiguous-selection handler must not treat
     * those clicks as background modal-dismiss taps.
     */
    it("records a scroll anchor and ignores plain unmanaged link clicks", async () => {
        const scrollAnchorEvents = [];
        const backEvents = [];
        const scrollAnchorListener = args => scrollAnchorEvents.push(args);
        const backListener = args => backEvents.push(args);
        eventBus.on("set_scroll_anchor", scrollAnchorListener);
        eventBus.on("back_clicked", backListener);

        try {
            const wrapper = mountAmbiguousSelection();
            const link = document.createElement("a");
            link.setAttribute("href", "https://example.test");
            const linkText = document.createElement("span");
            const textNode = document.createTextNode("Example");
            linkText.appendChild(textNode);
            link.appendChild(linkText);
            document.body.appendChild(link);

            const event = new MouseEvent("click", {
                bubbles: true,
                cancelable: true,
                clientY: 100,
            });
            Object.defineProperty(event, "target", {value: textNode});

            await wrapper.vm.handle(event);

            expect(scrollAnchorEvents).toEqual([[link]]);
            expect(backEvents).toEqual([]);
            expect(wrapper.text()).toBe("");
        } finally {
            eventBus.off("set_scroll_anchor", scrollAnchorListener);
            eventBus.off("back_clicked", backListener);
        }
    });
});
