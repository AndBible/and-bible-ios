/*
 * Copyright (c) 2021-2022 Martin Denham, Tuomas Airaksinen and the AndBible contributors.
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

import {setupEventBusListener} from "@/eventbus";
import {getPlatform, type Platform} from "@/composables/native-bridge";
import {onBeforeMount} from "vue";

/**
 * Resolve one admitted font module to the platform resource endpoint.
 *
 * @param moduleName exact installed module initials supplied by the native admitted projection
 * @param platform current host platform; injectable for deterministic route tests
 * @returns Android app-assets URL or the iOS contained custom-scheme URL
 * @sideEffects none
 * @throws never
 */
export function addonFontStyleSheetURL(
    moduleName: string,
    platform: Platform = getPlatform(),
): string {
    const encodedName = encodeURIComponent(moduleName);
    return platform === "ios"
        ? `andbible-resource://font/${encodedName}/fonts.css`
        : `/fonts/${encodedName}/fonts.css`;
}

export function useAddonFonts() {
    const elements: HTMLElement[] = [];

    setupEventBusListener("reload_addons", ({fontModuleNames}: { fontModuleNames: string[] }) => {
        reloadFonts(fontModuleNames)
    })

    function reloadFonts(fontModuleNames: string[]) {
        for (const e of elements) {
            e.remove();
        }
        elements.splice(0);
        for (const modName of fontModuleNames) {
            const link = document.createElement("link");
            link.href = addonFontStyleSheetURL(modName);
            link.type = "text/css";
            link.rel = "stylesheet";
            document.getElementsByTagName("head")[0].appendChild(link)
            elements.push(link);
        }
    }

    onBeforeMount(() => {
        const fontModuleNames = new URLSearchParams(window.location.search).get("fontModuleNames");
        if (!fontModuleNames) return
        reloadFonts(fontModuleNames.split(","));
    })
}
