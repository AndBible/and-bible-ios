import Foundation
import SwiftData
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 Exercises the real Bookmark activity root in a finite UIKit owner.

 These native contracts keep the model owner live and cover direct geometry, rendered row updates,
 and persisted source observation. Scene-backed navigation belongs to the full Bookmark app
 journeys, which exercise assignment, Back, dismissal, and reopen on supported runtimes.
 */
@MainActor
final class BookmarkListViewportLayoutTests: XCTestCase {
    /** The finite host renders recognizable SwiftUI text into its real window pixels. */
    func testHostPixelRecognitionFindsRenderedSwiftUIText() async {
        let expected = "Rendered native sample"
        let host = makeWindowHost(
            VStack {
                Color.clear.frame(height: 8)
                Text(expected)
            }
        )
        defer { host.close() }

        try? await Task.sleep(for: .milliseconds(100))
        let recognizedText = host.recognizedPixelText()
        let recognizedDocument = recognizedText.joined(separator: " ")

        XCTAssertTrue(
            recognizedDocument.contains(expected),
            "Expected real window pixels to contain '\(expected)'. OCR: \(recognizedText)"
        )
    }

    /** The UIKit host publishes a chrome-like hierarchy despite a neutral sibling preference. */
    func testHostPublishesFilledColorViewport() async {
        let recorder = BookmarkListViewportFrameRecorder()
        let hosted = BookmarkListViewportProbeContent(recorder: recorder) {
            VStack(spacing: 0) {
                Color.blue.frame(height: 56)
                Color.red
            }
            .overlay {
                Color.clear.preference(
                    key: BookmarkListViewportFramePreferenceKey.self,
                    value: .null
                )
            }
        }

        let result = await host(hosted, recorder: recorder)

        assertFillsViewport(result.frame, bounds: result.bounds, observations: result.observations)
    }

    /** The shared Android activity shell accepts the same finite owner before Bookmark modifiers. */
    func testSharedActivityShellFillsOwningViewport() async {
        let recorder = BookmarkListViewportFrameRecorder()
        let hosted = BookmarkListViewportProbeContent(recorder: recorder) {
            BookmarkListMinimalActivity()
        }

        let result = await host(hosted, recorder: recorder)

        assertFillsViewport(result.frame, bounds: result.bounds, observations: result.observations)
    }

    /** A directly hosted Bookmark activity consumes the finite viewport supplied by its owner. */
    func testDirectBookmarkListFillsOwningViewport() async throws {
        let container = try makeHostedBookmarkListModelContainer()
        let recorder = BookmarkListViewportFrameRecorder()
        let hosted = BookmarkListViewportProbe(recorder: recorder)
            .modelContainer(container)

        let result = await host(hosted, recorder: recorder)

        assertFillsViewport(result.frame, bounds: result.bounds)
        withExtendedLifetime(container) {}
    }

    /** Ten rows and two long notes do not collapse a directly hosted Bookmark activity. */
    func testPopulatedDirectBookmarkListFillsOwningViewport() async throws {
        let container = try makeHostedBookmarkListModelContainer()
        try seedPopulatedBookmarkList(in: ModelContext(container))
        let recorder = BookmarkListViewportFrameRecorder()
        let hosted = BookmarkListViewportProbe(recorder: recorder)
            .modelContainer(container)

        let result = await host(hosted, recorder: recorder)

        assertFillsViewport(result.frame, bounds: result.bounds, observations: result.observations)
        withExtendedLifetime(container) {}
    }

    /** The real assignment activity fills a finite owner before nested-navigation effects. */
    func testDirectLabelAssignmentFillsOwningViewport() async throws {
        let fixture = try makeLabelAssignmentFixture()
        let recorder = BookmarkListViewportFrameRecorder()
        let hosted = BookmarkListLabelAssignmentProbe(
            bookmarkID: fixture.bookmarkID,
            recorder: recorder
        )
        .modelContainer(fixture.container)

        let result = await host(hosted, recorder: recorder)

        assertFillsViewport(result.frame, bounds: result.bounds, observations: result.observations)
        withExtendedLifetime(fixture.container) {}
    }

    /** Selected My Documents edits restart observation while unrelated saves leave it unchanged. */
    func testPersistedSourceObserverTracksOnlyExactSelectedPage() async throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let selectedDocument = MyDocument(name: "Selected", initials: "Selected")
        let selectedPage = MyDocumentPage(title: "Page", pageKey: "page")
        let selectedContent = MyDocumentPageContent(pageId: selectedPage.id, content: "Before")
        let unrelatedDocument = MyDocument(name: "Unrelated", initials: "Unrelated")
        let unrelatedPage = MyDocumentPage(title: "Other", pageKey: "other")
        let unrelatedContent = MyDocumentPageContent(pageId: unrelatedPage.id, content: "Other")
        [selectedDocument, unrelatedDocument].forEach(context.insert)
        [selectedPage, unrelatedPage].forEach(context.insert)
        [selectedContent, unrelatedContent].forEach(context.insert)
        selectedPage.document = selectedDocument
        selectedContent.page = selectedPage
        unrelatedPage.document = unrelatedDocument
        unrelatedContent.page = unrelatedPage
        try context.save()

        let recorder = BookmarkListPersistedSourceRecorder()
        let hosted = BookmarkListPersistedMyDocumentSourceObserver(
            documentInitials: "Selected",
            pageKey: "page"
        ) { source in
            BookmarkListPersistedSourceProbe(source: source, recorder: recorder)
        }
        .modelContainer(container)
        let host = makeWindowHost(hosted)
        defer { host.close() }

        let observedInitialSource = await waitUntil { recorder.latest?.rawContent == "Before" }
        XCTAssertTrue(
            observedInitialSource,
            "Expected the exact selected page to publish its copied source"
        )
        let selectedObservationCount = recorder.count

        unrelatedContent.content = "Changed elsewhere"
        try context.save()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.count, selectedObservationCount)
        XCTAssertEqual(recorder.latest?.rawContent, "Before")

        selectedContent.content = "After"
        try context.save()
        let observedChangedSource = await waitUntil { recorder.latest?.rawContent == "After" }
        XCTAssertTrue(
            observedChangedSource,
            "Expected the selected page mutation to publish a new exact source identity"
        )
        withExtendedLifetime(container) {}
    }

    /** A selected source mutation restarts its visible row loader without reloading unrelated rows. */
    func testVisibleRowReloadsForExactSelectedPersistedSource() async throws {
        let container = try makeHostedBookmarkListModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "Selected", initials: "Selected")
        let page = MyDocumentPage(title: "Page", pageKey: "page")
        let pageContent = MyDocumentPageContent(pageId: page.id, content: "Before")
        let unrelatedDocument = MyDocument(name: "Unrelated", initials: "Unrelated")
        let bookmark = GenericBookmark(key: "page", bookInitials: "Selected")
        [document, unrelatedDocument].forEach(context.insert)
        context.insert(page)
        context.insert(pageContent)
        context.insert(bookmark)
        page.document = document
        pageContent.page = page
        try context.save()

        let before = "Before projection text"
        let after = "After projection text"
        let recorder = BookmarkListRowLoadRecorder(content: before)
        let hosted = BookmarkListView(
            surfacePalette: .standard,
            onDismiss: {},
            rowProjectionLoader: { request, _ in recorder.load(request) },
            projectionContexts: .empty
        )
        .modelContainer(container)
        let host = makeWindowHost(hosted)
        defer { host.close() }

        let observedInitialContent = await waitUntil { recorder.loadedContents == [before] }
        try? await Task.sleep(for: .milliseconds(100))
        let initialRecognizedText = host.recognizedPixelText()
        let initialRecognizedDocument = initialRecognizedText.joined(separator: " ")
        XCTAssertTrue(
            observedInitialContent && initialRecognizedDocument.contains(before),
            "Expected first copied source in real row pixels. "
                + "Loads: \(recorder.loadedContents); OCR: \(initialRecognizedText)"
        )

        recorder.content = "Unrelated projection text"
        unrelatedDocument.name = "Changed elsewhere"
        try context.save()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.loadedContents, [before])

        recorder.content = after
        pageContent.content = "After"
        try context.save()
        let observedReload = await waitUntil { recorder.loadedContents == [before, after] }
        try? await Task.sleep(for: .milliseconds(100))
        let updatedRecognizedText = host.recognizedPixelText()
        let updatedRecognizedDocument = updatedRecognizedText.joined(separator: " ")
        XCTAssertTrue(
            observedReload
                && updatedRecognizedDocument.contains(after)
                && !updatedRecognizedDocument.contains(before),
            "Expected selected-source mutation to replace real row pixels. "
                + "Loads: \(recorder.loadedContents); OCR: \(updatedRecognizedText)"
        )
        withExtendedLifetime(container) {}
    }

    /** Deleting the selected page removes its authoritative row source instead of retaining it. */
    func testPersistedSourceObserverClearsDeletedSelectedPage() async throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "Selected", initials: "Selected")
        let page = MyDocumentPage(title: "Page", pageKey: "page")
        let pageContent = MyDocumentPageContent(pageId: page.id, content: "Before")
        context.insert(document)
        context.insert(page)
        context.insert(pageContent)
        page.document = document
        pageContent.page = page
        try context.save()

        let recorder = BookmarkListPersistedSourceRecorder()
        let hosted = BookmarkListPersistedMyDocumentSourceObserver(
            documentInitials: "Selected",
            pageKey: "page"
        ) { source in
            BookmarkListPersistedSourceProbe(source: source, recorder: recorder)
        }
        .modelContainer(container)
        let host = makeWindowHost(hosted)
        defer { host.close() }

        let observedInitialSource = await waitUntil { recorder.latest?.rawContent == "Before" }
        XCTAssertTrue(observedInitialSource)
        let initialObservationCount = recorder.count

        context.delete(pageContent)
        context.delete(page)
        try context.save()

        let observedDeletion = await waitUntil {
            recorder.count > initialObservationCount && recorder.latest == nil
        }
        XCTAssertTrue(
            observedDeletion,
            "Expected deleting the selected page to clear its exact persisted source eligibility"
        )
        withExtendedLifetime(container) {}
    }

    /** SQL collation cannot admit a canonically equivalent but Java-distinct source identity. */
    func testPersistedSourceObserverRejectsCanonicallyEquivalentIdentity() async throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        let document = MyDocument(name: "Composed", initials: composed)
        let page = MyDocumentPage(title: "Page", pageKey: composed)
        let content = MyDocumentPageContent(pageId: page.id, content: "Wrong identity")
        context.insert(document)
        context.insert(page)
        context.insert(content)
        page.document = document
        content.page = page
        try context.save()

        let recorder = BookmarkListPersistedSourceRecorder()
        let hosted = BookmarkListPersistedMyDocumentSourceObserver(
            documentInitials: decomposed,
            pageKey: decomposed
        ) { source in
            BookmarkListPersistedSourceProbe(source: source, recorder: recorder)
        }
        .modelContainer(container)
        let host = makeWindowHost(hosted)
        defer { host.close() }

        let observedSourceDecision = await waitUntil { recorder.count > 0 }
        XCTAssertTrue(observedSourceDecision)
        XCTAssertNil(recorder.latest)
        withExtendedLifetime(container) {}
    }

    /** Hosts one real SwiftUI hierarchy long enough for destination presentation and layout. */
    private func host<Content: View>(
        _ content: Content,
        recorder: BookmarkListViewportFrameRecorder
    ) async -> (frame: CGRect, bounds: CGRect, observations: [CGRect]) {
        let bounds = CGRect(x: 0, y: 0, width: 375, height: 667)
        let controller = UIHostingController(rootView: content)
        let window = UIWindow(frame: bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = bounds
        controller.view.setNeedsLayout()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

        let deadline = Date().addingTimeInterval(1)
        repeat {
            controller.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        } while !Self.fillsViewport(recorder.lastFrame, bounds: bounds) && Date() < deadline

        let frame = recorder.lastFrame ?? .null
        let observations = recorder.frames
        window.isHidden = true
        window.rootViewController = nil
        return (frame, bounds, observations)
    }

    /** Mounts a SwiftUI hierarchy in a finite live window for observation tests. */
    private func makeWindowHost<Content: View>(_ content: Content) -> BookmarkListWindowHost {
        let bounds = CGRect(x: 0, y: 0, width: 375, height: 667)
        let controller = UIHostingController(rootView: content)
        let window = UIWindow(frame: bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = bounds
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return BookmarkListWindowHost(window: window)
    }

    /** Passively waits for a correlated observation while yielding the main actor. */
    private func waitUntil(
        timeout: TimeInterval = 1,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        return predicate()
    }

    /** Compares the measured destination against its actual owner rather than a device constant. */
    private func assertFillsViewport(
        _ frame: CGRect,
        bounds: CGRect,
        observations: [CGRect] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let evidence = observations.map { String(describing: $0) }.joined(separator: ", ")
        XCTAssertFalse(
            frame.isNull,
            "Expected the Bookmark activity to publish a layout frame. Observed: [\(evidence)]",
            file: file,
            line: line
        )
        let visible = frame.intersection(bounds)
        XCTAssertGreaterThanOrEqual(
            visible.width,
            bounds.width * 0.9,
            "Expected Bookmark activity width to fill its finite owner; measured \(frame). Observed: [\(evidence)]",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            visible.height,
            bounds.height * 0.8,
            "Expected Bookmark activity height to fill its finite owner; measured \(frame). Observed: [\(evidence)]",
            file: file,
            line: line
        )
    }

    /** Returns whether a measured frame occupies the owner-relative activity viewport contract. */
    private static func fillsViewport(_ frame: CGRect?, bounds: CGRect) -> Bool {
        guard let frame, !frame.isNull else { return false }
        let visible = frame.intersection(bounds)
        return visible.width >= bounds.width * 0.9 && visible.height >= bounds.height * 0.8
    }

    /** Seeds the same population shape as the failing ten-row performance fixture. */
    private func seedPopulatedBookmarkList(in context: ModelContext) throws {
        for index in 0..<10 {
            let ordinal = 4 + index
            let bookmark = BibleBookmark(
                kjvOrdinalStart: ordinal,
                kjvOrdinalEnd: ordinal,
                ordinalStart: ordinal,
                ordinalEnd: ordinal,
                v11n: "KJVA",
                createdAt: Date(timeIntervalSince1970: TimeInterval(ordinal)),
                lastUpdatedOn: Date(timeIntervalSince1970: TimeInterval(ordinal))
            )
            bookmark.book = "Genesis"
            context.insert(bookmark)
            if index < 2 {
                let note = BibleBookmarkNotes(
                    bookmarkId: bookmark.id,
                    notes: String(repeating: "Visible bookmark note \(index). ", count: 12)
                )
                context.insert(note)
                note.bookmark = bookmark
            }
        }
        try context.save()
    }

    /** Builds the two-label, one-bookmark owner used by the production assignment destination. */
    private func makeLabelAssignmentFixture() throws -> (container: ModelContainer, bookmarkID: UUID) {
        let container = try makeHostedBookmarkListModelContainer()
        let context = ModelContext(container)
        let seedLabel = BibleCore.Label(name: "UI Test Seed", color: 0xFF91A7FF)
        let otherLabel = BibleCore.Label(name: "Other Label", color: 0xFFFFCC99)
        let bookmark = BibleBookmark(
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            ordinalStart: 4,
            ordinalEnd: 4,
            v11n: "KJVA"
        )
        context.insert(seedLabel)
        context.insert(otherLabel)
        context.insert(bookmark)
        try context.save()
        return (container, bookmark.id)
    }
}

/** Keeps one test-owned UIKit window alive until its observation has completed. */
@MainActor
private final class BookmarkListWindowHost {
    private var window: UIWindow?

    init(window: UIWindow) {
        self.window = window
    }

    func close() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    /** Recognizes user-visible text from the actual hosted window pixels. */
    func recognizedPixelText() -> [String] {
        guard let window else { return [] }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in
            window.layer.render(in: context.cgContext)
        }
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }
}

/** Captures the latest real global frame without feeding test state back into SwiftUI layout. */
@MainActor
private final class BookmarkListViewportFrameRecorder {
    private(set) var frames: [CGRect] = []

    var lastFrame: CGRect? { frames.last }

    func record(_ frame: CGRect) {
        if frames.last != frame {
            frames.append(frame)
        }
    }
}

/** Records distinct observed source values without feeding state back into SwiftUI. */
@MainActor
private final class BookmarkListPersistedSourceRecorder {
    private var values: [BibleReaderPreparedMyDocumentSource?] = []

    var count: Int { values.count }
    var latest: BibleReaderPreparedMyDocumentSource? { values.last ?? nil }

    func record(_ value: BibleReaderPreparedMyDocumentSource?) {
        if values.isEmpty || values.last! != value {
            values.append(value)
        }
    }
}

/** Main-owner test loader that records each visible-row projection attempt. */
@MainActor
private final class BookmarkListRowLoadRecorder {
    var content: String
    private(set) var loadedContents: [String] = []

    init(content: String) {
        self.content = content
    }

    func load(_ request: BookmarkListRowProjectionRequest) -> BookmarkListResolvedRowProjection {
        loadedContents.append(content)
        return BookmarkListResolvedRowProjection(
            request: request,
            reference: "Selected: page",
            textProjection: BookmarkListTextProjection(
                prefix: "",
                selectedText: content,
                suffix: "",
                fullText: content
            )
        )
    }
}

/** Publishes each SwiftData-observed exact source value to the test recorder. */
private struct BookmarkListPersistedSourceProbe: View {
    let source: BibleReaderPreparedMyDocumentSource?
    let recorder: BookmarkListPersistedSourceRecorder

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { recorder.record(source) }
            .onChange(of: source) { _, value in recorder.record(value) }
    }
}

/** Places the production Bookmark activity beside a geometry preference used only for observation. */
private struct BookmarkListViewportProbe: View {
    let recorder: BookmarkListViewportFrameRecorder

    var body: some View {
        BookmarkListView()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: BookmarkListViewportFramePreferenceKey.self,
                        value: proxy.frame(in: .global)
                    )
                }
            }
            .onPreferenceChange(BookmarkListViewportFramePreferenceKey.self) {
                recorder.record($0)
            }
    }
}

/** Observes an arbitrary positive-control view through the same preference path as Bookmark list. */
private struct BookmarkListViewportProbeContent<Content: View>: View {
    let recorder: BookmarkListViewportFrameRecorder
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: BookmarkListViewportFramePreferenceKey.self,
                        value: proxy.frame(in: .global)
                    )
                }
            }
            .onPreferenceChange(BookmarkListViewportFramePreferenceKey.self) {
                recorder.record($0)
            }
    }
}

/** Measures the real assignment activity without any navigation container. */
private struct BookmarkListLabelAssignmentProbe: View {
    let bookmarkID: UUID
    let recorder: BookmarkListViewportFrameRecorder

    var body: some View {
        LabelAssignmentView(
            bookmarkId: bookmarkID,
            surfacePalette: .standard,
            onDismiss: {}
        )
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BookmarkListViewportFramePreferenceKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        }
        .onPreferenceChange(BookmarkListViewportFramePreferenceKey.self) {
            recorder.record($0)
        }
    }
}

/** Minimal real shared activity surface used to separate shell layout from Bookmark state. */
private struct BookmarkListMinimalActivity: View {
    var body: some View {
        AndroidActivitySurface(palette: .standard) {
            AndroidActivityTopAppBar(
                title: "Bookmarks",
                accessibilityIdentifier: "bookmarkListMinimalAppBar",
                backgroundColor: ReaderThemeSurfacePalette.standard.toolbarBackgroundColor,
                foregroundColor: ReaderThemeSurfacePalette.standard.toolbarForegroundColor,
                onBack: {}
            ) {
                EmptyView()
            }
        } content: {
            ScrollView {
                Text("Bookmark content")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/** Latest geometry emitted by the Bookmark activity under test. */
private struct BookmarkListViewportFramePreferenceKey: PreferenceKey {
    static var defaultValue = CGRect.null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        guard !next.isNull else { return }
        value = next
    }
}

/** Builds the exact in-memory schema read by the hosted Bookmark activity on appearance. */
private func makeHostedBookmarkListModelContainer() throws -> ModelContainer {
    let schema = Schema([
        BibleBookmark.self,
        BibleBookmarkNotes.self,
        BibleBookmarkToLabel.self,
        GenericBookmark.self,
        GenericBookmarkNotes.self,
        GenericBookmarkToLabel.self,
        BibleCore.Label.self,
        StudyPadTextEntry.self,
        StudyPadTextEntryText.self,
        Setting.self,
        MyDocument.self,
        MyDocumentPage.self,
        MyDocumentPageContent.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}
