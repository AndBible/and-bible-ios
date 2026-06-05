/*
 * Copyright (c) 2024-2026 Sykerö Software / Tuomas Airaksinen and the AndBible contributors.
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

import {mount, flushPromises} from "@vue/test-utils";
import {defineComponent, nextTick, reactive, ref} from "vue";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";

import ChapterNavigationButtons from "@/components/ChapterNavigationButtons.vue";
import Title from "@/components/OSIS/Title.vue";
import {useInfiniteScroll} from "@/composables/infinite-scroll";
import {useReadingTracker} from "@/composables/reading-tracker";
import {eventBus} from "@/eventbus";
import {androidKey, appSettingsKey, calculatedConfigKey, configKey, stringsKey} from "@/types/constants";

vi.mock("@fortawesome/vue-fontawesome", () => ({
    FontAwesomeIcon: {
        name: "FontAwesomeIcon",
        template: "<i class=\"fa-icon\"></i>",
        props: ["icon", "spin"],
    },
}));

const strings = {
    previousChapter: "Previous chapter",
    loadMore: "Load more",
    nextChapter: "Next chapter",
    scrollToTitle: "Scroll to title",
};

/**
 * Builds the common reader dependency injection set used by Vue reader-control tests.
 *
 * @param overrides - Optional dependency replacements for the individual test contract.
 * @returns Symbol-keyed Vue provide map matching the production reader providers.
 * @remarks The tests verify renderer-only controls, so bridge methods are spies and config is limited
 * to fields touched by the mounted components. Missing values would indicate the component now depends
 * on additional shared reader state.
 */
function commonProvides(overrides = {}) {
    return {
        [configKey]: {
            showSectionTitles: true,
            showNonCanonical: true,
            showTitleScrollButton: true,
            ...overrides.config,
        },
        [appSettingsKey]: {
            disableAnimations: false,
            autoTrackReading: true,
            errorBox: false,
            ...overrides.appSettings,
        },
        [calculatedConfigKey]: ref({
            topOffset: 0,
            ...overrides.calculatedConfig,
        }),
        [stringsKey]: {
            ...strings,
            ...overrides.strings,
        },
        [androidKey]: {
            recordChapterRead: vi.fn(),
            openChapterReadHistory: vi.fn(),
            ...overrides.android,
        },
    };
}

describe("reader parity controls", () => {
    afterEach(() => {
        vi.restoreAllMocks();
        vi.unstubAllGlobals();
    });

    /**
     * Protects the Android title-scroll affordance contract.
     *
     * The setup mounts the OSIS title with title-scroll enabled and animations disabled. A passing test
     * proves the icon-only control is accessible and uses non-animated scrolling instead of relying on a
     * browser-specific animation sentinel.
     */
    it("labels the title scroll button and uses non-animated auto scrolling", async () => {
        Object.defineProperty(window, "scrollY", {value: 40, configurable: true});
        const scrollTo = vi.spyOn(window, "scrollTo").mockImplementation(() => {});

        const wrapper = mount(Title, {
            props: {
                canonical: "true",
                short: "",
                type: "main",
            },
            slots: {
                default: "Genesis",
            },
            global: {
                provide: commonProvides({
                    appSettings: {disableAnimations: true},
                    calculatedConfig: {topOffset: 12},
                }),
            },
        });

        wrapper.find("h3").element.getBoundingClientRect = () => ({top: 100});
        const button = wrapper.find("button.title-scroll-btn");
        expect(button.attributes("type")).toBe("button");
        expect(button.attributes("aria-label")).toBe("Scroll to title");

        await button.trigger("click");

        expect(scrollTo).toHaveBeenCalledWith({
            top: 128,
            behavior: "auto",
        });
    });

    /**
     * Protects manual chapter navigation accessibility.
     *
     * The setup mounts the Android-parity chapter navigation cluster. A passing test proves each
     * icon-only button exposes a stable accessible label and remains a non-submit button when embedded
     * in future renderer surfaces.
     */
    it("labels manual chapter navigation icon buttons", () => {
        const wrapper = mount(ChapterNavigationButtons, {
            props: {
                position: "bottom",
                loading: false,
                reachedEnd: false,
            },
            global: {
                provide: commonProvides(),
            },
        });

        const buttons = wrapper.findAll("button");
        expect(buttons.map(button => button.attributes("type"))).toEqual(["button", "button", "button"]);
        expect(buttons.map(button => button.attributes("aria-label"))).toEqual([
            "Previous chapter",
            "Load more",
            "Next chapter",
        ]);
    });
});

describe("reading tracker", () => {
    let observers;
    let android;

    /**
     * Mounts a minimal Bible chapter root for exercising read-progress behavior.
     *
     * @param initialReadCount - Persisted read count supplied by native state.
     * @returns Mounted Vue wrapper plus the composable controls captured from setup.
     * @remarks The mocked IntersectionObserver records observed verse elements and can be triggered
     * manually, making duplicate-read regressions deterministic.
     */
    function mountReadingTracker(initialReadCount = 0) {
        let controls;
        const Harness = defineComponent({
            template: `
                <div ref="containerRef">
                    <span class="verse ordinal" data-ordinal="1"></span>
                    <span class="verse ordinal" data-ordinal="2"></span>
                </div>
            `,
            setup() {
                const containerRef = ref(null);
                controls = useReadingTracker(containerRef, "KJV", [1, 2], 1, initialReadCount);
                return {containerRef};
            },
        });

        const wrapper = mount(Harness, {
            global: {
                provide: commonProvides({android}),
            },
        });
        return {wrapper, controls};
    }

    beforeEach(() => {
        observers = [];
        android = {
            recordChapterRead: vi.fn(),
            openChapterReadHistory: vi.fn(),
        };

        class MockIntersectionObserver {
            constructor(callback) {
                this.callback = callback;
                this.elements = [];
                this.disconnect = vi.fn();
                observers.push(this);
            }

            observe(element) {
                this.elements.push(element);
            }
        }

        vi.stubGlobal("IntersectionObserver", MockIntersectionObserver);
    });

    afterEach(() => {
        eventBus.all.clear();
        vi.unstubAllGlobals();
        vi.restoreAllMocks();
    });

    /**
     * Protects Android read-progress parity for manual reads.
     *
     * The setup starts automatic chapter observation, then records a manual read. A passing test proves
     * manual completion disconnects the observer so later visibility callbacks cannot add a duplicate
     * automatic read row.
     */
    it("stops automatic tracking after a manual read", async () => {
        const {wrapper, controls} = mountReadingTracker();
        await nextTick();

        controls.toggleChapterRead();
        observers[0].callback(observers[0].elements.map(element => ({isIntersecting: true, target: element})));

        expect(observers[0].disconnect).toHaveBeenCalled();
        expect(android.recordChapterRead).toHaveBeenCalledTimes(1);
        expect(android.recordChapterRead).toHaveBeenCalledWith("KJV", 1, 1, "MANUAL");
        wrapper.unmount();
    });

    /**
     * Protects native read-state reconciliation.
     *
     * The setup simulates native reporting that the chapter already has a read history row while the
     * observer is active. A passing test proves the renderer accepts native state as authoritative and
     * does not emit another automatic read when the coverage threshold is later reached.
     */
    it("stops automatic tracking after native read-count updates", async () => {
        const {wrapper, controls} = mountReadingTracker();
        await nextTick();

        eventBus.emit("update_chapter_read_status", [{chapter: 1, count: 1}]);
        observers[0].callback(observers[0].elements.map(element => ({isIntersecting: true, target: element})));

        expect(controls.chapterReadCount.value).toBe(1);
        expect(observers[0].disconnect).toHaveBeenCalled();
        expect(android.recordChapterRead).not.toHaveBeenCalled();
        wrapper.unmount();
    });
});

describe("infinite scroll edge state", () => {
    /**
     * Protects manual navigation state when the previous chapter does not exist.
     *
     * The setup requests content at the top and receives Android's `null` sentinel for start-of-book.
     * A passing test proves the top/start edge does not incorrectly set `reachedEnd`, which would
     * disable bottom navigation and block valid forward movement.
     */
    it("does not mark the bottom reached when only the top has no more content", async () => {
        let controls;
        const requestPreviousChapter = vi.fn().mockResolvedValue(null);
        const requestNextChapter = vi.fn().mockResolvedValue({type: "bible"});
        const Harness = defineComponent({
            template: "<div id=\"bottom\"></div>",
            setup() {
                controls = useInfiniteScroll(
                    {requestPreviousChapter, requestNextChapter},
                    {scrollYAtStart: ref(0)},
                    reactive([]),
                    {infiniteScroll: false},
                );
                return {};
            },
        });

        const wrapper = mount(Harness);
        await nextTick();

        controls.loadTextAtTop();
        await flushPromises();

        expect(requestPreviousChapter).toHaveBeenCalledTimes(1);
        expect(controls.reachedEnd.value).toBe(false);
        wrapper.unmount();
    });
});
