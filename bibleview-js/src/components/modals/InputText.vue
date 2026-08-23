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
  <ModalDialog v-if="show" @close="cancel" blocking locate-top>
    <template #title>
      <slot/>
    </template>
    <template #extra-buttons>
      <slot name="buttons"/>
    </template>
    <slot name="content">
      <input class="text-input" ref="inputElement" :placeholder="strings.inputPlaceholder" v-model="text"/>
      <div v-if="error" class="error">{{ error }}</div>
    </slot>
    <template #footer>
      <button class="button" @click="cancel">{{ strings.cancel }}</button>
      <button class="button" @click="ok">{{ strings.ok }}</button>
    </template>
  </ModalDialog>
</template>

<script lang="ts" setup>
/**
 * Presents a blocking text prompt whose visible and standard modal dismissals share one result.
 *
 * @slot default Prompt title content.
 * @slot buttons Additional toolbar controls rendered before the standard dismissal control.
 * @slot content Optional replacement for the default text input and validation message.
 * @remarks The exposed `inputText` method focuses the mounted input and suspends its caller until
 * an affirmative footer action returns text or any cancellation path returns `null`. Standard
 * toolbar, backdrop, and Escape dismissal therefore cannot strand the awaiting caller. The prompt
 * is blocking, so the shared modal stack deliberately does not invoke its registered close callback.
 * Only one prompt may be active at a time, and custom content must preserve the component's
 * input-ref contract when using `inputText`.
 */
import ModalDialog from "@/components/modals/ModalDialog.vue";
import {ref} from "vue";
import {useCommon} from "@/composables";
import {Deferred, waitUntilRefValue} from "@/utils";

const text = ref("");
const error = ref("");
const show = ref(false);
const inputElement = ref<HTMLElement | null>(null);
let promise: Deferred<string> | null = null;

/**
 * Opens the prompt and waits for one affirmative or cancellation result.
 *
 * @param initialValue Initial input text shown to the user.
 * @param _error Optional validation message rendered below the default input.
 * @returns The submitted nonempty text, or `null` after any cancellation path.
 * @remarks Mounting changes visible modal state and focuses the input. Callers must not overlap
 * invocations because the component owns a single pending result.
 */
async function inputText(initialValue = "", _error = ""): Promise<string | null> {
    text.value = initialValue;
    error.value = _error;
    show.value = true;
    promise = new Deferred<string>();
    await waitUntilRefValue(inputElement)
    inputElement.value!.focus();
    const result = await promise.wait()
    show.value = false;
    return result || null;
}

/** Resolves the active prompt with its current text; requires a visible pending prompt. */
function ok() {
    promise!.resolve(text.value);
}

/** Resolves the active prompt as cancelled; repeated dismissal attempts remain harmless. */
function cancel() {
    promise!.resolve();
}

const {strings} = useCommon();

defineExpose({inputText, setText: (v: string) => text.value = v});
</script>

<style scoped>
.text-input {
    padding: 5pt;
    margin: 5pt;
}

.error {
    color: red;
}
</style>
