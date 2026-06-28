import {mount} from "@vue/test-utils";
import {defineComponent, ref} from "vue";
import {afterEach, describe, expect, it, vi} from "vitest";

import {resolveScrollToVerseRequest, useScroll} from "@/composables/scroll";

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
});
