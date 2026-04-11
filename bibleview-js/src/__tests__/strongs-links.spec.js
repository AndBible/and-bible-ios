/*
 * Copyright (c) 2026 Sykerö Software / Tuomas Airaksinen and the AndBible contributors.
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

import { describe, expect, it } from "vitest";
import {
    buildStrongsLinkFromAttributes,
    buildStrongsLinkFromDisplayValue,
    canonicalizeStrongsValue,
} from "@/composables/strongs-links";

describe("strongs-links", () => {
    it("canonicalizes padded Strong's values before emitting links", () => {
        expect(canonicalizeStrongsValue("H00430")).toBe("H430");
        expect(canonicalizeStrongsValue("G00001")).toBe("G1");
    });

    it("builds identical canonical links for OSIS attribute and displayed-number paths", () => {
        const fromAttributes = buildStrongsLinkFromAttributes("strong:H00430 lemma.TR:אלהים");
        const fromDisplay = buildStrongsLinkFromDisplayValue("H", "00430");

        expect(fromAttributes).toContain("strong=H430");
        expect(fromAttributes).toBe("ab-w://?lemma.TR=אלהים&strong=H430");
        expect(fromDisplay).toBe("ab-w://?strong=H430");
    });

    it("preserves non-Strong's arguments while canonicalizing the strong key", () => {
        expect(
            buildStrongsLinkFromAttributes("strong:H00430", "robinson:N-NSM 2")
        ).toBe("ab-w://?strong=H430&robinson=N-NSM_2");
    });
});
