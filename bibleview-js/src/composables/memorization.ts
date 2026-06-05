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

import {nextTick, onMounted, reactive, Ref} from "vue";
import {setupEventBusListener} from "@/eventbus";
import {Config} from "@/composables/config";

type MemorizationDelta = {
    addedMemorized: number[],
    removedMemorized: number[],
    addedTargets: number[],
    removedTargets: number[],
}

type IndicatorType = "memorized" | "target";

const INDICATOR_CLASS = "memorization-indicator";

/**
 * Groups arbitrary verse ordinals into stable consecutive ranges for indicator rendering.
 *
 * @param ordinals - KJV-normalized ordinals received from the native reading/memorization stores.
 * @returns Inclusive `[start, end]` ranges sorted by ordinal with duplicates removed.
 * @remarks The function is deterministic and has no side effects. Empty input produces no ranges.
 */
export function groupConsecutive(ordinals: number[]): [number, number][] {
    if (ordinals.length === 0) return [];
    const sorted = [...new Set(ordinals)].sort((a, b) => a - b);
    const ranges: [number, number][] = [];
    let start = sorted[0], end = sorted[0];
    for (let i = 1; i < sorted.length; i++) {
        if (sorted[i] === end + 1) {
            end = sorted[i];
        } else {
            ranges.push([start, end]);
            start = sorted[i];
            end = sorted[i];
        }
    }
    ranges.push([start, end]);
    return ranges;
}

/**
 * Reads the top of a verse's first rendered line so indicators align with wrapped text.
 *
 * @param elem - Rendered verse element in the active Bible document container.
 * @returns The first client-rect top, falling back to the element bounding box.
 * @remarks This helper only reads layout and does not mutate DOM.
 */
function getFirstLineTop(elem: Element): number {
    const rects = elem.getClientRects();
    return rects.length > 0 ? rects[0].top : elem.getBoundingClientRect().top;
}

/**
 * Computes the visible bottom for the final line in a memorization range.
 *
 * @param lastElem - Last verse element in the rendered memorization range.
 * @param nextOrdinal - Ordinal immediately after the range.
 * @param container - Bible document DOM container.
 * @param documentId - Current document id used to scope ordinal lookup.
 * @returns Pixel bottom coordinate relative to the viewport.
 * @remarks If the last verse shares a wrapped line with the next verse, Android stops the indicator
 * before that shared line. Missing next-verse elements fall back to the last rendered line.
 */
function getEffectiveBottom(lastElem: Element, nextOrdinal: number, container: HTMLElement, documentId: string): number {
    const rects = lastElem.getClientRects();
    if (rects.length === 0) return lastElem.getBoundingClientRect().bottom;
    if (rects.length === 1) return rects[0].bottom;

    const nextElem = container.querySelector(`#doc-${documentId} #o-${nextOrdinal}`);
    if (nextElem) {
        const nextRects = nextElem.getClientRects();
        if (nextRects.length > 0) {
            const lastLineTop = rects[rects.length - 1].top;
            const nextFirstTop = nextRects[0].top;
            if (Math.abs(lastLineTop - nextFirstTop) < 3) {
                return rects[rects.length - 2].bottom;
            }
        }
    }
    return rects[rects.length - 1].bottom;
}

/**
 * Creates one absolute-positioned memorization indicator line for a rendered ordinal range.
 *
 * @param container - Bible document element that receives the overlay line.
 * @param firstOrdinal - Inclusive first ordinal in the indicator range.
 * @param lastOrdinal - Inclusive last ordinal in the indicator range.
 * @param type - Whether the line represents memorized verses or memorization targets.
 * @param documentId - Current document id used to scope DOM ordinal lookup.
 * @returns A detached indicator element, or `null` when the target verses are not rendered.
 * @remarks The returned element has no event handlers and is safe to remove by class name.
 */
function createIndicatorElement(
    container: HTMLElement,
    firstOrdinal: number,
    lastOrdinal: number,
    type: IndicatorType,
    documentId: string,
): HTMLElement | null {
    const firstElem = container.querySelector(`#doc-${documentId} #o-${firstOrdinal}`) as HTMLElement | null;
    const lastElem = container.querySelector(`#doc-${documentId} #o-${lastOrdinal}`) as HTMLElement | null;
    if (!firstElem || !lastElem) return null;

    const containerRect = container.getBoundingClientRect();
    const firstTop = getFirstLineTop(firstElem);
    const lastBottom = getEffectiveBottom(lastElem, lastOrdinal + 1, container, documentId);

    const top = firstTop - containerRect.top;
    const height = lastBottom - firstTop;
    if (height <= 0) return null;

    const line = document.createElement("div");
    line.className = `${INDICATOR_CLASS} ${INDICATOR_CLASS}--${type}`;
    line.style.position = "absolute";
    line.style.left = "-6px";
    line.style.width = "3px";
    line.style.top = `${top}px`;
    line.style.height = `${height}px`;
    line.style.pointerEvents = "none";
    line.dataset.startOrdinal = String(firstOrdinal);
    line.dataset.endOrdinal = String(lastOrdinal);
    line.dataset.type = type;
    return line;
}

/**
 * Tracks memorized and target ordinals and renders Android-style side indicators in Bible text.
 *
 * @param config - Reactive reader display configuration. `showMemorizationIndicators` controls
 * whether indicator DOM is rendered.
 * @returns Reactive memorization sets plus merge/setup functions used by BibleDocument instances.
 * @remarks The composable listens for `update_memorization_data` events and mutates shared reactive
 * sets. Indicator rendering mutates only document-local DOM overlays and removes old overlays before
 * each render. Missing verse elements are treated as not-yet-rendered, which supports infinite scroll.
 */
export function useMemorization(config: Config) {
    const memorized = reactive(new Set<number>());
    const targets = reactive(new Set<number>());

    /**
     * Merges full-document memorization data into the shared session set.
     *
     * @param newMemorized - Ordinals already marked memorized.
     * @param newTargets - Ordinals selected as memorization targets.
     * @remarks Used as chapters load incrementally; duplicate ordinals are ignored by Set semantics.
     */
    function mergeData(newMemorized: number[], newTargets: number[]) {
        for (const o of newMemorized) memorized.add(o);
        for (const o of newTargets) targets.add(o);
    }

    /**
     * Applies an incremental native memorization update.
     *
     * @param delta - Added and removed ordinals from the native memorization store.
     * @remarks Ordering is deterministic: removals and additions are applied in the event payload order.
     */
    function applyDelta(delta: MemorizationDelta) {
        for (const o of delta.addedMemorized) memorized.add(o);
        for (const o of delta.removedMemorized) memorized.delete(o);
        for (const o of delta.addedTargets) targets.add(o);
        for (const o of delta.removedTargets) targets.delete(o);
    }

    setupEventBusListener("update_memorization_data",
        (delta: MemorizationDelta) => applyDelta(delta)
    );

    /**
     * Rebuilds the current document's memorization indicator overlay.
     *
     * @param container - Document container receiving indicator children.
     * @param documentId - Current document id used in ordinal element selectors.
     * @remarks Rendering is idempotent for the current state: previous indicators are removed before
     * new ones are appended. Disabled config removes any previously rendered indicators.
     */
    function renderIndicators(container: HTMLElement, documentId: string) {
        container.querySelectorAll(`.${INDICATOR_CLASS}`).forEach(el => el.remove());

        if (!config.showMemorizationIndicators) {
            return;
        }

        const targetOnlyOrdinals = [...targets].filter(o => !memorized.has(o));
        for (const [start, end] of groupConsecutive(targetOnlyOrdinals)) {
            const el = createIndicatorElement(container, start, end, "target", documentId);
            if (el) container.appendChild(el);
        }

        for (const [start, end] of groupConsecutive([...memorized])) {
            const el = createIndicatorElement(container, start, end, "memorized", documentId);
            if (el) container.appendChild(el);
        }
    }

    /**
     * Hooks a Bible document container into config and memorization update events.
     *
     * @param containerRef - Ref to the document root element.
     * @param documentId - Current document id used to scope ordinal selectors.
     * @remarks Rendering is scheduled after Vue updates to avoid measuring stale DOM. Event listeners
     * are scoped through the shared event bus, matching Android's bibleview-js implementation.
     */
    function setupIndicatorRendering(containerRef: Ref<HTMLElement | null>, documentId: string) {
        const render = () => {
            if (containerRef.value) {
                renderIndicators(containerRef.value, documentId);
            }
        };
        onMounted(() => nextTick(render));
        setupEventBusListener("set_config", () => nextTick(render));
        setupEventBusListener("update_memorization_data", () => nextTick(render));
    }

    return {memorized, targets, mergeData, setupIndicatorRendering};
}
