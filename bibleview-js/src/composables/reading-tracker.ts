/*
 * Copyright (c) 2024-2026 Sykerö Software / Tuomas Airaksinen and the AndBible contributors.
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

import {inject, onMounted, onUnmounted, ref, Ref, watch} from "vue";
import {OrdinalRange} from "@/types/client-objects";
import {androidKey, appSettingsKey} from "@/types/constants";
import {setupEventBusListener} from "@/eventbus";

const COVERAGE_THRESHOLD = 0.9;

/**
 * Tracks chapter read state and mirrors Android's manual/automatic chapter-read behavior.
 *
 * @param containerRef - Ref to the Bible document root containing verse ordinal elements.
 * @param bookInitials - Active module initials sent back to native progress persistence.
 * @param ordinalRange - Inclusive KJV ordinal range for the rendered chapter.
 * @param chapterNumber - Display chapter number recorded with read progress.
 * @param initialReadCount - Current persisted read-count for this chapter.
 * @returns Reactive read count plus handlers for toggling read state and opening history.
 * @remarks iOS stores `autoTrackReading` in `appSettings` rather than `config`; otherwise this follows
 * Android's bibleview-js behavior. The composable creates an IntersectionObserver only while automatic
 * tracking is enabled, disconnects it on completion/unmount, and records a chapter read once 90 percent
 * of verse ordinal elements have intersected. Native bridge failures are not caught here because the
 * Android bridge contract treats these calls as fire-and-forget commands.
 */
export function useReadingTracker(
    containerRef: Ref<HTMLElement | null>,
    bookInitials: string,
    ordinalRange: OrdinalRange,
    chapterNumber: number,
    initialReadCount: number,
) {
    const appSettings = inject(appSettingsKey)!;
    const android = inject(androidKey)!;

    const chapterReadCount = ref(initialReadCount);
    const seenOrdinals = new Set<number>();
    let observer: IntersectionObserver | null = null;
    let autoTrackDone = chapterReadCount.value > 0;

    const totalVerses = ordinalRange[1] - ordinalRange[0] + 1;

    /**
     * Checks whether enough verse ordinals were seen to auto-record the chapter as read.
     *
     * @remarks This mutates native reading progress once, then disconnects the observer to avoid
     * duplicate history rows for the same rendered chapter.
     */
    function checkCoverage() {
        if (autoTrackDone || totalVerses <= 0) return;
        const coverage = seenOrdinals.size / totalVerses;
        if (coverage >= COVERAGE_THRESHOLD) {
            autoTrackDone = true;
            android.recordChapterRead(bookInitials, ordinalRange[0], chapterNumber, "AUTO_SCROLL");
            cleanup();
        }
    }

    /**
     * Starts watching visible verse ordinal elements for automatic read tracking.
     *
     * @remarks Missing containers or already-read chapters are no-ops. The observer uses a fixed 50%
     * threshold to match Android and only records ordinals exposed by the renderer.
     */
    function setupObserver() {
        if (!containerRef.value || autoTrackDone) return;

        observer = new IntersectionObserver(
            (entries) => {
                for (const entry of entries) {
                    if (entry.isIntersecting) {
                        const ordinal = parseInt((entry.target as HTMLElement).dataset.ordinal!);
                        if (!isNaN(ordinal)) {
                            seenOrdinals.add(ordinal);
                        }
                    }
                }
                checkCoverage();
            },
            {threshold: 0.5}
        );

        const verseElements = containerRef.value.querySelectorAll(".verse.ordinal[data-ordinal]");
        for (const el of verseElements) {
            observer.observe(el);
        }
    }

    /**
     * Disconnects any active IntersectionObserver.
     *
     * @remarks Safe to call repeatedly; used for disabled settings, completion, and unmount cleanup.
     */
    function cleanup() {
        if (observer) {
            observer.disconnect();
            observer = null;
        }
    }

    /**
     * Records a manual chapter read and increments the displayed count optimistically.
     *
     * @remarks Android uses repeated taps as additional read history rows. Removing rows is handled
     * through the read-history dialog opened by long press/context menu.
     */
    function toggleChapterRead() {
        android.recordChapterRead(bookInitials, ordinalRange[0], chapterNumber, "MANUAL");
        chapterReadCount.value++;
    }

    /**
     * Opens the native read-history surface for the current chapter.
     *
     * @remarks This is a bridge side effect only; the event bus updates the count when native state
     * changes after the dialog.
     */
    function openChapterReadHistory() {
        android.openChapterReadHistory(bookInitials, ordinalRange[0], chapterNumber);
    }

    setupEventBusListener("update_chapter_read_status", (data: {chapter: number, count: number}) => {
        if (data.chapter === chapterNumber) {
            chapterReadCount.value = data.count;
        }
    });

    watch(() => appSettings.autoTrackReading, (enabled) => {
        if (enabled && !autoTrackDone) {
            setupObserver();
        } else {
            cleanup();
        }
    });

    onMounted(() => {
        if (appSettings.autoTrackReading && !autoTrackDone) {
            setupObserver();
        }
    });

    onUnmounted(() => {
        cleanup();
    });

    return {chapterReadCount, toggleChapterRead, openChapterReadHistory};
}
