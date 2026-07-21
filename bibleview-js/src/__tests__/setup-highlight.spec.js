import {enableAutoUnmount, mount} from "@vue/test-utils";
import {defineComponent, h, nextTick, provide, ref} from "vue";
import {afterEach, describe, expect, it, vi} from "vitest";

import Verse from "@/components/OSIS/Verse.vue";
import {useConfig} from "@/composables/config";
import {useOrdinalHighlight} from "@/composables/ordinal-highlight";
import {useScroll} from "@/composables/scroll";
import {useStrings} from "@/composables/strings";
import {eventBus} from "@/eventbus";
import {
    androidKey,
    appSettingsKey,
    bibleDocumentInfoKey,
    calculatedConfigKey,
    configKey,
    osisFragmentKey,
    ordinalHighlightKey,
    stringsKey,
} from "@/types/constants";

enableAutoUnmount(afterEach);

window.bibleViewDebug = {};

afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    document.body.innerHTML = "";
});

const DocumentVerse = defineComponent({
    props: {
        bookInitials: {type: String, required: true},
        testId: {type: String, required: true},
    },
    setup(props) {
        provide(bibleDocumentInfoKey, {
            bibleBookName: "John",
            bookInitials: props.bookInitials,
            osisRef: "John.3",
            ordinalRange: [77, 79],
            originalOrdinalRange: null,
            v11n: "KJV",
        });
        return () => h("div", {"data-testid": props.testId}, [
            h(Verse, {osisID: "John.3.16", verseOrdinal: "77"}, () => "For God so loved"),
        ]);
    },
});

describe("setup-content verse highlighting", () => {
    /**
     * Verifies setup-content highlights flow through the rendered Bible document identity.
     *
     * Android scopes an anchor highlight by source module, source OSIS reference, and ordinal.
     * This mounted contract test drives the real setup-content listener and ordinal highlighter,
     * then proves only the matching rendered document receives the visual highlight class.
     *
     * - Side effects: Mounts two document contexts and emits one setup-content bridge event.
     * - Failure modes: A missing document identity, unscoped fallback, or broken setup listener
     *   either leaves the target unhighlighted or leaks the highlight into the other module.
     */
    it("renders an anchor highlight only in the matching module and reference", async () => {
        Object.defineProperty(window, "scrollY", {value: 0, configurable: true});
        vi.stubGlobal("devicePixelRatio", 1);
        vi.spyOn(window, "getComputedStyle").mockReturnValue({
            getPropertyValue: () => "20px",
        });
        vi.spyOn(window, "scrollTo").mockImplementation(() => {});

        const wrapper = mount(defineComponent({
            setup() {
                const documentType = ref("bible");
                const {config, appSettings, calculatedConfig} = useConfig(documentType);
                const ordinalHighlight = useOrdinalHighlight();

                provide(configKey, config);
                provide(appSettingsKey, appSettings);
                provide(calculatedConfigKey, calculatedConfig);
                provide(stringsKey, useStrings());
                provide(androidKey, {querySelection: () => null});
                provide(osisFragmentKey, {bookCategory: "BIBLE", direction: "ltr"});
                provide(ordinalHighlightKey, ordinalHighlight);

                useScroll(
                    config,
                    appSettings,
                    calculatedConfig,
                    ordinalHighlight,
                    ref(Promise.resolve()),
                    ref(1)
                );

                return () => h("div", [
                    h(DocumentVerse, {bookInitials: "NASB", testId: "matching"}),
                    h(DocumentVerse, {bookInitials: "KJV", testId: "other-module"}),
                ]);
            },
        }));

        for (const target of wrapper.findAll("#o-77")) {
            Object.defineProperty(target.element, "innerText", {value: "John 3:16"});
            target.element.getBoundingClientRect = () => ({top: 240});
        }

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
        await nextTick();
        await nextTick();

        expect(wrapper.get('[data-testid="matching"] .highlight-transition').classes()).toContain("isHighlighted");
        expect(wrapper.get('[data-testid="other-module"] .highlight-transition').classes()).not.toContain("isHighlighted");
    });
});
