import {describe, expect, it} from "vitest";

import {resolveScrollToVerseRequest} from "@/composables/scroll";

describe("resolveScrollToVerseRequest", () => {
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
});
