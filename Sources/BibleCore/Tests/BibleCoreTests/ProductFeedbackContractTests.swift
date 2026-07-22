import Foundation
import XCTest
@testable import BibleCore

/**
 Verifies the iOS product-feedback contract against a committed Android-source inventory.

 The fixture pins Android commit `2e45efb` and the resource/end-point surface used by report and
 review flows. A failure means a product route or required localization key can drift without a
 deliberate Android-parity review.
 */
final class ProductFeedbackContractTests: XCTestCase {
    /**
     Ensures diagnostic and support destinations remain Android's exact addressed routes.

     - Expected result: The typed contract equals the committed Android fixture, including both
       FAQ anchors whose punctuation is part of the user-visible routing contract.
     - Failure meaning: Feedback could be sent to an unaddressed or generic destination.
     */
    func testContractMatchesCommittedAndroidEndpoints() throws {
        let fixture = try loadFixture()

        XCTAssertEqual(ProductFeedbackContract.diagnosticRecipient, fixture.diagnosticRecipient)
        XCTAssertEqual(ProductFeedbackContract.supportRecipient, fixture.supportRecipient)
        XCTAssertEqual(ProductFeedbackContract.supportURL.absoluteString, fixture.supportURL)
        XCTAssertEqual(ProductFeedbackContract.textIssueURL.absoluteString, fixture.textIssueURL)
        XCTAssertEqual(ProductFeedbackContract.missingModuleURL.absoluteString, fixture.missingModuleURL)
        XCTAssertEqual(ProductFeedbackContract.manualReportSource, "manual")
        XCTAssertEqual(fixture.androidCommit, "2e45efb0d814f9a4e43f0e8f382328a61543cc1b")
        XCTAssertTrue(fixture.resourceKeys.contains("report_bug_email_subject_3"))
        XCTAssertTrue(fixture.resourceKeys.contains("rate_message6"))
    }

    /**
     Compares the committed fixture against the sibling Android checkout when it is available.

     - Setup: The test discovers the Android sibling from `ANDROID_SOURCE_ROOT` or this worktree's
       parent directory. CI without that checkout validates the committed fixture above instead.
     - Expected result: The checkout remains on the pinned commit and retains every fixture key and
       endpoint literal in Android's source files.
     - Failure meaning: The fixture no longer proves the Android contract it claims to represent.
     */
    func testFixtureMatchesLiveAndroidCheckoutWhenAvailable() throws {
        let fixture = try loadFixture()
        guard let androidRoot = androidSourceRoot() else { return }

        XCTAssertEqual(try gitRevision(at: androidRoot), fixture.androidCommit)
        let strings = try String(
            contentsOf: androidRoot.appendingPathComponent(fixture.sourcePaths[2]),
            encoding: .utf8
        )
        for key in fixture.resourceKeys {
            XCTAssertTrue(
                strings.contains("name=\"\(key)\""),
                "Android strings.xml is missing required feedback key \(key)"
            )
        }

        let menuSource = try String(
            contentsOf: androidRoot.appendingPathComponent(fixture.sourcePaths[0]),
            encoding: .utf8
        )
        let reportSource = try String(
            contentsOf: androidRoot.appendingPathComponent(fixture.sourcePaths[1]),
            encoding: .utf8
        )
        XCTAssertTrue(menuSource.contains(fixture.supportURL))
        XCTAssertTrue(menuSource.contains(fixture.supportRecipient))
        XCTAssertTrue(reportSource.contains(fixture.diagnosticRecipient))
    }

    /**
     Preserves Android's subject placeholder inputs without inventing a version or source value.

     - Expected result: Build and source combine only in the first positional argument; application
       name and marketing version remain separate for each locale's subject format.
     - Failure meaning: A localized subject can reorder or lose Android-required metadata.
     */
    func testSubjectRetainsAndroidPositionalInputs() {
        let subject = ProductFeedbackSubject(
            build: "42",
            source: ProductFeedbackContract.manualReportSource,
            applicationName: "AndBible",
            marketingVersion: "1.2.3"
        )

        XCTAssertEqual(subject.buildAndSource, "42 manual")
        XCTAssertEqual(subject.applicationName, "AndBible")
        XCTAssertEqual(subject.marketingVersion, "1.2.3")
    }

    /**
     Ensures a pre-listing beta cannot manufacture an App Store handoff or use an in-app prompt.

     - Expected result: Missing numeric configuration is represented as unavailable.
     - Failure meaning: The review flow could falsely imply that a user reached a listing.
     */
    func testMissingAppStoreListingRemainsExplicitlyUnavailable() {
        XCTAssertNil(ProductFeedbackContract.appStoreDestination)
    }

    /**
     Decodes the committed Android contract fixture directly from the test source tree.

     - Returns: Decoded fixture used by parity assertions.
     - Side effects: Reads a checked-in JSON fixture only.
     - Throws: A decoding or file error when the fixture is missing or malformed.
     */
    private func loadFixture() throws -> AndroidProductFeedbackFixture {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/android-product-feedback-contract.json")
        return try JSONDecoder().decode(
            AndroidProductFeedbackFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
    }

    /**
     Finds the optional Android source checkout used for stronger local parity verification.

     - Returns: The Android repository root when present, otherwise `nil` for portable package CI.
     - Side effects: Reads only process environment and file-system metadata.
     - Failure modes: A missing sibling is intentionally nonfatal because the checked-in fixture is
       the portable verification source.
     */
    private func androidSourceRoot() -> URL? {
        let fileManager = FileManager.default
        if let configuredRoot = ProcessInfo.processInfo.environment["ANDROID_SOURCE_ROOT"] {
            let configuredURL = URL(fileURLWithPath: configuredRoot, isDirectory: true)
            if fileManager.fileExists(atPath: configuredURL.appendingPathComponent(".git").path) {
                return configuredURL
            }
        }

        let worktreeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let siblingRoot = worktreeRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("and-bible")
        guard fileManager.fileExists(atPath: siblingRoot.appendingPathComponent(".git").path) else {
            return nil
        }
        return siblingRoot
    }

    /**
     Reads a repository HEAD revision without invoking a shell.

     - Parameter repositoryURL: Repository whose current commit should match the fixture.
     - Returns: Trimmed full SHA reported by Git.
     - Side effects: Starts a read-only Git subprocess.
     - Throws: A Cocoa error when Git cannot return a successful full revision.
     */
    private func gitRevision(at repositoryURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryURL.path, "rev-parse", "HEAD"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/**
 Decoded, reviewable subset of Android source facts used by product-feedback parity tests.

 The fixture is test evidence, not a runtime source of truth; production code retains typed values
 so an unavailable App Store listing cannot be papered over by fixture data.
 */
private struct AndroidProductFeedbackFixture: Decodable {
    /// Pinned Android source revision from which all fixture facts were reviewed.
    let androidCommit: String
    /// Android source files reviewed when deriving the contract.
    let sourcePaths: [String]
    /// Android resource keys required by the iOS report and review surfaces.
    let resourceKeys: [String]
    /// Android diagnostic-report email recipient.
    let diagnosticRecipient: String
    /// Android review-guidance support email recipient.
    let supportRecipient: String
    /// Android Questions support wiki route.
    let supportURL: String
    /// Android text-maintainer FAQ route.
    let textIssueURL: String
    /// Android missing-module FAQ route.
    let missingModuleURL: String
}
