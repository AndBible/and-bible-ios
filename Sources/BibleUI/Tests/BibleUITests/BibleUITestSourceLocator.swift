import Foundation

/**
 Shared source-file locator for BibleUI package tests that intentionally scan production Swift.

 The helper walks upward from a test source path until it finds a requested repo-relative path.
 This keeps source-string guardrails deterministic after app-host tests move into nested package
 test directories. It performs read-only filesystem checks and throws when the checkout layout does
 not contain the expected source file.
 */
enum BibleUITestSourceLocator {
    /**
     Finds the repository root that contains a known repo-relative source path.

     - Parameter relativePath: Source-controlled path expected to exist below the repository root.
     - Parameter filePath: Starting file path used for the upward search.
     - Returns: Directory URL for the repository root containing `relativePath`.
     - Throws: An `NSError` when no parent directory contains the requested path.
     */
    static func repositoryRoot(containing relativePath: String, from filePath: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return directory
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                throw NSError(
                    domain: "BibleUITestSourceLocator",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unable to locate repository root containing \(relativePath) from \(filePath)"
                    ]
                )
            }
            directory = parent
        }
    }

    /**
     Reads a repo-relative source file for source-string guardrail tests.

     - Parameter relativePath: Source-controlled file path below the repository root.
     - Parameter filePath: Starting file path used to locate the root.
     - Returns: UTF-8 contents of the requested source file.
     - Throws: Filesystem or decoding errors from root lookup or source loading.
     */
    static func source(at relativePath: String, from filePath: String = #filePath) throws -> String {
        let root = try repositoryRoot(containing: relativePath, from: filePath)
        let sourceURL = root.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
