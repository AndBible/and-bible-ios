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
  <div
      v-if="expanded"
      ref="menuElement"
      class="document-action-menu"
      :style="menuStyle"
      role="toolbar"
      :aria-label="strings.documentActionsAccessibilityLabel"
      @click.stop
      @click.capture="close"
      @touchstart.stop
      @touchend.stop
  >
    <div class="action-buttons">
      <WholePageBookmarks
          :book-initials="document.bookInitials"
          :book-key="document.annotateRef"
      />
      <!-- My Documents controls appear only when every native command has a stable page identity. -->
      <template v-if="document.isMyDocument && document.myDocumentPageId">
        <button
            type="button"
            class="journal-button"
            :aria-label="strings.editTextPlaceholder"
            :title="strings.editTextPlaceholder"
            data-action="edit-my-document"
            @click.stop="$emit('edit')"
        >
          <FontAwesomeIcon :icon="faEdit"/>
        </button>
        <button
            type="button"
            class="journal-button"
            :aria-label="strings.shareMyDocumentPageAccessibilityLabel"
            :title="strings.shareMyDocumentPageAccessibilityLabel"
            data-action="share-my-document"
            @click.stop="android.shareMyDocumentContent(document.bookInitials, document.osisRef)"
        >
          <FontAwesomeIcon :icon="faShareAlt"/>
        </button>
        <button
            type="button"
            class="journal-button"
            :aria-label="strings.copyMyDocumentPageAccessibilityLabel"
            :title="strings.copyMyDocumentPageAccessibilityLabel"
            data-action="copy-my-document"
            @click.stop="android.copyMyDocumentContent(document.bookInitials, document.osisRef)"
        >
          <FontAwesomeIcon :icon="faCopy"/>
        </button>
      </template>
      <!-- AI deletion requires both a persisted page and source prompt identity. -->
      <template v-if="document.isMyDocument && document.myDocumentPageId && document.sourcePromptId">
        <button
            type="button"
            class="journal-button"
            :aria-label="strings.deleteMyDocumentPageAccessibilityLabel"
            :title="strings.deleteMyDocumentPageAccessibilityLabel"
            data-action="delete-ai-document"
            @click.stop="$emit('delete-ai-page')"
        >
          <FontAwesomeIcon :icon="faTrash"/>
        </button>
      </template>
      <button
          type="button"
          class="journal-button"
          :aria-label="strings.cancel"
          :title="strings.cancel"
          data-action="close-document-actions"
          @click.stop="close"
      >
        <FontAwesomeIcon :icon="faTimes"/>
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
/**
 * Anchored action toolbar for generic, My Documents, and AI-generated document pages.
 *
 * @param document Complete rendered OSIS document whose exact source identities back every action.
 * @fires edit With no payload when the parent should load the raw My Documents editor.
 * @fires delete-ai-page With no payload when the parent should run confirmation before deletion.
 * @remarks Opening captures the anchor's viewport geometry and installs outside-click/back listeners;
 * closing or unmounting removes listeners and cancels delayed listener registration. Native action
 * failures are owned by the injected bridge and do not leave a client-side optimistic state.
 */
import {inject, nextTick, onBeforeUnmount, ref, watch} from "vue";
import {FontAwesomeIcon} from "@fortawesome/vue-fontawesome";
import {faCopy, faEdit, faShareAlt, faTimes, faTrash} from "@fortawesome/free-solid-svg-icons";
import {androidKey} from "@/types/constants";
import {eventBus} from "@/eventbus";
import WholePageBookmarks from "@/components/WholePageBookmarks.vue";
import type {OsisDocument} from "@/types/documents";
import {useCommon} from "@/composables";

defineProps<{document: OsisDocument}>();
defineEmits<{
    edit: []
    "delete-ai-page": []
}>();

const android = inject(androidKey)!;
const {strings} = useCommon();
const expanded = ref(false);
const menuElement = ref<HTMLElement | null>(null);
const anchorRect = ref<DOMRect | null>(null);
const menuStyle = ref<Record<string, string>>({});
let outsideListenerTimer: ReturnType<typeof setTimeout> | null = null;

/** Updates absolute document coordinates from the last captured anchor rectangle. */
function updateMenuPosition() {
    if (!anchorRect.value) return;
    menuStyle.value = {
        top: `${anchorRect.value.bottom + window.scrollY}px`,
        left: `${anchorRect.value.left + window.scrollX}px`,
    };
}

/** Keeps the rendered toolbar within the horizontal viewport after Vue lays it out. */
async function clampToViewport() {
    await nextTick();
    const element = menuElement.value;
    if (!element || !anchorRect.value) return;
    const rect = element.getBoundingClientRect();
    const viewportWidth = globalThis.document.documentElement.clientWidth;
    if (rect.right > viewportWidth) {
        menuStyle.value = {...menuStyle.value, left: `${Math.max(0, viewportWidth - rect.width)}px`};
    } else if (rect.left < 0) {
        menuStyle.value = {...menuStyle.value, left: "0px"};
    }
}

/** Closes the toolbar; reactive listener cleanup is performed by the `expanded` watcher. */
function close() {
    expanded.value = false;
}

/**
 * Opens the toolbar below a specific inline action icon.
 *
 * @param anchorElement Mounted inline icon whose geometry anchors the toolbar.
 * @returns A promise that resolves after viewport clamping completes.
 */
async function openMenu(anchorElement: HTMLElement) {
    anchorRect.value = anchorElement.getBoundingClientRect();
    expanded.value = true;
    updateMenuPosition();
    await clampToViewport();
}

/** Closes the toolbar when a captured document click lands outside its current element. */
function onDocumentClick(event: Event) {
    if (menuElement.value && !menuElement.value.contains(event.target as Node)) close();
}

/** Removes all global and event-bus listeners, including delayed registration still in flight. */
function detachOutsideListeners() {
    if (outsideListenerTimer !== null) {
        clearTimeout(outsideListenerTimer);
        outsideListenerTimer = null;
    }
    eventBus.off("back_clicked", close);
    eventBus.off("bookmark_clicked", close);
    globalThis.document.removeEventListener("click", onDocumentClick, true);
    globalThis.document.removeEventListener("touchend", onDocumentClick, true);
}

watch(expanded, isExpanded => {
    detachOutsideListeners();
    if (!isExpanded) return;
    eventBus.on("back_clicked", close);
    eventBus.on("bookmark_clicked", close);
    outsideListenerTimer = setTimeout(() => {
        outsideListenerTimer = null;
        if (!expanded.value) return;
        globalThis.document.addEventListener("click", onDocumentClick, true);
        globalThis.document.addEventListener("touchend", onDocumentClick, true);
    }, 0);
});

onBeforeUnmount(detachOutsideListeners);

defineExpose({openMenu});
</script>

<style scoped lang="scss">
.document-action-menu {
  position: absolute;
  z-index: 20;
}

.action-buttons {
  display: flex;
  background: var(--background-color);
  border: 1px solid rgba(0, 0, 0, 0.3);
  border-radius: 6px;
  opacity: 0.94;

  .night & {
    border-color: rgba(255, 255, 255, 0.6);
  }

  .monochrome & {
    border-color: black;
    opacity: 1;
  }

  .monochrome.night & {
    border-color: white;
  }
}

button.journal-button {
  border: 0;
  background: transparent;
}
</style>
