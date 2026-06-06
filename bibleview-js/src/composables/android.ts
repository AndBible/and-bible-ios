/*
 * Copyright (c) 2022-2022 Martin Denham, Tuomas Airaksinen and the AndBible contributors.
 *
 * This file is part of AndBible: Bible Study (http://github.com/AndBible/and-bible).
 *
 * AndBible is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software Foundation,
 * either version 3 of the License, or (at your option) any later version.
 *
 * AndBible is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with AndBible.
 * If not, see http://www.gnu.org/licenses/.
 */

/* eslint-disable no-undef */
import {emit} from "@/eventbus";
import {Deferred, rangeInside, setupDocumentEventListener, sleep, stubsFor} from "@/utils";
import {onMounted, reactive, Ref} from "vue";
import {calculateOffsetToVerse, ReachedRootError} from "@/dom";
import {isFunction, union} from "lodash";
import {Config, errorBox} from "@/composables/config";
import {AsyncFunc, StudyPadEntryType, JSONString, LogEntry, Nullable} from "@/types/common";
import {
    BaseBookmark,
    CombinedRange,
    EditAction,
    StudyPadBibleBookmarkItem,
    StudyPadGenericBookmarkItem,
    StudyPadItem,
    StudyPadTextItem
} from "@/types/client-objects";
import {AnyDocument, ReadingProgressSettings} from "@/types/documents";
import {isBibleBookmark, isGenericBookmark} from "@/composables/bookmarks";

export type ReadingProgressSource = "MANUAL" | "AUTO_SCROLL" | "AUTO_TTS"

export type BibleJavascriptInterface = {
    scrolledToOrdinal: (key: string, ordinal: number, atChapterTop: boolean) => void,
    setClientReady: () => void,
    setLimitAmbiguousModalSize: (value: boolean) => void,
    requestMoreToBeginning: AsyncFunc,
    requestMoreToEnd: AsyncFunc,
    refChooserDialog: AsyncFunc,
    parseRef: (callId: number, s: String) => void,
    getMyDocumentPageRawContent: (callId: number, bookInitials: string, pageKey: string) => void,
    saveMyDocumentPageContent: (bookInitials: string, pageId: string, content: string, title: string | null) => void,
    reloadMyDocumentPage: (bookInitials: string) => void,
    regenerateMyDocumentPage: (pageId: string) => void,
    deleteMyDocumentPage: (pageId: string) => void,
    saveBookmarkNote: (bookmarkId: IdType, note: Nullable<string>) => void,
    saveGenericBookmarkNote: (bookmarkId: IdType, note: Nullable<string>) => void,
    removeBookmark: (bookmarkId: IdType) => void,
    removeGenericBookmark: (bookmarkId: IdType) => void,
    assignLabels: (bookmarkId: IdType) => void,
    genericAssignLabels: (bookmarkId: IdType) => void,
    console: (loggerName: string, message: string) => void
    selectionCleared: () => void,
    reportInputFocus: (newValue: boolean) => void,
    openExternalLink: (link: string) => void,
    openEpubLink: (bookInitials: string, toKey: string, toId: string) => void,
    openDownloads: () => void,
    setEditing: (enabled: boolean) => void,
    createNewStudyPadEntry: (labelId: IdType, entryType?: StudyPadEntryType, afterEntryId?: IdType) => void,
    deleteStudyPadEntry: (studyPadId: IdType) => void,
    removeBookmarkLabel: (bookmarkId: IdType, labelId: IdType) => void,
    removeGenericBookmarkLabel: (bookmarkId: IdType, labelId: IdType) => void,
    updateOrderNumber: (labelId: IdType, data: JSONString) => void,
    setStudyPadCursor: (labelId: IdType, orderNumber: number) => void,
    getActiveLanguages: () => string,
    toast: (text: string) => void,
    updateStudyPadTextEntry: (data: JSONString) => void,
    updateStudyPadTextEntryText: (id: IdType, text: string) => void,
    updateBookmarkToLabel: (data: JSONString) => void
    updateGenericBookmarkToLabel: (data: JSONString) => void
    shareBookmarkVerse: (bookmarkId: IdType) => void,
    shareVerse: (bookInitials: string, startOrdinal: number, endOrdinal: number) => void,
    copyVerse: (bookInitials: string, startOrdinal: number, endOrdinal: number) => void,
    shareMyDocumentContent: (bookInitials: string, pageKey: string) => void,
    copyMyDocumentContent: (bookInitials: string, pageKey: string) => void,
    addBookmark: (bookInitials: string, startOrdinal: number, endOrdinal: number, addNote: boolean) => void,
    addGenericBookmark: (bookInitials: string, osisRef: string, startOrdinal: number, endOrdinal: number, addNote: boolean) => void,
    addParagraphBreakBookmark: (bookInitials: string, startOrdinal: number, endOrdinal: number) => void,
    addGenericParagraphBreakBookmark: (bookInitials: string, osisRef: string, startOrdinal: number, endOrdinal: number) => void,
    compare: (bookInitials: string, verseOrdinal: number, endOrdinal: number) => void,
    memorize: (bookInitials: string, verseOrdinal: number, endOrdinal: number) => void,
    markAsMemorized: (bookInitials: string, startOrdinal: number, endOrdinal: number) => void,
    addMemorizationTarget: (bookInitials: string, startOrdinal: number, endOrdinal: number) => void,
    unmarkMemorized: (bookInitials: string, startOrdinal: number, endOrdinal: number) => void,
    removeMemorizationTarget: (bookInitials: string, startOrdinal: number, endOrdinal: number) => void,
    openReadingProgress: (tab: number) => void,
    openReadingProgressSettings: () => void,
    recordChapterRead: (bookInitials: string, startOrdinal: number, chapter: number, source: ReadingProgressSource) => void,
    markChapterRead: (bookInitials: string, startOrdinal: number, chapter: number, source: ReadingProgressSource) => void,
    unmarkChapterRead: (bookInitials: string, startOrdinal: number, chapter: number) => void,
    openChapterReadHistory: (bookInitials: string, startOrdinal: number, chapter: number) => void,
    goToNextChapter: () => void,
    goToPreviousChapter: () => void,
    openStudyPad: (labelId: IdType, bookmarkId: IdType) => void,
    openMyNotes: (v11n: string, ordinal: number) => void,
    speak: (bookInitials: string, v11n: string, startOrdinal: number, endOrdinal: number) => void,
    speakGeneric: (bookInitials: string, osisRef: string, startOrdinal: number, endOrdinal: number) => void,
    speakMemorizationLoop: (bookInitials: string, v11n: string, startOrdinal: number, endOrdinal: number) => void,
    setAsPrimaryLabel: (bookmarkId: IdType, labelId: IdType) => void,
    setAsPrimaryLabelGeneric: (bookmarkId: IdType, labelId: IdType) => void,
    toggleBookmarkLabel: (bookmarkId: IdType, labelId: IdType) => void,
    toggleGenericBookmarkLabel: (bookmarkId: IdType, labelId: IdType) => void,
    reportModalState: (value: boolean) => void,
    querySelection: (bookmarkId: IdType, value: boolean) => void,
    setBookmarkWholeVerse: (bookmarkId: IdType, value: boolean) => void,
    setGenericBookmarkWholeVerse: (bookmarkId: IdType, value: boolean) => void,
    setBookmarkCustomIcon: (bookmarkId: IdType, value: Nullable<string>) => void,
    setBookmarkEditAction: (bookmarkId: IdType, value: string) => void,
    setGenericBookmarkCustomIcon: (bookmarkId: IdType, value: Nullable<string>) => void,
    toggleCompareDocument: (documentId: string) => void,
    helpDialog: (content: string, title: Nullable<string>) => void,
    shareHtml: (html: string) => void,
    helpBookmarks: () => void,
    onKeyDown: (key: string) => void,
    saveState: (newState: string) => void,
    setReadingProgressSettings: (json: string) => void,
}

export type MyDocumentPageRawContent = {
    pageId: string,
    contentType: string,
    content: string,
    title: string,
    sourcePromptId: Nullable<string>,
}

export type UseAndroid = ReturnType<typeof useAndroid>

let callId = 0;

export const logEntries = reactive<LogEntry[]>([])

const logEntriesTemp: LogEntry[] = [];

function addLog(logEntry: Pick<LogEntry, "type" | "msg">) {
    const previous = logEntriesTemp.find(v => v.msg === logEntry.msg && v.type === logEntry.type);
    if (previous) {
        previous.count++;
        return;
    }
    logEntriesTemp.push({...logEntry, count: 1});
}

let logSyncEnabled = false;

export async function enableLogSync(value: boolean) {
    logSyncEnabled = value;
    while (logSyncEnabled) {
        await sleep(1000)
        if (logEntriesTemp.length > logEntries.length) {
            logEntries.push(...logEntriesTemp.slice(logEntries.length, logEntriesTemp.length));
        }
    }
}

export function clearLog() {
    logEntriesTemp.splice(0);
    logEntries.splice(0);
}

export function patchAndroidConsole() {
    const origConsole = window.console;
    const android = window.android as BibleJavascriptInterface | undefined;
    window.bibleViewDebug.logEntries = logEntries;
    // Override normal console, so that argument values also propagate to Android logcat
    const enableAndroidLogging = process.env.NODE_ENV !== "development";
    window.console = {
        ...origConsole,
        _msg(s, args) {
            const printableArgs = args.map(v => isFunction(v) ? v : v ? JSON.stringify(v).slice(0, 500) : v);
            return `${s} ${printableArgs}`
        },
        flog(s, ...args) {
            if (enableAndroidLogging && errorBox && android) android.console('flog', this._msg(s, args))
            origConsole.log(this._msg(s, args))
        },
        log(s, ...args) {
            if (enableAndroidLogging && errorBox && android) android.console('log', this._msg(s, args))
            origConsole.log(s, ...args)
        },
        error(s, ...args) {
            if (errorBox) {
                addLog({type: "ERROR", msg: this._msg(s, args)});
                if (enableAndroidLogging && android) android.console('error', this._msg(s, args))
            }
            origConsole.error(s, ...args)
        },
        warn(s, ...args) {
            if (errorBox) {
                addLog({type: "WARN", msg: this._msg(s, args)});
                if (enableAndroidLogging && android) android.console('warn', this._msg(s, args))
            }
            origConsole.warn(s, ...args)
        }
    }
}

export type QuerySelection = {
    bookInitials: string
    osisRef: string
    startOrdinal: number,
    startOffset: number,
    endOrdinal: number,
    endOffset: number,
    bookmarks: IdType[],
    text: string
}

export function useAndroid({bookmarks}: { bookmarks: Ref<BaseBookmark[]> }, config: Config) {
    const responsePromises = new Map();
    // The production app injects this bridge before the webview boots. Development
    // mode returns stubs later, so a central assertion is less noisy than optional
    // checks at every native callsite.
    const android = window.android as BibleJavascriptInterface;

    function response(callId: number, returnValue: any) {
        const val = responsePromises.get(callId);
        if (val) {
            const {promise, func} = val;
            responsePromises.delete(callId);
            console.log("Returning response from async android function: ", func, callId, returnValue);
            promise.resolve(returnValue);
        } else {
            console.error("Promise not found for callId", callId)
        }
    }

    function querySelection(): QuerySelection | string | null {
        const selection = window.getSelection()!;
        if (selection.rangeCount < 1 || selection.isCollapsed) return null;
        const selectionOnly = selection.toString();
        const range = selection.getRangeAt(0)!;
        const documentElem: HTMLElement = range.startContainer.parentElement!.closest(".document")!;
        if (!documentElem) {
            console.log(`querySelection: returning only selection ${selectionOnly}`)
            return selectionOnly
        }

        const bookInitials = documentElem.dataset.bookInitials!;
        const osisRef = documentElem.dataset.osisRef!;
        let startOrdinal: number, startOffset: number, endOrdinal: number, endOffset: number;

        try {
            ({ordinal: startOrdinal, offset: startOffset} =
                calculateOffsetToVerse(range.startContainer, range.startOffset));

            ({ordinal: endOrdinal, offset: endOffset} =
                calculateOffsetToVerse(range.endContainer, range.endOffset));

        } catch (e) {
            if (e instanceof ReachedRootError) {
                console.log(`querySelection: ReachedRootError, returning only selection ${selectionOnly}`)
                return selectionOnly
            } else {
                throw e;
            }
        }

        function bookmarkRange(b: BaseBookmark): CombinedRange {
            if (!b.ordinalRange) {
                throw new Error("Cannot calculate selection overlap for bookmark without ordinal range");
            }
            const offsetRange = b.offsetRange || [0, null]
            if (b.bookInitials !== bookInitials) {
                offsetRange[0] = 0;
                offsetRange[1] = null;
            }
            return [[b.ordinalRange[0], offsetRange[0]], [b.ordinalRange[1], offsetRange[1]]]
        }

        const filteredBookmarks = bookmarks.value.filter(b =>
            b.ordinalRange && rangeInside(
                bookmarkRange(b),
                [[startOrdinal, startOffset], [endOrdinal, endOffset]]
            )
        );

        const deleteBookmarks = union(filteredBookmarks.map(b => b.id));

        const returnSelection: QuerySelection = {
            bookInitials,
            osisRef,
            startOrdinal,
            startOffset,
            endOrdinal,
            endOffset,
            bookmarks: deleteBookmarks,
            text: selection.toString()
        }

        console.log(`querySelection: returning selection`, {returnSelection})
        return returnSelection;
    }

    window.bibleView.response = response;
    window.bibleView.emit = emit;
    window.bibleView.querySelection = querySelection

    async function deferredCall(func: AsyncFunc): Promise<any> {
        const promise = new Deferred();
        const thisCall = callId++;
        responsePromises.set(thisCall, {func, promise});
        console.log("Calling async android function: ", func, thisCall);
        func(thisCall);
        const returnValue = await promise.wait();
        console.log("Response from async android function: ", thisCall, returnValue);
        return returnValue
    }

    async function requestPreviousChapter(): Promise<Nullable<AnyDocument>> {
        return deferredCall((callId) => android.requestMoreToBeginning(callId));
    }

    async function requestNextChapter(): Promise<Nullable<AnyDocument>> {
        return deferredCall((callId) => android.requestMoreToEnd(callId));
    }

    async function refChooserDialog(): Promise<string> {
        return deferredCall((callId) => android.refChooserDialog(callId));
    }

    function scrolledToOrdinal(key: string, ordinal: Nullable<number>, atChapterTop = false) {
        if (ordinal == null || ordinal < 0) return;
        android.scrolledToOrdinal(key, ordinal, atChapterTop)
    }

    function saveBookmarkNote(bookmark: BaseBookmark, noteText: Nullable<string>) {
        if(isBibleBookmark(bookmark)) {
            android.saveBookmarkNote(bookmark.id, noteText);
        } else if(isGenericBookmark(bookmark)) {
            android.saveGenericBookmarkNote(bookmark.id, noteText);
        }
    }

    function removeBookmark(bookmark: BaseBookmark) {
        if(isBibleBookmark(bookmark)) {
            android.removeBookmark(bookmark.id);
        } else if(isGenericBookmark(bookmark)) {
            android.removeGenericBookmark(bookmark.id);
        }
    }

    function assignLabels(bookmark: BaseBookmark) {
        if (isBibleBookmark(bookmark)) {
            android.assignLabels(bookmark.id);
        } else if(isGenericBookmark(bookmark)) {
            android.genericAssignLabels(bookmark.id);
        }
    }

    function toggleBookmarkLabel(bookmark: BaseBookmark, labelId: IdType) {
        if(isBibleBookmark(bookmark)) {
            android.toggleBookmarkLabel(bookmark.id, labelId);
        } else if(isGenericBookmark(bookmark)) {
            android.toggleGenericBookmarkLabel(bookmark.id, labelId);
        }
    }

    function setClientReady() {
        android.setClientReady();
    }

    function reportInputFocus(value: boolean) {
        android.reportInputFocus(value);
    }

    function openExternalLink(link: string) {
        console.log('[android.ts] openExternalLink called with:', link);
        android.openExternalLink(link);
    }

    function openEpubLink(bookInitials: string, toKey: string, toId: string) {
        android.openEpubLink(bookInitials, toKey, toId);
    }

    function setEditing(value: boolean) {
        android.setEditing(value);
    }

    function createNewStudyPadEntry(labelId: IdType, afterEntryType: StudyPadEntryType = "none", afterEntryId: IdType = "") {
        android.createNewStudyPadEntry(labelId, afterEntryType, afterEntryId);
    }

    function deleteStudyPadEntry(studyPadId: IdType) {
        android.deleteStudyPadEntry(studyPadId);
    }

    function getActiveLanguages(): string[] {
        return JSON.parse(android.getActiveLanguages());
    }

    function removeBookmarkLabel(bookmark: BaseBookmark, labelId: IdType) {
        if(isBibleBookmark(bookmark)) {
            android.removeBookmarkLabel(bookmark.id, labelId);
        } else if(isGenericBookmark(bookmark)) {
            android.removeGenericBookmarkLabel(bookmark.id, labelId);
        }
    }

    function shareBookmarkVerse(bookmark: BaseBookmark) {
        if(isBibleBookmark(bookmark)) {
            android.shareBookmarkVerse(bookmark.id);
        } else {
            console.error("Only bible bookmarks supported for share feature")
        }
    }

    function shareVerse(bookInitials: string, startOrdinal: number, endOrdinal?: number) {
        android.shareVerse(bookInitials, startOrdinal, endOrdinal ?? -1);
    }

    function copyVerse(bookInitials: string, startOrdinal: number, endOrdinal?: number) {
        android.copyVerse(bookInitials, startOrdinal, endOrdinal ?? -1);
    }

    function addBookmark(bookInitials: string, startOrdinal: number, endOrdinal?: number, addNote: boolean = false) {
        android.addBookmark(bookInitials, startOrdinal, endOrdinal ?? -1, addNote);
    }

    function addGenericBookmark(bookInitials: string, osisRef: string, startOrdinal: number, endOrdinal?: number, addNote: boolean = false) {
        android.addGenericBookmark(bookInitials, osisRef, startOrdinal, endOrdinal ?? -1, addNote);
    }

    function addParagraphBreakBookmark(bookInitials: string, startOrdinal: number, endOrdinal?: number) {
        android.addParagraphBreakBookmark(bookInitials, startOrdinal, endOrdinal ?? -1);
    }

    function addGenericParagraphBreakBookmark(bookInitials: string, osisRef: string, startOrdinal: number, endOrdinal?: number) {
        android.addGenericParagraphBreakBookmark(bookInitials, osisRef, startOrdinal, endOrdinal ?? -1);
    }

    function compare(bookInitials: string, startOrdinal: number, endOrdinal?: number) {
        android.compare(bookInitials, startOrdinal, endOrdinal ?? -1);
    }

    function memorize(bookInitials: string, startOrdinal: number, endOrdinal?: number) {
        android.memorize(bookInitials, startOrdinal, endOrdinal ?? -1);
    }

    function markAsMemorized(bookInitials: string, startOrdinal: number, endOrdinal?: number) {
        android.markAsMemorized(bookInitials, startOrdinal, endOrdinal ?? -1);
    }

    function addMemorizationTarget(bookInitials: string, startOrdinal: number, endOrdinal?: number) {
        android.addMemorizationTarget(bookInitials, startOrdinal, endOrdinal ?? -1);
    }

    function unmarkMemorized(bookInitials: string, startOrdinal: number, endOrdinal?: number) {
        android.unmarkMemorized(bookInitials, startOrdinal, endOrdinal ?? -1);
    }

    function removeMemorizationTarget(bookInitials: string, startOrdinal: number, endOrdinal?: number) {
        android.removeMemorizationTarget(bookInitials, startOrdinal, endOrdinal ?? -1);
    }

    function openReadingProgress(tab: number = 0) {
        android.openReadingProgress(tab);
    }

    function openReadingProgressSettings() {
        android.openReadingProgressSettings();
    }

    function recordChapterRead(bookInitials: string, startOrdinal: number, chapter: number, source: ReadingProgressSource) {
        android.recordChapterRead(bookInitials, startOrdinal, chapter, source);
    }

    function markChapterRead(bookInitials: string, startOrdinal: number, chapter: number, source: ReadingProgressSource) {
        android.markChapterRead(bookInitials, startOrdinal, chapter, source);
    }

    function unmarkChapterRead(bookInitials: string, startOrdinal: number, chapter: number) {
        android.unmarkChapterRead(bookInitials, startOrdinal, chapter);
    }

    function openChapterReadHistory(bookInitials: string, startOrdinal: number, chapter: number) {
        android.openChapterReadHistory(bookInitials, startOrdinal, chapter);
    }

    function openStudyPad(labelId: IdType, bookmark: BaseBookmark) {
        if(isBibleBookmark(bookmark) || isGenericBookmark(bookmark)) {
            // Exceptionally here bookmark type does not matter
            android.openStudyPad(labelId, bookmark.id);
        }
    }

    function openMyNotes(v11n: string, ordinal: number) {
        android.openMyNotes(v11n, ordinal);
    }

    function speak(bookInitials: string, v11n: string, startOrdinal: number, endOrdinal?: number) {
        android.speak(bookInitials, v11n, startOrdinal, endOrdinal ?? -1);
    }

    function speakGeneric(bookInitials: string, osisRef: string, startOrdinal: number, endOrdinal?: number) {
        android.speakGeneric(bookInitials, osisRef, startOrdinal, endOrdinal ?? -1);
    }

    function speakMemorizationLoop(bookInitials: string, v11n: string, startOrdinal: number, endOrdinal?: number) {
        android.speakMemorizationLoop(bookInitials, v11n, startOrdinal, endOrdinal ?? -1);
    }

    function openDownloads() {
        android.openDownloads();
    }

    async function parseRef(s: string): Promise<string> {
        const result = await deferredCall((callId) => android.parseRef(callId, s))
        return result ?? ""
    }

    async function getMyDocumentPageRawContent(
        bookInitials: string,
        pageKey: string,
    ): Promise<MyDocumentPageRawContent | null> {
        const result = await deferredCall((callId) => android.getMyDocumentPageRawContent(callId, bookInitials, pageKey))
        return result as MyDocumentPageRawContent | null
    }

    function shareMyDocumentContent(bookInitials: string, pageKey: string) {
        android.shareMyDocumentContent(bookInitials, pageKey);
    }

    function copyMyDocumentContent(bookInitials: string, pageKey: string) {
        android.copyMyDocumentContent(bookInitials, pageKey);
    }

    function saveMyDocumentPageContent(bookInitials: string, pageId: string, content: string, title: string | null) {
        android.saveMyDocumentPageContent(bookInitials, pageId, content, title);
    }

    function reloadMyDocumentPage(bookInitials: string) {
        android.reloadMyDocumentPage(bookInitials);
    }

    function regenerateMyDocumentPage(pageId: string) {
        android.regenerateMyDocumentPage(pageId);
    }

    function deleteMyDocumentPage(pageId: string) {
        android.deleteMyDocumentPage(pageId);
    }

    function updateOrderNumber(
        labelId: IdType,
        bookmarks: StudyPadBibleBookmarkItem[],
        genericBookmarks: StudyPadGenericBookmarkItem[],
        studyPadTextItems: StudyPadTextItem[]
    ) {
        const orderNumberPairs: (l: StudyPadItem[]) => {first: IdType, second: number}[] =
            l => l.map((v: StudyPadItem) => ({first: v.id, second: v.orderNumber}))
        android.updateOrderNumber(labelId, JSON.stringify(
            {
                bookmarks: orderNumberPairs(bookmarks),
                genericBookmarks: orderNumberPairs(genericBookmarks),
                studyPadTextItems: orderNumberPairs(studyPadTextItems)
            })
        );
    }

    function setStudyPadCursor(labelId: IdType, orderNumber: number) {
        android.setStudyPadCursor(labelId, orderNumber);
    }

    function toast(text: string) {
        android.toast(text);
    }

    function updateStudyPadEntry(entry: StudyPadItem, changes: Partial<StudyPadItem>) {
        const changedEntry = {...entry, ...changes}
        if (entry.type === "journal") {
            const {text, ...rest} = changes;
            if(text !== undefined) {
                android.updateStudyPadTextEntryText(entry.id, text);
            }
            if(Object.keys(rest).length > 0) {
                android.updateStudyPadTextEntry(JSON.stringify(changedEntry as StudyPadTextItem));
            }
        } else if (entry.type === "bookmark" || entry.type === "generic-bookmark") {
            const changedBookmarkItem = changedEntry as StudyPadBibleBookmarkItem
            const e = {
                bookmarkId: changedBookmarkItem.id,
                labelId: changedBookmarkItem.bookmarkToLabel.labelId,
                indentLevel: changedBookmarkItem.indentLevel,
                orderNumber: changedBookmarkItem.orderNumber,
                expandContent: changedBookmarkItem.expandContent,
            }
            if(isBibleBookmark(entry)) {
                android.updateBookmarkToLabel(JSON.stringify(e));
            } else if(isGenericBookmark(entry)) {
                android.updateGenericBookmarkToLabel(JSON.stringify(e));
            }
        }
    }

    function setAsPrimaryLabel(bookmark: BaseBookmark, labelId: IdType) {
        if(isBibleBookmark(bookmark)) {
            android.setAsPrimaryLabel(bookmark.id, labelId);
        } else if(isGenericBookmark(bookmark)) {
            android.setAsPrimaryLabelGeneric(bookmark.id, labelId);
        }
    }

    function setBookmarkWholeVerse(bookmark: BaseBookmark, value: boolean) {
        if(isBibleBookmark(bookmark)) {
            android.setBookmarkWholeVerse(bookmark.id, value);
        } else {
            android.setGenericBookmarkWholeVerse(bookmark.id, value);
        }
    }

    function setCustomIcon(bookmark: BaseBookmark, value: Nullable<string>) {
        if(isBibleBookmark(bookmark)) {
            android.setBookmarkCustomIcon(bookmark.id, value);
        } else {
            android.setGenericBookmarkCustomIcon(bookmark.id, value);
        }
    }

    function setEditAction(bookmark: BaseBookmark, value: EditAction) {
        android.setBookmarkEditAction(bookmark.id, JSON.stringify(value));
    }

    function reportModalState(value: boolean) {
        android.reportModalState(value)
    }

    function toggleCompareDocument(docId: string) {
        android.toggleCompareDocument(docId);
    }

    function helpDialog(content: string, title: Nullable<string> = null) {
        android.helpDialog(content, title);
    }

    function helpBookmarks() {
        android.helpBookmarks();
    }

    function setLimitAmbiguousModalSize(value: boolean) {
        android.setLimitAmbiguousModalSize(value);
    }

    function shareHtml(value: string) {
        android.shareHtml(value);
    }

    function onKeyDown(key: string) {
        android.onKeyDown(key);
    }

    function saveState(newState: any) {
        android.saveState(JSON.stringify(newState));
    }

    function setReadingProgressSettings(settings: ReadingProgressSettings) {
        android.setReadingProgressSettings(JSON.stringify(settings));
    }

    /**
     * Requests native chapter navigation when Android-style manual chapter controls are visible.
     */
    function goToNextChapter() {
        android.goToNextChapter();
    }

    /**
     * Requests native previous-chapter navigation when Android-style manual controls are visible.
     */
    function goToPreviousChapter() {
        android.goToPreviousChapter();
    }

    const exposed = {
        shareHtml,
        helpBookmarks,
        setLimitAmbiguousModalSize,
        setEditing,
        reportInputFocus,
        saveBookmarkNote,
        requestPreviousChapter,
        requestNextChapter,
        scrolledToOrdinal,
        setClientReady,
        querySelection,
        removeBookmark,
        assignLabels,
        openExternalLink,
        openEpubLink,
        createNewStudyPadEntry,
        deleteStudyPadEntry,
        removeBookmarkLabel,
        updateOrderNumber,
        setStudyPadCursor,
        updateStudyPadEntry,
        getActiveLanguages,
        toast,
        shareBookmarkVerse,
        openStudyPad,
        getMyDocumentPageRawContent,
        shareMyDocumentContent,
        copyMyDocumentContent,
        saveMyDocumentPageContent,
        reloadMyDocumentPage,
        regenerateMyDocumentPage,
        deleteMyDocumentPage,
        setAsPrimaryLabel,
        toggleBookmarkLabel,
        reportModalState,
        setBookmarkWholeVerse,
        setCustomIcon,
        setEditAction,
        toggleCompareDocument,
        openMyNotes,
        openDownloads,
        refChooserDialog,
        shareVerse,
        copyVerse,
        addBookmark,
        addGenericBookmark,
        addParagraphBreakBookmark,
        addGenericParagraphBreakBookmark,
        compare,
        memorize,
        markAsMemorized,
        addMemorizationTarget,
        unmarkMemorized,
        removeMemorizationTarget,
        openReadingProgress,
        openReadingProgressSettings,
        recordChapterRead,
        markChapterRead,
        unmarkChapterRead,
        openChapterReadHistory,
        speak,
        speakGeneric,
        speakMemorizationLoop,
        helpDialog,
        onKeyDown,
        parseRef,
        saveState,
        setReadingProgressSettings,
        goToNextChapter,
        goToPreviousChapter,
    }

    if (config.developmentMode) return {
        ...stubsFor(exposed, {
            getActiveLanguages: ['he', 'nl', 'en'],
        }),
        querySelection
    } as typeof exposed

    setupDocumentEventListener("selectionchange", () => {
        const sel = window.getSelection()!;
        if (sel.rangeCount > 0 && sel.getRangeAt(0).collapsed) {
            android.selectionCleared();
        }
    });

    onMounted(() => {
        setClientReady();
    });

    return exposed;
}
