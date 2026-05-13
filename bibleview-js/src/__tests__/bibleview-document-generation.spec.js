/*
 * Copyright (c) 2026 AndBible contributors.
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
import {nextTick} from "vue";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import BibleView from "@/components/BibleView.vue";
import {emit} from "@/eventbus";

function errorDocument(id, text) {
    return {
        id,
        type: "error",
        errorMessage: `<p>${text}</p>`,
        severity: "NORMAL",
    };
}

function setupContent() {
    emit("setup_content", {
        jumpToOrdinal: null,
        jumpToAnchor: null,
        jumpToId: "top",
        topOffset: 0,
        bottomOffset: 0,
    });
}

async function flushDocumentWork() {
    for (let i = 0; i < 8; i++) {
        await new Promise(resolve => setTimeout(resolve, 0));
        await nextTick();
    }
}

describe("BibleView document generation", () => {
    let wrapper;
    let originalFontsDescriptor;

    beforeEach(() => {
        originalFontsDescriptor = Object.getOwnPropertyDescriptor(document, "fonts");
        window.bibleView = {};
        window.bibleViewDebug = {};
        vi.stubGlobal("scrollTo", vi.fn());
        vi.stubGlobal("requestAnimationFrame", callback => setTimeout(() => callback(performance.now()), 0));
        vi.stubGlobal("cancelAnimationFrame", id => clearTimeout(id));
        Object.defineProperty(document, "fonts", {
            configurable: true,
            value: {ready: Promise.resolve()},
        });
        vi.stubGlobal("android", new Proxy({}, {
            get(_target, property) {
                if (property === "getActiveLanguages") {
                    return () => "[]";
                }
                return vi.fn();
            },
        }));
    });

    afterEach(() => {
        wrapper?.unmount();
        wrapper = null;
        if (originalFontsDescriptor) {
            Object.defineProperty(document, "fonts", originalFontsDescriptor);
        } else {
            delete document.fonts;
        }
        vi.unstubAllGlobals();
        vi.restoreAllMocks();
    });

    it("ignores pending document work after a newer clear", async () => {
        wrapper = mount(BibleView);
        await nextTick();

        emit("clear_document");
        emit("add_documents", errorDocument("old", "Old generation"));
        setupContent();
        emit("clear_document");
        emit("add_documents", errorDocument("new", "New generation"));
        setupContent();

        await flushDocumentWork();

        expect(wrapper.text()).toContain("New generation");
        expect(wrapper.text()).not.toContain("Old generation");
    });
});
