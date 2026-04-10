import {Nullable} from "@/types/common";

export function configChangeScrollTarget(
    currentVerse: Nullable<number>,
    currentDocumentId: Nullable<string>,
    atChapterTop: boolean
): Nullable<string> {
    if (atChapterTop) {
        return currentDocumentId ?? "top";
    }
    if (currentVerse != null) {
        return `o-${currentVerse}`;
    }
    return null;
}
