/**
 Chapter identity used by the reader's infinite-scroll range coordinator.

 - Side effects: None; this is a value payload.
 - Failure modes: None; callers provide only already-normalized book/chapter values.
 */
struct BibleReaderInfiniteScrollChapter: Equatable {
    /// Display book name from the active reader versification.
    let book: String

    /// One-based chapter number within `book`.
    let chapter: Int
}

/**
 Owns the reader-local loaded chapter range used by Vue infinite scroll.

 Android keeps the currently loaded Bible window range separate from current-page navigation state:
 prepend/append requests ask for the adjacent chapter, and the range advances only when the
 adjacent document was actually loaded. This coordinator keeps that state rule out of
 `BibleReaderController` while leaving document construction and bridge responses with the
 controller.

 - Side effects: Mutates only the in-memory lower/upper loaded range.
 - Failure modes: Returns `nil` when there is no adjacent book or chapter. Failed document loading is
   reported by simply not committing the candidate, so the range remains unchanged.
 */
struct BibleReaderInfiniteScrollCoordinator {
    /// Earliest chapter currently loaded in the WebView.
    private var lowerBound = BibleReaderInfiniteScrollChapter(book: "Genesis", chapter: 1)

    /// Latest chapter currently loaded in the WebView.
    private var upperBound = BibleReaderInfiniteScrollChapter(book: "Genesis", chapter: 1)

    /**
     Resets the loaded range to the currently rendered Bible chapter.

     - Parameters:
       - book: Display book name from the active module versification.
       - chapter: One-based chapter number.
     - Side effects: Replaces both range bounds.
     - Failure modes: None; invalid values remain caller responsibility, matching the previous
       controller-owned state.
     */
    mutating func reset(book: String, chapter: Int) {
        let chapter = BibleReaderInfiniteScrollChapter(book: book, chapter: chapter)
        lowerBound = chapter
        upperBound = chapter
    }

    /**
     Resolves the chapter immediately before the current lower loaded bound.

     - Parameters:
       - previousBook: Lookup for the previous book in the active module versification.
       - chapterCount: Lookup for the final chapter number of a book.
     - Returns: Adjacent previous chapter, or `nil` when the current lower bound is the first
       selectable chapter.
     - Side effects: None; callers must commit the returned candidate after loading succeeds.
     - Failure modes: Returns `nil` when no previous book exists.
     */
    func previousCandidate(
        previousBook: (String) -> String?,
        chapterCount: (String) -> Int
    ) -> BibleReaderInfiniteScrollChapter? {
        let chapter = lowerBound.chapter - 1
        guard chapter >= 1 else {
            guard let book = previousBook(lowerBound.book) else { return nil }
            return BibleReaderInfiniteScrollChapter(book: book, chapter: chapterCount(book))
        }
        return BibleReaderInfiniteScrollChapter(book: lowerBound.book, chapter: chapter)
    }

    /**
     Resolves the chapter immediately after the current upper loaded bound.

     - Parameters:
       - nextBook: Lookup for the next book in the active module versification.
       - chapterCount: Lookup for the final chapter number of a book.
     - Returns: Adjacent next chapter, or `nil` when the current upper bound is the final selectable
       chapter.
     - Side effects: None; callers must commit the returned candidate after loading succeeds.
     - Failure modes: Returns `nil` when no next book exists.
     */
    func nextCandidate(
        nextBook: (String) -> String?,
        chapterCount: (String) -> Int
    ) -> BibleReaderInfiniteScrollChapter? {
        let chapter = upperBound.chapter + 1
        let lastChapter = chapterCount(upperBound.book)
        guard chapter <= lastChapter else {
            guard let book = nextBook(upperBound.book) else { return nil }
            return BibleReaderInfiniteScrollChapter(book: book, chapter: 1)
        }
        return BibleReaderInfiniteScrollChapter(book: upperBound.book, chapter: chapter)
    }

    /**
     Commits a successfully loaded previous candidate as the new lower bound.

     - Parameter chapter: Candidate returned from `previousCandidate`.
     - Side effects: Replaces the lower loaded bound.
     - Failure modes: None; callers only commit after document loading succeeds.
     */
    mutating func commitPrevious(_ chapter: BibleReaderInfiniteScrollChapter) {
        lowerBound = chapter
    }

    /**
     Commits a successfully loaded next candidate as the new upper bound.

     - Parameter chapter: Candidate returned from `nextCandidate`.
     - Side effects: Replaces the upper loaded bound.
     - Failure modes: None; callers only commit after document loading succeeds.
     */
    mutating func commitNext(_ chapter: BibleReaderInfiniteScrollChapter) {
        upperBound = chapter
    }
}
