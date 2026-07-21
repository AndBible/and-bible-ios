/*
 * Copyright (c) 2026 Sykerö Software / Tuomas Airaksinen and the AndBible contributors.
 *
 * This file is part of AndBible: Bible Study (http://github.com/AndBible/and-bible).
 */

import {computed, inject, onBeforeUnmount, onMounted, watch} from "vue";
import {faBookmark, faEllipsisV} from "@fortawesome/free-solid-svg-icons";
import {icon as renderIcon, type Icon, type IconDefinition} from "@fortawesome/fontawesome-svg-core";
import {globalBookmarksKey} from "@/types/constants";
import {isWholePageItem, resolveIcon} from "@/composables/bookmarks";
import {useCommon} from "@/composables";

/** Native interactive elements that must remain outside an injected document action control. */
const interactiveTags = new Set(["A", "BUTTON", "INPUT", "SELECT", "TEXTAREA", "LABEL"]);

/** Converts a Font Awesome definition to the exact inline SVG markup inserted into rendered OSIS. */
function iconToHtml(iconValue: IconDefinition | Icon): string {
    return "html" in iconValue ? iconValue.html[0] : renderIcon(iconValue).html[0];
}

/** Finds the first non-whitespace text node in source rendering order. */
function findFirstTextNode(root: Node): Text | null {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode: node => node.textContent?.trim()
            ? NodeFilter.FILTER_ACCEPT
            : NodeFilter.FILTER_REJECT,
    });
    return walker.nextNode() as Text | null;
}

/** Finds the outermost interactive ancestor between a text node and its fragment boundary. */
function findInteractiveAncestor(node: Node, boundary: Element): Element | null {
    let outermost: Element | null = null;
    let current = node.parentElement;
    while (current && current !== boundary) {
        if (interactiveTags.has(current.tagName)) outermost = current;
        current = current.parentElement;
    }
    return outermost;
}

/**
 * Injects a reactive action-menu icon before the first rendered text in a generic OSIS document.
 *
 * @param documentId Exact Vue document ID used to locate the mounted fragment.
 * @param bookInitials Exact source initials used to resolve whole-page bookmark state.
 * @param annotateRef Effective annotation reference used to resolve whole-page bookmark state.
 * @param openMenu Callback receiving the injected icon when pointer or keyboard activation occurs.
 * @returns Nothing; lifecycle hooks own insertion and cleanup.
 * @throws No explicit errors. Missing document/fragment/text nodes skip insertion without fallback.
 * @remarks Watches bookmark labels and color settings to update injected SVG/color in place. On
 * unmount, every inserted node and its DOM listeners are removed with the node.
 */
export function useInlineActionIcons(
    documentId: string,
    bookInitials: string,
    annotateRef: string,
    openMenu: (anchor: HTMLElement) => void,
) {
    const globalBookmarks = inject(globalBookmarksKey)!;
    const {config, appSettings, adjustedColor, strings} = useCommon();
    const injectedIcons: HTMLSpanElement[] = [];

    /** First matching whole-page item and its visual label, reactively recomputed. */
    const wholePageBookmark = computed(() => {
        void config.showBookmarks;
        void config.showMyNotes;
        void config.showAiDocMarkers;
        void appSettings.monochromeMode;
        const item = globalBookmarks.bookmarks.value.find(bookmark =>
            isWholePageItem(bookmark, bookInitials, annotateRef)
        );
        if (!item) return null;
        const label = globalBookmarks.bookmarkLabels.get(item.primaryLabelId || item.labels[0]);
        return label ? {item, label} : null;
    });

    /** Action icon derived from the first matching bookmark or the neutral overflow affordance. */
    const menuIcon = computed<IconDefinition | Icon>(() => {
        const bookmark = wholePageBookmark.value;
        return bookmark
            ? resolveIcon(bookmark.item, bookmark.label) ?? faBookmark
            : faEllipsisV;
    });

    /** Action icon color derived from bookmark label and display color policy. */
    const menuColor = computed<string | null>(() => {
        const bookmark = wholePageBookmark.value;
        if (!bookmark) return null;
        const color = appSettings.monochromeMode
            ? "black"
            : bookmark.label.color;
        return adjustedColor(color).string();
    });

    /** Replaces SVG and color styling for one injected icon without changing its dimensions. */
    function applyIconStyle(span: HTMLSpanElement) {
        span.innerHTML = iconToHtml(menuIcon.value);
        const color = menuColor.value;
        span.style.color = color ?? "";
        span.style.opacity = color ? "1" : "";
    }

    watch([menuIcon, menuColor], () => injectedIcons.forEach(applyIconStyle));

    /** Creates one accessible inline icon and wires pointer/keyboard menu activation. */
    function createInlineIcon(): HTMLSpanElement {
        const span = document.createElement("span");
        span.className = "inline-action-icon skip-offset";
        span.role = "button";
        span.tabIndex = 0;
        span.ariaLabel = strings.documentActionsAccessibilityLabel;
        span.title = strings.documentActionsAccessibilityLabel;
        applyIconStyle(span);
        const activate = (event: Event) => {
            event.stopPropagation();
            event.preventDefault();
            openMenu(span);
        };
        span.addEventListener("click", activate);
        span.addEventListener("keydown", event => {
            if (event.key === "Enter" || event.key === " ") activate(event);
        });
        injectedIcons.push(span);
        return span;
    }

    onMounted(() => {
        const documentElement = document.getElementById(`doc-${documentId}`);
        const fragmentElement = documentElement?.querySelector('[id^="frag-"]');
        if (!fragmentElement) return;
        const firstText = findFirstTextNode(fragmentElement);
        if (!firstText) return;
        const interactive = findInteractiveAncestor(firstText, fragmentElement);
        const insertionTarget = interactive ?? firstText;
        insertionTarget.parentNode?.insertBefore(createInlineIcon(), insertionTarget);
    });

    onBeforeUnmount(() => {
        injectedIcons.forEach(span => span.remove());
        injectedIcons.length = 0;
    });
}
