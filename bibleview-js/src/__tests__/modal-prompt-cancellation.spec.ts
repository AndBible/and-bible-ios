/*
 * Copyright (c) 2026 Sykerö Software / Tuomas Airaksinen and the AndBible contributors.
 *
 * This file is part of AndBible: Bible Study (http://github.com/AndBible/and-bible).
 */

import {flushPromises, mount, type VueWrapper} from "@vue/test-utils";
import {nextTick, ref, type Component} from "vue";
import {afterEach, describe, expect, it, vi} from "vitest";
import InputText from "@/components/modals/InputText.vue";
import AreYouSure from "@/components/modals/AreYouSure.vue";
import {
    androidKey,
    appSettingsKey,
    calculatedConfigKey,
    configKey,
    modalKey,
    stringsKey,
} from "@/types/constants";

/** User-reachable close sources owned by the production blocking `ModalDialog` wrapper. */
const closePaths = ["toolbar", "backdrop", "escape"] as const;

type ClosePath = typeof closePaths[number];

type PromptApi = {
    inputText: (initialValue?: string, error?: string) => Promise<string | null>
    areYouSure: () => Promise<unknown>
};

type PromptScenario = {
    label: string
    component: Component
    open: (api: PromptApi) => Promise<unknown>
    expectedCancellation: null | undefined
};

/**
 * Describes both shared deferred-result prompts without replacing their production modal child.
 *
 * @remarks Each opener enters the visible pending state that previously became stranded when the
 * standard modal close event only hid its parent component.
 */
const promptScenarios: PromptScenario[] = [
    {
        label: "InputText",
        component: InputText,
        open: api => api.inputText("existing text"),
        expectedCancellation: null,
    },
    {
        label: "AreYouSure",
        component: AreYouSure,
        open: api => api.areYouSure(),
        expectedCancellation: undefined,
    },
];

const promptCloseCases = promptScenarios.flatMap(scenario =>
    closePaths.map(closePath => ({...scenario, closePath})),
);

/** Font Awesome test double that preserves the standard close button's clickable structure. */
const FontAwesomeIconStub = {
    name: "FontAwesomeIcon",
    props: ["icon"],
    template: '<i class="font-awesome-icon"></i>',
};

/**
 * Installs deterministic browser-frame scheduling for modal focus resignation.
 *
 * @returns A callback that executes every queued frame exactly once.
 * @remarks Production close paths with focused input defer their close event by one frame. The
 * returned flush operation removes callbacks before invoking them so reentrant scheduling remains
 * visible to the test rather than running in the same batch.
 */
function installAnimationFrameQueue(): () => void {
    const callbacks = new Map<number, FrameRequestCallback>();
    let nextHandle = 1;
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
        const handle = nextHandle++;
        callbacks.set(handle, callback);
        return handle;
    });
    vi.stubGlobal("cancelAnimationFrame", (handle: number) => callbacks.delete(handle));

    return () => {
        const queued = [...callbacks.entries()];
        queued.forEach(([handle]) => callbacks.delete(handle));
        queued.forEach(([, callback]) => callback(0));
    };
}

/**
 * Builds the minimal shared providers consumed by the prompt and production modal components.
 *
 * @param register Captures the modal-stack registration required by the production child.
 * @returns Symbol-keyed providers with deterministic labels, offsets, and inert native bridges.
 */
function promptProviders(register: ReturnType<typeof vi.fn>) {
    return {
        [androidKey]: {},
        [appSettingsKey]: {
            bottomOffset: 0,
            errorBox: false,
            topOffset: 0,
        },
        [calculatedConfigKey]: ref({}),
        [configKey]: {},
        [modalKey]: {
            closeModals: vi.fn(),
            modalOpen: ref(false),
            register,
        },
        [stringsKey]: {
            cancel: "Cancel",
            inputPlaceholder: "Enter text",
            ok: "OK",
            yes: "Yes",
        },
    };
}

/**
 * Activates one production modal dismissal source and commits any deferred close frame.
 *
 * @param wrapper Mounted prompt containing the real `ModalDialog` component.
 * @param closePath Standard dismissal source to activate.
 * @param flushFrames Deterministic browser-frame queue flush.
 * @returns After Vue has processed the close event and pending prompt resolution.
 */
async function closePrompt(
    wrapper: VueWrapper,
    closePath: ClosePath,
    flushFrames: () => void,
): Promise<void> {
    switch (closePath) {
        case "toolbar":
            await wrapper.get("button.modal-action-button").trigger("click");
            break;
        case "backdrop":
            await wrapper.get(".modal-backdrop").trigger("click");
            break;
        case "escape":
            document.dispatchEvent(new KeyboardEvent("keyup", {key: "Escape"}));
            await nextTick();
            break;
    }

    flushFrames();
    await flushPromises();
}

afterEach(() => {
    document.body.innerHTML = "";
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
});

describe("deferred modal prompt cancellation", () => {
    /**
     * Protects the result contract for every standard close path on both deferred prompt wrappers.
     *
     * Each case mounts the production prompt and `ModalDialog`, starts its exposed asynchronous
     * request, and dismisses through a real toolbar, backdrop, or Escape action. Blocking prompts
     * are intentionally excluded from modal-stack-wide registered dismissal by `useModal`.
     * The request must settle once with its documented cancellation value and remove the modal;
     * failure means a caller remains suspended after the user has visibly dismissed the prompt.
     */
    it.each(promptCloseCases)(
        "$label resolves once after $closePath cancellation",
        async ({component, open, expectedCancellation, closePath}) => {
            vi.stubGlobal("ResizeObserver", class {
                observe() {}
                unobserve() {}
                disconnect() {}
            });
            const flushFrames = installAnimationFrameQueue();
            const register = vi.fn();
            const wrapper = mount(component, {
                attachTo: document.body,
                global: {
                    provide: promptProviders(register),
                    stubs: {
                        FontAwesomeIcon: FontAwesomeIconStub,
                        teleport: true,
                    },
                },
            });

            const resultPromise = open(wrapper.vm as unknown as PromptApi);
            const resolved = vi.fn();
            void resultPromise.then(resolved);
            await flushPromises();
            expect(wrapper.find(".modal-content").exists()).toBe(true);

            await closePrompt(wrapper, closePath, flushFrames);

            await expect(resultPromise).resolves.toBe(expectedCancellation);
            expect(resolved).toHaveBeenCalledOnce();
            expect(resolved).toHaveBeenCalledWith(expectedCancellation);
            expect(wrapper.find(".modal-content").exists()).toBe(false);
            wrapper.unmount();
        },
    );
});
