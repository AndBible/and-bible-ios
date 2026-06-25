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
import {afterEach, describe, expect, it} from "vitest";
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

function mountAmbiguousSelection() {
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
                },
                [calculatedConfigKey]: {},
                [configKey]: {},
                [globalBookmarksKey]: {
                    bookmarkIdsByOrdinal: new Map(),
                    bookmarkMap: new Map(),
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
                AmbiguousSelectionBookmarkButton: true,
                ModalDialog: {
                    template: "<div><slot name=\"title\"/><slot name=\"extra-buttons\"/><slot/></div>",
                },
            },
        },
    });
}

afterEach(() => {
    document.body.innerHTML = "";
});

describe("AmbiguousSelection bookmark routing", () => {
    /**
     * Protects Android bookmark popup parity for taps on visible bookmarked verse text.
     *
     * Android opens the bookmark detail modal for a bookmark-owned tap instead of showing the
     * general verse action chooser. The event still carries verse metadata because the tap occurs
     * inside scripture text, so this test prevents that metadata from demoting the bookmark action.
     */
    it("opens a single visible bookmark directly even when verse metadata is present", async () => {
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

            expect(bookmarkEvents).toEqual([
                ["bookmark-1", {locateTop: false}],
            ]);
            await handlePromise;
        } finally {
            eventBus.off("bookmark_clicked", listener);
        }
    });
});
