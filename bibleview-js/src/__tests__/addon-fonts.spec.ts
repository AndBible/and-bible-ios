// @vitest-environment node

import {describe, expect, it} from "vitest";
import {addonFontStyleSheetURL} from "../composables/addon-fonts";

describe("Android add-on font stylesheet routing", () => {
    it("uses the iOS custom resource origin without collapsing exact module spellings", () => {
        const composed = "Fónt";
        const decomposed = "Fo\u0301nt";

        expect(addonFontStyleSheetURL(composed, "ios")).toBe(
            `andbible-resource://font/${encodeURIComponent(composed)}/fonts.css`,
        );
        expect(addonFontStyleSheetURL(decomposed, "ios")).toBe(
            `andbible-resource://font/${encodeURIComponent(decomposed)}/fonts.css`,
        );
        expect(addonFontStyleSheetURL("Case Font", "android")).toBe(
            "/fonts/Case%20Font/fonts.css",
        );
    });
});
