import Foundation
import XCTest

/**
 Base test case for BibleUI package tests that need temporary bundled SWORD modules.

 The fixture mirrors the app-host test helper's behavior without depending on the shared
 `AndBibleTests` superclass. Each test receives a copied `AndBible/Resources/sword` tree under a
 unique temporary directory, and teardown removes every path registered through
 `makeTemporaryBundledSwordPath()`.
 */
class BibleUISwordFixtureTestCase: XCTestCase {
    private var temporarySwordModulePaths: [String] = []

    /**
     Removes every temporary SWORD directory created by the test.

     - Side effects: Deletes filesystem paths registered during the test and clears the registry.
     - Failure modes: Cleanup errors are intentionally ignored so the original test failure remains
       the reported XCTest failure.
     */
    override func tearDown() {
        let fileManager = FileManager.default
        for path in temporarySwordModulePaths {
            try? fileManager.removeItem(atPath: path)
        }
        temporarySwordModulePaths.removeAll()
        super.tearDown()
    }

    /**
     Copies the repository-bundled SWORD fixture into an isolated temporary module root.

     - Returns: Filesystem path to the temporary `sword` directory containing `mods.d` and module
       data files.
     - Side effects: Creates a temporary directory and copies bundled fixture files into it.
     - Failure modes: Throws filesystem errors from directory creation or recursive copying; records
       an XCTest failure if the repository fixture path cannot be found.
     */
    func makeTemporaryBundledSwordPath() throws -> String {
        let fileManager = FileManager.default
        let sourceRoot = try BibleUITestSourceLocator.repositoryRoot(
            containing: "AndBible/Resources/sword"
        )
        let bundledSwordURL = sourceRoot
            .appendingPathComponent("AndBible", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        XCTAssertTrue(
            fileManager.fileExists(atPath: bundledSwordURL.path),
            "Expected repo-bundled sword resources at \(bundledSwordURL.path)"
        )

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try copyDirectoryContents(from: bundledSwordURL, to: tempRoot)

        temporarySwordModulePaths.append(tempRoot.path)
        return tempRoot.path
    }

    /**
     Recursively copies all source directory contents into a destination directory.

     - Parameters:
       - source: Directory whose children should be copied.
       - destination: Directory that will receive the copied children.
     - Side effects: Creates destination directories and copies files.
     - Failure modes: Propagates filesystem enumeration, metadata, directory creation, and copy
       errors.
     */
    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try copyDirectoryContents(from: item, to: target)
            } else {
                try fileManager.copyItem(at: item, to: target)
            }
        }
    }
}
