// MyDocumentsListView.swift -- Android-aligned My Documents selector

import Foundation
import BibleCore
import SwiftData
import SwiftUI

/**
 Lists stored My Documents and opens a selected page in the reader document pipeline.

 Android's drawer launches `MyDocumentsActivity`, then `MyDocumentPagesActivity`; selecting a page
 returns the chosen document initials and page key to the reader. This view mirrors that ownership
 path without adding native iOS sheet chrome. It intentionally reads the existing SwiftData
 `MyDocument` graph and delegates page opening to the caller so the reader can reuse
 `BibleReaderController.loadMyDocumentPage(bookInitials:pageKey:)`.

 Data dependencies:
 - `documents` streams persisted `MyDocument` rows from SwiftData, ordered by Android-style
   `orderNumber`
 - each document's `pages` relationship supplies the second-step page list

 Side effects:
 - selecting a page invokes `onOpenPage` with the Android-compatible document initials and page key
 - the view itself does not create, edit, delete, or persist rows
 */
public struct MyDocumentsListView: View {
    /// Persisted My Documents ordered by the user-visible Android list order.
    @Query(sort: \MyDocument.orderNumber) private var documents: [MyDocument]

    /// Callback that opens a selected My Documents page in the owning reader pane.
    private let onOpenPage: (String, String) -> Void

    /**
     Creates a My Documents selector.

     - Parameter onOpenPage: Callback invoked with `(bookInitials, pageKey)` when the user selects
       a page from the nested page list.
     */
    public init(onOpenPage: @escaping (String, String) -> Void) {
        self.onOpenPage = onOpenPage
    }

    /// Documents sorted with a stable name/initials tie-breaker for deterministic UI tests.
    private var sortedDocuments: [MyDocument] {
        documents.sorted { lhs, rhs in
            if lhs.orderNumber != rhs.orderNumber {
                return lhs.orderNumber < rhs.orderNumber
            }
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.initials.localizedCaseInsensitiveCompare(rhs.initials) == .orderedAscending
        }
    }

    /// Compact list state exported for UI tests without walking every SwiftUI row.
    private var myDocumentsAccessibilityValue: String {
        let baseState = "total=\(sortedDocuments.count)"
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return baseState
        }

        let rowTokens = sortedDocuments
            .prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
            .map { "|\(myDocumentsAccessibilitySegment($0.initials))|" }
            .joined(separator: ",")
        return "\(baseState);rows=\(rowTokens)"
    }

    /**
     Builds the document list or Android-compatible empty state.
     */
    public var body: some View {
        Group {
            if sortedDocuments.isEmpty {
                ContentUnavailableView(
                    String(localized: "my_documents", defaultValue: "My Documents"),
                    systemImage: "doc.text",
                    description: Text(String(localized: "my_documents_empty", defaultValue: "No documents yet."))
                )
                .accessibilityIdentifier("myDocumentsListScreen")
                .accessibilityValue(myDocumentsAccessibilityValue)
            } else {
                List {
                    ForEach(sortedDocuments) { document in
                        NavigationLink {
                            MyDocumentPagesListView(document: document, onOpenPage: onOpenPage)
                        } label: {
                            MyDocumentRow(document: document)
                        }
                        .accessibilityIdentifier(myDocumentsDocumentRowIdentifier(for: document))
                        .accessibilityLabel(document.name)
                        .accessibilityValue(myDocumentsDocumentAccessibilityValue(for: document))
                    }
                }
                .accessibilityIdentifier("myDocumentsListScreen")
                .accessibilityValue(myDocumentsAccessibilityValue)
            }
        }
        .overlay(alignment: .topLeading) {
            myDocumentsListStateExport
        }
        .navigationTitle(String(localized: "my_documents", defaultValue: "My Documents"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Hidden compact state probe for UI automation.
    @ViewBuilder
    private var myDocumentsListStateExport: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(myDocumentsAccessibilityValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("myDocumentsListStateExport")
                .accessibilityValue(myDocumentsAccessibilityValue)
        }
    }

    /**
     Builds a stable document-row identifier.

     - Parameter document: Document represented by the row.
     - Returns: UI-test identifier using Android-compatible document initials.
     */
    private func myDocumentsDocumentRowIdentifier(for document: MyDocument) -> String {
        "myDocumentsDocumentRow::\(myDocumentsAccessibilitySegment(document.initials))"
    }

    /**
     Serializes document metadata into a compact row accessibility value.

     - Parameter document: Document represented by the row.
     - Returns: Stable metadata string used by UI automation.
     */
    private func myDocumentsDocumentAccessibilityValue(for document: MyDocument) -> String {
        "initials=\(document.initials);pages=\((document.pages ?? []).count)"
    }
}

// MARK: - Document Row

/**
 Row summary matching Android's My Documents list content contract.

 The Android row shows the document name and either its description or a no-description fallback.
 iOS adds the initials as secondary metadata because initials are the stable generated-document key
 used by the reader bridge.
 */
private struct MyDocumentRow: View {
    /// Persisted document summarized by the row.
    let document: MyDocument

    /// Description text shown under the document name.
    private var descriptionText: String {
        guard let description = document.documentDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else {
            return String(localized: "my_document_no_description", defaultValue: "No description")
        }
        return description
    }

    /// Builds the visible row content.
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(document.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(descriptionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Text(document.initials)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Page List

/**
 Lists pages for one My Document and opens the selected page in the reader.

 Android's `MyDocumentPagesActivity` owns this second step and returns the selected page key. The
 view follows the same contract: row taps do not edit the page in place; they invoke `onOpenPage`
 so the reader can load the generated general-book page.
 */
private struct MyDocumentPagesListView: View {
    /// Parent document whose pages should be displayed.
    let document: MyDocument

    /// Callback that opens a selected page in the reader.
    let onOpenPage: (String, String) -> Void

    /// Pages sorted with a deterministic title/key tie-breaker.
    private var sortedPages: [MyDocumentPage] {
        (document.pages ?? []).sorted { lhs, rhs in
            if lhs.orderNumber != rhs.orderNumber {
                return lhs.orderNumber < rhs.orderNumber
            }
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.pageKey.localizedCaseInsensitiveCompare(rhs.pageKey) == .orderedAscending
        }
    }

    /// Compact page-list state exported for UI tests.
    private var pageListAccessibilityValue: String {
        let documentToken = myDocumentsAccessibilitySegment(document.initials)
        let baseState = "document=\(documentToken);total=\(sortedPages.count)"
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return baseState
        }

        let rowTokens = sortedPages
            .prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
            .map { "|\(myDocumentsAccessibilitySegment($0.pageKey))|" }
            .joined(separator: ",")
        return "\(baseState);rows=\(rowTokens)"
    }

    /// Builds the page list or empty page state.
    var body: some View {
        Group {
            if sortedPages.isEmpty {
                ContentUnavailableView(
                    document.name,
                    systemImage: "doc.text",
                    description: Text(String(localized: "my_document_pages_empty", defaultValue: "No pages in this document."))
                )
                .accessibilityIdentifier("myDocumentPagesScreen")
                .accessibilityValue(pageListAccessibilityValue)
            } else {
                List {
                    ForEach(sortedPages) { page in
                        Button {
                            onOpenPage(document.initials, page.pageKey)
                        } label: {
                            MyDocumentPageRow(page: page)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(myDocumentPageRowIdentifier(for: page))
                        .accessibilityLabel(pageTitle(for: page))
                        .accessibilityValue("pageKey=\(page.pageKey);contentType=\(page.contentType.rawValue)")
                    }
                }
                .accessibilityIdentifier("myDocumentPagesScreen")
                .accessibilityValue(pageListAccessibilityValue)
            }
        }
        .overlay(alignment: .topLeading) {
            pageListStateExport
        }
        .navigationTitle(document.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Hidden compact state probe for UI automation.
    @ViewBuilder
    private var pageListStateExport: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(pageListAccessibilityValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("myDocumentPagesStateExport")
                .accessibilityValue(pageListAccessibilityValue)
        }
    }

    /**
     Builds a stable page-row identifier scoped to the parent document.

     - Parameter page: Page represented by the row.
     - Returns: UI-test identifier using document initials and page key.
     */
    private func myDocumentPageRowIdentifier(for page: MyDocumentPage) -> String {
        "myDocumentsPageRow::\(myDocumentsAccessibilitySegment(document.initials))::\(myDocumentsAccessibilitySegment(page.pageKey))"
    }
}

/**
 Visible row for one My Document page.
 */
private struct MyDocumentPageRow: View {
    /// Persisted page summarized by the row.
    let page: MyDocumentPage

    /// Builds the visible row content.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pageTitle(for: page))
                .font(.body)
                .foregroundStyle(.primary)
            Text(page.contentType.rawValue)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/**
 Resolves a non-empty display title for one My Documents page.

 - Parameter page: Page whose title should be displayed.
 - Returns: `page.title` when present, otherwise the stable page key.
 */
private func pageTitle(for page: MyDocumentPage) -> String {
    let trimmed = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? page.pageKey : trimmed
}

/**
 Sanitizes a My Documents value into the compact token format used by UI-test state exports.

 - Parameter value: Free-form value such as document initials or a page key.
 - Returns: Identifier-safe token using underscores for non-alphanumeric runs.
 */
private func myDocumentsAccessibilitySegment(_ value: String) -> String {
    let replaced = value.replacingOccurrences(
        of: "[^A-Za-z0-9]+",
        with: "_",
        options: .regularExpression
    )
    return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}
