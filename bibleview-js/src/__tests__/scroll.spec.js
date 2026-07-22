import {enableAutoUnmount, mount} from "@vue/test-utils";
import {defineComponent, ref} from "vue";
import {afterEach, describe, expect, it, vi} from "vitest";

import {resolveScrollToVerseRequest, useScroll} from "@/composables/scroll";
import {eventBus} from "@/eventbus";

enableAutoUnmount(afterEach);

afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    Object.defineProperty(window, "scrollY", {value: 0, configurable: true});
    document.body.innerHTML = "";
});

describe("scroll composable", () => {
    it("maps ordinal payloads to ordinal anchor ids", () => {
        expect(resolveScrollToVerseRequest({
            ordinal: 30850,
            now: true,
            highlight: true,
            force: true,
            duration: 250,
        })).toEqual({
            targetId: "o-30850",
            options: {now: true, highlight: true, force: true, duration: 250},
        });
    });

    it("falls back to top scrolling when the payload has no ordinal", () => {
        expect(resolveScrollToVerseRequest({
            ordinal: null,
            now: false,
            highlight: false,
            force: true,
        })).toEqual({
            targetId: null,
            options: {now: false, highlight: false, force: true, duration: undefined},
        });
    });

    /**
     * Protects Android setup-content parity for anchored selection restoration.
     *
     * Android highlights every ordinal in the supplied source range before restoring the anchor.
     * The source module and OSIS reference must reach the highlighter so mixed-module documents do
     * not infer identity from whichever pane happens to be active.
     */
    it("highlights the complete setup anchor range before restoring scroll", async () => {
        const target = document.createElement("span");
        target.id = "o-77";
        Object.defineProperty(target, "innerText", {value: "John 3:16"});
        target.getBoundingClientRect = () => ({top: 240});
        document.body.appendChild(target);

        Object.defineProperty(window, "scrollY", {value: 0, configurable: true});
        vi.stubGlobal("devicePixelRatio", 1);
        vi.spyOn(window, "getComputedStyle").mockReturnValue({
            getPropertyValue: () => "20px",
        });
        const scrollTo = vi.spyOn(window, "scrollTo").mockImplementation(() => {});
        const highlightOrdinal = vi.fn();
        const resetHighlights = vi.fn();

        mount(defineComponent({
            setup() {
                useScroll(
                    {},
                    {disableAnimations: false, topOffset: 0, bottomOffset: 0, imeOpen: false},
                    ref({topOffset: 30}),
                    {highlightOrdinal, resetHighlights},
                    ref(Promise.resolve()),
                    ref(4)
                );
            },
            template: "<div />",
        }));

        eventBus.emit("setup_content", [{
            jumpToOrdinal: null,
            jumpToAnchor: 77,
            jumpToId: null,
            topOffset: 0,
            bottomOffset: 0,
            ordinalStart: 77,
            ordinalEnd: 79,
            highlight: true,
            bookInitials: "NASB",
            osisRef: "John.3",
        }]);
        await Promise.resolve();
        await Promise.resolve();

        expect(resetHighlights).toHaveBeenCalledOnce();
        expect(highlightOrdinal.mock.calls).toEqual([
            [77, "NASB", "John.3"],
            [78, "NASB", "John.3"],
            [79, "NASB", "John.3"],
        ]);
        expect(scrollTo).toHaveBeenCalled();
    });

    /**
     * Protects document-generation isolation while setup-content awaits newly rendered content.
     *
     * A setup event belonging to an obsolete document must not highlight or restore-scroll after a
     * newer generation replaces it, even when the obsolete document promise resolves later.
     */
    it("drops stale setup anchor highlight and scroll work", async () => {
        let resolveDocument;
        const pendingDocument = new Promise(resolve => {
            resolveDocument = resolve;
        });
        const generation = ref(8);
        const highlightOrdinal = vi.fn();
        const resetHighlights = vi.fn();
        const scrollTo = vi.spyOn(window, "scrollTo").mockImplementation(() => {});

        mount(defineComponent({
            setup() {
                useScroll(
                    {},
                    {disableAnimations: false, topOffset: 0, bottomOffset: 0, imeOpen: false},
                    ref({topOffset: 30}),
                    {highlightOrdinal, resetHighlights},
                    ref(pendingDocument),
                    generation
                );
            },
            template: "<div />",
        }));

        eventBus.emit("setup_content", [{
            jumpToOrdinal: null,
            jumpToAnchor: 77,
            jumpToId: null,
            topOffset: 0,
            bottomOffset: 0,
            ordinalStart: 77,
            ordinalEnd: 79,
            highlight: true,
            bookInitials: "NASB",
            osisRef: "John.3",
        }]);
        generation.value = 9;
        resolveDocument();
        await Promise.resolve();
        await Promise.resolve();

        expect(resetHighlights).not.toHaveBeenCalled();
        expect(highlightOrdinal).not.toHaveBeenCalled();
        expect(scrollTo).not.toHaveBeenCalled();
    });

    /**
     * Protects Android parity for synchronized-scroll anchoring.
     *
     * Android resolves the target verse's rendered document position instead of trusting
     * `offsetTop`, which can be relative to a nested document container after infinite-scroll
     * content has been prepended.
     */
    it("scrolls to the rendered verse position instead of a local offsetTop", () => {
        const target = document.createElement("span");
        target.id = "o-10";
        Object.defineProperty(target, "innerText", {value: "verse 10"});
        Object.defineProperty(target, "offsetTop", {value: 120});
        target.getBoundingClientRect = () => ({top: 250});
        document.body.appendChild(target);

        Object.defineProperty(window, "scrollY", {value: 400, configurable: true});
        vi.stubGlobal("devicePixelRatio", 1);
        vi.spyOn(window, "getComputedStyle").mockReturnValue({
            getPropertyValue: (name) => name === "line-height" || name === "font-size" ? "20px" : "",
        });
        const scrollTo = vi.spyOn(window, "scrollTo").mockImplementation(() => {});

        const wrapper = mount(defineComponent({
            setup() {
                const scroll = useScroll(
                    {},
                    {disableAnimations: false, topOffset: 0, bottomOffset: 0, imeOpen: false},
                    ref({topOffset: 30}),
                    {highlightOrdinal: vi.fn(), resetHighlights: vi.fn()},
                    ref(Promise.resolve()),
                    ref(0)
                );
                return {scrollToId: scroll.scrollToId};
            },
            template: "<div />",
        }));

        wrapper.vm.scrollToId("o-10", {now: true});

        expect(scrollTo).toHaveBeenCalledWith(0, 620);
    });

    /**
     * Protects scroll lifecycle cleanup when a component unmounts or jsdom tears down.
     *
     * The touch-start cancellation listener must be registered with a stable callback and removed
     * during scope disposal. Otherwise Vitest can report late `document is not defined` errors, and
     * the real web view can leak stale touch handlers across reader document lifetimes.
     */
    it("removes touch cancellation listener with the registered callback", () => {
        const addListener = vi.spyOn(document, "addEventListener");
        const removeListener = vi.spyOn(document, "removeEventListener");
        vi.spyOn(window, "requestAnimationFrame").mockReturnValue(1);
        vi.spyOn(window, "cancelAnimationFrame").mockImplementation(() => {});
        vi.spyOn(window, "scrollTo").mockImplementation(() => {});

        const wrapper = mount(defineComponent({
            setup() {
                const scroll = useScroll(
                    {},
                    {disableAnimations: false, topOffset: 0, bottomOffset: 0, imeOpen: false},
                    ref({topOffset: 30}),
                    {highlightOrdinal: vi.fn(), resetHighlights: vi.fn()},
                    ref(Promise.resolve()),
                    ref(0)
                );
                return {doScrolling: scroll.doScrolling};
            },
            template: "<div />",
        }));

        wrapper.vm.doScrolling(200, 100);

        const touchStartAdd = addListener.mock.calls.find(([event]) => event === "touchstart");
        expect(touchStartAdd).toBeTruthy();

        wrapper.unmount();

        expect(removeListener).toHaveBeenCalledWith("touchstart", touchStartAdd[1]);
    });

    /**
     * Protects Android scroll-anchor parity for reader links that open auxiliary panels.
     *
     * Android records the clicked link as a temporary scroll anchor, then keeps it visible if a
     * viewport resize would otherwise push it under the top toolbar or out of view. Failure means
     * the link-modal path can move the original tap target off-screen after the auxiliary panel
     * changes available reader height.
     */
    it("keeps the emitted scroll anchor visible across resize", async () => {
        const target = document.createElement("a");
        target.className = "reference-link";
        target.textContent = "Genesis 1:1";
        target.getBoundingClientRect = () => ({top: 10, bottom: 20});
        document.body.appendChild(target);

        Object.defineProperty(window, "scrollY", {value: 500, configurable: true});
        Object.defineProperty(window, "innerHeight", {value: 600, configurable: true});
        vi.spyOn(window, "requestAnimationFrame").mockImplementation(callback => {
            callback(0);
            return 1;
        });
        const scrollTo = vi.spyOn(window, "scrollTo").mockImplementation(() => {});

        mount(defineComponent({
            setup() {
                useScroll(
                    {},
                    {disableAnimations: false, topOffset: 0, bottomOffset: 0, imeOpen: false},
                    ref({topOffset: 100}),
                    {highlightOrdinal: vi.fn(), resetHighlights: vi.fn()},
                    ref(Promise.resolve()),
                    ref(0)
                );
            },
            template: "<div />",
        }));

        await new Promise(resolve => setTimeout(resolve, 0));
        eventBus.emit("set_scroll_anchor", [target]);
        window.dispatchEvent(new Event("resize"));
        await new Promise(resolve => setTimeout(resolve, 0));

        expect(scrollTo).toHaveBeenCalledWith(0, 243.33333333333334);
    });

    /**
     * Protects reader document lifecycle cleanup for temporary link scroll anchors.
     *
     * Link navigation can clear or replace the reader document before the resize that follows panel
     * opening. A detached source anchor must not be measured later because that would scroll the new
     * document based on stale geometry from the old document.
     */
    it("ignores a detached scroll anchor after the reader document is cleared", async () => {
        const target = document.createElement("a");
        target.className = "reference-link";
        target.textContent = "Genesis 1:1";
        target.getBoundingClientRect = () => ({top: 10, bottom: 20});
        document.body.appendChild(target);

        Object.defineProperty(window, "scrollY", {value: 500, configurable: true});
        Object.defineProperty(window, "innerHeight", {value: 600, configurable: true});
        vi.spyOn(window, "requestAnimationFrame").mockImplementation(callback => {
            callback(0);
            return 1;
        });
        const scrollTo = vi.spyOn(window, "scrollTo").mockImplementation(() => {});

        mount(defineComponent({
            setup() {
                useScroll(
                    {},
                    {disableAnimations: false, topOffset: 0, bottomOffset: 0, imeOpen: false},
                    ref({topOffset: 100}),
                    {highlightOrdinal: vi.fn(), resetHighlights: vi.fn()},
                    ref(Promise.resolve()),
                    ref(0)
                );
            },
            template: "<div />",
        }));

        await new Promise(resolve => setTimeout(resolve, 0));
        eventBus.emit("set_scroll_anchor", [target]);
        eventBus.emit("clear_document", []);
        target.remove();
        window.dispatchEvent(new Event("resize"));
        await new Promise(resolve => setTimeout(resolve, 0));

        expect(scrollTo).not.toHaveBeenCalled();
    });
});
