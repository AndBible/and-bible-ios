// ModuleStoreExactOverlayManifest.swift - Ordered exact-file module-store publication

import Foundation

/**
 Ordered file manifest for an exact-path module-store overlay.

 Content files publish first. Activation files, such as SWORD configs or derived catalog pointers,
 publish only after every content file is present so inventory readers cannot discover an incomplete
 document. The transaction publisher revalidates every path and staged file under its exclusive
 lease; this value carries ordering only and grants no filesystem authority.
 */
public struct ModuleStoreExactOverlayManifest: Sendable, Equatable {
    /// Root-relative data, database, resource, and index paths published before activation files.
    public let contentRelativePaths: [String]

    /// Root-relative configs or catalog pointers published after all content files.
    public let activationRelativePaths: [String]

    /// Every destination in deterministic publication order.
    public var allRelativePaths: [String] {
        contentRelativePaths + activationRelativePaths
    }

    /**
     Creates one ordered exact-file overlay manifest.

     - Parameters:
       - contentRelativePaths: Data/resource paths that must exist before discovery is enabled.
       - activationRelativePaths: Config/pointer paths published last.
     - Side effects: none.
     - Failure modes: none; the transaction publisher performs authoritative path and file checks.
     */
    public init(
        contentRelativePaths: [String],
        activationRelativePaths: [String]
    ) {
        self.contentRelativePaths = contentRelativePaths
        self.activationRelativePaths = activationRelativePaths
    }
}
