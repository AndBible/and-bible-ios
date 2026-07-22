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
  <div class="ambiguous-button" :style="buttonStyle" @click.stop="openBookmark(false)">
    <!-- AI markers are navigation records, not editable bookmark records. -->
    <template v-if="isAiDocMarker(bookmark)">
      <div class="verse-range one-liner">
        <FontAwesomeIcon :icon="faRobot" size="xs" style="padding-inline-end: 5px"/>
        {{ bookmark.verseRangeAbbreviated }}&nbsp;
        <q><em>{{ bookmark.title }}</em></q>
      </div>
    </template>
    <template v-else>
      <div class="verse-range one-liner">
        <template v-if="customIcon">
          <FontAwesomeIcon :icon="customIcon" size="xs" style="padding-inline-end: 5px"/>
        </template>
        <template v-if="isBibleBookmark(bookmark)">
          {{ bookmark.verseRangeAbbreviated }}&nbsp;
        </template>
        <q v-if="bookmark.text"><em>{{ bookmark.text }}</em></q>
      </div>
      <div v-if="bookmark.hasNote" class="note one-liner small">
        <FontAwesomeIcon icon="edit" size="xs"/>
        {{ htmlToString(bookmarkNotesHtml) }}
      </div>

      <div style="overflow-x: auto" class="label-list">
        <LabelList in-bookmark single-line :bookmark-id="bookmark.id"/>
      </div>

      <div style="height: 7px"/>
      <BookmarkButtons
          :bookmark="bookmark"
          show-study-pad-buttons
          @edit-clicked="editNotes"
          @info-clicked="openBookmark(true)"
      />
    </template>
  </div>
</template>

<script lang="ts" setup>
/**
 * Renders one bookmark-like choice in the ambiguous reader action modal.
 *
 * @param bookmarkId Exact global bookmark/AI marker identifier to resolve reactively.
 * @fires selected For normal bookmark actions after the choice has emitted its modal route.
 * @remarks AI markers bypass editable bookmark controls and navigate through the native exact
 * document/key command. Missing marker IDs remain a provider contract violation, matching existing
 * bookmark chooser behavior.
 */
import LabelList from "@/components/LabelList.vue";
import {computed, inject} from "vue";
import {useCommon} from "@/composables";
import {emit} from "@/eventbus";
import Color from "color";
import BookmarkButtons from "@/components/BookmarkButtons.vue";
import {FontAwesomeIcon} from "@fortawesome/vue-fontawesome";
import {androidKey, globalBookmarksKey, locateTopKey} from "@/types/constants";
import {BaseBookmark} from "@/types/client-objects";
import {isAiDocMarker, isBibleBookmark, resolveIcon} from "@/composables/bookmarks";
import {Marked} from "marked";
import DOMPurify from "dompurify";
import {PURIFY_CONFIG} from "@/composables/slot-html-content";
import {faRobot} from "@fortawesome/free-solid-svg-icons";

const markdownParser = new Marked({breaks: true, gfm: true});

const $emit = defineEmits(["selected"]);
const props = defineProps<{ bookmarkId: IdType }>();

const {bookmarkMap, bookmarkLabels} = inject(globalBookmarksKey)!;
const android = inject(androidKey)!;
const {appSettings} = useCommon();
const bookmark = computed(() => bookmarkMap.get(props.bookmarkId)! as BaseBookmark);
const bookmarkNotes = computed(() => bookmark.value.notes!);
const bookmarkNotesHtml = computed(() => {
    if (
        bookmark.value.notesContentType === "MARKDOWN" ||
        (bookmark.value.notesContentType == null && appSettings.notesContentType === "MARKDOWN")
    ) {
        return DOMPurify.sanitize(markdownParser.parse(bookmarkNotes.value) as string, PURIFY_CONFIG);
    }
    return bookmarkNotes.value;
});

const primaryLabel = computed(() => {
    const primaryLabelId = bookmark.value.primaryLabelId || bookmark.value.labels[0];
    return bookmarkLabels.get(primaryLabelId)!;
});

const customIcon = computed(() => resolveIcon(bookmark.value, primaryLabel.value));

const buttonStyle = computed<string|undefined>(() => {
    let color = Color(primaryLabel.value.color);
    color = color.alpha(0.5)
    if (appSettings.monochromeMode) {
        return;
    }
    return `background-color: ${color.hsl()};`
});

const locateTop = inject(locateTopKey)!;

/** Selects the normal bookmark and opens its note editor at the current modal location. */
function editNotes() {
    $emit("selected");
    emit("bookmark_clicked", bookmark.value.id, {openNotes: true, locateTop: locateTop.value});
}

/** Routes AI markers to native navigation and normal bookmarks to the bookmark detail modal. */
function openBookmark(openInfo = false) {
    if (isAiDocMarker(bookmark.value)) {
        android.openAiDocPage(bookmark.value.documentInitials, bookmark.value.pageKey);
        return;
    }
    $emit("selected");
    emit("bookmark_clicked", bookmark.value.id, {openInfo, locateTop: locateTop.value});
}

/** Converts already-sanitized note HTML to the plain-text preview shown in the chooser. */
function htmlToString(html: string) {
    const ele = document.createElement("div")
    ele.innerHTML = html
    return ele.innerText
}
</script>

<style scoped lang="scss">
@use "@/common.scss" as *;

.ambiguous-button {
  color: black;

  .monochrome & {
    background-color: white;
    border-style: solid;
    border-width: 1px;
  }

  .night & {
    color: #d7d7d7;
  }

  .monochrome.night & {
    color: white;
    background-color: black;
    border-style: solid;
    border-width: 1px;
  }

  @extend .button;
  text-align: start;
}

.small {
  font-size: 0.9em
}
</style>
