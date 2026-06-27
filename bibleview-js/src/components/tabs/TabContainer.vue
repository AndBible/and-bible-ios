<!--
  - Copyright (c) 2021-2026 Sykerö Software / Tuomas Airaksinen and the AndBible contributors.
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
  <div class="tab-container" :class="containerClass">
    <div v-if="showNavigation" class="tab-navigation-row">
      <TabNavigation
          :tabs="tabs"
          :active-tab="activeTab"
          :navigation-class="navigationClass"
          @tab-change="handleTabChange"
      />
      <slot name="trailing"></slot>
    </div>
    
    <div class="tab-content" :class="contentClass">
      <TabPanel
          v-for="tab in tabs"
          :key="tab.id"
          :tab-id="tab.id"
          :active="activeTab === tab.id"
          :panel-class="panelClass"
      >
        <slot :name="tab.id" :tab="tab" :active="activeTab === tab.id"></slot>
      </TabPanel>
    </div>
  </div>
</template>

<script setup lang="ts">
/**
 * Coordinates Android-style tab navigation with active panel rendering.
 *
 * @param tabs - Candidate tab descriptors. Entries without an id or label are filtered before
 * rendering so parents can build lists defensively.
 * @param defaultTab - Optional initial tab id. If omitted, the first enabled tab becomes active.
 * @param showNavigation - Hides the navigation row when false while keeping panel rendering intact.
 * @param containerClass - Optional class applied to the outer container.
 * @param navigationClass - Optional class passed through to the shared `TabNavigation` rail.
 * @param contentClass - Optional class applied to the panel content wrapper.
 * @param panelClass - Optional class applied to each panel.
 * @fires tabChange Emitted after selecting an enabled tab that differs from the active tab.
 * @slot default Named tab slots receive `{ tab, active }` for the matching tab id.
 * @slot trailing Optional controls rendered beside the tab rail in the Android `tab-navigation-row`.
 * @remarks This component owns tab state and exposes imperative helpers for existing modal/document
 * integrations. It has no persistence side effects; callers persist state from the emitted event or
 * from their own watchers.
 */
import {computed, provide, ref, watch} from 'vue';
import TabNavigation from './TabNavigation.vue';
import TabPanel from './TabPanel.vue';
import {IconDefinition} from "@fortawesome/fontawesome-svg-core";
import {activeTabKey, setActiveTabKey} from "@/types/constants";

export interface Tab {
  id: string;
  label: string;
  icon?: string | IconDefinition;
  disabled?: boolean;
}

const props = withDefaults(defineProps<{
  tabs: Tab[];
  defaultTab?: string;
  showNavigation?: boolean;
  containerClass?: string;
  navigationClass?: string;
  contentClass?: string;
  panelClass?: string;
}>(), {
  showNavigation: true,
  containerClass: '',
  navigationClass: '',
  contentClass: '',
  panelClass: ''
});

const emit = defineEmits<{
  tabChange: [tabId: string, tab: Tab];
}>();

const activeTab = ref<string>(
    props.defaultTab || 
    props.tabs.find(tab => !tab.disabled)?.id || 
    props.tabs[0]?.id || 
    ''
);

const tabs = computed(() => {
  return props.tabs.filter(tab => tab.id && tab.label);
});

provide(activeTabKey, activeTab);
provide(setActiveTabKey, (tabId: string) => {
  if (tabId !== activeTab.value) {
    const tab = tabs.value.find(t => t.id === tabId);
    if (tab && !tab.disabled) {
      activeTab.value = tabId;
    }
  }
});

/**
 * Applies a requested tab change and notifies parents when the request is valid.
 *
 * @param tabId - Identifier received from the tab rail or imperative `setActiveTab` helper.
 * @remarks Unknown, disabled, or already-active tab ids are ignored. Successful changes mutate only
 * local reactive state and emit `tabChange`; parents remain responsible for external side effects.
 */
function handleTabChange(tabId: string) {
  const tab = tabs.value.find(t => t.id === tabId);
  if (tab && !tab.disabled && tabId !== activeTab.value) {
    activeTab.value = tabId;
    emit('tabChange', tabId, tab);
  }
}

watch(() => props.tabs, (newTabs) => {
  if (!newTabs.find(tab => tab.id === activeTab.value)) {
    const firstAvailable = newTabs.find(tab => !tab.disabled);
    if (firstAvailable) {
      activeTab.value = firstAvailable.id;
    }
  }
}, { immediate: true });

watch(() => props.defaultTab, (newDefaultTab) => {
  if (newDefaultTab && newDefaultTab !== activeTab.value) {
    const tab = tabs.value.find(t => t.id === newDefaultTab);
    if (tab && !tab.disabled) {
      activeTab.value = newDefaultTab;
    }
  }
});

defineExpose({
  setActiveTab: (tabId: string) => handleTabChange(tabId),
  getActiveTab: () => activeTab.value,
  getTabs: () => tabs.value
});
</script>

<style scoped lang="scss">
.tab-container {
  display: flex;
  flex-direction: column;
}

.tab-navigation-row {
  display: flex;
  align-items: stretch;

  :deep(.tab-navigation-wrapper) {
    flex: 1;
    min-width: 0;
  }
}

.tab-content {
  flex: 1;
  padding-top: 1em;
}
</style>
