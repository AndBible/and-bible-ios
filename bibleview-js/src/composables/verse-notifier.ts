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
import {ComputedRef, onUnmounted, ref, Ref, watch} from "vue";
import {setupWindowEventListener} from "@/utils";
import {throttle} from "lodash";
import {CalculatedConfig, Config} from "@/composables/config";
import {UseAndroid} from "@/composables/android";
import {useScroll} from "@/composables/scroll";
import {Nullable} from "@/types/common";

/**
 * Reports positions obtained from user-driven DOM observations to the native bridge.
 *
 * Programmatic scrolling and document replacement invalidate both restoration and bridge-report
 * ownership without emitting feedback. When programmatic scrolling settles, the DOM is observed
 * silently to restore configuration-change state; only a later unsuppressed scroll reports to the
 * bridge, including when it returns to the same tuple from an earlier document generation.
 */
export function useVerseNotifier(
    config: Config,
    calculatedConfig: CalculatedConfig,
    mounted: Ref<boolean>,
    {scrolledToOrdinal}: UseAndroid,
    topElement: Ref<HTMLElement | null>,
    {isScrolling}: ReturnType<typeof useScroll>,
    lineHeight: ComputedRef<number>,
    documentGeneration: Ref<number>,
) {
    const currentVerse = ref<number | null>(null);
    const currentKey = ref<string>("")
    const currentDocumentId = ref<string | null>(null);
    const currentAtChapterTop = ref(false);
    let lastReportedPosition: readonly [string, number, boolean] | null = null;

    /**
     * Removes the outgoing document's restoration and bridge-report ownership.
     *
     * This synchronously clears every observed-position field and emits no bridge callback. Callers
     * cancel queued observation work first so an older document cannot repopulate the cleared state.
     */
    function invalidateObservedPosition() {
        currentVerse.value = null;
        currentKey.value = "";
        currentDocumentId.value = null;
        currentAtChapterTop.value = false;
        lastReportedPosition = null;
    }

    let lastDirection = "ltr";
    const step = 10;

    function* iterate(direction = "ltr") {
        if (direction === "ltr") {
            for (let x = window.innerWidth - Math.max(step, calculatedConfig.value.marginRight); x > 0; x -= step) {
                yield x;
            }
        } else {
            for (let x = Math.max(step, calculatedConfig.value.marginLeft); x < window.innerWidth; x += step) {
                yield x;
            }
        }
    }

    /**
     * Scans the rendered document for the first visible ordinal and updates restoration state.
     *
     * When `reportToBridge` is true, a changed key/ordinal/chapter-top tuple is also published to
     * native code. When false, settlement only refreshes restoration state. If no ordinal is found,
     * the previously invalidated state remains unchanged and no bridge callback is emitted.
     */
    function observeVisiblePosition(reportToBridge: boolean) {
        let y = calculatedConfig.value.topOffset + lineHeight.value * 0.3;

        // Find element, starting from right
        let element: Nullable<HTMLElement>;
        while (y < window.innerHeight) {
            let directionChanged = true;
            while (directionChanged) {
                directionChanged = false;
                for (const x of iterate(lastDirection)) {
                    element = document.elementFromPoint(x, y) as Nullable<HTMLElement>
                    if (element) {
                        element = element.closest(".ordinal") as Nullable<HTMLElement>;
                        if (element) {
                            const direction = window.getComputedStyle(element).getPropertyValue("direction");
                            if (direction !== lastDirection) {
                                directionChanged = true;
                                lastDirection = direction;
                                break;
                            }
                            currentVerse.value = parseInt(element.dataset.ordinal!)
                            const doc = element.closest(".document") as Nullable<HTMLElement>
                            currentKey.value = doc?.dataset.osisRef || ""
                            currentDocumentId.value = doc?.id || null
                            const verseAnchor = document.getElementById(`o-${currentVerse.value}`);
                            const topBoundary = window.scrollY + calculatedConfig.value.topOffset;
                            currentAtChapterTop.value = verseAnchor != null && topBoundary + 1 < verseAnchor.offsetTop;
                            const position = [
                                currentKey.value,
                                currentVerse.value,
                                currentAtChapterTop.value,
                            ] as const;
                            if (reportToBridge && (
                                lastReportedPosition == null ||
                                position.some((value, index) => value !== lastReportedPosition![index])
                            )) {
                                lastReportedPosition = position;
                                scrolledToOrdinal(...position);
                            }
                            return;
                        }
                    }
                }
                y += lineHeight.value * 0.6;
            }
        }
    }

    // Throttle is preferred over debounce because do not want that bible ref display is
    // totally frozen during scrolling
    const onScroll = throttle(() => {
        if (isScrolling.value) return;
        observeVisiblePosition(true);
    }, 50);

    watch(documentGeneration, () => {
        onScroll.cancel();
        invalidateObservedPosition();
    }, {flush: "sync"});
    watch(isScrolling, scrolling => {
        if (scrolling) {
            onScroll.cancel();
            invalidateObservedPosition();
        } else {
            // Refresh config-change restoration state without feeding the owned destination back
            // to native code. A later user scroll remains responsible for bridge publication.
            observeVisiblePosition(false);
        }
    }, {flush: "sync"});

    setupWindowEventListener('scroll', onScroll)
    onUnmounted(() => onScroll.cancel());
    return {currentVerse, currentDocumentId, currentAtChapterTop}
}
