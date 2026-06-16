<!--
  - Copyright (c) 2026 Martin Denham, Tuomas Airaksinen and the AndBible contributors.
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
  <div class="markdown-edit-area">
    <div class="markdown-actionbar">
      <button
          type="button"
          class="markdown-button end"
          title="Close"
          @click="close"
      >
        <FontAwesomeIcon icon="times"/>
      </button>
    </div>
    <textarea
        v-model="editText"
        class="markdown-content"
        :aria-label="contentAccessibilityLabel"
        @keydown.esc.prevent.stop="close"
    />
    <div class="saved-notice" v-if="!dirty">
      <FontAwesomeIcon icon="save"/>
    </div>
  </div>
</template>

<script lang="ts" setup>
/**
 * Plain-text Markdown note editor used when Android note `TextContentType` is `MARKDOWN`.
 *
 * @param text - Current Markdown source text.
 * @param contentAccessibilityLabel - Optional accessible label for the textarea.
 * @fires save - Emitted after debounced edits and before close/unmount when text is dirty.
 * @fires close - Emitted when the user closes the editor.
 * @remarks The editor intentionally stores Markdown source text instead of HTML so the bridge
 * payload remains compatible with Android's Markdown note rows.
 */
import {debounce} from "lodash";
import {inject, onBeforeUnmount, onMounted, onUnmounted, ref, watch} from "vue";
import {FontAwesomeIcon} from "@fortawesome/vue-fontawesome";
import {keyboardKey} from "@/types/constants";

const props = defineProps<{
    text: string
    contentAccessibilityLabel?: string
}>();
const emit = defineEmits(["save", "close"]);

const editText = ref(props.text);
const dirty = ref(false);
const {editorMode} = inject(keyboardKey)!;

function save() {
    if (dirty.value) {
        emit("save", editText.value);
        dirty.value = false;
    }
}

function close() {
    save();
    emit("close");
}

watch(editText, () => {
    dirty.value = true;
});
watch(editText, debounce(save, 2000));

onMounted(() => {
    editorMode.value++;
});

onBeforeUnmount(() => {
    save();
});

onUnmounted(() => {
    editorMode.value--;
});
</script>

<style lang="scss" scoped>
@use "@/common.scss" as *;

.markdown-edit-area {
  position: relative;
  width: 100%;
  color: inherit;
}

.markdown-actionbar {
  min-height: 25px;
  color: rgba(0, 0, 0, 0.6);

  .night & {
    color: rgba(255, 255, 255, 0.5);
  }
}

.markdown-button {
  @extend .journal-button;
  border: 0;
  background: transparent;
  color: inherit;
  height: 22px;
  width: 22px;

  &.end {
    position: absolute;
    top: 0;

    [dir=ltr] & {
      right: 0;
    }

    [dir=rtl] & {
      left: 0;
    }
  }
}

.markdown-content {
  @extend .visible-scrollbar;
  box-sizing: border-box;
  width: 100%;
  max-height: calc(var(--max-height) - 40px);
  min-height: 120px;
  padding: 7px;
  border: 0;
  color: var(--text-color);
  background: var(--background-color);
  font-family: var(--font-family);
  font-size: var(--font-size);
  resize: vertical;
}
</style>
