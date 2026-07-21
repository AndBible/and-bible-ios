// @vitest-environment node

import {fileURLToPath} from "node:url";
import {describe, expect, it} from "vitest";
import {loadConfigFromFile} from "vite";

const configPath = fileURLToPath(new URL("../../vite.config.mts", import.meta.url));

describe("BibleView build configuration", () => {
    it("serializes debug source-map generation but leaves production parallelism unchanged", async () => {
        const debug = await loadConfigFromFile({command: "build", mode: "debug"}, configPath);
        const production = await loadConfigFromFile({command: "build", mode: "production"}, configPath);

        expect(debug?.config.build?.sourcemap).toBe("inline");
        expect(debug?.config.build?.rollupOptions?.maxParallelFileOps).toBe(1);
        expect(production?.config.build?.sourcemap).toBe(false);
        expect(production?.config.build?.rollupOptions?.maxParallelFileOps).toBeUndefined();
    });
});
