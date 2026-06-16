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
import {describe, expect, it} from "vitest";
import {ref} from "vue";

import EditableText from "@/components/EditableText.vue";
import {useConfig} from "@/composables/config";
import {androidKey, appSettingsKey, calculatedConfigKey, configKey, exportModeKey, stringsKey} from "@/types/constants";
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
});
