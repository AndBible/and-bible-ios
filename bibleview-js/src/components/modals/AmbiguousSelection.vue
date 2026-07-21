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
  <ModalDialog ref="modal" :blocking="blocking" v-if="showModal" :locate-top="locateTop" @close="cancelled"
               :limit="limitAmbiguousModalSize">
    <template #extra-buttons>
      <button
          class="modal-action-button right"
          @touchstart.stop
          @click="multiSelectionButtonClicked"
      >
        <FontAwesomeIcon icon="plus-circle"/>
      </button>
      <button v-if="modal && (limitAmbiguousModalSize || modal.height > 196)" class="modal-action-button right"
              @touchstart.stop @click="limitAmbiguousModalSize = !limitAmbiguousModalSize">
        <FontAwesomeIcon :icon="limitAmbiguousModalSize?'expand-arrows-alt':'compress-arrows-alt'"/>
      </button>
      <button class="modal-action-button right" @touchstart.stop @click="help">
        <FontAwesomeIcon icon="question-circle"/>
      </button>
    </template>

    <div class="buttons">
      <AmbiguousActionButtons v-if="selectionInfo" :has-actions="!noActions" :selection-info="selectionInfo"
                              @close="cancelled"/>
      <template v-for="(s, index) of selectedActions" :key="index">
        <template v-if="!s.options.bookmarkId">
          <button class="button light" @click.stop="selected(s)">
            <span :style="`color: ${s.options.color}`"><FontAwesomeIcon v-if="s.options.icon"
                                                                        :icon="s.options.icon"/></span>
            {{ s.options.title }}
          </button>
        </template>
      </template>
      <AmbiguousSelectionBookmarkButton
          v-for="b of clickedBookmarks"
          :key="`b-${b.id}`"
          :bookmark-id="b.id"
          @selected="selected(b)"
      />
      <div v-if="clickedBookmarks.length > 0 && selectedBookmarks.length > 0" class="separator"/>
      <AmbiguousSelectionBookmarkButton
          v-for="b of selectedBookmarks"
          :key="`b-${b.id}`"
          :bookmark-id="b.id"
          @selected="selected(b)"
      />
    </div>
    <template #title>
      <template v-if="verseInfo">
        {{ bibleBookName }} {{ verseInfo.chapter }}:{{ verseInfo.verse }}<template v-if="verseInfo.verseTo">-{{ verseInfo.verseTo }}</template>
      </template>
      <template v-else>
        {{ strings.bookmarks }}
      </template>
    </template>
  </ModalDialog>
</template>

<script lang="ts" setup>
/**
 * Coordinates reader clicks that can resolve to multiple actions, bookmarks, or AI document markers.
 *
 * @param blocking Whether the modal prevents background interaction.
 * @param doNotCloseModals Whether background clicks preserve other open modal state.
 * @fires back-clicked When a plain reader click should dismiss the owning modal layer.
 * @remarks AI marker choices sort before normal bookmarks, matching Android's navigation-first
 * chooser. The component owns transient selection highlighting and resolves its internal deferred
 * choice deterministically when a normal action is selected or cancelled.
 */
import ModalDialog from "@/components/modals/ModalDialog.vue";
import {useCommon} from "@/composables";
import {FontAwesomeIcon} from "@fortawesome/vue-fontawesome";
import {computed, inject, provide, ref, Ref} from "vue";
import {
    Callback,
    Deferred,
    EventOrdinalInfo,
    EventVerseInfo,
    getAllEventFunctions,
    getEventOrdinalInfo,
    getEventVerseInfo,
    getHighestPriorityEventFunctions,
    isBottomHalfClicked,
} from "@/utils";
import AmbiguousSelectionBookmarkButton from "@/components/modals/AmbiguousSelectionBookmarkButton.vue";
import {emit, setupEventBusListener} from "@/eventbus";
import AmbiguousActionButtons from "@/components/AmbiguousActionButtons.vue";
import {sortBy} from "lodash";
import {
    androidKey,
    appSettingsKey,
    globalBookmarksKey, keyboardKey,
    locateTopKey,
    modalKey,
    ordinalHighlightKey
} from "@/types/constants";
import {BaseBookmark} from "@/types/client-objects";
import {Nullable, Optional, SelectionInfo} from "@/types/common";

const props = withDefaults(
    defineProps<{ blocking?: boolean, doNotCloseModals?: boolean }>(),
    {blocking: false, doNotCloseModals: false}
);

const $emit = defineEmits(["back-clicked"])

const appSettings = inject(appSettingsKey)!;
const {setupKeyboardListener} = inject(keyboardKey)!;
const limitAmbiguousModalSize = computed({
    get() {
        return appSettings.limitAmbiguousModalSize;
    },
    set(value) {
        android.setLimitAmbiguousModalSize(value);
    }
});
const {bookmarkMap, bookmarkIdsByOrdinal} = inject(globalBookmarksKey)!;
const {strings, config} = useCommon();
const android = inject(androidKey)!;
const multiSelectionMode = ref(false);

const {resetHighlights, highlightOrdinal, hasHighlights} = inject(ordinalHighlightKey)!;
const {modalOpen, closeModals} = inject(modalKey)!;

const showModal = ref(false);
const locateTop = ref(false);
provide(locateTopKey, locateTop);

const verseInfo: Ref<Nullable<EventVerseInfo>> = ref(null);
const ordinalInfo: Ref<Nullable<EventOrdinalInfo>> = ref(null);

setupEventBusListener("clear_document", () => {
   verseInfo.value = null;
   ordinalInfo.value = null;
});

const selectionInfo = computed<Nullable<SelectionInfo>>(() => {
    if (!verseInfo.value && !ordinalInfo.value) return null;
    return {
        verseInfo: verseInfo.value,
        ordinalInfo: ordinalInfo.value,
        startOrdinal: startOrdinal.value!,
        endOrdinal: endOrdinal.value!,
    }
});

const originalSelections = ref<Callback[] | null>(null);
const bibleBookName = computed(() => verseInfo.value && verseInfo.value.bibleBookName);

const selectedActions = computed<Callback[]>(() => {
    if (originalSelections.value === null) return [];
    return originalSelections.value.filter(v => !v.options.bookmarkId)
});

const clickedBookmarks = computed<BaseBookmark[]>(() => {
    if (originalSelections.value === null) return [];

    return sortBy(
        originalSelections.value
            .filter(v => v.options.bookmarkId && !v.options.hidden && bookmarkMap.has(v.options.bookmarkId))
            .map(v => bookmarkMap.get(v.options.bookmarkId)!),
        [v => v.type === "ai-doc-marker" ? 0 : 1, v => v.text.length]
    );
});

let deferred: Nullable<Deferred<BaseBookmark | Callback | undefined>> = null;

async function select(event: MouseEvent, sel: Callback[]): Promise<Callback | BaseBookmark | undefined> {
    originalSelections.value = sel;
    locateTop.value = isBottomHalfClicked(event);
    showModal.value = true;

    deferred = new Deferred();
    return await deferred.wait();
}

function selected(s: Callback | BaseBookmark) {
    deferred!.resolve(s);
}

function cancelled() {
    if (deferred) {
        deferred.resolve();
    }
}

function close() {
    multiSelectionMode.value = false;
    showModal.value = false;
    resetHighlights(true);
}

//const {isDoubleClick} = createDoubleClickDetector();

function updateHighlight() {
    resetHighlights();
    for (let o of ordinalRange()) {
        if(ordinalInfo.value != null) {
            highlightOrdinal(o, ordinalInfo.value.bookInitials, ordinalInfo.value.osisRef);
        } else {
            highlightOrdinal(o);
        }
    }
    if (!verseInfo.value) return;
    if (endOrdinal.value == null || endOrdinal.value === startOrdinal.value) {
        verseInfo.value.verseTo = "";
    } else {
        const {ordinalRange: [, chapterEnd]} = verseInfo.value.bibleDocumentInfo!;

        const endOrd = chapterEnd > endOrdinal.value ? endOrdinal.value : chapterEnd;
        verseInfo.value.verseTo = `${verseInfo.value.verse + endOrd - startOrdinal.value!}${endOrdinal.value > chapterEnd ? "+" : ""}`;
    }
}

function multiSelect(_verseInfo: Optional<EventVerseInfo>, _ordinalInfo: Optional<EventOrdinalInfo>) {
    if (!_verseInfo && !_ordinalInfo) return false;
    if(_verseInfo) {
        if (_verseInfo.ordinal < startOrdinal.value!) {
            endOrdinal.value = null;
            return false
        } else {
            endOrdinal.value = _verseInfo.ordinal;
        }
    }
    if(_ordinalInfo) {
        if (_ordinalInfo.ordinal < startOrdinal.value!) {
            endOrdinal.value = null;
            return false
        } else {
            endOrdinal.value = _ordinalInfo.ordinal;
        }
    }
    updateHighlight();
    return true;
}

const startOrdinal = ref<number | null>(null);
const endOrdinal = ref<number | null>(null);

function* ordinalRange(): Generator<number> {
    const _endOrdinal = endOrdinal.value || startOrdinal.value;
    for (let o = startOrdinal.value!; o <= _endOrdinal!; o++) {
        yield o;
    }
}

const selectedBookmarks = computed<BaseBookmark[]>(() => {
    const clickedIds = new Set(clickedBookmarks.value.map(b => b.id));
    const result: IdType[] = [];
    const keyBase = ordinalInfo.value?.osisRef ?? "BIBLE";
    for (const o of ordinalRange()) {
        result.push(
            ...Array.from(bookmarkIdsByOrdinal.get(`${keyBase}-${o}`) || [])
                .filter(bId => !clickedIds.has(bId) && !result.includes(bId)))
    }
    return sortBy(
        result.map(bId => bookmarkMap.get(bId)).filter(b => b) as BaseBookmark[],
        [v => v.type === "ai-doc-marker" ? 0 : 1]
    );
});

function setInitialVerse(_verseInfo: EventVerseInfo) {
    verseInfo.value = _verseInfo;
    startOrdinal.value = _verseInfo.ordinal;
    endOrdinal.value = null;
    updateHighlight();
}

function setInitialOrdinal(_ordinalInfo: EventOrdinalInfo) {
    ordinalInfo.value = _ordinalInfo;
    startOrdinal.value = _ordinalInfo.ordinal;
    endOrdinal.value = null;
    updateHighlight();
}

function multiSelectionButtonClicked() {
    if (multiSelectionMode.value) {
        endOrdinal.value = endOrdinal.value! + 1;
    } else {
        multiSelectionMode.value = true;
        endOrdinal.value = startOrdinal.value! + 1;
    }

    updateHighlight();
}

function minusKeyPressed() {
    if(!endOrdinal.value || !startOrdinal.value) {
        return
    }
    if(endOrdinal.value > startOrdinal.value) {
        endOrdinal.value = endOrdinal.value! - 1;
    }
    updateHighlight();
}

/**
 * Finds the nearest clicked anchor from a reader click event.
 *
 * Reader clicks can originate from nested elements or text nodes inside an anchor. Normalizing to
 * the anchor keeps downstream scroll-anchor behavior stable.
 *
 * @param event Bubbled reader mouse event.
 * @returns The nearest containing anchor, or null when the click did not come from link content.
 */
function closestAnchorFromEvent(event: MouseEvent): HTMLAnchorElement | null {
    const target = event.target;
    if (target instanceof Element) {
        return target.closest("a");
    }
    if (target instanceof Node) {
        return target.parentElement?.closest("a") ?? null;
    }
    return null;
}

/**
 * Handles bubbled reader clicks and chooses between direct actions, verse selection, and modal
 * dismissal.
 *
 * The activation debounce still suppresses plain pane-activation taps, but verse or ordinal
 * metadata marks the event as a content tap and must be processed even when the pane has just
 * become active. Plain unmanaged links record a scroll anchor and stay on the link path, while
 * bookmark actions are filtered out of chooser state when bookmark display is disabled.
 *
 * @param event Bubbled mouse event that may carry registered callbacks, verse metadata, or ordinal
 * metadata added by child document components.
 * @returns A promise that settles after a direct callback runs or the ambiguous selection modal is
 * dismissed.
 * @remarks Mutates modal/highlight state and emits reader events. Action mode returns before state
 * mutation; inactive plain taps return after clearing any existing highlights.
 */
async function handle(event: MouseEvent) {
    const clickedLink = closestAnchorFromEvent(event);
    if (clickedLink) {
        emit("set_scroll_anchor", clickedLink);
    }
    const isActive = appSettings.activeWindow && (performance.now() - appSettings.activeSince > 250);
    const eventFunctions = getHighestPriorityEventFunctions(event);
    const allEventFunctions = getAllEventFunctions(event).filter(e => config.showBookmarks || !e.options.bookmarkId);
    const hasParticularClicks = eventFunctions.filter(f => !f.options.hidden).length > 0; // let's not show only "hidden" items
    const _verseInfo: Nullable<EventVerseInfo> = getEventVerseInfo(event);
    const _ordinalInfo: Nullable<EventOrdinalInfo> = getEventOrdinalInfo(event);
    const hasContentSelection = _verseInfo != null || _ordinalInfo != null;
    if (appSettings.actionMode) {
        return;
    }
    if (!hasParticularClicks && clickedLink) {
        return;
    }
    const hadHighlights = hasHighlights.value;
    resetHighlights();
    if (hadHighlights && !showModal.value && !hasParticularClicks) {
        return;
    }
    if (!isActive && !hasParticularClicks && !hasContentSelection) {
        return;
    }
    emit("back_clicked");

    if (multiSelectionMode.value && multiSelect(_verseInfo, _ordinalInfo)) {
        return;
    }
    multiSelectionMode.value = false;

    if (eventFunctions.length > 0 || _verseInfo != null || _ordinalInfo != null) {
        const firstFunc = eventFunctions[0];
        const singleHighPriority = eventFunctions.length === 1 && firstFunc.options.priority > 0 && !firstFunc.options.dottedStrongs && !firstFunc.options.hiddenStrongs;
        const singleDotted = allEventFunctions.length === 1 && firstFunc?.options.dottedStrongs && !firstFunc?.options.hiddenStrongs;
        if (singleHighPriority || singleDotted) {
            if (eventFunctions[0].options.bookmarkId || firstFunc.options.hiddenStrongs) {
                emit("bookmark_clicked", eventFunctions[0].options.bookmarkId, {locateTop: isBottomHalfClicked(event)});
            } else {
                const cb = eventFunctions[0].callback;
                if (cb) {
                    cb();
                }
            }
        } else {
            if (modalOpen.value && !hasParticularClicks) {
                if (!props.doNotCloseModals) {
                    closeModals();
                }
            } else if (_verseInfo) {
                setInitialVerse(_verseInfo);
                const s = await select(event, allEventFunctions);
                if (s && s.type === "callback" && s.callback) s.callback();
            } else if (_ordinalInfo) {
                setInitialOrdinal(_ordinalInfo);
                const s = await select(event, allEventFunctions);
                if (s && s.type === "callback" && s.callback) s.callback();
            }
        }
    } else {
        $emit("back-clicked");
        if (!props.doNotCloseModals) {
            closeModals();
        }
    }
    close();
}

const noActions = computed(() => selectedActions.value.length === 0);

function help() {
    android.helpBookmarks()
}

setupKeyboardListener((e: KeyboardEvent) => {
    if (!showModal.value) return false;
    console.log("AmbiguousSelection keyboard listener", e);
    if (e.key === "+") {
        multiSelectionButtonClicked();
        return true;
    }
    if (e.key === "-") {
        minusKeyPressed();
        return true;
    }
    else if (e.ctrlKey && e.code === "KeyC") {
        if (selectionInfo.value?.verseInfo) {
            console.log("Ctrl + c pressed. Copying (book initial, start ordinal, end ordinal)", selectionInfo.value?.verseInfo.bookInitials, startOrdinal.value, endOrdinal.value)
            android.copyVerse(selectionInfo.value.verseInfo.bookInitials, startOrdinal.value!, endOrdinal.value!)
            return true;
        }
    }
    return false;
}, 4)

const modal = ref<InstanceType<typeof ModalDialog> | null>(null);
defineExpose({handle});
</script>

<style scoped lang="scss">
@use "@/common.scss" as *;

.buttons {
  @extend .visible-scrollbar;
  max-height: calc(var(--max-height) - 25pt);
  display: flex;
  flex-direction: column;
  overflow-y: auto;
}

.separator {
  margin-top: 2pt;
  margin-bottom: 2pt;
}

</style>
