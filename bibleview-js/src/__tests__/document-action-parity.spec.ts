/*
 * Copyright (c) 2026 Sykerö Software / Tuomas Airaksinen and the AndBible contributors.
 *
 * This file is part of AndBible: Bible Study (http://github.com/AndBible/and-bible).
 */

import {flushPromises, mount, type VueWrapper} from "@vue/test-utils";
import {nextTick, ref} from "vue";
import {afterEach, describe, expect, it, vi} from "vitest";
import type {AiDocMarker, BaseBookmark, BibleBookmark, GenericBookmark, LabelAndStyle} from "@/types/client-objects";
import type {OsisDocument} from "@/types/documents";
import DocumentActionMenu from "@/components/documents/DocumentActionMenu.vue";
import WholePageBookmarks from "@/components/WholePageBookmarks.vue";
import OsisDocumentComponent from "@/components/documents/OsisDocument.vue";
import AmbiguousSelectionBookmarkButton from "@/components/modals/AmbiguousSelectionBookmarkButton.vue";
import BookmarkModal from "@/components/modals/BookmarkModal.vue";
import ModalDialog from "@/components/modals/ModalDialog.vue";
import BookmarkText from "@/components/BookmarkText.vue";
import {emit} from "@/eventbus";
import {
    androidKey,
    appSettingsKey,
    calculatedConfigKey,
    configKey,
    customCssKey,
    globalBookmarksKey,
    locateTopKey,
    modalKey,
    stringsKey,
} from "@/types/constants";

window.bibleView = {};
window.bibleViewDebug = {};

/** Stable labels used by action components without loading asynchronous locale bundles. */
const strings = {
    addBookmark: "Bookmark",
    bookmarks: "Bookmarks",
    cancel: "Cancel",
    copyMyDocumentPageAccessibilityLabel: "Copy My Document page",
    deleteMyDocumentPageAccessibilityLabel: "Delete My Document page",
    deleteMyDocumentPageConfirmation: "Delete this page?",
    deleteMyDocumentPageConfirmationTitle: "Delete AI page?",
    documentActionsAccessibilityLabel: "Document actions",
    editTextPlaceholder: "Tap to edit text",
    myNotesEditorAccessibilityLabel: "My Notes note editor for %s",
    regenerateMyDocumentPageAccessibilityLabel: "Regenerate My Document page",
    saveMyDocumentPageAccessibilityLabel: "Save My Document page",
    shareMyDocumentPageAccessibilityLabel: "Share My Document page",
};

/** Font Awesome test double that keeps action buttons clickable without icon library registration. */
const FontAwesomeIconStub = {
    name: "FontAwesomeIcon",
    props: ["icon", "size"],
    template: "<i class=\"font-awesome-icon\"></i>",
};

/**
 * Builds a complete generic document fixture with exact source and rendered-fragment identity.
 *
 * @param overrides Fields replaced for the behavior under test.
 * @returns A typed OSIS document accepted by the production action components.
 * @remarks The fixture has no reactive state or side effects; callers may safely reuse nested values.
 */
function documentFixture(overrides: Partial<OsisDocument> = {}): OsisDocument {
    return {
        id: "document-1",
        type: "osis",
        osisFragment: {
            xml: '<div data-source="exact">Rendered &amp; exact</div>',
            key: "fragment-key",
            keyName: "Rendered page",
            v11n: null,
            bookCategory: "GENERAL_BOOK",
            bookInitials: "GEN.Book",
            bookAbbreviation: "GEN",
            osisRef: "fragment:key",
            isNewTestament: false,
            features: {},
            hasStrongs: false,
            ordinalRange: null,
            language: "en",
            direction: "ltr",
        },
        bookInitials: "GEN.Book",
        bookCategory: "GENERAL_BOOK",
        bookAbbreviation: "GEN",
        bookName: "Generic Book",
        key: "source:key/alpha?x=1",
        v11n: null,
        osisRef: "page:key/alpha?x=1",
        annotateRef: "annotate:key",
        genericBookmarks: [],
        ordinalRange: null,
        isNativeHtml: false,
        highlightedOrdinalRange: null,
        isMyDocument: false,
        isAiDocument: false,
        myDocumentPageId: null,
        sourcePromptId: null,
        sourcePromptName: null,
        sourceModelName: null,
        aiDocMarkers: [],
        commentaryRange: null,
        ...overrides,
    };
}

/**
 * Builds one AI marker whose navigation and source-page identities are deliberately distinct.
 *
 * @returns A complete marker record for normal and ambiguous click-route tests.
 * @remarks No IDs are generated, keeping payload assertions deterministic.
 */
function aiMarkerFixture(): AiDocMarker {
    return {
        id: "ai-marker-1",
        type: "ai-doc-marker",
        hashCode: 1,
        ordinalRange: [12, 12],
        offsetRange: null,
        labels: ["ai-label"],
        bookInitials: "KJV",
        bookName: "King James Version",
        bookAbbreviation: "KJV",
        createdAt: 1,
        text: "",
        fullText: "",
        bookmarkToLabels: [],
        primaryLabelId: "ai-label",
        lastUpdatedOn: 1,
        notes: null,
        notesContentType: null,
        hasNote: false,
        wholeVerse: true,
        customIcon: "robot",
        editAction: {mode: null, content: null},
        verseRangeAbbreviated: "Gen 1:12",
        title: "Explain this verse",
        documentInitials: "AI.Documents",
        pageKey: "page:key/42",
        sourcePromptId: "source-prompt-id",
        sourceBookInitials: "GEN.Book",
        sourceBookKey: "annotate:key",
    };
}

/**
 * Builds one complete Bible bookmark for the reader note-editor accessibility contract.
 *
 * @returns A deterministic Genesis 1:1 bookmark with no existing note.
 * @remarks The fixture has no generated values or side effects, so its reference-specific label is
 * stable across component and end-to-end tests.
 */
function bibleBookmarkFixture(): BibleBookmark {
    return {
        id: "bible-bookmark-1",
        type: "bookmark",
        hashCode: 3,
        ordinalRange: [1, 1],
        offsetRange: null,
        labels: [],
        bookInitials: "KJV",
        bookName: "King James Version",
        bookAbbreviation: "KJV",
        createdAt: 1,
        text: "In the beginning",
        fullText: "In the beginning God created the heaven and the earth.",
        bookmarkToLabels: [],
        primaryLabelId: "",
        lastUpdatedOn: 1,
        notes: null,
        notesContentType: "HTML",
        hasNote: false,
        wholeVerse: true,
        customIcon: null,
        editAction: {mode: null, content: null},
        osisRef: "Gen.1.1",
        originalOrdinalRange: [1, 1],
        verseRange: "Genesis 1:1",
        verseRangeOnlyNumber: "1:1",
        verseRangeAbbreviated: "Gen 1:1",
        v11n: "KJV",
        osisFragment: null,
    };
}

/**
 * Builds a generic bookmark with structured source OSIS and a deliberately unsafe raw fallback.
 *
 * @returns Complete bookmark payload that distinguishes structured rendering from `v-html`.
 */
function genericBookmarkFixture(): GenericBookmark {
    return {
        id: "generic-bookmark-1",
        type: "generic-bookmark",
        hashCode: 2,
        ordinalRange: null,
        offsetRange: null,
        labels: [],
        bookInitials: "GEN.Book",
        bookName: "Generic Book",
        bookAbbreviation: "GEN",
        createdAt: 1,
        text: "Structured source",
        fullText: "Structured source",
        bookmarkToLabels: [],
        primaryLabelId: "",
        lastUpdatedOn: 1,
        notes: null,
        notesContentType: null,
        hasNote: false,
        wholeVerse: false,
        customIcon: null,
        editAction: {mode: null, content: null},
        key: "source:key/alpha?x=1",
        keyName: "Source page",
        highlightedText: '<strong data-legacy-fallback="true">Legacy fallback</strong>',
        osisFragment: {
            xml: '<div><p data-structured="true">Structured OSIS</p></div>',
            key: "GEN.Book--annotate:key",
            keyName: "Structured source",
            v11n: null,
            bookCategory: "GENERAL_BOOK",
            bookInitials: "GEN.Book",
            bookAbbreviation: "GEN",
            osisRef: "annotate:key",
            isNewTestament: false,
            features: {},
            hasStrongs: false,
            ordinalRange: null,
            language: "en",
            direction: "ltr",
        },
    };
}

/**
 * Builds the pseudo-label styling expected by ambiguous AI marker presentation.
 *
 * @returns A complete flattened label/style record with the robot icon.
 */
function aiLabelFixture(): LabelAndStyle {
    const style = {
        color: 0x6464ff,
        isSpeak: false,
        isParagraphBreak: false,
        underline: false,
        underlineWholeVerse: false,
        markerStyle: true,
        markerStyleWholeVerse: true,
        hideStyle: false,
        hideStyleWholeVerse: false,
        customIcon: "robot",
    };
    return {
        id: "ai-label",
        name: "AI document",
        style,
        isRealLabel: false,
        ...style,
    };
}

/**
 * Creates shared reactive bookmark state for component tests.
 *
 * @param bookmarks Initial normal bookmarks or AI markers.
 * @returns Minimal provider state matching fields consumed by action and bookmark composables.
 */
function bookmarkProvider(bookmarks: BaseBookmark[] = []) {
    return {
        bookmarks: ref([...bookmarks]),
        bookmarkMap: new Map(bookmarks.map(bookmark => [bookmark.id, bookmark])),
        bookmarkLabels: new Map([["ai-label", aiLabelFixture()]]),
        labelsUpdated: ref(0),
        updateBookmarks: vi.fn(),
    };
}

/**
 * Builds common Vue providers with bridge spies supplied by each test.
 *
 * @param android Native bridge method test doubles.
 * @param globalBookmarks Reactive bookmark provider.
 * @returns Symbol-keyed providers consumed by production components.
 */
function commonProviders(android: Record<string, unknown>, globalBookmarks = bookmarkProvider()) {
    return {
        [androidKey]: android,
        [appSettingsKey]: {
            monochromeMode: false,
            nightMode: false,
            notesContentType: "MARKDOWN",
            errorBox: false,
        },
        [calculatedConfigKey]: ref({}),
        [configKey]: {
            bookmarksHideLabels: [],
            showAiDocMarkers: true,
            showBookmarks: true,
            showMyNotes: true,
        },
        [globalBookmarksKey]: globalBookmarks,
        [stringsKey]: strings,
    };
}

/** Opens an exposed action menu against deterministic viewport geometry. */
async function openActionMenu(wrapper: VueWrapper) {
    const anchor = document.createElement("button");
    vi.spyOn(anchor, "getBoundingClientRect").mockReturnValue({
        x: 20,
        y: 20,
        top: 20,
        right: 38,
        bottom: 38,
        left: 20,
        width: 18,
        height: 18,
        toJSON: () => ({}),
    } as DOMRect);
    await (wrapper.vm as unknown as {openMenu: (element: HTMLElement) => Promise<void>}).openMenu(anchor);
    await nextTick();
}

afterEach(() => {
    document.body.innerHTML = "";
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
});

describe("reader modal accessibility", () => {
    /** Close sources implemented directly by the shared ModalDialog component. */
    const modalOwnedClosePaths = ["toolbar", "backdrop", "escape", "registered"] as const;

    /**
     * Protects the shared modal's icon-only dismissal control for VoiceOver and keyboard users.
     *
     * The mounted production component receives the localized string provider used by BibleView.
     * A passing test proves the visible close glyph exposes one named button and retains the same
     * close event; failure means assistive technology can no longer identify or activate dismissal.
     */
    it("names the standard dismissal button with the localized cancel command", async () => {
        vi.stubGlobal("ResizeObserver", class {
            observe() {}
            unobserve() {}
            disconnect() {}
        });
        const register = vi.fn();
        const wrapper = mount(ModalDialog, {
            slots: {default: "Reader modal body"},
            global: {
                provide: {
                    ...commonProviders({}),
                    [modalKey]: {
                        register,
                        closeModals: vi.fn(),
                        modalOpen: ref(false),
                    },
                },
                stubs: {
                    FontAwesomeIcon: FontAwesomeIconStub,
                    teleport: true,
                },
            },
        });
        await nextTick();

        const closeButton = wrapper.get("button.modal-action-button");
        expect(closeButton.attributes("aria-label")).toBe("Cancel");
        expect(closeButton.attributes("title")).toBe("Cancel");
        await closeButton.trigger("click");
        expect(wrapper.emitted("close")).toHaveLength(1);
        expect(register).toHaveBeenCalledOnce();
        wrapper.unmount();
    });

    /**
     * Protects focus resignation and save ordering for every ModalDialog-owned close path.
     *
     * Each case focuses a real input inside the mounted modal, then activates the toolbar,
     * backdrop, Escape listener, or registered modal-stack callback. Blur must run before the
     * parent close listener so editor save-on-blur work completes before Vue unmounts the content;
     * failure means WebKit can leave the software keyboard covering the restored reader.
     */
    it.each(modalOwnedClosePaths)("blurs owned focus before the %s path closes", async closePath => {
        vi.stubGlobal("ResizeObserver", class {
            observe() {}
            unobserve() {}
            disconnect() {}
        });
        const frameCallbacks: FrameRequestCallback[] = [];
        const requestAnimationFrame = vi.fn((callback: FrameRequestCallback) => {
            frameCallbacks.push(callback);
            return frameCallbacks.length;
        });
        vi.stubGlobal("requestAnimationFrame", requestAnimationFrame);
        const order: string[] = [];
        const onClose = vi.fn(() => order.push("close"));
        const register = vi.fn();
        const wrapper = mount(ModalDialog, {
            attachTo: document.body,
            props: {
                blocking: closePath === "backdrop",
                onClose,
            },
            slots: {default: '<input data-test="modal-editor">'},
            global: {
                provide: {
                    ...commonProviders({}),
                    [modalKey]: {
                        register,
                        closeModals: vi.fn(),
                        modalOpen: ref(false),
                    },
                },
                stubs: {
                    FontAwesomeIcon: FontAwesomeIconStub,
                    teleport: true,
                },
            },
        });
        await flushPromises();

        const editor = wrapper.get('[data-test="modal-editor"]').element as HTMLInputElement;
        editor.addEventListener("blur", () => order.push("blur"), {once: true});
        editor.focus();
        expect(document.activeElement).toBe(editor);

        switch (closePath) {
            case "toolbar": {
                const closeButton = wrapper.get("button.modal-action-button");
                const mouseDown = new MouseEvent("mousedown", {bubbles: true, cancelable: true});
                closeButton.element.dispatchEvent(mouseDown);
                expect(mouseDown.defaultPrevented).toBe(true);
                expect(document.activeElement).toBe(editor);
                await closeButton.trigger("click");
                break;
            }
            case "backdrop":
                await wrapper.get(".modal-backdrop").trigger("click");
                break;
            case "escape":
                document.dispatchEvent(new KeyboardEvent("keyup", {key: "Escape"}));
                await nextTick();
                break;
            case "registered": {
                const registration = register.mock.calls[0]?.[0] as {close: () => void};
                registration.close();
                await nextTick();
                break;
            }
        }

        expect(order).toEqual(["blur"]);
        expect(onClose).not.toHaveBeenCalled();
        expect(wrapper.emitted("close")).toBeUndefined();
        expect(requestAnimationFrame).toHaveBeenCalledOnce();
        frameCallbacks[0]?.(0);
        await nextTick();

        expect(order).toEqual(["blur", "close"]);
        expect(onClose).toHaveBeenCalledOnce();
        expect(wrapper.emitted("close")).toHaveLength(1);
        wrapper.unmount();
    });

    /**
     * Protects focus owned by reader content behind a modal during programmatic dismissal.
     *
     * The background input is attached to the document while the mounted modal contains no active
     * editor. Closing through the registered modal-stack callback must still emit once but must not
     * blur unrelated focus; failure means opening or replacing a nonblocking modal can disrupt a
     * reader control outside the closing card.
     */
    it("does not blur focus outside the closing modal", async () => {
        vi.stubGlobal("ResizeObserver", class {
            observe() {}
            unobserve() {}
            disconnect() {}
        });
        const backgroundInput = document.createElement("input");
        document.body.appendChild(backgroundInput);
        const backgroundBlur = vi.fn();
        backgroundInput.addEventListener("blur", backgroundBlur);
        const onClose = vi.fn();
        const register = vi.fn();
        const wrapper = mount(ModalDialog, {
            attachTo: document.body,
            attrs: {onClose},
            slots: {default: "Reader modal body"},
            global: {
                provide: {
                    ...commonProviders({}),
                    [modalKey]: {
                        register,
                        closeModals: vi.fn(),
                        modalOpen: ref(false),
                    },
                },
                stubs: {
                    FontAwesomeIcon: FontAwesomeIconStub,
                    teleport: true,
                },
            },
        });
        await flushPromises();

        backgroundInput.focus();
        expect(document.activeElement).toBe(backgroundInput);
        const registration = register.mock.calls[0]?.[0] as {close: () => void};
        registration.close();
        await nextTick();

        expect(backgroundBlur).not.toHaveBeenCalled();
        expect(document.activeElement).toBe(backgroundInput);
        expect(onClose).toHaveBeenCalledOnce();
        expect(wrapper.emitted("close")).toHaveLength(1);
        wrapper.unmount();
    });

    /**
     * Protects deferred close ownership when a parent replaces a modal before WebKit's next frame.
     *
     * Two registered close requests while an editor is focused must share one frame. Unmounting
     * cancels that frame, and even a stale callback invocation must not emit into replacement
     * state; failure can close a newer modal that reused the parent's close listener.
     */
    it("cancels one coalesced deferred close when the modal unmounts", async () => {
        vi.stubGlobal("ResizeObserver", class {
            observe() {}
            unobserve() {}
            disconnect() {}
        });
        const frameCallbacks = new Map<number, FrameRequestCallback>();
        const requestAnimationFrame = vi.fn((callback: FrameRequestCallback) => {
            const handle = frameCallbacks.size + 1;
            frameCallbacks.set(handle, callback);
            return handle;
        });
        const cancelAnimationFrame = vi.fn((handle: number) => frameCallbacks.delete(handle));
        vi.stubGlobal("requestAnimationFrame", requestAnimationFrame);
        vi.stubGlobal("cancelAnimationFrame", cancelAnimationFrame);
        const onClose = vi.fn();
        const register = vi.fn();
        const wrapper = mount(ModalDialog, {
            attachTo: document.body,
            attrs: {onClose},
            slots: {default: '<input data-test="modal-editor">'},
            global: {
                provide: {
                    ...commonProviders({}),
                    [modalKey]: {
                        register,
                        closeModals: vi.fn(),
                        modalOpen: ref(false),
                    },
                },
                stubs: {
                    FontAwesomeIcon: FontAwesomeIconStub,
                    teleport: true,
                },
            },
        });
        await flushPromises();

        const editor = wrapper.get('[data-test="modal-editor"]').element as HTMLInputElement;
        editor.focus();
        const registration = register.mock.calls[0]?.[0] as {close: () => void};
        registration.close();
        registration.close();

        expect(requestAnimationFrame).toHaveBeenCalledOnce();
        const staleCallback = frameCallbacks.get(1);
        wrapper.unmount();
        expect(cancelAnimationFrame).toHaveBeenCalledWith(1);
        expect(frameCallbacks.size).toBe(0);

        staleCallback?.(0);
        await nextTick();
        expect(onClose).not.toHaveBeenCalled();
        expect(wrapper.emitted("close")).toBeUndefined();
    });

    /**
     * Protects the production bookmark modal's reference-specific editor naming contract.
     *
     * Setup emits the real shared `bookmark_clicked` event with `openNotes=true` for a Genesis 1:1
     * bookmark. The modal must forward a localized name into `EditableText`; failure means Pell
     * omits its textbox role/name and the software-keyboard workflow becomes inaccessible and
     * untestable. Listener cleanup occurs when the wrapper unmounts.
     */
    it("passes the selected Bible reference to the bookmark note editor", async () => {
        const bookmark = bibleBookmarkFixture();
        const wrapper = mount(BookmarkModal, {
            global: {
                provide: commonProviders(
                    {openAiDocPage: vi.fn(), saveBookmarkNote: vi.fn()},
                    bookmarkProvider([bookmark]),
                ),
                stubs: {
                    BookmarkButtons: true,
                    BookmarkText: true,
                    EditableText: {
                        name: "EditableText",
                        props: ["editorAccessibilityLabel"],
                        template: '<div data-test="bookmark-note-editor"></div>',
                    },
                    FontAwesomeIcon: FontAwesomeIconStub,
                    LabelList: true,
                    ModalDialog: {template: '<div data-test="bookmark-modal"><slot/></div>'},
                },
            },
        });

        emit("bookmark_clicked", bookmark.id, {openNotes: true});
        await nextTick();

        const editor = wrapper.getComponent({name: "EditableText"});
        expect(editor.props("editorAccessibilityLabel")).toBe(
            "My Notes note editor for Genesis 1:1",
        );
        wrapper.unmount();
    });
});

describe("generic document action parity", () => {
    /**
     * Protects selection-free whole-page bookmark and existing My Documents copy/share contracts.
     *
     * A real menu button click must preserve Android's exact two-field source/key bookmark command,
     * while copy/share retain exact My Documents initials and rendered page reference.
     * AI deletion remains available for source-prompt pages, while regeneration stays hidden until
     * the iOS host has a production generation backend. Failure means a visible control is wired to
     * inferred payload data or to a native command that cannot complete.
     */
    it("sends exact whole-page, copy, and share payloads from real menu clicks", async () => {
        const android = {
            copyMyDocumentContent: vi.fn(),
            createWholePageBookmark: vi.fn(),
            regenerateMyDocumentPage: vi.fn(),
            shareMyDocumentContent: vi.fn(),
        };
        const document = documentFixture({
            isMyDocument: true,
            myDocumentPageId: "persisted-page-id",
            sourcePromptId: "source-prompt-id",
        });
        const wrapper = mount(DocumentActionMenu, {
            props: {document},
            global: {
                provide: commonProviders(android),
                stubs: {FontAwesomeIcon: FontAwesomeIconStub},
            },
        });

        await openActionMenu(wrapper);
        await wrapper.get('[data-action="create-whole-page-bookmark"]').trigger("click");
        expect(android.createWholePageBookmark).toHaveBeenCalledWith(
            "GEN.Book",
            "annotate:key",
        );

        await openActionMenu(wrapper);
        await wrapper.get('[data-action="share-my-document"]').trigger("click");
        expect(android.shareMyDocumentContent).toHaveBeenCalledWith("GEN.Book", "page:key/alpha?x=1");

        await openActionMenu(wrapper);
        await wrapper.get('[data-action="copy-my-document"]').trigger("click");
        expect(android.copyMyDocumentContent).toHaveBeenCalledWith("GEN.Book", "page:key/alpha?x=1");

        await openActionMenu(wrapper);
        expect(wrapper.find('[data-action="regenerate-ai-document"]').exists()).toBe(false);
        expect(wrapper.find('[data-action="delete-ai-document"]').exists()).toBe(true);

        wrapper.unmount();
    });

    /**
     * Protects the normal document action-menu AI marker branch from opening bookmark details.
     *
     * The visible marker is matched by source identity, then an actual click must call native AI
     * navigation with its exact, distinct document/key pair. Failure indicates marker identity was
     * replaced by the source page identity.
     */
    it("opens a whole-page AI marker with its exact document and key", async () => {
        const marker = aiMarkerFixture();
        const android = {createWholePageBookmark: vi.fn(), openAiDocPage: vi.fn()};
        const wrapper = mount(WholePageBookmarks, {
            props: {
                bookInitials: "GEN.Book",
                bookKey: "annotate:key",
            },
            global: {
                provide: commonProviders(android, bookmarkProvider([marker])),
                stubs: {FontAwesomeIcon: FontAwesomeIconStub},
            },
        });

        await wrapper.get('[data-action="open-ai-document"]').trigger("click");

        expect(android.openAiDocPage).toHaveBeenCalledWith("AI.Documents", "page:key/42");
        expect(android.createWholePageBookmark).not.toHaveBeenCalled();
        wrapper.unmount();
    });
});

describe("generic bookmark source rendering parity", () => {
    /**
     * Protects Android's structured `OsisFragment`/`OsisSegment` path for generic bookmarks.
     *
     * The structured fragment must reach `OsisFragment` with title suppression, while the legacy
     * raw HTML fallback must not mount. Failure means native OSIS metadata is discarded in favor of
     * unstructured highlighted HTML.
     */
    it("renders GenericBookmark.osisFragment through OsisFragment", () => {
        const bookmark = genericBookmarkFixture();
        const wrapper = mount(BookmarkText, {
            props: {bookmark, expanded: true},
            global: {
                provide: commonProviders({}),
                stubs: {
                    AmbiguousSelection: true,
                    OsisFragment: {
                        name: "OsisFragment",
                        props: {
                            fragment: {type: Object, required: true},
                            hideTitles: {type: Boolean, default: false},
                        },
                        template: '<div data-test="structured-osis">{{ fragment.key }}</div>',
                    },
                },
            },
        });

        expect(wrapper.get('[data-test="structured-osis"]').text()).toBe(
            "GEN.Book--annotate:key",
        );
        expect(wrapper.find('[data-legacy-fallback="true"]').exists()).toBe(false);
        const fragment = wrapper.getComponent({name: "OsisFragment"});
        expect(fragment.props("fragment")).toEqual(bookmark.osisFragment);
        expect(fragment.props("hideTitles")).toBe(true);
        wrapper.unmount();
    });
});

describe("AI marker modal parity", () => {
    /**
     * Protects the ambiguous chooser's AI-specific presentation and exact click route.
     *
     * The marker renders its range/title without editable bookmark controls. Clicking the rendered
     * choice must navigate natively using the marker's document/key payload. Failure means AI
     * markers are being treated as editable persisted bookmarks in the ambiguous path.
     */
    it("renders and opens an ambiguous AI marker from an actual click", async () => {
        const marker = aiMarkerFixture();
        const android = {openAiDocPage: vi.fn()};
        const wrapper = mount(AmbiguousSelectionBookmarkButton, {
            props: {bookmarkId: marker.id},
            global: {
                provide: {
                    ...commonProviders(android, bookmarkProvider([marker])),
                    [locateTopKey]: ref(false),
                },
                stubs: {
                    BookmarkButtons: {template: '<div data-test="bookmark-buttons"></div>'},
                    FontAwesomeIcon: FontAwesomeIconStub,
                    LabelList: true,
                },
            },
        });

        expect(wrapper.text()).toContain("Gen 1:12");
        expect(wrapper.text()).toContain("Explain this verse");
        expect(wrapper.find('[data-test="bookmark-buttons"]').exists()).toBe(false);

        await wrapper.get(".ambiguous-button").trigger("click");

        expect(android.openAiDocPage).toHaveBeenCalledWith("AI.Documents", "page:key/42");
        wrapper.unmount();
    });

    /**
     * Protects the shared normal bookmark event path when an AI marker reaches `BookmarkModal`.
     *
     * The event must bypass modal rendering and forward the exact marker target. This test covers
     * marker-icon clicks emitted elsewhere in the document pipeline; listener cleanup occurs on
     * unmount so no cross-test event state remains.
     */
    it("bypasses bookmark modal state for AI marker events", async () => {
        const marker = aiMarkerFixture();
        const android = {openAiDocPage: vi.fn(), saveBookmarkNote: vi.fn()};
        const wrapper = mount(BookmarkModal, {
            global: {
                provide: commonProviders(android, bookmarkProvider([marker])),
                stubs: {
                    BookmarkButtons: true,
                    BookmarkText: true,
                    EditableText: true,
                    FontAwesomeIcon: FontAwesomeIconStub,
                    LabelList: true,
                    ModalDialog: {template: "<div data-test=\"bookmark-modal\"><slot/></div>"},
                },
            },
        });

        emit("bookmark_clicked", marker.id);
        await nextTick();

        expect(android.openAiDocPage).toHaveBeenCalledWith("AI.Documents", "page:key/42");
        expect(wrapper.find('[data-test="bookmark-modal"]').exists()).toBe(false);
        wrapper.unmount();
    });
});

describe("generic document metadata parity", () => {
    /**
     * Protects commentary range display and exact AI source-prompt navigation.
     *
     * A source prompt ID produces a clickable bridge action carrying that exact ID. A page without
     * an ID keeps the prompt name as plain text so it cannot expose a dead navigation control.
     */
    it("renders commentaryRange.name and links only identified AI source prompts", async () => {
        const globalBookmarks = bookmarkProvider();
        const android = {
            getMyDocumentPageRawContent: vi.fn(),
            openPromptEditor: vi.fn(),
            reloadMyDocumentPage: vi.fn(),
            saveMyDocumentPageContent: vi.fn(),
        };
        const document = documentFixture({
            bookCategory: "COMMENTARY",
            isAiDocument: true,
            sourcePromptId: "prompt-id",
            sourcePromptName: "Historical context",
            sourceModelName: "Model Exact",
            commentaryRange: {
                startOsisRef: "Gen.1.1",
                endOsisRef: "Gen.1.3",
                name: "Genesis 1:1-3",
            },
        });
        const mountDocument = (currentDocument: OsisDocument) => mount(OsisDocumentComponent, {
            props: {document: currentDocument},
            global: {
                provide: {
                    ...commonProviders(android, globalBookmarks),
                    [customCssKey]: {registerBook: vi.fn()},
                },
                stubs: {
                    AreYouSure: true,
                    DocumentActionMenu: {
                        template: "<div></div>",
                        methods: {openMenu: vi.fn()},
                    },
                    FeaturesLink: true,
                    FontAwesomeIcon: FontAwesomeIconStub,
                    OpenAllLink: true,
                    OsisFragment: {
                        props: ["fragment"],
                        template: '<div id="frag-document-test">Rendered commentary</div>',
                    },
                },
            },
        });
        const wrapper = mountDocument(document);

        await flushPromises();

        expect(wrapper.get(".commentary-range").text()).toBe("Genesis 1:1-3");
        expect(wrapper.get(".ai-footer").text()).toContain("Historical context");
        expect(wrapper.get(".ai-footer").text()).toContain("Model Exact");
        const sourcePromptLink = wrapper.get(".ai-footer a.prompt-link");
        expect(sourcePromptLink.attributes("href")).toBeUndefined();
        await sourcePromptLink.trigger("click");
        expect(android.openPromptEditor).toHaveBeenCalledOnce();
        expect(android.openPromptEditor).toHaveBeenCalledWith("prompt-id");
        wrapper.unmount();

        const fallbackWrapper = mountDocument({
            ...document,
            sourcePromptId: null,
        });
        await flushPromises();

        expect(fallbackWrapper.find(".ai-footer a.prompt-link").exists()).toBe(false);
        expect(fallbackWrapper.get(".ai-footer > span:not(.model-name)").text()).toBe("Historical context");
        fallbackWrapper.unmount();
    });
});
