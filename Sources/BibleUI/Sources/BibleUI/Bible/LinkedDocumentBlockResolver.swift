// LinkedDocumentBlockResolver.swift -- Source-independent linked document navigation

import Foundation

/** One consecutive run of document keys with identical semantic content. */
struct LinkedDocumentBlock<Key: Hashable> {
    /// First key in the consecutive run.
    let start: Key

    /// Last key in the consecutive run.
    let end: Key

    /// Stable semantic content, or nil when the selected key is empty.
    let content: String?
}

/**
 Resolves adjacent semantic content blocks without knowing the document category or storage backend.

 Empty keys delimit blocks and are skipped by previous/next navigation. Equal content separated by
 an empty key remains two blocks, matching Android's `CommentaryBlockResolver`. One operation-local
 cache retains only successful content; nil/error reads are retried like Kotlin nullable
 `getOrPut` results.
 */
struct LinkedDocumentBlockResolver<Key: Hashable> {
    /// Returns the next traversable key, or nil at the source boundary.
    let next: (Key) -> Key?

    /// Returns the previous traversable key, or nil at the source boundary.
    let previous: (Key) -> Key?

    /// Returns trimmed semantic content, or nil for an empty/unreadable key.
    let render: (Key) -> String?

    /**
     Resolves the complete equal-content run containing one key.

     - Parameter key: Selected source key.
     - Returns: Consecutive block, or a single-key nil-content block when the selection is empty.
     - Side effects: Calls traversal and rendering closures and caches results for this operation.
     - Failure modes: Closure-level failures must be represented as nil; traversal cycles stop at the
       first non-monotonic repeated key.
     */
    func block(containing key: Key) -> LinkedDocumentBlock<Key> {
        let session = Session(render: render)
        return resolveBlock(containing: key, session: session)
    }

    /**
     Resolves the start of the adjacent non-empty block.

     - Parameters:
       - key: Key inside the current block, or an empty separator key.
       - forward: True for the next block; false for the previous block.
     - Returns: Start key of the adjacent non-empty block, or nil at the traversal boundary.
     - Side effects: Traverses and renders source keys through one operation-local cache.
     - Failure modes: Empty/unreadable keys are skipped. Repeated traversal keys terminate safely.
     */
    func adjacentBlockStart(from key: Key, forward: Bool) -> Key? {
        let session = Session(render: render)
        let current = resolveBlock(containing: key, session: session)
        var cursor = forward ? current.end : current.start
        var visited: Set<Key> = [cursor]

        while let candidate = forward ? next(cursor) : previous(cursor) {
            guard visited.insert(candidate).inserted else { return nil }
            cursor = candidate
            guard session.content(for: candidate) != nil else { continue }
            return forward
                ? candidate
                : resolveBlock(containing: candidate, session: session).start
        }
        return nil
    }

    /** Expands one block while sharing the caller's render cache. */
    private func resolveBlock(
        containing key: Key,
        session: Session
    ) -> LinkedDocumentBlock<Key> {
        guard let content = session.content(for: key) else {
            return LinkedDocumentBlock(start: key, end: key, content: nil)
        }

        var start = key
        var visitedBefore: Set<Key> = [key]
        while let candidate = previous(start),
              visitedBefore.insert(candidate).inserted,
              session.content(for: candidate) == content {
            start = candidate
        }

        var end = key
        var visitedAfter: Set<Key> = [key]
        while let candidate = next(end),
              visitedAfter.insert(candidate).inserted,
              session.content(for: candidate) == content {
            end = candidate
        }
        return LinkedDocumentBlock(start: start, end: end, content: content)
    }

    /** Operation-local successful-content render cache. */
    private final class Session {
        /// Backend render closure captured for one navigation action.
        private let render: (Key) -> String?

        /// Successful render values keyed by exact source identity.
        private var values: [Key: String] = [:]

        /** Creates one cache around the resolver's immutable render closure. */
        init(render: @escaping (Key) -> String?) {
            self.render = render
        }

        /** Returns cached content while deliberately retrying nil/error render outcomes. */
        func content(for key: Key) -> String? {
            if let content = values[key] { return content }
            guard let content = render(key) else { return nil }
            values[key] = content
            return content
        }
    }
}
