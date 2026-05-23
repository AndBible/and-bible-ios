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
      :id="`doc-${document.id}`"
      class="document"
      :data-book-initials="bookInitials"
      :data-osis-ref="osisRef"
  >
    <AreYouSure v-if="canUseMyDocumentAIPageActions" ref="areYouSureDelete">
      <template #title>
        {{ strings.deleteMyDocumentPageConfirmationTitle }}
      </template>
      {{ strings.deleteMyDocumentPageConfirmation }}
    </AreYouSure>
    <div v-if="editMode" class="mydoc-edit-container">
      <textarea
          v-model="editContent"
          class="mydoc-raw-editor"
          rows="12"
          :aria-label="strings.editTextPlaceholder"
          @keydown.escape.prevent.stop="closeEditor"
      />
      <div class="mydoc-editor-actions">
        <button
            type="button"
            class="journal-button"
            :aria-label="strings.saveMyDocumentPageAccessibilityLabel"
            :title="strings.saveMyDocumentPageAccessibilityLabel"
            @click="saveEditor"
        >
          <FontAwesomeIcon icon="save"/>
        </button>
        <button
            type="button"
            class="journal-button"
            :aria-label="strings.cancel || 'Cancel'"
            :title="strings.cancel || 'Cancel'"
            @click="closeEditor"
        >
          <FontAwesomeIcon icon="times"/>
        </button>
      </div>
    </div>

    <template v-else>
      <div
          v-if="canUseMyDocumentActions"
          class="mydoc-actions"
      >
        <button
            type="button"
            class="journal-button"
            :aria-label="strings.editTextPlaceholder"
            :title="strings.editTextPlaceholder"
            @click.stop="startEditing"
        >
          <FontAwesomeIcon icon="edit"/>
        </button>
        <button
            v-if="canUseMyDocumentAIPageActions"
            type="button"
            class="journal-button"
            :aria-label="strings.regenerateMyDocumentPageAccessibilityLabel"
            :title="strings.regenerateMyDocumentPageAccessibilityLabel"
            @click.stop="regenerateAIPage"
        >
          <FontAwesomeIcon icon="arrows-rotate"/>
        </button>
        <button
            v-if="canUseMyDocumentAIPageActions"
            type="button"
            class="journal-button"
            :aria-label="strings.deleteMyDocumentPageAccessibilityLabel"
            :title="strings.deleteMyDocumentPageAccessibilityLabel"
            @click.stop="deleteAIPage"
        >
          <FontAwesomeIcon icon="trash"/>
        </button>
      </div>
      <OsisFragment :is-native-html="document.isNativeHtml" :fragment="osisFragment"/>
      <button
          v-if="isMyDocument && isContentEmpty"
          type="button"
          class="mydoc-placeholder"
          @click="startEditing"
      >
        <FontAwesomeIcon icon="edit" class="placeholder-icon"/>
        <span>{{ strings.editTextPlaceholder }}</span>
      </button>
      <OpenAllLink v-if="document.bookCategory != 'GENERAL_BOOK'" :v11n="document.v11n"/>
      <FeaturesLink :fragment="osisFragment"/>
    </template>
  </div>
</template>

<script setup lang="ts">
import OsisFragment from "@/components/documents/OsisFragment.vue";
import FeaturesLink from "@/components/FeaturesLink.vue";
import OpenAllLink from "@/components/OpenAllLink.vue";
import AreYouSure from "@/components/modals/AreYouSure.vue";
import {useCommon, useReferenceCollector} from "@/composables";
import {androidKey, customCssKey, globalBookmarksKey, osisDocumentInfoKey, referenceCollectorKey} from "@/types/constants";
import {computed, inject, provide, ref} from "vue";
import {OsisDocument} from "@/types/documents";
import {useBookmarks} from "@/composables/bookmarks";
import {FontAwesomeIcon} from "@fortawesome/vue-fontawesome";

const props = defineProps<{ document: OsisDocument }>();

// eslint-disable-next-line vue/no-setup-props-destructure,no-unused-vars
const {
    id,
    ordinalRange,
    osisFragment,
    bookCategory,
    bookInitials,
    annotateRef,
    osisRef,
    genericBookmarks,
    highlightedOrdinalRange,
    isMyDocument = false,
    myDocumentPageId = null,
    sourcePromptId = null,
} = props.document;
const referenceCollector = useReferenceCollector();

const globalBookmarks = inject(globalBookmarksKey)!;
const {registerBook} = inject(customCssKey)!;
const android = inject(androidKey)!;
globalBookmarks.updateBookmarks(genericBookmarks);

const {config, appSettings, ...common} = useCommon();
const strings = common.strings;

const isContentEmpty = computed(() => {
    const xml = osisFragment.xml || "";
    return xml.replace(/<[^>]*>/g, "").trim().length === 0;
});
const canUseMyDocumentActions = computed(() => isMyDocument && Boolean(myDocumentPageId));
const canUseMyDocumentAIPageActions = computed(() => canUseMyDocumentActions.value && Boolean(sourcePromptId));

useBookmarks(id, ordinalRange, globalBookmarks, bookInitials, annotateRef, false, ref(true), common, config, appSettings);
provide(osisDocumentInfoKey, {bookInitials, highlightedOrdinalRange, osisRef: annotateRef})

registerBook(`epub/${bookInitials}/${osisRef}`)

if (bookCategory === "COMMENTARY" || bookCategory === "GENERAL_BOOK") {
    provide(referenceCollectorKey, referenceCollector);
}

const editMode = ref(false);
const editContent = ref("");
const editPageId = ref("");
const areYouSureDelete = ref<InstanceType<typeof AreYouSure> | null>(null);

async function startEditing() {
    if (!isMyDocument) return;

    const info = await android.getMyDocumentPageRawContent(bookInitials, osisRef);
    if (!info) return;

    editPageId.value = info.pageId;
    editContent.value = info.content;
    editMode.value = true;
}

function saveEditor() {
    if (!editPageId.value) return;

    android.saveMyDocumentPageContent(bookInitials, editPageId.value, editContent.value, null);
    closeEditor();
}

function closeEditor() {
    editMode.value = false;
    android.reloadMyDocumentPage(bookInitials);
}

function regenerateAIPage() {
    if (!myDocumentPageId || !sourcePromptId) return;

    android.regenerateMyDocumentPage(myDocumentPageId);
}

async function deleteAIPage() {
    if (!myDocumentPageId || !sourcePromptId) return;

    if (await areYouSureDelete.value?.areYouSure()) {
        android.deleteMyDocumentPage(myDocumentPageId);
    }
}
</script>

<style lang="scss" scoped>
.document {
  overflow: hidden;
}

.mydoc-actions {
  float: right;
  display: flex;
  gap: 0.25em;
  margin: 0 0 0.5em 0.5em;
}

.mydoc-edit-container {
  border: 2px solid rgba(0, 0, 255, 0.5);
  border-radius: 5px;
  margin: 4px;
  overflow: hidden;

  .monochrome & {
    border-color: black;
  }

  .monochrome.night & {
    border-color: white;
  }
}

.mydoc-raw-editor {
  box-sizing: border-box;
  display: block;
  width: 100%;
  min-height: 16rem;
  padding: 0.75em;
  border: 0;
  resize: vertical;
  background: var(--background-color);
  color: var(--text-color);
  font: inherit;
  line-height: 1.4;
}

.mydoc-editor-actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.25em;
  padding: 0.4em;
  border-top: 1px solid rgba(0, 0, 0, 0.15);
}

.mydoc-placeholder {
  display: flex;
  align-items: center;
  gap: 0.5em;
  width: 100%;
  border: 0;
  padding: 2em;
  background: transparent;
  color: inherit;
  opacity: 0.5;
  cursor: pointer;
  font: inherit;
  font-style: italic;
  text-align: start;
}

.placeholder-icon {
  font-size: 1.2em;
}
</style>
