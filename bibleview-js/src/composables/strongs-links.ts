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

type LinkArgument = {
    key: string
    value: string
}

function prep(string: string): string[] {
    let remainingString = string;
    const res: string[] = [];
    do {
        const match = remainingString.match(/([^ :]+:)([^:]+)$/);
        if (!match) return res;
        const s = match[0];
        res.push(s);
        remainingString = remainingString.slice(0, remainingString.length - s.length);
    } while (remainingString.trim().length > 0);
    return res;
}

function parseArgs(string: string): LinkArgument[] {
    return prep(string).map(segment => {
        const trimmed = segment.trim();
        const colonIdx = trimmed.indexOf(":");
        return {
            key: trimmed.slice(0, colonIdx),
            value: trimmed.slice(colonIdx + 1).trim(),
        };
    });
}

export function canonicalizeStrongsValue(value: string): string {
    const trimmed = value.trim().replace(/_/g, " ");
    const prefix = trimmed.slice(0, 1).toUpperCase();
    const digits = trimmed.slice(1).replace(/\s+/g, "");
    if ((prefix !== "H" && prefix !== "G") || !/^\d+$/.test(digits)) {
        return trimmed.replace(/ /g, "_");
    }

    const strippedDigits = digits.replace(/^0+(?=\d)/, "");
    return `${prefix}${strippedDigits}`;
}

function serializeArg({key, value}: LinkArgument): string {
    const normalizedValue = key === "strong"
        ? canonicalizeStrongsValue(value)
        : value.replace(/ /g, "_");
    return `${key}=${normalizedValue}`;
}

export function buildStrongsLinkFromAttributes(...values: (string | undefined)[]): string {
    const args: LinkArgument[] = [];
    for (const value of values) {
        if (!value) continue;
        args.push(...parseArgs(value));
    }
    return "ab-w://?" + args.map(serializeArg).join("&");
}

export function buildStrongsLinkFromDisplayValue(letter: string, strongsNum: string): string {
    return `ab-w://?strong=${canonicalizeStrongsValue(`${letter}${strongsNum}`)}`;
}
