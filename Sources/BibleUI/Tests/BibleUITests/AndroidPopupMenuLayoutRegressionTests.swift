import SwiftUI
import Vision
import XCTest

@testable import BibleUI

/**
 Protects multi-row Android popup menus from collapsing their rows into the same surface position.

 These tests render the production menu views and use Vision observations as an independent
 pixel-level oracle. A layout-neutral tuple inside `AndroidPopupMenuSurface` becomes an overlay,
 so merely recognizing both labels is insufficient: their rendered bounds must be vertically
 disjoint. Rendering and OCR are synchronous, mutate no application state, and fail when an image
 cannot be produced or either expected label cannot be recognized.
 */
@MainActor
final class AndroidPopupMenuLayoutRegressionTests: XCTestCase {
    /** The bookmark menu renders Selection above Verses instead of overlaying both row labels. */
    func testSelectionBookmarkMenuRendersVerticallyDistinctRows() throws {
        let observations = try recognizedText(
            in: BibleSelectionBookmarkMenu(
                colorScheme: .light,
                surfacePalette: .standard,
                onSelection: {},
                onWholeVerse: {}
            ),
            colorScheme: .light,
            dynamicTypeSize: .large
        )

        try assertVerticallyDisjoint(
            "Selection",
            and: "Verses",
            in: observations
        )
    }

    /** The reading-progress menu keeps its two dark-mode rows separate at a larger text size. */
    func testReadingProgressOverflowMenuRendersVerticallyDistinctRows() throws {
        let nightPalette = ReaderThemeSurfacePalette(
            settings: .appDefaults,
            nightMode: true
        )
        let observations = try recognizedText(
            in: ReadingProgressOverflowMenu(
                colorScheme: .dark,
                surfacePalette: nightPalette,
                onOpenSettings: {},
                onOpenHelp: {}
            ),
            colorScheme: .dark,
            dynamicTypeSize: .xxLarge
        )

        try assertVerticallyDisjoint(
            "Progress",
            and: "Help",
            in: observations
        )
    }

    /** A missing settings destination leaves Help visible without drawing a phantom settings row. */
    func testReadingProgressOverflowMenuWithoutSettingsRendersOnlyHelp() throws {
        let observations = try recognizedText(
            in: ReadingProgressOverflowMenu(
                colorScheme: .light,
                surfacePalette: .standard,
                onOpenSettings: nil,
                onOpenHelp: {}
            ),
            colorScheme: .light,
            dynamicTypeSize: .large
        )

        XCTAssertNotNil(observation(matching: "Help", in: observations))
        XCTAssertNil(observation(matching: "Progress", in: observations))
    }

    /**
     Renders a production menu at its real popup width and recognizes text from the resulting pixels.

     - Parameters:
       - view: Production SwiftUI menu whose layout is under test.
       - colorScheme: Explicit appearance matching the menu's palette.
       - dynamicTypeSize: Text size used for this deterministic render pass.
     - Returns: Vision text observations with normalized image-space bounding boxes.
     - Throws: An XCTest unwrap error when SwiftUI cannot produce a bitmap, or a Vision error when
       OCR cannot process that bitmap. The helper changes no shared state and creates no tasks.
     */
    private func recognizedText<Content: View>(
        in view: Content,
        colorScheme: ColorScheme,
        dynamicTypeSize: DynamicTypeSize
    ) throws -> [VNRecognizedTextObservation] {
        let renderer = ImageRenderer(
            content: ZStack(alignment: .topLeading) {
                view
                    .frame(width: 220)
                    .fixedSize(horizontal: false, vertical: true)
            }
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.colorScheme, colorScheme)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        )
        renderer.scale = 2
        let cgImage = try XCTUnwrap(renderer.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return request.results ?? []
    }

    /**
     Asserts two recognized labels occupy non-overlapping vertical bands in the rendered menu.

     - Parameters:
       - firstLabel: Space-separated words expected in the first OCR observation.
       - secondLabel: Space-separated words expected in the second OCR observation.
       - observations: Vision results from the production menu bitmap.
     - Throws: An XCTest unwrap error when either label is absent. This deterministic comparison
       has no side effects; overlap means the menu rows were composed as an overlay.
     */
    private func assertVerticallyDisjoint(
        _ firstLabel: String,
        and secondLabel: String,
        in observations: [VNRecognizedTextObservation]
    ) throws {
        let first = try XCTUnwrap(
            observation(matching: firstLabel, in: observations),
            "Expected OCR to recognize '\(firstLabel)'; found \(recognizedStrings(in: observations))"
        )
        let second = try XCTUnwrap(
            observation(matching: secondLabel, in: observations),
            "Expected OCR to recognize '\(secondLabel)'; found \(recognizedStrings(in: observations))"
        )

        XCTAssertGreaterThanOrEqual(
            first.boundingBox.minY,
            second.boundingBox.maxY,
            "Expected '\(firstLabel)' above '\(secondLabel)' in Vision's lower-left coordinates, "
                + "but OCR bounds overlap or reverse order: "
                + "\(first.boundingBox) and \(second.boundingBox)"
        )
    }

    /**
     Finds the first OCR observation containing every normalized word from an expected label.

     - Parameters:
       - expectedLabel: Space-separated words to match, ignoring punctuation and case.
       - observations: Vision observations to search in their reported order.
     - Returns: The first matching observation, or `nil` when no single rendered line contains all
       expected words. The lookup is deterministic and mutates no state.
     */
    private func observation(
        matching expectedLabel: String,
        in observations: [VNRecognizedTextObservation]
    ) -> VNRecognizedTextObservation? {
        let expectedWords = normalizedWords(in: expectedLabel)
        return observations.first { observation in
            guard let candidate = observation.topCandidates(1).first else { return false }
            let candidateWords = normalizedWords(in: candidate.string)
            return expectedWords.allSatisfy(candidateWords.contains)
        }
    }

    /** Returns normalized alphanumeric words for punctuation-insensitive OCR matching. */
    private func normalizedWords(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    /** Returns top OCR candidates for assertion diagnostics without changing recognition results. */
    private func recognizedStrings(in observations: [VNRecognizedTextObservation]) -> [String] {
        observations.compactMap { $0.topCandidates(1).first?.string }
    }
}
