import {enableAutoUnmount, mount} from "@vue/test-utils";
import {computed, defineComponent, nextTick, reactive, ref} from "vue";
import {afterEach, describe, expect, it, vi} from "vitest";

import {useVerseNotifier} from "@/composables/verse-notifier";
import {useScroll} from "@/composables/scroll";
import {configChangeScrollTarget} from "@/composables/reading-position";
import {emit} from "@/eventbus";

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
     * Keeps replacement insertion under programmatic destination ownership until setup settles.
     *
     * Native sends setup_content before the asynchronous document insertion promise completes.
     * A layout scroll from that insertion may expose the document's first verse, but it must not
     * feed that transient coordinate back across the bridge before setup_content applies its jump.
     * The settled destination remains available for configuration restoration without a callback,
     * and the next user-driven scroll remains authoritative.
     */
    it("suppresses insertion telemetry while setup_content awaits and applies its destination", async () => {
        const genesisOneTwentyTwo = renderedOrdinal("Gen.1.22", 22);
        const genesisOneTwentyFour = renderedOrdinal("Gen.1.24", 24);
        const genesisOneTwentyFive = renderedOrdinal("Gen.1.25", 25);
        let visibleElement = genesisOneTwentyTwo;
        const scrolledToOrdinal = vi.fn();
        const documentGeneration = ref(1);
        let resolveInsertion!: () => void;
        const insertion = new Promise<void>(resolve => {
            resolveInsertion = resolve;
        });
        const documentPromise = ref<Promise<void> | null>(insertion);
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
        vi.spyOn(genesisOneTwentyFour, "getBoundingClientRect").mockReturnValue({
            top: 240,
        } as DOMRect);

        mount(defineComponent({
            setup() {
                const scroll = useScroll(
                    {} as never,
                    reactive({disableAnimations: false, topOffset: 0, bottomOffset: 0}) as never,
                    ref({marginLeft: 0, marginRight: 0, topOffset: 0}) as never,
                    {highlightOrdinal: vi.fn(), resetHighlights: vi.fn()} as never,
                    documentPromise,
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
        await nextTick();

        emit("setup_content", {
            jumpToOrdinal: 24,
            jumpToAnchor: null,
            jumpToId: null,
            topOffset: 0,
            bottomOffset: 0,
        });
        window.dispatchEvent(new Event("scroll"));
        await new Promise(resolve => setTimeout(resolve, 60));
        expect(scrolledToOrdinal).not.toHaveBeenCalled();

        visibleElement = genesisOneTwentyFour;
        resolveInsertion();
        await new Promise(resolve => setTimeout(resolve, 120));
        expect(scrolledToOrdinal).not.toHaveBeenCalled();
        expect(configChangeScrollTarget(
            notifier!.currentVerse.value,
            notifier!.currentDocumentId.value,
            notifier!.currentAtChapterTop.value,
        )).toBe("o-24");

        visibleElement = genesisOneTwentyFive;
        window.dispatchEvent(new Event("scroll"));
        await new Promise(resolve => setTimeout(resolve, 60));
        expect(scrolledToOrdinal).toHaveBeenCalledTimes(1);
        expect(scrolledToOrdinal).toHaveBeenLastCalledWith("Gen.1.25", 25, false);
    });

    /** Keeps an obsolete setup completion from releasing the replacement that superseded it. */
    it("retains newer setup_content ownership when an older generation settles", async () => {
        const genesisOneTwentyTwo = renderedOrdinal("Gen.1.22", 22);
        const genesisOneTwentyFour = renderedOrdinal("Gen.1.24", 24);
        let visibleElement = genesisOneTwentyTwo;
        const scrolledToOrdinal = vi.fn();
        const documentGeneration = ref(1);
        let resolveOlder!: () => void;
        let resolveNewer!: () => void;
        const olderInsertion = new Promise<void>(resolve => { resolveOlder = resolve; });
        const newerInsertion = new Promise<void>(resolve => { resolveNewer = resolve; });
        const documentPromise = ref<Promise<void> | null>(olderInsertion);

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
        vi.spyOn(genesisOneTwentyFour, "getBoundingClientRect").mockReturnValue({
            top: 240,
        } as DOMRect);

        mount(defineComponent({
            setup() {
                const scroll = useScroll(
                    {} as never,
                    reactive({disableAnimations: false, topOffset: 0, bottomOffset: 0}) as never,
                    ref({marginLeft: 0, marginRight: 0, topOffset: 0}) as never,
                    {highlightOrdinal: vi.fn(), resetHighlights: vi.fn()} as never,
                    documentPromise,
                    documentGeneration,
                );
                useVerseNotifier(
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
        await nextTick();

        emit("setup_content", {
            jumpToOrdinal: 22,
            jumpToAnchor: null,
            jumpToId: null,
            topOffset: 0,
            bottomOffset: 0,
        });
        documentGeneration.value = 2;
        documentPromise.value = newerInsertion;
        emit("setup_content", {
            jumpToOrdinal: 24,
            jumpToAnchor: null,
            jumpToId: null,
            topOffset: 0,
            bottomOffset: 0,
        });

        resolveOlder();
        await nextTick();
        window.dispatchEvent(new Event("scroll"));
        await new Promise(resolve => setTimeout(resolve, 60));
        expect(scrolledToOrdinal).not.toHaveBeenCalled();

        visibleElement = genesisOneTwentyFour;
        resolveNewer();
        await new Promise(resolve => setTimeout(resolve, 120));
        expect(scrolledToOrdinal).not.toHaveBeenCalled();
    });

    /** Prevents a reverse-completing setup in one generation from restoring an older viewport. */
    it("keeps the newest same-generation setup_content destination", async () => {
        const genesisOneTwentyTwo = renderedOrdinal("Gen.1.22", 22);
        const genesisOneTwentyFour = renderedOrdinal("Gen.1.24", 24);
        const visibleElement = genesisOneTwentyFour;
        let simulatedScrollY = 0;
        const scrolledToOrdinal = vi.fn();
        const documentGeneration = ref(1);
        let resolveOlder!: () => void;
        let resolveNewer!: () => void;
        const olderInsertion = new Promise<void>(resolve => { resolveOlder = resolve; });
        const newerInsertion = new Promise<void>(resolve => { resolveNewer = resolve; });
        const documentPromise = ref<Promise<void> | null>(olderInsertion);

        Object.defineProperty(document, "elementFromPoint", {
            configurable: true,
            value: vi.fn(() => visibleElement),
        });
        vi.spyOn(window, "getComputedStyle").mockReturnValue({
            getPropertyValue: (property: string) => property === "font-size" ? "16" : property === "line-height" ? "20" : "ltr",
        } as CSSStyleDeclaration);
        vi.spyOn(window, "scrollTo").mockImplementation((_x, y) => {
            simulatedScrollY = Number(y);
            window.dispatchEvent(new Event("scroll"));
        });
        vi.spyOn(genesisOneTwentyTwo, "getBoundingClientRect").mockReturnValue({top: 220} as DOMRect);
        vi.spyOn(genesisOneTwentyFour, "getBoundingClientRect").mockReturnValue({top: 240} as DOMRect);

        mount(defineComponent({
            setup() {
                const scroll = useScroll(
                    {} as never,
                    reactive({disableAnimations: false, topOffset: 0, bottomOffset: 0}) as never,
                    ref({marginLeft: 0, marginRight: 0, topOffset: 0}) as never,
                    {highlightOrdinal: vi.fn(), resetHighlights: vi.fn()} as never,
                    documentPromise,
                    documentGeneration,
                );
                useVerseNotifier(
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
        await nextTick();

        emit("setup_content", {
            jumpToOrdinal: 22,
            jumpToAnchor: null,
            jumpToId: null,
            topOffset: 0,
            bottomOffset: 0,
        });
        documentPromise.value = newerInsertion;
        emit("setup_content", {
            jumpToOrdinal: 24,
            jumpToAnchor: null,
            jumpToId: null,
            topOffset: 0,
            bottomOffset: 0,
        });

        resolveNewer();
        await new Promise(resolve => setTimeout(resolve, 120));
        expect(simulatedScrollY).toBe(238);

        resolveOlder();
        await new Promise(resolve => setTimeout(resolve, 120));
        expect(simulatedScrollY).toBe(238);
        expect(scrolledToOrdinal).not.toHaveBeenCalled();
    });

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
