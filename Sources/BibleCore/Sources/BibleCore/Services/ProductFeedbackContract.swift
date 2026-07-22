// ProductFeedbackContract.swift -- Android-aligned product feedback endpoints and report types

import Foundation

/**
 Defines the product-facing endpoints and stable report vocabulary shared by iOS feedback flows.

 The values intentionally mirror the Android feedback implementation rather than being repeated
 across SwiftUI callbacks. The App Store identifier remains deliberately unavailable until an
 official listing exists; callers must surface that state instead of constructing a bogus URL or
 falling back to an in-app rating prompt.
 */
public enum ProductFeedbackContract {
    /// Android's manual report source label included in the addressed email subject.
    public static let manualReportSource = "manual"
    /// Destination for addressed diagnostic reports.
    public static let diagnosticRecipient = "errors.andbible@gmail.com"
    /// Destination for support questions from the review guidance.
    public static let supportRecipient = "help.andbible@gmail.com"
    /// Android's Questions drawer destination.
    public static let supportURL = URL(string: "https://github.com/AndBible/and-bible/wiki/Support")!
    /// Android's FAQ destination for source-text or translation issues.
    public static let textIssueURL = URL(string: "https://github.com/AndBible/and-bible/wiki/FAQ#i-found-text-issue-in-one-of-the-bible--commentary-etc-modules-in-and-bible")!
    /// Android's FAQ destination for unavailable modules.
    public static let missingModuleURL = URL(string: "https://github.com/AndBible/and-bible/wiki/FAQ#please-add-module-x-to-and-bible")!

    /**
     Returns the configured App Store listing routes when an official numeric identifier exists.

     - Returns: A write-review route and HTTPS listing fallback, or `nil` while the product is in
       beta and has no App Store identifier.
     - Side effects: none.
     - Failure modes: Missing or malformed configuration intentionally produces `nil`; callers
       must retain their dialog and report the unavailable handoff rather than claiming success.
     */
    public static var appStoreDestination: AppStoreDestination? {
        guard let identifier = appStoreIdentifier,
              identifier.allSatisfy(\.isNumber),
              !identifier.isEmpty,
              let writeReviewURL = URL(string: "itms-apps://apps.apple.com/app/id\(identifier)?action=write-review"),
              let listingURL = URL(string: "https://apps.apple.com/app/id\(identifier)")
        else {
            return nil
        }
        return AppStoreDestination(writeReviewURL: writeReviewURL, listingURL: listingURL)
    }

    /// Official App Store numeric identifier. Set only after the App Store listing is published.
    private static let appStoreIdentifier: String? = nil
}

/**
 Represents the two deterministic routes needed for an App Store rating handoff.

 The primary route requests the listing's review action and the HTTPS route is retained only for a
 platform-open failure. Both URLs are derived from the same numeric identifier.
 */
public struct AppStoreDestination: Equatable, Sendable {
    /// Native App Store route requesting the listing review action.
    public let writeReviewURL: URL
    /// Web listing fallback used when the native route cannot be opened.
    public let listingURL: URL

    /**
     Creates one validated App Store route pair.

     - Parameters:
       - writeReviewURL: Native review URL derived from a numeric App Store identifier.
       - listingURL: HTTPS listing URL for the same identifier.
     - Side effects: none.
     - Failure modes: Validation occurs at contract construction; this value cannot represent a
       missing URL.
     */
    public init(writeReviewURL: URL, listingURL: URL) {
        self.writeReviewURL = writeReviewURL
        self.listingURL = listingURL
    }
}

/**
 Builds Android's localized three-argument manual-report subject after the UI resolves its format.

 Keeping formatting in the platform-neutral contract makes the argument order independently
 testable while localization adapters retain ownership of translated format strings.
 */
public struct ProductFeedbackSubject: Equatable, Sendable {
    /// iOS numeric build number used in Android's first subject placeholder.
    public let build: String
    /// Android-compatible report source, normally `manual`.
    public let source: String
    /// Product name supplied to Android's second subject placeholder.
    public let applicationName: String
    /// Marketing version supplied to Android's third subject placeholder.
    public let marketingVersion: String

    /**
     Creates inputs for one addressed feedback subject.

     - Parameters:
       - build: Nonempty numeric app build string.
       - source: Report-origin label retained in the subject.
       - applicationName: User-visible product name.
       - marketingVersion: User-visible release version.
     - Side effects: none.
     - Failure modes: Empty values remain visible to callers so invalid metadata cannot be silently
       replaced with fabricated diagnostics.
     */
    public init(build: String, source: String, applicationName: String, marketingVersion: String) {
        self.build = build
        self.source = source
        self.applicationName = applicationName
        self.marketingVersion = marketingVersion
    }

    /// Combined Android first-placeholder value, such as `123 manual`.
    public var buildAndSource: String { "\\(build) \\(source)" }
}

/**
 Names the privacy-reviewed diagnostic artifact categories that a prepared report may contain.

 The semantic kind lets the report body describe only files that actually survived collection and
 lets mail/export adapters enforce type-specific bounds without inspecting user-visible filenames.
 */
public enum ProductFeedbackAttachmentKind: String, Codable, CaseIterable, Equatable, Sendable {
    /// Gzip-compressed, redacted application-process log.
    case applicationLog
    /// Encoded current reader-window screenshot.
    case currentScreenshot
    /// Bounded MetricKit or app-owned recent crash diagnostic.
    case recentCrashDiagnostic
    /// Safely retained crash-time app-state image, never a normal manual screenshot.
    case recentCrashScreenshot
}
