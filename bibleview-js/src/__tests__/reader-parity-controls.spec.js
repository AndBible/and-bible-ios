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
import BibleDocument from "@/components/documents/BibleDocument.vue";
import Title from "@/components/OSIS/Title.vue";
import {useInfiniteScroll} from "@/composables/infinite-scroll";
import {useMemorization} from "@/composables/memorization";
import {useReadingTracker} from "@/composables/reading-tracker";
import {eventBus} from "@/eventbus";
import {androidKey, appSettingsKey, calculatedConfigKey, configKey, globalBookmarksKey, stringsKey} from "@/types/constants";

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
    markChapterAsRead: "Mark chapter as read",
    openChapterReadHistory: "Open chapter read history",
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
            showMarkAsReadButton: true,
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

/**
 * Creates the minimal global bookmark provider required by `BibleDocument`.
 *
 * @returns Reactive bookmark state with a spyable `updateBookmarks` method.
 * @remarks Reader-control tests do not exercise bookmark rendering, but the production Bible document
 * always registers bookmark data with this provider during setup.
 */
function globalBookmarksProvider() {
    return {
        bookmarks: ref([]),
        bookmarkMap: new Map(),
        bookmarkLabels: new Map(),
        labelsUpdated: ref(0),
        updateBookmarks: vi.fn(),
    };
}

/**
 * Builds a minimal Bible document payload for reader-control component tests.
 *
 * @param overrides - Field replacements for the specific behavior under test.
 * @returns A Bible document object with the fields consumed by `BibleDocument.vue`.
 * @remarks Child OSIS rendering is stubbed in these tests, so the fragment carries only stable identity
 * and ordinal metadata needed by the parent component.
 */
function bibleDocument(overrides = {}) {
    return {
        id: "1",
        type: "bible",
        osisFragment: {
            xml: "<div></div>",
            key: "Gen.1",
            keyName: "Genesis 1",
            v11n: "KJVA",
            bookCategory: "BIBLE",
            bookInitials: "KJV",
            bookAbbreviation: "Gen",
            osisRef: "Gen.1",
            isNewTestament: false,
            features: {},
            ordinalRange: [1, 1],
            language: "en",
            direction: "ltr",
        },
        bookInitials: "KJV",
        bookCategory: "BIBLE",
        bookAbbreviation: "Gen",
        bookName: "Genesis",
        key: "Gen.1",
        v11n: "KJVA",
        osisRef: "Gen.1",
        annotateRef: "",
        genericBookmarks: [],
        ordinalRange: [1, 1],
        originalOrdinalRange: [1, 1],
        isNativeHtml: false,
        bookmarks: [],
        bibleBookName: "Genesis",
        addChapter: false,
        chapterNumber: 1,
        ...overrides,
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

    /**
     * Protects manual chapter navigation edge-state wiring.
     *
     * The setup mounts the shared Android-parity navigation cluster at both reader edges. A passing
     * test proves both toolbar instances can receive both sentinels: previous-chapter controls disable
     * at the start edge, next-chapter controls disable at the end edge, and load-more disables only for
     * the edge represented by that toolbar.
     */
    it("disables manual navigation controls at reached edges", () => {
        const topWrapper = mount(ChapterNavigationButtons, {
            props: {
                position: "top",
                loading: false,
                reachedStart: true,
                reachedEnd: true,
            },
            global: {
                provide: commonProvides(),
            },
        });
        const bottomWrapper = mount(ChapterNavigationButtons, {
            props: {
                position: "bottom",
                loading: false,
                reachedStart: true,
                reachedEnd: true,
            },
            global: {
                provide: commonProvides(),
            },
        });

        const topButtons = topWrapper.findAll("button");
        expect(topButtons[0].attributes("disabled")).toBeDefined();
        expect(topButtons[1].attributes("disabled")).toBeDefined();
        expect(topButtons[2].attributes("disabled")).toBeDefined();

        const bottomButtons = bottomWrapper.findAll("button");
        expect(bottomButtons[0].attributes("disabled")).toBeDefined();
        expect(bottomButtons[1].attributes("disabled")).toBeDefined();
        expect(bottomButtons[2].attributes("disabled")).toBeDefined();
    });

    /**
     * Protects the Android mark-as-read affordance while making it accessible in the WebView.
     *
     * The setup mounts a Bible document with OSIS children stubbed out and auto-tracking disabled. A
     * passing test proves the visual checkmark is a semantic button with a stable label and still emits
     * the same manual read bridge command when activated.
     */
    it("renders mark-as-read as a labeled button that records manual reads", async () => {
        window.bibleViewDebug = {};
        const android = {
            recordChapterRead: vi.fn(),
            openChapterReadHistory: vi.fn(),
        };

        const wrapper = mount(BibleDocument, {
            props: {
                document: bibleDocument(),
            },
            global: {
                provide: {
                    ...commonProvides({
                        android,
                        appSettings: {autoTrackReading: false},
                        config: {showMarkAsReadButton: true},
                    }),
                    [globalBookmarksKey]: globalBookmarksProvider(),
                },
                stubs: {
                    Chapter: true,
                    OsisFragment: true,
                },
            },
        });

        const button = wrapper.find("button.mark-as-read-button");
        expect(button.attributes("type")).toBe("button");
        expect(button.attributes("aria-label")).toBe("Mark chapter as read");

        await button.trigger("click");

        expect(android.recordChapterRead).toHaveBeenCalledWith("KJV", 1, 1, "MANUAL");
    });
});

describe("memorization indicators", () => {
    afterEach(() => {
        eventBus.all.clear();
    });

    /**
     * Supplies deterministic layout data to JSDOM elements used by overlay rendering.
     *
     * @param element - Element whose layout methods should be replaced.
     * @param rect - Viewport coordinates returned to the memorization renderer.
     * @remarks JSDOM has no real layout engine, so indicator tests replace only the DOM read methods
     * used by the production overlay code.
     */
    function stubElementRect(element, rect) {
        element.getBoundingClientRect = () => rect;
        element.getClientRects = () => [rect];
    }

    /**
     * Protects the document-root selector contract for memorization overlays.
     *
     * The setup passes a raw document id to a `#doc-<id>` container, matching `BibleDocument.vue`.
     * A passing test proves indicators find ordinal descendants under that root, rather than looking
     * for the root inside itself and silently skipping all memorization lines.
     */
    it("renders indicators when the container is already the document root", async () => {
        const Harness = defineComponent({
            template: `
                <div id="doc-1" ref="containerRef">
                    <span id="o-1"></span>
                    <span id="o-2"></span>
                </div>
            `,
            setup() {
                const containerRef = ref(null);
                const memorization = useMemorization({showMemorizationIndicators: true});
                memorization.mergeData([1, 2], []);
                memorization.setupIndicatorRendering(containerRef, "1");
                return {containerRef};
            },
        });

        const wrapper = mount(Harness);
        stubElementRect(wrapper.find("#doc-1").element, {top: 10, bottom: 110});
        stubElementRect(wrapper.find("#o-1").element, {top: 20, bottom: 40});
        stubElementRect(wrapper.find("#o-2").element, {top: 50, bottom: 70});

        await nextTick();
        await nextTick();

        const indicator = wrapper.find(".memorization-indicator--memorized");
        expect(indicator.exists()).toBe(true);
        expect(indicator.attributes("data-start-ordinal")).toBe("1");
        expect(indicator.attributes("data-end-ordinal")).toBe("2");
        expect(indicator.element.style.top).toBe("10px");
        expect(indicator.element.style.height).toBe("50px");
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
     * Protects manual navigation state when a chapter edge does not exist.
     *
     * The setup requests content at the top and bottom and receives Android's `null` sentinel for each
     * missing edge. A passing test proves the top/start edge does not incorrectly set `reachedEnd`,
     * and that both edge sentinels prevent repeated manual bridge calls and loading indicators.
     */
    it("does not re-request chapters after edge sentinels are reached", async () => {
        let controls;
        const requestPreviousChapter = vi.fn().mockResolvedValue(null);
        const requestNextChapter = vi.fn().mockResolvedValue(null);
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
        expect(controls.reachedStart.value).toBe(true);
        expect(controls.reachedEnd.value).toBe(false);

        controls.loadTextAtTop();
        await flushPromises();

        expect(requestPreviousChapter).toHaveBeenCalledTimes(1);
        expect(controls.loadingAtTop.value).toBe(false);

        await controls.loadTextAtEnd();
        await flushPromises();

        expect(requestNextChapter).toHaveBeenCalledTimes(1);
        expect(controls.reachedEnd.value).toBe(true);

        await controls.loadTextAtEnd();
        await flushPromises();

        expect(requestNextChapter).toHaveBeenCalledTimes(1);
        expect(controls.loadingAtEnd.value).toBe(false);
        wrapper.unmount();
    });
});
