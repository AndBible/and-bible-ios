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

    /**
     Extracts one Swift function body from source text for focused source-contract assertions.

     Source guards should stay tied to the function boundary they protect instead of searching for
     arbitrary file-wide fragments. The scanner balances braces after the named function
     declaration and returns only that function's source body.

     - Parameter functionName: Name of the Swift function declaration to extract.
     - Parameter source: Source file contents containing the function declaration.
     - Returns: Source text from the function declaration through its closing brace.
     - Throws: An `NSError` when the declaration is missing or the function body is unbalanced.
     */
    static func extractFunction(named functionName: String, from source: String) throws -> String {
        guard let functionRange = source.range(of: "func \(functionName)") else {
            throw NSError(
                domain: "BibleUITestSourceLocator",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Function \(functionName) not found"]
            )
        }
        guard let openingBrace = source[functionRange.lowerBound...].firstIndex(of: "{") else {
            throw NSError(
                domain: "BibleUITestSourceLocator",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Function \(functionName) has no body"]
            )
        }

        var depth = 0
        var current = openingBrace
        while current < source.endIndex {
            let character = source[current]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[functionRange.lowerBound...current])
                }
            }
            current = source.index(after: current)
        }

        throw NSError(
            domain: "BibleUITestSourceLocator",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Function \(functionName) body was not balanced"]
        )
    }
}
