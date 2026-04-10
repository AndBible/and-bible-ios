import {describe, expect, it} from "vitest";

import {configChangeScrollTarget} from "@/composables/reading-position";

describe("configChangeScrollTarget", () => {
    it("preserves chapter-top context at the current chapter container", () => {
        expect(configChangeScrollTarget(1, "doc-current", true)).toBe("doc-current");
    });

    it("falls back to the visible verse ordinal away from chapter top", () => {
        expect(configChangeScrollTarget(41, "doc-current", false)).toBe("o-41");
    });

    it("returns null when there is no known location yet", () => {
        expect(configChangeScrollTarget(null, null, false)).toBeNull();
    });

    it("falls back to absolute top when the chapter container is unavailable", () => {
        expect(configChangeScrollTarget(1, null, true)).toBe("top");
    });
});
