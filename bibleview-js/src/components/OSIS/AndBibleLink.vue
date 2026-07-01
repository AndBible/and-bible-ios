<!--
  - Copyright (c) 2020-2022 Martin Denham, Tuomas Airaksinen and the AndBible contributors.
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
  <a href="#link" @click.prevent="openLink($event, href)"><slot/></a>
</template>

<script setup lang="ts">
import {useCommon} from "@/composables";
import {navigateLink} from "@/utils";
import {emit} from "@/eventbus";

defineProps<{href: string}>();

/**
 * Routes an OSIS link through the app navigation bridge after recording its scroll anchor.
 *
 * @param event Click event from the rendered anchor.
 * @param url Internal or external AndBible link target.
 * @returns Nothing.
 * @remarks Emits `set_scroll_anchor` for viewport preservation and then delegates navigation to
 * `navigateLink`, which uses the native iOS bridge when required.
 */
function openLink(event: MouseEvent, url: string) {
    emit("set_scroll_anchor", event.currentTarget as HTMLElement);
    navigateLink(url);
}

useCommon();
</script>

<style>

</style>
