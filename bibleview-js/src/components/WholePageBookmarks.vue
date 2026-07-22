<!--
  - Copyright (c) 2026 Sykerö Software / Tuomas Airaksinen and the AndBible contributors.
  -
  - This file is part of AndBible: Bible Study (http://github.com/AndBible/and-bible).
  -
  - AndBible is free software: you can redistribute it and/or modify it under the
  - terms of the GNU General Public License as published by the Free Software Foundation,
  - either version 3 of the License, or (at your option) any later version.
  -->

<template>
  <!-- Existing whole-page items retain their bookmark/AI identity and native click route. -->
  <button
      v-for="bookmark in visibleBookmarks"
      :key="bookmark.id"
      type="button"
      class="journal-button bookmark-item"
      :style="{color: getColor(bookmark)}"
      :aria-label="isAiDocMarker(bookmark) ? bookmark.title : strings.bookmarks"
      :title="isAiDocMarker(bookmark) ? bookmark.title : strings.bookmarks"
      :data-action="isAiDocMarker(bookmark) ? 'open-ai-document' : 'open-whole-page-bookmark'"
      @click.stop="openItem(bookmark)"
  >
    <FontAwesomeIcon :icon="getIcon(bookmark)"/>
    <span v-if="bookmark.hasNote" class="note-indicator" aria-hidden="true">
      <FontAwesomeIcon :icon="faEdit" size="xs"/>
    </span>
  </button>
  <button
      type="button"
      class="journal-button add-bookmark-button"
      :aria-label="strings.addBookmark"
      :title="strings.addBookmark"
      data-action="create-whole-page-bookmark"
      @click.stop="createBookmark"
  >
    <FontAwesomeIcon :icon="faPlus"/>
  </button>
</template>

<script setup lang="ts">
/**
 * Renders bookmark actions for one complete generic document page inside `DocumentActionMenu`.
 *
 * @param bookInitials Exact source module initials used for item matching and native persistence.
 * @param bookKey Exact source page key used for item matching and native persistence.
 * @fires bookmark_clicked When an existing generic whole-page bookmark is activated.
 * @remarks AI marker clicks navigate through the native document/key bridge. The add action creates
 * a bookmark without consulting text selection, preserving Android whole-page behavior.
 */
import {computed, inject} from "vue";
import {FontAwesomeIcon} from "@fortawesome/vue-fontawesome";
import {faBookmark, faEdit, faPlus} from "@fortawesome/free-solid-svg-icons";
import {androidKey, globalBookmarksKey} from "@/types/constants";
import {BaseBookmark} from "@/types/client-objects";
import {isAiDocMarker, isWholePageItem, resolveIcon} from "@/composables/bookmarks";
import {useCommon} from "@/composables";
import {emit} from "@/eventbus";

const props = defineProps<{
    bookInitials: string
    bookKey: string
}>();

const globalBookmarks = inject(globalBookmarksKey)!;
const android = inject(androidKey)!;
const {config, appSettings, adjustedColor, strings} = useCommon();

/** Whole-page bookmarks and AI markers whose source identity exactly matches this page. */
const wholePageItems = computed(() => globalBookmarks.bookmarks.value.filter(bookmark =>
    isWholePageItem(bookmark, props.bookInitials, props.bookKey)
));

/** Items allowed by the same bookmark, note, hidden-label, and AI visibility settings as Android. */
const visibleBookmarks = computed(() => {
    const hiddenLabels = new Set(config.bookmarksHideLabels);
    return wholePageItems.value.filter(bookmark => {
        if (isAiDocMarker(bookmark)) return config.showAiDocMarkers;
        if (!config.showBookmarks && !(bookmark.hasNote && config.showMyNotes)) return false;
        return bookmark.labels.every(labelId => !hiddenLabels.has(labelId));
    });
});

/** Resolves the primary visual label for one bookmark-like item without mutating label state. */
function getLabel(bookmark: BaseBookmark) {
    const labelId = bookmark.primaryLabelId || bookmark.labels[0];
    return globalBookmarks.bookmarkLabels.get(labelId);
}

/** Returns the display color after applying monochrome and e-ink color policy. */
function getColor(bookmark: BaseBookmark): string {
    const label = getLabel(bookmark);
    if (!label) return "gray";
    const color = appSettings.monochromeMode ? "black" : label.color;
    return adjustedColor(color).string();
}

/** Returns a custom marker icon when configured, otherwise the standard bookmark icon. */
function getIcon(bookmark: BaseBookmark) {
    const label = getLabel(bookmark);
    return label ? resolveIcon(bookmark, label) ?? faBookmark : faBookmark;
}

/** Routes an item click to exact AI navigation or the existing generic bookmark modal event. */
function openItem(bookmark: BaseBookmark) {
    if (isAiDocMarker(bookmark)) {
        android.openAiDocPage(bookmark.documentInitials, bookmark.pageKey);
    } else {
        emit("bookmark_clicked", bookmark.id);
    }
}

/** Sends the exact source and key for a selection-free whole-page generic bookmark. */
function createBookmark() {
    android.createWholePageBookmark(props.bookInitials, props.bookKey);
}

defineExpose({visibleBookmarks});
</script>

<style lang="scss" scoped>
button.journal-button {
  border: 0;
  background: transparent;
}

.bookmark-item .note-indicator {
  margin-inline-start: 0.15em;
  opacity: 0.7;
}

.add-bookmark-button {
  color: rgba(128, 128, 128, 0.7);
}
</style>
