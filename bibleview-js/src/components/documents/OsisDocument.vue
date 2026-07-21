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
      :data-book-category="bookCategory"
      :data-v11n="document.v11n"
  >
    <AreYouSure v-if="canUseMyDocumentAIPageActions" ref="areYouSureDelete">
      <template #title>
        {{ strings.deleteMyDocumentPageConfirmationTitle }}
      </template>
      {{ strings.deleteMyDocumentPageConfirmation }}
    </AreYouSure>
    <div v-if="editMode" class="mydoc-edit-container">
      <EditableText
          :text="editContent"
          :content-type="editContentType"
          :note-editor-context="editPageId ? { entityType: 'MY_DOCUMENT_PAGE', entityId: editPageId } : null"
          :edit-directly="true"
          @save="handleEditorSave"
          @closed="handleEditorClosed"
      />
    </div>

    <template v-else>
      <h2 v-if="bookCategory === 'COMMENTARY' && commentaryRange" class="commentary-range">
        {{ commentaryRange.name }}
      </h2>
      <OsisFragment :is-native-html="document.isNativeHtml" :fragment="osisFragment"/>
      <DocumentActionMenu
          ref="actionMenu"
          :document="document"
          @edit="startEditing"
          @delete-ai-page="deleteAIPage"
      />
      <button
          v-if="isMyDocument && isContentEmpty"
          type="button"
          class="mydoc-placeholder"
          @click="startEditing"
      >
        <FontAwesomeIcon icon="edit" class="placeholder-icon"/>
        <span>{{ strings.editTextPlaceholder }}</span>
      </button>
      <div v-if="isAiDocument && sourcePromptName" class="ai-footer">
        <a
            v-if="sourcePromptId"
            class="prompt-link"
            @click.prevent="android.openPromptEditor(sourcePromptId)"
        >{{ sourcePromptName }}</a>
        <span v-else>{{ sourcePromptName }}</span>
        <span v-if="sourceModelName" class="model-name"> ({{ sourceModelName }})</span>
      </div>
      <OpenAllLink v-if="document.bookCategory != 'GENERAL_BOOK'" :v11n="document.v11n"/>
      <FeaturesLink :fragment="osisFragment"/>
    </template>
  </div>
</template>

<script setup lang="ts">
/**
 * Renders one generic OSIS, commentary, My Documents, or AI-generated document page.
 *
 * @param document Typed source payload including exact module/key identity, rendered fragment,
 * bookmarks, optional commentary range, and optional My Documents metadata.
 * @remarks Registers source CSS and bookmark DOM behavior, injects an inline page-action trigger,
 * and owns raw My Documents edit state. Native bridge failures leave the current rendered document
 * unchanged; AI deletion is gated by the existing confirmation modal.
 */
import OsisFragment from "@/components/documents/OsisFragment.vue";
import DocumentActionMenu from "@/components/documents/DocumentActionMenu.vue";
import FeaturesLink from "@/components/FeaturesLink.vue";
import OpenAllLink from "@/components/OpenAllLink.vue";
import AreYouSure from "@/components/modals/AreYouSure.vue";
import EditableText from "@/components/EditableText.vue";
import {useCommon, useReferenceCollector} from "@/composables";
import {androidKey, customCssKey, globalBookmarksKey, osisDocumentInfoKey, referenceCollectorKey} from "@/types/constants";
import {computed, inject, provide, ref} from "vue";
import {OsisDocument} from "@/types/documents";
import {TextContentType} from "@/types/client-objects";
import {useBookmarks} from "@/composables/bookmarks";
import {FontAwesomeIcon} from "@fortawesome/vue-fontawesome";
import {useInlineActionIcons} from "@/composables/inline-action-icons";

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
    isAiDocument = false,
    myDocumentPageId = null,
    sourcePromptId = null,
    sourcePromptName = null,
    sourceModelName = null,
    aiDocMarkers = [],
    commentaryRange = null,
} = props.document;
const referenceCollector = useReferenceCollector();

const globalBookmarks = inject(globalBookmarksKey)!;
const {registerBook} = inject(customCssKey)!;
const android = inject(androidKey)!;
globalBookmarks.updateBookmarks([...genericBookmarks, ...aiDocMarkers]);

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

const actionMenu = ref<InstanceType<typeof DocumentActionMenu> | null>(null);

useInlineActionIcons(id, bookInitials, annotateRef, anchor => {
    actionMenu.value?.openMenu(anchor);
});

const editMode = ref(false);
const editContent = ref("");
const editContentType = ref<TextContentType>("MARKDOWN");
const editPageId = ref("");
const areYouSureDelete = ref<InstanceType<typeof AreYouSure> | null>(null);

/** Loads exact native raw content and enters the editor only after a valid page response arrives. */
async function startEditing() {
    if (!isMyDocument) return;

    const info = await android.getMyDocumentPageRawContent(bookInitials, osisRef);
    if (!info) return;

    editPageId.value = info.pageId;
    editContent.value = info.content;
    editContentType.value = info.contentType as TextContentType;
    editMode.value = true;
}

/** Persists each editor save against the exact resolved My Documents page. */
function handleEditorSave(content: string) {
    if (!editPageId.value) return;
    editContent.value = content;
    android.saveMyDocumentPageContent(bookInitials, editPageId.value, content, null);
}

/** Leaves edit mode and asks native code to reload the source document from persisted content. */
function handleEditorClosed() {
    editMode.value = false;
    android.reloadMyDocumentPage(bookInitials);
}

/** Confirms and delegates deletion of a persisted AI-generated page without optimistic removal. */
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

.commentary-range {
  font-size: 1.15em;
  margin: 0.5em 0;
}

.ai-footer {
  margin-top: 1em;
  padding-top: 0.5em;
  font-size: 0.8em;
  opacity: 0.6;
  text-align: end;

  .prompt-link {
    color: inherit;
    cursor: pointer;
    text-decoration: underline;
  }
}
</style>

<style lang="scss">
.inline-action-icon {
  display: inline;
  margin-inline-end: 18px;
  cursor: pointer;
  opacity: 0.4;

  svg {
    width: 18px;
    height: 18px;
    vertical-align: middle;
    fill: currentColor;
  }
}
</style>
