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

import {ref, onMounted, onBeforeUnmount, watch} from "vue";
import type {Ref} from "vue";

/**
 * Tracks whether horizontal tab content overflows the visible tab rail.
 *
 * @param elementRef - Vue ref for the scrollable tab navigation element.
 * @returns Reactive flags for hidden tab content on either side of the rail.
 * @remarks Android uses these flags to show subtle edge fades instead of adding margins or native
 * scroll affordances around dictionary and mode tabs.
 */
export function useScrollOverflow(elementRef: Ref<HTMLElement | null>) {
    const canScrollLeft = ref(false);
    const canScrollRight = ref(false);

    let observedElement: HTMLElement | null = null;
    let resizeObserver: ResizeObserver | null = null;

    function update() {
        const el = elementRef.value;
        if (!el) {
            canScrollLeft.value = false;
            canScrollRight.value = false;
            return;
        }
        canScrollLeft.value = el.scrollLeft > 1;
        canScrollRight.value = el.scrollLeft < el.scrollWidth - el.clientWidth - 1;
    }

    function setup() {
        const el = elementRef.value;
        if (!el) return;
        if (observedElement === el) {
            update();
            return;
        }
        teardown();
        observedElement = el;
        el.addEventListener("scroll", update, {passive: true});
        if (typeof ResizeObserver !== "undefined") {
            resizeObserver = new ResizeObserver(update);
            resizeObserver.observe(el);
        }
        update();
    }

    function teardown() {
        if (observedElement) {
            observedElement.removeEventListener("scroll", update);
        }
        resizeObserver?.disconnect();
        observedElement = null;
        resizeObserver = null;
    }

    onMounted(() => setup());
    onBeforeUnmount(() => teardown());

    watch(elementRef, (newEl, oldEl) => {
        if (oldEl) teardown();
        if (newEl) setup();
    });

    return {canScrollLeft, canScrollRight};
}
