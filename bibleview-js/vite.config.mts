/*
 * Copyright (c) 2022 Martin Denham, Tuomas Airaksinen and the AndBible contributors.
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

import { fileURLToPath, URL } from 'node:url'
import {defineConfig, UserConfig} from 'vite'
import vue from '@vitejs/plugin-vue'
import { load } from "js-yaml";
import _toSource from "tosource";
import {resolve} from "path";

const toSource = _toSource as unknown as (obj: any) => string;

// https://vitejs.dev/config/

const fileRegex = /\.ya?ml$/;
export function yaml() { // copied from https://github.com/mzaini30/vite-plugin-yaml2
    return {
        name: "yaml-to-js",
        transform(src: string, id: string) {
            if (fileRegex.test(id)) {
                const transformedCode = `const data = ${toSource(load(src))}\n`;
                const result = transformedCode + "export default data";

                return {
                    code: result,
                    map: null, // provide source map if available
                };
            }
        },
    }
}

/**
 * Creates the deterministic BibleView build configuration for one named mode.
 *
 * @param mode Vite mode selected by the package script. `debug` keeps an inline source map while
 * `production` emits no source map. `development` retains Vue's local development metadata.
 * @returns A Vite configuration whose output directory may be overridden by
 * `BIBLEVIEW_OUTPUT_DIR` for isolated CI and release builds.
 * @remarks Build output is the only filesystem side effect. Debug builds compile Vue components
 * with production path handling so their bytes do not depend on a developer's checkout path.
 * Invalid output paths and build failures are reported by Vite.
 */
export function bibleViewConfig(mode: string): UserConfig {
    const sourcemap = mode === "debug" ? "inline" : false;
    const outDir = process.env.BIBLEVIEW_OUTPUT_DIR?.trim() || "dist";
    console.log("BibleView build", {mode, sourcemap, outDir});

    return {
        base: '',
        build: {
            outDir,
            emptyOutDir: true,
            sourcemap,
            rollupOptions: {
                // Rollup can collapse identical inline source maps in completion order on Linux.
                // Serial file operations keep debug mappings reproducible without slowing releases.
                ...(sourcemap ? {maxParallelFileOps: 1} : {}),
                input: {
                    main: resolve(__dirname, "index.html")
                }
            },
            commonjsOptions: {
                //
                //exclude: ["node_modules/bible-passage-reference-parser/js/en_bcv_parser.min.js"],
                //exclude: ["bible-passage-reference-parser"],
                //include: [
                //    "node_modules/color/index.js"
                //],
            }
        },
        // Vite's production compiler strips checkout-specific Vue `__file` metadata. The explicit
        // replacement preserves the requested runtime label for debug diagnostics.
        define: {
            "process.env.NODE_ENV": JSON.stringify(mode),
        },
        plugins: [vue(), yaml()],
        resolve: {
            alias: {
                '@': fileURLToPath(new URL('./src', import.meta.url)),
                '~@': fileURLToPath(new URL('./src', import.meta.url)),
                "vue": "vue/dist/vue.esm-bundler.js",
            }
        },
        test: {
            environment: "jsdom",
            globals: true,
        },
    }
}

export default defineConfig(({mode}) => bibleViewConfig(mode))
