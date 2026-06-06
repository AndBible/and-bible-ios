<!--
  - Copyright (c) 2021-2022 Martin Denham, Tuomas Airaksinen and the AndBible contributors.
  -
  - This file is part of AndBible: Bible Study (http://github.com/AndBible/and-bible).
  -
  - AndBible is free software: you can redistribute it and/or modify it under the
  - terms of the GNU General Public License as published by the Free Software Foundation,
  - either version 3 of the License, or (at your option) any later version.
  -
  - AndBible is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
  - without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
  - See the GNU General Public License for more details.
  -
  - You should have received a copy of the GNU General Public License along with AndBible.
  - If not, see http://www.gnu.org/licenses/.
  -->

<template>
  <div
      ref="containerRef"
      :id="`doc-${document.id}`"
       class="document bible-document"
       :data-book-initials="bookInitials"
       :data-osis-ref="osisRef"
  >
    <Chapter v-if="document.addChapter" :n="document.chapterNumber.toString()"/>
    <OsisFragment :fragment="document.osisFragment"/>
    <div v-if="config.showMarkAsReadButton" class="mark-as-read-container">
      <div class="mark-as-read-wrapper">
        <button
            type="button"
            class="mark-as-read-button"
            :class="{read: chapterReadCount > 0}"
            :aria-label="strings.markChapterAsRead"
            :title="strings.markChapterAsRead"
            @click="onCheckClick"
            @touchstart.passive="onCheckPressStart"
            @touchend="onCheckPressEnd"
            @touchmove="onCheckPressEnd"
            @touchcancel="onCheckPressEnd"
            @contextmenu.prevent="onOpenReadHistory"
        >
          <FontAwesomeIcon class="mark-as-read-icon" :icon="faCheck" aria-hidden="true"/>
        </button>
        <button
            v-if="chapterReadCount > 0"
            type="button"
            class="read-count"
            :aria-label="strings.openChapterReadHistory"
            :title="strings.openChapterReadHistory"
            @click="onOpenReadHistory"
        >×{{ chapterReadCount }}</button>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
/**
 * Renders a Bible chapter document and attaches Android-parity reader progress affordances.
 *
 * @remarks
 * The component provides Bible document context to OSIS children, registers bookmark and AI-marker
 * data with the shared bookmark pipeline, merges memorization ordinals into the shared overlay
 * renderer when the root BibleView provider is present, and exposes the Android mark-as-read/checkmark
 * behavior. Bridge calls are fire-and-forget and native state reconciliation arrives through event-bus
 * updates. Direct unit-test mounts without the root provider skip only memorization overlays.
 */
import {inject, onUnmounted, provide, ref} from "vue";
import {useBookmarks} from "@/composables/bookmarks";
import OsisFragment from "@/components/documents/OsisFragment.vue";
import {useCommon} from "@/composables";
import Chapter from "@/components/OSIS/Chapter.vue";
import {bibleDocumentInfoKey, footnoteCountKey, globalBookmarksKey, memorizationKey} from "@/types/constants";
import {BibleDocumentType} from "@/types/documents";
import {useReadingTracker} from "@/composables/reading-tracker";
import {FontAwesomeIcon} from "@fortawesome/vue-fontawesome";
import {faCheck} from "@fortawesome/free-solid-svg-icons";

const props = defineProps<{ document: BibleDocumentType }>();

// eslint-disable-next-line no-unused-vars,vue/no-setup-props-destructure
const {id, bibleBookName, bookInitials, bookmarks, aiDocMarkers = [], ordinalRange, originalOrdinalRange, v11n, osisRef} = props.document;

provide(bibleDocumentInfoKey, {bibleBookName, bookInitials, ordinalRange, originalOrdinalRange, v11n})

const containerRef = ref<HTMLElement | null>(null);

const globalBookmarks = inject(globalBookmarksKey)!;
globalBookmarks.updateBookmarks([...bookmarks, ...aiDocMarkers]);

const memorization = inject(memorizationKey, null);
if (memorization && props.document.memorizedOrdinals) {
    memorization.mergeData(props.document.memorizedOrdinals, props.document.targetOrdinals ?? []);
}
memorization?.setupIndicatorRendering(containerRef, id);

const {config, appSettings, strings, ...common} = useCommon();

useBookmarks(id, ordinalRange, globalBookmarks, bookInitials,  null, true, ref(true), common, config, appSettings);

let footNoteCount = ordinalRange[0] || 0;

function getFootNoteCount() {
    return footNoteCount++;
}

provide(footnoteCountKey, {getFootNoteCount});

const displayChapter = Math.max(1, props.document.chapterNumber);

const {
    chapterReadCount,
    toggleChapterRead: onMarkAsRead,
    openChapterReadHistory: onOpenReadHistory,
} = useReadingTracker(
    containerRef, bookInitials, ordinalRange, displayChapter,
    props.document.chapterReadCount ?? 0,
);

const LONG_PRESS_MS = 500;
let longPressTimer: number | null = null;
let longPressed = false;

/**
 * Starts Android-style long-press handling for the read-history affordance.
 *
 * @remarks The WebView can show a selection callout during long presses, so this component tracks the
 * timer directly and opens history before the normal click handler records a new read entry.
 */
function onCheckPressStart() {
    longPressed = false;
    longPressTimer = window.setTimeout(() => {
        longPressTimer = null;
        longPressed = true;
        onOpenReadHistory();
    }, LONG_PRESS_MS);
}

/**
 * Cancels any pending long-press timer for the mark-as-read affordance.
 *
 * @remarks Safe for touchend, touchmove, and touchcancel; it mutates only this component's timer state.
 */
function onCheckPressEnd() {
    if (longPressTimer != null) {
        window.clearTimeout(longPressTimer);
        longPressTimer = null;
    }
}

onUnmounted(() => {
    onCheckPressEnd();
});

/**
 * Handles a tap on the chapter read indicator.
 *
 * @param event - Browser click event generated by touch or pointer activation.
 * @remarks A click following a long press is swallowed so opening history does not also append a read
 * history row. Normal clicks optimistically record one manual read through the native bridge.
 */
function onCheckClick(event: Event) {
    if (longPressed) {
        longPressed = false;
        event.preventDefault();
        return;
    }
    onMarkAsRead();
}
</script>

<style lang="scss" scoped>
.bible-document {
    position: relative;
}

.mark-as-read-container {
    text-align: center;
    padding: 8px 0;
}

.mark-as-read-wrapper {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    position: relative;
    user-select: none;
    -webkit-user-select: none;
    -webkit-touch-callout: none;
}

.mark-as-read-button {
    cursor: pointer;
    font-size: 18px;
    color: rgba(0, 0, 0, 0.3);
    padding: 6px;
    border-radius: 50%;
    background: transparent;
    border: none;
    line-height: 1;

    .night & {
        color: rgba(255, 255, 255, 0.3);
    }

    .monochrome & {
        color: black;
        border: 1px solid rgba(0, 0, 0, 0.4);
    }

    .monochrome.night & {
        color: white;
        border: 1px solid rgba(255, 255, 255, 0.4);
    }

    &.read {
        color: #4CAF50;

        .night & {
            color: #66BB6A;
        }

        .monochrome & {
            color: black;
            border: 2px solid black;
        }

        .monochrome.night & {
            color: white;
            border: 2px solid white;
        }
    }
}

.mark-as-read-icon {
    pointer-events: none;
}

.read-count {
    cursor: pointer;
    font-size: 12px;
    font-weight: bold;
    margin-left: 2px;
    color: #4CAF50;
    background: transparent;
    border: none;
    padding: 0;
    line-height: 1;

    .night & {
        color: #66BB6A;
    }

    .monochrome & {
        color: black;
    }

    .monochrome.night & {
        color: white;
    }
}
</style>
