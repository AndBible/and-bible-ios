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
  <ModalDialog v-if="showHelp" @close="showHelp = false" blocking locate-top>
    {{ sprintf(strings.refParserHelp, "RefParser") }}
    <a @click="openDownloads">{{ strings.openDownloads }}</a>
    <template #title>
      {{ strings.inputReference }}
    </template>
  </ModalDialog>
  <InputText ref="inputText">
    {{ strings.inputReference }}
    <template #buttons>
      <button v-if="!hasRefParser" class="modal-action-button right" @touchstart.stop @click="showHelp = !showHelp">
        <FontAwesomeIcon icon="question-circle"/>
      </button>
      <button class="modal-action-button right" @touchstart.stop @click="refChooserDialogHandler">
        <FontAwesomeIcon icon="hand-pointer"/>
      </button>
    </template>
  </InputText>
  <div @click.stop class="edit-area pell">
    <textarea
        ref="textareaEl"
        v-model="editText"
        class="md-content"
        :aria-label="contentAccessibilityLabel"
        @keydown="handleKeyDown"
    />
    <div ref="actionbarEl" class="pell-actionbar">
      <div ref="headingWrapperEl" class="md-popup-wrapper">
        <button class="pell-button" @click="toggleMenu('heading')"><FontAwesomeIcon :icon="faHeading"/></button>
        <div v-if="showHeadingMenu" class="md-popup-menu">
          <button class="md-popup-option" @click="selectHeading(1)">H1</button>
          <button class="md-popup-option" @click="selectHeading(2)">H2</button>
          <button class="md-popup-option" @click="selectHeading(3)">H3</button>
        </div>
      </div>
      <div ref="textStyleWrapperEl" class="md-popup-wrapper">
        <button class="pell-button" @click="toggleMenu('textStyle')"><FontAwesomeIcon :icon="faFont"/></button>
        <div v-if="showTextStyleMenu" class="md-popup-menu">
          <button class="md-popup-option" @click="applyTextStyle('**', '**')"><FontAwesomeIcon :icon="faBold"/></button>
          <button class="md-popup-option" @click="applyTextStyle('*', '*')"><FontAwesomeIcon :icon="faItalic"/></button>
          <button class="md-popup-option" @click="applyTextStyle('<u>', '</u>')"><FontAwesomeIcon :icon="faUnderline"/></button>
        </div>
      </div>
      <span class="pell-divider"/>
      <button class="pell-button" @click="toggleLinePrefix('1. ')"><FontAwesomeIcon :icon="faListOl"/></button>
      <button class="pell-button" @click="toggleLinePrefix('- ')"><FontAwesomeIcon :icon="faListUl"/></button>
      <div ref="indentWrapperEl" class="md-popup-wrapper">
        <button class="pell-button" @click="toggleMenu('indent')"><FontAwesomeIcon :icon="faIndent"/></button>
        <div v-if="showIndentMenu" class="md-popup-menu">
          <button class="md-popup-option" @click="applyIndent(1)"><FontAwesomeIcon :icon="faIndent"/></button>
          <button class="md-popup-option" @click="applyIndent(-1)"><FontAwesomeIcon :icon="faOutdent"/></button>
        </div>
      </div>
      <span class="pell-divider"/>
      <button class="pell-button" :disabled="!canUndo" @click="undo"><FontAwesomeIcon :icon="faUndo"/></button>
      <button class="pell-button" :disabled="redoStack.length === 0" @click="redo"><FontAwesomeIcon :icon="faRedo"/></button>
      <button class="pell-button" @click="insertBibleLink"><FontAwesomeIcon :icon="faBible"/></button>
      <span class="pell-divider"/>
      <button class="pell-button end" @click="closeEditor"><FontAwesomeIcon :icon="faTimes"/></button>
    </div>
    <div class="saved-notice" v-if="!dirty">
      <FontAwesomeIcon icon="save"/>
    </div>
  </div>
</template>

<script lang="ts" setup>
/**
 * Android-parity Markdown source editor used when note `TextContentType` is `MARKDOWN`.
 *
 * @param text - Current Markdown source text.
 * @param contentAccessibilityLabel - Optional accessible label for the textarea.
 * @fires save - Emitted after debounced edits and before close/unmount when source text is dirty.
 * @fires close - Emitted when the user closes the editor.
 * @remarks The editor stores Markdown source text and mirrors Android's core editing controls:
 * headings, inline styles, lists, indentation, undo/redo, reference insertion, auto-list
 * continuation, and keyboard shortcuts. Android's AI action is intentionally omitted because the
 * iOS bridge does not expose `noteEditorLlmAction`.
 */
import {debounce} from "lodash";
import {computed, inject, nextTick, onBeforeUnmount, onMounted, onUnmounted, reactive, ref, watch} from "vue";
import {FontAwesomeIcon} from "@fortawesome/vue-fontawesome";
import {
    faBible,
    faBold,
    faFont,
    faHeading,
    faIndent,
    faItalic,
    faListOl,
    faListUl,
    faOutdent,
    faRedo,
    faTimes,
    faUnderline,
    faUndo,
} from "@fortawesome/free-solid-svg-icons";
import {useCommon} from "@/composables";
import InputText from "@/components/modals/InputText.vue";
import ModalDialog from "@/components/modals/ModalDialog.vue";
import {useStrings} from "@/composables/strings";
import {androidKey, appSettingsKey, customFeaturesKey, keyboardKey} from "@/types/constants";

const props = defineProps<{
    text: string
    contentAccessibilityLabel?: string
}>();
const emit = defineEmits(["save", "close"]);

const android = inject(androidKey)!;
const appSettings = inject(appSettingsKey)!;
const {parse, features} = inject(customFeaturesKey)!;
const editText = ref(props.text);
const lastSavedText = ref(props.text);
const dirty = computed(() => editText.value !== lastSavedText.value);
const {editorMode} = inject(keyboardKey)!;
const hasRefParser = computed(() => features.has("RefParser"));
const textareaEl = ref<HTMLTextAreaElement | null>(null);
const actionbarEl = ref<HTMLElement | null>(null);
const headingWrapperEl = ref<HTMLElement | null>(null);
const textStyleWrapperEl = ref<HTMLElement | null>(null);
const indentWrapperEl = ref<HTMLElement | null>(null);
const inputText = ref<InstanceType<typeof InputText> | null>(null);
const strings = useStrings();
const showHelp = ref(false);
const showHeadingMenu = ref(false);
const showTextStyleMenu = ref(false);
const showIndentMenu = ref(false);

interface EditorState {
    text: string
    selectionStart: number
    selectionEnd: number
}

const undoStack = reactive<EditorState[]>([]);
const redoStack = reactive<EditorState[]>([]);
const MAX_UNDO = 100;
const checkpoint = reactive<EditorState>({text: props.text, selectionStart: 0, selectionEnd: 0});
let programmaticChange = false;
const canUndo = computed(() => undoStack.length > 0 || editText.value !== checkpoint.text);

/**
 * Records the current text and selection as the undo baseline after a user edit.
 *
 * - Side effects: mutates the reactive checkpoint object.
 * - Failure modes: none.
 */
function updateCheckpoint() {
    const ta = textareaEl.value;
    checkpoint.text = editText.value;
    checkpoint.selectionStart = ta?.selectionStart ?? 0;
    checkpoint.selectionEnd = ta?.selectionEnd ?? 0;
}

const commitTyping = debounce(() => {
    if (editText.value === checkpoint.text) return;
    undoStack.push({
        text: checkpoint.text,
        selectionStart: checkpoint.selectionStart,
        selectionEnd: checkpoint.selectionEnd,
    });
    if (undoStack.length > MAX_UNDO) undoStack.shift();
    redoStack.length = 0;
    updateCheckpoint();
}, 800);

/**
 * Forces pending typed text into the undo stack before a toolbar or shortcut edit.
 *
 * - Side effects: cancels the debounced typing checkpoint and mutates undo/redo state.
 * - Failure modes: none.
 */
function flushTyping() {
    commitTyping.cancel();
    if (editText.value !== checkpoint.text) {
        undoStack.push({
            text: checkpoint.text,
            selectionStart: checkpoint.selectionStart,
            selectionEnd: checkpoint.selectionEnd,
        });
        if (undoStack.length > MAX_UNDO) undoStack.shift();
        updateCheckpoint();
    }
}

/**
 * Pushes the current source text and selection to the undo stack before programmatic edits.
 *
 * - Side effects: mutates undo/redo stacks and flags the next model update as programmatic.
 * - Failure modes: returns when the textarea has not mounted.
 */
function pushUndo() {
    const ta = textareaEl.value;
    if (!ta) return;
    flushTyping();
    undoStack.push({text: editText.value, selectionStart: ta.selectionStart, selectionEnd: ta.selectionEnd});
    if (undoStack.length > MAX_UNDO) undoStack.shift();
    redoStack.length = 0;
    programmaticChange = true;
}

/**
 * Restores a previous editor state and selection after undo/redo.
 *
 * - Parameters:
 *   - ta: Mounted textarea receiving focus and selection.
 *   - state: Text plus selection bounds to restore.
 * - Side effects: mutates editor source, checkpoint, focus, and selection.
 * - Failure modes: none.
 */
function restoreState(ta: HTMLTextAreaElement, state: EditorState) {
    programmaticChange = true;
    editText.value = state.text;
    checkpoint.text = state.text;
    checkpoint.selectionStart = state.selectionStart;
    checkpoint.selectionEnd = state.selectionEnd;
    nextTick(() => {
        ta.focus();
        ta.selectionStart = state.selectionStart;
        ta.selectionEnd = state.selectionEnd;
    });
}

/**
 * Restores the previous source-editing state using Android's Markdown editor semantics.
 *
 * - Side effects: mutates editor source, selection, undo stack, and redo stack.
 * - Failure modes: returns when no mounted textarea or undo state exists.
 */
function undo() {
    const ta = textareaEl.value;
    if (!ta) return;
    commitTyping.cancel();
    if (editText.value !== checkpoint.text) {
        redoStack.push({text: editText.value, selectionStart: ta.selectionStart, selectionEnd: ta.selectionEnd});
        restoreState(ta, checkpoint);
        return;
    }
    if (undoStack.length === 0) return;
    redoStack.push({text: editText.value, selectionStart: ta.selectionStart, selectionEnd: ta.selectionEnd});
    restoreState(ta, undoStack.pop()!);
}

/**
 * Reapplies the latest undone source-editing state.
 *
 * - Side effects: mutates editor source, selection, undo stack, and redo stack.
 * - Failure modes: returns when no mounted textarea or redo state exists.
 */
function redo() {
    const ta = textareaEl.value;
    if (!ta || redoStack.length === 0) return;
    commitTyping.cancel();
    undoStack.push({text: editText.value, selectionStart: ta.selectionStart, selectionEnd: ta.selectionEnd});
    restoreState(ta, redoStack.pop()!);
}

function closeAllMenus() {
    showHeadingMenu.value = false;
    showTextStyleMenu.value = false;
    showIndentMenu.value = false;
}

/**
 * Opens one toolbar menu and closes sibling menus.
 *
 * - Parameter menu: Toolbar menu identifier.
 * - Side effects: mutates toolbar menu visibility.
 * - Failure modes: none.
 */
function toggleMenu(menu: "heading" | "textStyle" | "indent") {
    const wasOpen = menu === "heading" ? showHeadingMenu.value
        : menu === "textStyle" ? showTextStyleMenu.value
            : showIndentMenu.value;
    closeAllMenus();
    if (!wasOpen) {
        if (menu === "heading") showHeadingMenu.value = true;
        else if (menu === "textStyle") showTextStyleMenu.value = true;
        else showIndentMenu.value = true;
    }
}

function selectHeading(level: number) {
    closeAllMenus();
    toggleHeading(level);
}

function applyTextStyle(prefix: string, suffix: string) {
    closeAllMenus();
    wrapSelection(prefix, suffix);
}

function applyIndent(direction: number) {
    closeAllMenus();
    changeIndent(direction);
}

/**
 * Resizes the textarea to fit Markdown source without hiding the toolbar under the keyboard.
 *
 * - Side effects: mutates textarea style and may restore window scroll position.
 * - Failure modes: returns when the textarea is not mounted.
 */
function autoResize() {
    const ta = textareaEl.value;
    if (ta) {
        const scrollY = window.scrollY;
        ta.style.height = "0";
        ta.style.height = `${ta.scrollHeight}px`;
        if (window.scrollY !== scrollY) {
            window.scrollTo({top: scrollY});
        }
    }
}

/**
 * Emits the latest source text when it differs from the last saved value.
 *
 * - Side effects: emits `save` and updates the saved baseline.
 * - Failure modes: none.
 */
function save() {
    if (dirty.value) {
        emit("save", editText.value);
        lastSavedText.value = editText.value;
    }
}

const debouncedSave = debounce(save, 2000);

watch(editText, () => {
    nextTick(autoResize);
    debouncedSave();
    if (programmaticChange) {
        programmaticChange = false;
        updateCheckpoint();
    } else {
        commitTyping();
    }
});

function openDownloads() {
    showHelp.value = false;
    android.openDownloads();
}

async function refChooserDialogHandler() {
    inputText.value?.setText(await android.refChooserDialog());
}

/**
 * Replaces the active selection and restores the cursor after Vue patches the textarea value.
 *
 * - Parameters:
 *   - replacement: Markdown source inserted in place of the current selection.
 *   - cursorOffset: Optional offset from the original selection start for collapsed snippets.
 * - Side effects: mutates source text, undo state, focus, and selection.
 * - Failure modes: returns when the textarea is not mounted.
 */
function replaceSelection(replacement: string, cursorOffset?: number) {
    pushUndo();
    const ta = textareaEl.value;
    if (!ta) return;
    const start = ta.selectionStart;
    const end = ta.selectionEnd;
    const before = ta.value.substring(0, start);
    const after = ta.value.substring(end);
    editText.value = before + replacement + after;

    const newPos = cursorOffset !== undefined ? start + cursorOffset : start + replacement.length;
    setCursorAfterEdit(newPos);
}

/**
 * Wraps the current selection in Markdown delimiters, or inserts an empty delimited pair.
 *
 * - Parameters:
 *   - prefix: Markdown prefix inserted before the selection.
 *   - suffix: Markdown suffix inserted after the selection.
 * - Side effects: mutates source text, undo state, focus, and selection.
 * - Failure modes: returns when the textarea is not mounted.
 */
function wrapSelection(prefix: string, suffix: string) {
    const ta = textareaEl.value;
    if (!ta) return;
    const start = ta.selectionStart;
    const end = ta.selectionEnd;
    const selected = ta.value.substring(start, end);

    if (selected) {
        replaceSelection(prefix + selected + suffix);
    } else {
        replaceSelection(prefix + suffix, prefix.length);
    }
}

function getLineStart(text: string, pos: number): number {
    const idx = text.lastIndexOf("\n", pos - 1);
    return idx === -1 ? 0 : idx + 1;
}

function setCursorAfterEdit(position: number) {
    const ta = textareaEl.value;
    if (!ta) return;
    nextTick(() => {
        ta.focus();
        ta.selectionStart = position;
        ta.selectionEnd = position;
    });
}

function getLineContext(pos: number) {
    const ta = textareaEl.value!;
    const lineStart = getLineStart(ta.value, pos);
    const lineEnd = ta.value.indexOf("\n", pos);
    const actualLineEnd = lineEnd === -1 ? ta.value.length : lineEnd;
    const line = ta.value.substring(lineStart, actualLineEnd);
    const before = ta.value.substring(0, lineStart);
    const after = ta.value.substring(actualLineEnd);
    return {lineStart, line, before, after};
}

/**
 * Toggles or changes the Markdown heading marker for the current source line.
 *
 * - Parameter level: Heading level from 1 through 6.
 * - Side effects: mutates source text, undo state, focus, and selection.
 * - Failure modes: returns when the textarea is not mounted.
 */
function toggleHeading(level: number) {
    pushUndo();
    const ta = textareaEl.value;
    if (!ta) return;
    const start = ta.selectionStart;
    const {lineStart, line, before, after} = getLineContext(start);
    const prefix = `${"#".repeat(level)} `;

    const headingMatch = line.match(/^(#{1,6})\s/);
    if (headingMatch) {
        const stripped = line.substring(headingMatch[0].length);
        if (headingMatch[1].length === level) {
            editText.value = before + stripped + after;
            setCursorAfterEdit(Math.max(lineStart, start - headingMatch[0].length));
        } else {
            editText.value = before + prefix + stripped + after;
            setCursorAfterEdit(start + prefix.length - headingMatch[0].length);
        }
    } else {
        editText.value = before + prefix + line + after;
        setCursorAfterEdit(start + prefix.length);
    }
}

/**
 * Toggles an ordered or unordered list marker on the current source line.
 *
 * - Parameter prefix: Markdown line prefix such as `1. ` or `- `.
 * - Side effects: mutates source text, undo state, focus, and selection.
 * - Failure modes: returns when the textarea is not mounted.
 */
function toggleLinePrefix(prefix: string) {
    pushUndo();
    const ta = textareaEl.value;
    if (!ta) return;
    const start = ta.selectionStart;
    const {line, before, after} = getLineContext(start);

    if (line.startsWith(prefix)) {
        editText.value = before + line.substring(prefix.length) + after;
        setCursorAfterEdit(start - prefix.length);
    } else {
        editText.value = before + prefix + line + after;
        setCursorAfterEdit(start + prefix.length);
    }
}

/**
 * Adds or removes Android's two-space Markdown indent on the current source line.
 *
 * - Parameter direction: Positive to indent, negative to outdent.
 * - Side effects: mutates source text, undo state, focus, and selection.
 * - Failure modes: returns when the textarea is not mounted.
 */
function changeIndent(direction: number) {
    pushUndo();
    const ta = textareaEl.value;
    if (!ta) return;
    const start = ta.selectionStart;
    const {lineStart, line, before, after} = getLineContext(start);
    const indent = "  ";

    if (direction > 0) {
        editText.value = before + indent + line + after;
        setCursorAfterEdit(start + indent.length);
    } else if (line.startsWith(indent)) {
        editText.value = before + line.substring(indent.length) + after;
        setCursorAfterEdit(Math.max(lineStart, start - indent.length));
    }
}

/**
 * Inserts a Markdown Bible reference link using Android's reference picker/parser flow.
 *
 * - Side effects: may open the shared input modal, call Android bridge reference helpers, mutate
 *   source text, undo state, focus, and selection.
 * - Failure modes: canceled input leaves source unchanged; invalid references keep prompting until
 *   canceled or parsed.
 */
async function insertBibleLink() {
    const ta = textareaEl.value;
    if (!ta) return;
    const selStart = ta.selectionStart;
    const selEnd = ta.selectionEnd;
    let text: string | null = ta.value.substring(selStart, selEnd);
    let error = "";
    let parsed = "";

    while (parsed === "" && text !== null) {
        text = await inputText.value?.inputText(text, error) ?? null;
        if (text !== null) {
            parsed = await android.parseRef(text);
            if (parsed === "") {
                parsed = parse(text);
            }
            error = parsed === "" ? strings.invalidReference : "";
        }
    }
    if (text !== null) {
        pushUndo();
        const linkText = ta.value.substring(selStart, selEnd) || text;
        const mdLink = `[${linkText}](osis://?osis=${parsed})`;
        const before = ta.value.substring(0, selStart);
        const after = ta.value.substring(selEnd);
        editText.value = before + mdLink + after;
        setCursorAfterEdit(selStart + mdLink.length);
    } else {
        ta.focus();
    }
}

function closeEditor() {
    save();
    emit("close");
}

/**
 * Handles Android Markdown editor keyboard shortcuts and list continuation.
 *
 * - Parameter e: Browser keyboard event from the mounted textarea.
 * - Side effects: may prevent default browser behavior, mutate source text, undo state, focus, and
 *   selection, or close the editor.
 * - Failure modes: returns without changes when the shortcut is not handled.
 */
function handleKeyDown(e: KeyboardEvent) {
    if (e.key === "Escape") {
        closeEditor();
        e.stopPropagation();
        return;
    }

    if ((e.ctrlKey || e.metaKey) && e.key === "z" && !e.shiftKey) {
        e.preventDefault();
        undo();
        return;
    }

    if ((e.ctrlKey || e.metaKey) && (e.key === "y" || (e.key === "z" && e.shiftKey))) {
        e.preventDefault();
        redo();
        return;
    }

    if ((e.ctrlKey || e.metaKey) && e.key === "b") {
        e.preventDefault();
        wrapSelection("**", "**");
        return;
    }

    if ((e.ctrlKey || e.metaKey) && e.key === "i") {
        e.preventDefault();
        wrapSelection("*", "*");
        return;
    }

    if ((e.ctrlKey || e.metaKey) && e.key === "u") {
        e.preventDefault();
        wrapSelection("<u>", "</u>");
        return;
    }

    if (e.key === "Enter") {
        const ta = textareaEl.value;
        if (!ta) return;
        const pos = ta.selectionStart;
        const lineStart = getLineStart(ta.value, pos);
        const currentLine = ta.value.substring(lineStart, pos);

        const ulMatch = currentLine.match(/^(\s*)-\s/);
        if (ulMatch) {
            if (currentLine.trim() === "-") {
                e.preventDefault();
                pushUndo();
                editText.value = ta.value.substring(0, lineStart) + ta.value.substring(pos);
                setCursorAfterEdit(lineStart);
                return;
            }
            e.preventDefault();
            pushUndo();
            const prefix = `${ulMatch[1]}- `;
            editText.value = `${ta.value.substring(0, pos)}\n${prefix}${ta.value.substring(pos)}`;
            setCursorAfterEdit(pos + 1 + prefix.length);
            return;
        }

        const olMatch = currentLine.match(/^(\s*)(\d+)\.\s/);
        if (olMatch) {
            const num = parseInt(olMatch[2]);
            if (currentLine.trim() === `${num}.`) {
                e.preventDefault();
                pushUndo();
                editText.value = ta.value.substring(0, lineStart) + ta.value.substring(pos);
                setCursorAfterEdit(lineStart);
                return;
            }
            e.preventDefault();
            pushUndo();
            const prefix = `${olMatch[1]}${num + 1}. `;
            editText.value = `${ta.value.substring(0, pos)}\n${prefix}${ta.value.substring(pos)}`;
            setCursorAfterEdit(pos + 1 + prefix.length);
        }
    }
}

function scrollToCursor() {
    const ta = textareaEl.value;
    const bar = actionbarEl.value;
    if (!ta || !bar || document.activeElement !== ta) return;
    const barRect = bar.getBoundingClientRect();
    const visibleBottom = window.innerHeight - appSettings.bottomOffset;
    if (barRect.bottom > visibleBottom) {
        const behavior: ScrollBehavior = appSettings.disableAnimations ? "auto" : "smooth";
        window.scrollBy({top: barRect.bottom - visibleBottom + 8, behavior});
    }
}

function onViewportResize() {
    scrollToCursor();
}

function onDocumentClick(e: MouseEvent) {
    const target = e.target as Node;
    const wrappers = [headingWrapperEl.value, textStyleWrapperEl.value, indentWrapperEl.value];
    if (!wrappers.some(w => w?.contains(target))) {
        closeAllMenus();
    }
}

onMounted(() => {
    textareaEl.value?.focus();
    autoResize();
    editorMode.value++;
    window.visualViewport?.addEventListener("resize", onViewportResize);
    document.addEventListener("click", onDocumentClick, true);
});

onBeforeUnmount(() => {
    save();
    window.visualViewport?.removeEventListener("resize", onViewportResize);
    document.removeEventListener("click", onDocumentClick, true);
});

onUnmounted(() => {
    editorMode.value--;
});

const {sprintf} = useCommon();
</script>

<style lang="scss">
@use "@/lib/pell/pell.scss" as pell;
@use "@/common.scss" as *;

.md-popup-wrapper {
  position: relative;
  display: inline-block;
}

.md-popup-menu {
  position: absolute;
  bottom: 100%;
  left: 0;
  display: flex;
  flex-direction: column;
  background-color: var(--background-color);
  border: 1px solid hsla(0, 0%, 0%, 0.2);
  border-radius: 3px;
  z-index: 10;

  .night & {
    border-color: hsla(0, 0%, 100%, 0.2);
  }
}

.md-popup-option {
  background: transparent;
  color: inherit;
  border: none;
  padding: 10px 16px;
  font-size: 14px;
  font-weight: bold;
  cursor: pointer;
  text-align: left;
  white-space: nowrap;

  &:hover {
    background-color: hsla(0, 0%, 0%, 0.1);
  }

  .night &:hover {
    background-color: hsla(0, 0%, 100%, 0.1);
  }
}

.md-content {
  display: block;
  min-height: 1em;
  padding: 0 7px 5px 7px;
  z-index: 1;
  position: relative;
  box-sizing: border-box;
  width: 100%;
  border: none;
  outline: none;
  resize: none;
  overflow: hidden;
  overflow-wrap: break-word;
  word-break: break-word;
  font-family: inherit;
  font-size: inherit;
  color: inherit;
  background: var(--background-color);
}

.md-content:focus {
  outline: none;
}

.pell-button {
  color: inherit;
  width: pell.$pell-button-width * 0.9;
  height: pell.$pell-button-height * 0.9;
  margin: 0 1px;

  .night & {
    color: inherit;
  }

  &.end {
    position: absolute;

    [dir=ltr] & {
      right: 0;
    }

    [dir=rtl] & {
      left: 0;
    }
  }
}

.pell-actionbar {
  background-color: inherit;
  color: rgba(0, 0, 0, 0.6);

  .night & {
    color: rgba(255, 255, 255, 0.5);
  }
}

.saved-notice {
  position: absolute;
  right: 5px;
  bottom: pell.$pell-button-height;
  padding-inline-end: 3pt;
  color: hsla(112, 40%, 33%, 0.8);
  opacity: 0.8;
  font-size: 10px;
  z-index: 0;

  .night & {
    color: hsla(112, 40%, 33%, 0.8);
  }
}

.pell-divider {
  background-color: hsla(0, 0%, 0%, 0.2);

  .night & {
    background-color: hsla(0, 0%, 100%, 0.2);
  }
}

.edit-area {
  width: 100%;
  position: relative;
}

.edit-area, .pell {
  margin: 0;
}
</style>
