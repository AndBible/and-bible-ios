/*
 * Copyright (c) 2021-2022 Martin Denham, Tuomas Airaksinen and the AndBible contributors.
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
import OsisSegment from "@/components/documents/OsisSegment.vue";
import BibleDocument from "@/components/documents/BibleDocument.vue";

import test1Xml from "./testdata/eph.2-kjva.xml?raw";
import test1Result from "./testdata/eph.2-kjva-result.html?raw";


import {useConfig} from "@/composables/config";
import {useStrings} from "@/composables/strings";
import {useAndroid} from "@/composables/android";
import {useOrdinalHighlight} from "@/composables/ordinal-highlight";
import {ref} from "vue";
import {
    androidKey,
    appSettingsKey,
    calculatedConfigKey,
    configKey,
    customCssKey,
    footnoteCountKey,
    globalBookmarksKey,
    modalKey,
    osisFragmentKey,
    stringsKey,
    ordinalHighlightKey
} from "@/types/constants";
import AmbiguousSelection from "@/components/modals/AmbiguousSelection.vue";
import BookmarkLabelActions from "@/components/modals/BookmarkLabelActions.vue";
import LabelList from "@/components/LabelList.vue";
import {useGlobalBookmarks} from "@/composables/bookmarks";
import {useModal} from "@/composables/modal";
import {useCustomCss} from "@/composables/custom-css";
import { describe, it, expect } from 'vitest'

window.bibleViewDebug = {}
window.bibleView = {}

function verifyXmlRendering(xmlTemplate, renderedHtml) {
    const {config, appSettings, calculatedConfig} = useConfig(ref("bible"));
    const osisFragment = {
        bookCategory: "BIBLE",
    };

    const android = useAndroid({bookmarks: null}, config);
    const provide = {
        [osisFragmentKey]: osisFragment,
        [configKey]: config,
        [appSettingsKey]: appSettings,
        [calculatedConfigKey]: calculatedConfig,
        [footnoteCountKey]: {getFootNoteCount: () => 0},
        [androidKey]: android,
        [stringsKey]: useStrings(),
        [ordinalHighlightKey]: useOrdinalHighlight(),
        [globalBookmarksKey]: useGlobalBookmarks(config),
        [modalKey]: useModal(android),
        [customCssKey]: useCustomCss(),
    };
    const components = {AmbiguousSelection, LabelList, BookmarkLabelActions};
    const wrapper = mount(OsisSegment, {props: {osisTemplate: xmlTemplate, convert: true}, global: {provide, components}});
    expect(wrapper.html() + "\n").toBe(renderedHtml);
}

function buildBibleDocument(xmlTemplate, {
    chapterNumber = 1,
    addChapter = false,
    originalOrdinalRange = [1, 1],
    ordinalRange = [1, 50],
    key = "2Cor.1",
    keyName = "2 Corinthians 1",
    osisRef = "2Cor.1",
} = {}) {
    return {
        id: "doc-1",
        type: "bible",
        osisFragment: {
            xml: xmlTemplate,
            key,
            keyName,
            v11n: "KJVA",
            bookCategory: "BIBLE",
            bookInitials: "KJV",
            bookAbbreviation: "2Cor",
            osisRef,
            isNewTestament: true,
            features: {},
            ordinalRange,
            language: "en",
            direction: "ltr",
        },
        bookInitials: "KJV",
        bookCategory: "BIBLE",
        bookAbbreviation: "2Cor",
        bookName: "2 Corinthians",
        key,
        v11n: "KJVA",
        osisRef,
        annotateRef: "",
        genericBookmarks: [],
        ordinalRange,
        isNativeHtml: false,
        bookmarks: [],
        bibleBookName: "2 Corinthians",
        addChapter,
        chapterNumber,
        originalOrdinalRange,
    };
}

function mountBibleDocument(document, {configure} = {}) {
    const {config, appSettings, calculatedConfig} = useConfig(ref("bible"));
    if (configure) {
        configure({config, appSettings, calculatedConfig});
    }
    const android = useAndroid({bookmarks: null}, config);
    const provide = {
        [configKey]: config,
        [appSettingsKey]: appSettings,
        [calculatedConfigKey]: calculatedConfig,
        [footnoteCountKey]: {getFootNoteCount: () => 0},
        [androidKey]: android,
        [stringsKey]: useStrings(),
        [ordinalHighlightKey]: useOrdinalHighlight(),
        [globalBookmarksKey]: useGlobalBookmarks(config),
        [modalKey]: useModal(android),
        [customCssKey]: useCustomCss(),
    };
    const components = {AmbiguousSelection, LabelList, BookmarkLabelActions};
    return mount(BibleDocument, {props: {document}, global: {provide, components}});
}

describe("OsisSegment.vue", () => {
    // Skipping this now. Need to figure out how to make sure scoped css do not break our test
    // This does not seem to work, for some reason
    // https://runthatline.com/test-css-module-classes-in-vue-with-vitest/
    // https://github.com/AndBible/and-bible/issues/2434
    it.skip("Test rendering of Eph 2:8 in KJVA, #1985", () => verifyXmlRendering(test1Xml, test1Result));

    it("renders a chapter number from an opening chapter marker embedded in the OSIS fragment", () => {
        const wrapper = mountBibleDocument(buildBibleDocument(
            "<div><div><chapter chapterTitle=\"CHAPTER 2.\" osisID=\"2Cor.2\" sID=\"gen1794\"/><title type=\"chapter\">CHAPTER 2.</title></div><div><verse osisID=\"2Cor.2.1\" verseOrdinal=\"41\">But I determined this with myself.</verse></div></div>",
            {
                chapterNumber: 2,
                originalOrdinalRange: [41, 41],
                ordinalRange: [41, 53],
                key: "2Cor.2",
                keyName: "2 Corinthians 2",
                osisRef: "2Cor.2",
            }
        ));

        expect(wrapper.find(".chapter-number").exists()).toBe(true);
        expect(wrapper.find(".chapter-number").text()).toContain("2");
        expect(wrapper.text()).toContain("But I determined this with myself.");
    });

    it("renders a book title from verse-zero intro content for chapter one", () => {
        const wrapper = mountBibleDocument(buildBibleDocument(
            "<div><div><div canonical=\"true\" osisID=\"2Cor\" sID=\"gen1792\" type=\"book\"/><title type=\"main\">THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS</title></div><div><chapter chapterTitle=\"CHAPTER 1.\" osisID=\"2Cor.1\" sID=\"gen1793\"/><title type=\"chapter\">CHAPTER 1.</title></div><div><verse osisID=\"2Cor.1.1\" verseOrdinal=\"1\">Paul, an apostle of Jesus Christ.</verse></div></div>",
            {
                chapterNumber: 1,
                originalOrdinalRange: [1, 1],
                ordinalRange: [1, 29],
                key: "2Cor.1",
                keyName: "2 Corinthians 1",
                osisRef: "2Cor.1",
            }
        ));

        expect(wrapper.find(".chapter-number").exists()).toBe(true);
        expect(wrapper.text()).toContain("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS");
        expect(wrapper.text()).toContain("Paul, an apostle of Jesus Christ.");
    });

    it("keeps the verse-zero book title visible when verse numbers are disabled", () => {
        const wrapper = mountBibleDocument(buildBibleDocument(
            "<div><div><div canonical=\"true\" osisID=\"2Cor\" sID=\"gen1792\" type=\"book\"/><title type=\"main\">THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS</title></div><div><chapter chapterTitle=\"CHAPTER 1.\" osisID=\"2Cor.1\" sID=\"gen1793\"/><title type=\"chapter\">CHAPTER 1.</title></div><div><verse osisID=\"2Cor.1.1\" verseOrdinal=\"1\">Paul, an apostle of Jesus Christ.</verse></div></div>",
            {
                chapterNumber: 1,
                originalOrdinalRange: [1, 1],
                ordinalRange: [1, 29],
                key: "2Cor.1",
                keyName: "2 Corinthians 1",
                osisRef: "2Cor.1",
            }
        ), {
            configure: ({config}) => {
                config.showVerseNumbers = false;
                config.showSectionTitles = true;
                config.showNonCanonical = true;
            }
        });

        expect(wrapper.text()).toContain("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS");
        expect(wrapper.find(".chapter-number").exists()).toBe(true);
    });

    it("keeps the chapter separator visible when section titles are disabled", () => {
        const wrapper = mountBibleDocument(buildBibleDocument(
            "<div><div><div canonical=\"true\" osisID=\"2Cor\" sID=\"gen1792\" type=\"book\"/><title type=\"main\">THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS</title></div><div><chapter chapterTitle=\"CHAPTER 1.\" osisID=\"2Cor.1\" sID=\"gen1793\"/><title type=\"chapter\">CHAPTER 1.</title></div><div><verse osisID=\"2Cor.1.1\" verseOrdinal=\"1\">Paul, an apostle of Jesus Christ.</verse></div></div>",
            {
                chapterNumber: 1,
                originalOrdinalRange: [1, 1],
                ordinalRange: [1, 29],
                key: "2Cor.1",
                keyName: "2 Corinthians 1",
                osisRef: "2Cor.1",
            }
        ), {
            configure: ({config}) => {
                config.showVerseNumbers = false;
                config.showSectionTitles = false;
                config.showNonCanonical = true;
            }
        });

        expect(wrapper.find(".chapter-number").exists()).toBe(true);
        expect(wrapper.text()).not.toContain("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS");
    });
});
