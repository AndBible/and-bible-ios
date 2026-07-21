import {beforeEach, describe, expect, it} from "vitest";
import {ref} from "vue";
import {useAndroid} from "@/composables/android";
import {useConfig} from "@/composables/config";

/** Installs one exact selection inside a source-identified document. */
function selectDocumentText(markup: string): void {
    document.body.innerHTML = markup;
    const text = document.querySelector(".ordinal")!.firstChild!;
    const range = document.createRange();
    range.setStart(text, 0);
    range.setEnd(text, text.textContent!.length);
    const selection = window.getSelection()!;
    selection.removeAllRanges();
    selection.addRange(range);
}

describe("typed Speak selection routing", () => {
    beforeEach(() => {
        window.bibleView = {};
        window.bibleViewDebug = {};
        window.android = {} as never;
        document.body.innerHTML = "";
        window.getSelection()?.removeAllRanges();
    });

    it("returns category and versification with exact generic source ordinals", () => {
        selectDocumentText(`
            <div class="document"
                 data-book-initials="LXXCommentary"
                 data-osis-ref="Gen 1:1"
                 data-book-category="COMMENTARY"
                 data-v11n="LXX">
                <span class="ordinal" id="o-41">Commentary text</span>
            </div>
        `);
        const {config} = useConfig(ref("bible"));
        useAndroid({bookmarks: ref([])}, config);

        expect(window.bibleView.querySelection()).toMatchObject({
            bookInitials: "LXXCommentary",
            osisRef: "Gen 1:1",
            bookCategory: "COMMENTARY",
            v11n: "LXX",
            startOrdinal: 41,
            endOrdinal: 41,
            text: "Commentary text",
        });
    });

    it("uses an explicit null versification when a generic source declares no array value", () => {
        selectDocumentText(`
            <div class="document"
                 data-book-initials="Dictionary"
                 data-osis-ref="entry"
                 data-book-category="DICTIONARY">
                <span class="ordinal" id="o-7">Entry text</span>
            </div>
        `);
        const {config} = useConfig(ref("bible"));
        useAndroid({bookmarks: ref([])}, config);

        expect(window.bibleView.querySelection()).toMatchObject({
            bookCategory: "DICTIONARY",
            v11n: null,
            startOrdinal: 7,
            endOrdinal: 7,
        });
    });
});
