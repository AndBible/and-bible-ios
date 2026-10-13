import {enableAutoUnmount, mount} from "@vue/test-utils";
import {computed, defineComponent, nextTick, reactive, ref} from "vue";
import {afterEach, describe, expect, it, vi} from "vitest";

import {useVerseNotifier} from "@/composables/verse-notifier";
import {useScroll} from "@/composables/scroll";
import {configChangeScrollTarget} from "@/composables/reading-position";

enableAutoUnmount(afterEach);

afterEach(() => {
    vi.restoreAllMocks();
    Reflect.deleteProperty(document, "elementFromPoint");
    document.body.innerHTML = "";
});

/** Builds one rendered document anchor for the real verse-notifier DOM lookup. */
function renderedOrdinal(key: string, ordinal: number): HTMLElement {
    const documentElement = document.createElement("div");
    documentElement.className = "document";
    documentElement.dataset.osisRef = key;
    documentElement.id = `doc-${key}`;

    const ordinalElement = document.createElement("span");
    ordinalElement.className = "ordinal";
    ordinalElement.dataset.ordinal = String(ordinal);
    ordinalElement.id = `o-${ordinal}`;
    ordinalElement.innerText = String(ordinal);
    documentElement.appendChild(ordinalElement);
    document.body.appendChild(documentElement);
    return ordinalElement;
}

describe("verse notifier", () => {
    /**
     * Reproduces a replacement round trip whose return scroll is programmatic.
     *
     * The visible-position callback must identify the manually visible document even when that
     * document matches the tuple cached before a programmatic replacement. The test drives the
     * actual DOM lookup, scroll listener, Vue watcher, and bridge callback boundary; no native
     * state or timing surrogate decides the result.
     */
    it("reports a manually visible document after a suppressed programmatic replacement", async () => {
        const genesisOneTwentyTwo = renderedOrdinal("Gen.1.22", 22);
        const genesisOneTwentyFour = renderedOrdinal("Gen.1.24", 24);
        let visibleElement = genesisOneTwentyFour;
        const scrolledToOrdinal = vi.fn();
        const documentGeneration = ref(0);
        let scroll: ReturnType<typeof useScroll>;
        let notifier: ReturnType<typeof useVerseNotifier>;

        Object.defineProperty(document, "elementFromPoint", {
            configurable: true,
            value: vi.fn(() => visibleElement),
        });
        vi.spyOn(window, "getComputedStyle").mockReturnValue({
            getPropertyValue: (property: string) => property === "font-size" ? "16" : property === "line-height" ? "20" : "ltr",
        } as CSSStyleDeclaration);
        vi.spyOn(window, "scrollTo").mockImplementation(() => {
            window.dispatchEvent(new Event("scroll"));
        });
        vi.spyOn(genesisOneTwentyTwo, "getBoundingClientRect").mockReturnValue({
            top: 220,
        } as DOMRect);

        const wrapper = mount(defineComponent({
            setup() {
                scroll = useScroll(
                    {} as never,
                    reactive({disableAnimations: false, topOffset: 0, bottomOffset: 0}) as never,
                    ref({marginLeft: 0, marginRight: 0, topOffset: 0}) as never,
                    {highlightOrdinal: vi.fn(), resetHighlights: vi.fn()} as never,
                    ref(null),
                    documentGeneration,
                );
                notifier = useVerseNotifier(
                    {} as never,
                    ref({marginLeft: 0, marginRight: 0, topOffset: 0}) as never,
                    ref(true),
                    {scrolledToOrdinal} as never,
                    ref(null),
                    scroll,
                    computed(() => 20),
                    documentGeneration,
                );
            },
            template: "<div />",
        }));

        window.dispatchEvent(new Event("scroll"));
        await nextTick();
        expect(scrolledToOrdinal).toHaveBeenLastCalledWith("Gen.1.24", 24, false);

        visibleElement = genesisOneTwentyTwo;
        documentGeneration.value += 1;
        await new Promise(resolve => setTimeout(resolve, 60));
        scroll!.scrollToId("o-22", {now: true});
        await nextTick();
        expect(scrolledToOrdinal).toHaveBeenCalledTimes(1);
        expect(configChangeScrollTarget(
            notifier!.currentVerse.value,
            notifier!.currentDocumentId.value,
            notifier!.currentAtChapterTop.value,
        )).toBeNull();

        await new Promise(resolve => setTimeout(resolve, 110));
        expect(scrolledToOrdinal).toHaveBeenCalledTimes(1);
        expect(configChangeScrollTarget(
            notifier!.currentVerse.value,
            notifier!.currentDocumentId.value,
            notifier!.currentAtChapterTop.value,
        )).toBe("o-22");

        visibleElement = genesisOneTwentyFour;
        window.dispatchEvent(new Event("scroll"));
        await nextTick();

        expect(scrolledToOrdinal).toHaveBeenCalledTimes(2);
        expect(scrolledToOrdinal).toHaveBeenLastCalledWith("Gen.1.24", 24, false);

        documentGeneration.value += 1;
        expect(configChangeScrollTarget(
            notifier!.currentVerse.value,
            notifier!.currentDocumentId.value,
            notifier!.currentAtChapterTop.value,
        )).toBeNull();
        await new Promise(resolve => setTimeout(resolve, 60));
        window.dispatchEvent(new Event("scroll"));
        expect(scrolledToOrdinal).toHaveBeenCalledTimes(3);
        expect(scrolledToOrdinal).toHaveBeenLastCalledWith("Gen.1.24", 24, false);

        visibleElement = genesisOneTwentyTwo;
        await new Promise(resolve => setTimeout(resolve, 60));
        window.dispatchEvent(new Event("scroll"));
        expect(scrolledToOrdinal).toHaveBeenLastCalledWith("Gen.1.22", 22, false);

        genesisOneTwentyTwo.closest(".document")!.remove();
        const otherDocumentTwentyTwo = renderedOrdinal("Other.1.22", 22);
        visibleElement = otherDocumentTwentyTwo;
        await new Promise(resolve => setTimeout(resolve, 60));
        window.dispatchEvent(new Event("scroll"));
        expect(scrolledToOrdinal).toHaveBeenCalledTimes(5);
        expect(scrolledToOrdinal).toHaveBeenLastCalledWith("Other.1.22", 22, false);

        Object.defineProperty(otherDocumentTwentyTwo, "offsetTop", {
            configurable: true,
            value: 500,
        });
        await new Promise(resolve => setTimeout(resolve, 60));
        window.dispatchEvent(new Event("scroll"));
        expect(scrolledToOrdinal).toHaveBeenCalledTimes(6);
        expect(scrolledToOrdinal).toHaveBeenLastCalledWith("Other.1.22", 22, true);

        visibleElement = genesisOneTwentyFour;
        window.dispatchEvent(new Event("scroll"));
        wrapper.unmount();
        await new Promise(resolve => setTimeout(resolve, 60));
        expect(scrolledToOrdinal).toHaveBeenCalledTimes(6);

        visibleElement = genesisOneTwentyTwo;
        window.dispatchEvent(new Event("scroll"));
        expect(scrolledToOrdinal).toHaveBeenCalledTimes(6);
    });
});
