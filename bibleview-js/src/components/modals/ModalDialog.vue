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
  <teleport to="#modals">
    <div v-if="blocking" @click.stop="closeModal" class="modal-backdrop"/>
    <div :class="{blocking}">
      <div
          ref="modal"
          @click.stop
          class="modal-content"
          :class="{blocking, wide, edit, limit}"
      >
        <div ref="header" class="modal-header">
          <slot name="title-div">
            <div class="title">
              <slot name="title"/>
            </div>
          </slot>
          <div class="modal-toolbar">
            <slot name="buttons">
              <slot name="extra-buttons"/>
              <button
                  class="modal-action-button right"
                  :aria-label="strings.cancel"
                  :title="strings.cancel"
                  @touchstart.stop
                  @mousedown.stop.prevent
                  @click.stop="closeModal"
              >
                <FontAwesomeIcon icon="times"/>
              </button>
            </slot>
          </div>
        </div>
        <div ref="body" class="modal-body" @click.stop>
          <slot v-if="ready"/>
        </div>
        <div v-if="$slots.footer" class="modal-footer">
          <div class="modal-footer-buttons">
            <slot name="footer"/>
          </div>
        </div>
      </div>
    </div>
  </teleport>
</template>
<script setup lang="ts">
/**
 * Presents the shared draggable reader modal and owns its standard dismissal control.
 *
 * @param blocking Whether the modal owns a backdrop and blocks interaction with reader content.
 * @param wide Whether the modal uses the wider reader-dialog geometry.
 * @param edit Whether body padding is removed for an embedded editor.
 * @param locateTop Whether the modal anchors above its normal bottom position.
 * @param limit Whether the modal body uses the bounded compact height.
 * @slot title-div Complete custom header content.
 * @slot title Default title text when no custom header is supplied.
 * @slot extra-buttons Controls rendered before the standard localized dismissal button.
 * @slot buttons Complete replacement for the standard toolbar controls.
 * @slot default Modal body content.
 * @slot footer Optional footer content.
 * @fires close When the backdrop, Escape key, registered modal-stack callback, or localized
 * standard dismissal control closes the modal. Modal-owned focus is blurred first, and dismissal
 * waits one browser frame when necessary so editor updates and keyboard resignation can settle.
 * @remarks Registration mutates the shared modal stack, resize observation keeps the card within
 * the live reader viewport, and listeners, observers, and pending close frames are disposed during
 * unmount. Missing host geometry leaves placement at its existing CSS fallback without changing
 * dismissal behavior.
 */
import {inject, nextTick, onMounted, onUnmounted, ref, shallowRef, watch} from "vue";
import {useCommon} from "@/composables";
import {draggableElement, setupDocumentEventListener, setupWindowEventListener,} from "@/utils";
import {FontAwesomeIcon} from "@fortawesome/vue-fontawesome";
import {modalKey} from "@/types/constants";

const emit = defineEmits(["close"]);
const props = withDefaults(
    defineProps<{
        blocking?: boolean
        wide?: boolean
        edit?: boolean
        locateTop?: boolean
        limit?: boolean
    }>(),
    {
        blocking: false,
        wide: false,
        edit: false,
        locateTop: false,
        limit: false
    }
);

const modal = shallowRef<HTMLElement | null>(null);
const header = ref(null);
const ready = ref(false);

/**
 * Owns the single deferred close callback while WebKit commits modal focus resignation.
 *
 * `null` means no close is pending. A live handle coalesces repeated requests and is cancelled on
 * unmount so an obsolete modal cannot emit `close` into replacement parent state.
 */
let closeFrame: number | null = null;

/**
 * Resigns the currently focused modal descendant without disturbing reader focus behind it.
 *
 * @returns `true` when modal-owned focus was blurred; otherwise `false`.
 * @remarks The toolbar prevents mouse-down focus transfer so click-time focus remains on the
 * editor. A missing modal reference, a non-HTML active element, or focus outside this modal is
 * intentionally ignored.
 */
function blurModalOwnedFocus(): boolean {
    const activeElement = document.activeElement;
    if (activeElement instanceof HTMLElement && modal.value?.contains(activeElement)) {
        activeElement.blur();
        return true;
    }
    return false;
}

/**
 * Resigns modal-owned focus before notifying the parent that dismissal was requested.
 *
 * @returns Nothing.
 * @remarks `HTMLElement.blur()` dispatches the editor's existing save-on-blur work before the
 * close event can unmount modal content, and it asks WebKit to resign the software keyboard. When
 * focus was resigned, one animation frame lets WebKit commit that first-responder transition
 * before Vue removes the editor. Repeated close requests during that boundary emit only once.
 */
function closeModal() {
    if (closeFrame !== null) return;

    if (!blurModalOwnedFocus()) {
        emit("close");
        return;
    }

    const frameHandle = requestAnimationFrame(() => {
        if (closeFrame !== frameHandle) return;
        emit("close");
        closeFrame = null;
    });
    closeFrame = frameHandle;
}

/**
 * Repositions the modal inside the live WebView viewport after geometry or toolbar changes.
 *
 * @param horizontal Whether to restore the centered horizontal anchor before measuring.
 * @returns A promise that settles after Vue and WebKit have applied the final absolute position.
 * @remarks The Android reader keeps dialog chrome reachable when the IME resizes its WebView. The
 * preferred top or bottom anchor is preserved while it fits. If the resized viewport would place
 * the card outside its usable top/bottom offsets, the top is clamped so the complete card remains
 * visible when possible and its header remains reachable when the card is taller than the viewport.
 * This mutates only the modal element's inline geometry and the exposed measured height. Missing or
 * non-finite native offsets fail closed to the physical WebView edges; the function does not throw.
 */
async function resetPosition(horizontal = false) {
    const m = modal.value!;
    if (horizontal) {
        m.style.left = `var(--modal-left)`;
    }

    if (props.locateTop) {
        m.style.bottom = "";
        m.style.top = `calc(var(--top-offset) + var(--modal-top))`;
    } else {
        m.style.top = "";
        m.style.bottom = `calc(var(--bottom-offset) + var(--modal-top))`;
    }

    await nextTick();
    const topOffset = Number.isFinite(appSettings.topOffset)
        ? Math.max(0, appSettings.topOffset)
        : 0;
    const bottomOffset = Number.isFinite(appSettings.bottomOffset)
        ? Math.max(0, appSettings.bottomOffset)
        : 0;
    const viewportHeight = Number.isFinite(window.innerHeight)
        ? Math.max(0, window.innerHeight)
        : 0;
    const viewportBottom = Math.max(topOffset, viewportHeight - bottomOffset);
    const maximumTop = Math.max(topOffset, viewportBottom - m.offsetHeight);
    const clampedTop = Math.min(Math.max(m.offsetTop, topOffset), maximumTop);
    m.style.top = `${clampedTop}px`;
    m.style.bottom = "";
    await nextTick();
    height.value = m.clientHeight;
}

const {register} = inject(modalKey)!;
register({blocking: props.blocking, close: closeModal});

setupWindowEventListener("resize", () => resetPosition(true));
setupDocumentEventListener("keyup", (event: KeyboardEvent) => {
    if (event.key === "Escape") {
        closeModal();
    }
});

const height = ref(0);

const observer = new ResizeObserver(() => {
    resetPosition();
});

const body = ref<HTMLElement | null>(null);

onMounted(async () => {
    await resetPosition(true)
    const m = modal.value!
    draggableElement(m, header.value!);
    observer.observe(m);
    ready.value = true;
    body.value!.focus();
});

onUnmounted(() => {
    if (closeFrame !== null) {
        cancelAnimationFrame(closeFrame);
        closeFrame = null;
    }
    observer.disconnect();
});

const {appSettings, strings} = useCommon()

watch(() => [appSettings.bottomOffset, appSettings.topOffset], () => resetPosition());

defineExpose({height});
</script>

<style scoped lang="scss">
@use "@/common.scss" as *;

$border-radius: 8pt;
$border-radius2: $border-radius - 1.5pt;

.modal-content {
  font-family: sans-serif;
  font-size: 12pt;
  z-index: 5;

  .blocking & {
    z-index: 15;
  }

  position: fixed;
  background-color: $modal-content-background-color;
  padding: 0;
  border: 1px solid #888;
  box-shadow: 0 4px 8px 0 rgba(0, 0, 0, 0.2), 0 6px 20px 0 rgba(0, 0, 0, 0.19);
  animation-name: animatetop;
  animation-duration: 0.2s;
  .noAnimation & {
    animation: none;
    box-shadow: none;
  }

  .night & {
    background-color: $modal-content-background-color-night;
    color: #bdbdbd;
  }

  .monochrome.night & {
    border-color: white;
  }

  border-radius: $border-radius;
  width: var(--modal-width);

  --modal-left: calc((100% - var(--modal-width)) / 2);
  --modal-width: calc(min(80%, var(--text-max-width)));
  --modal-top: 30px;

  &.wide {
    --modal-width: calc(min(var(--text-max-width) + 20px, 100% - 60px));
    --modal-top: 25px;
  }
}

@keyframes animatetop {
  from {
    opacity: 0
  }
  to {
    opacity: 1
  }
}

.title {
  padding-top: 5pt;
  margin-top: 2pt;
}

.modal-header {
  display: flex;
  justify-content: space-between;
  padding: 0.1em;
  padding-left: 0.5em;
  background-color: $modal-header-background-color;
  --header-backround: #{$modal-header-background-color};
  color: white;
  font-weight: bold;
  border-radius: $border-radius2 $border-radius2 0 0;

  .night & {
    background-color: $night-modal-header-background-color;
    --header-backround: #{$night-modal-header-background-color};
    color: #e2e2e2;
  }
  .monochrome.night & {
    color: white;
  }
}

.modal-toolbar {
  align-self: flex-end;
  display: flex;
}

.modal-body {
  --max-height: calc(100vh - var(--top-offset) - var(--bottom-offset) - 100px);

  .limit & {
    --max-height: min(calc(100vh - var(--top-offset) - var(--bottom-offset) - 100px), 165px);
  }

  //min-height: 60pt;
  padding: 5px 5px;
  margin: 5pt 5pt;

  .edit & {
    padding: 0 0;
    margin: 0 0;
  }

  .night & {
    background-color: $modal-content-background-color-night;
  }
}

.modal-footer {
  border-radius: 0 0 $border-radius2 $border-radius2;
  display: flex;
  flex-direction: row;
  justify-content: space-around;
  padding-top: 2px;
  padding-bottom: 2px;
  background-color: #acacac;
  color: white;

  .night & {
    background-color: #454545;
    color: #bdbdbd;
  }
}

</style>
