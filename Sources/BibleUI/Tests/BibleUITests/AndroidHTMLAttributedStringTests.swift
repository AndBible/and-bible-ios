import SwiftUI
import XCTest
import SwordKit
import UIKit

@testable import BibleUI

/** Protects the worker-safe Android HTML projection boundary used by native SwiftUI text. */
final class AndroidHTMLAttributedStringTests: XCTestCase {
    /** Verifies entities, block breaks, nested emphasis, and links survive native translation. */
    func testAttributedStringUsesPinnedAndroidProjection() throws {
        let attributed = AttributedString(
            htmlBody: "<p><b>A&amp;<i>B</i></b> <a href='https://example.test/help'>Help</a></p>"
        )

        XCTAssertEqual(String(attributed.characters), "A&B Help\n\n")
        XCTAssertEqual(
            attributed.runs.compactMap(\.link).map(\.absoluteString),
            ["https://example.test/help"]
        )
        XCTAssertTrue(attributed.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertTrue(attributed.runs.contains {
            $0.inlinePresentationIntent?.contains(.emphasized) == true
        })
    }

    /** Verifies malformed HTML remains visible through tolerant TagSoup repair. */
    func testAttributedStringRepairsMalformedInlineMarkupWithoutImporterFailure() throws {
        let attributed = AttributedString(htmlBody: "before <b>bold <i>both</b> after")

        XCTAssertEqual(String(attributed.characters), "before bold both after")
    }

    /** A style boundary inside one grapheme does not discard a later independent style range. */
    func testAttributedStringPreservesLaterStyleAfterCombiningScalarBoundary() {
        let attributed = AttributedString(htmlBody: "a<b>\u{0301}</b><i>x</i>")

        XCTAssertEqual(String(attributed.characters), "a\u{0301}x")
        XCTAssertTrue(attributed.runs.contains {
            String(attributed[$0.range].characters) == "x"
                && $0.inlinePresentationIntent?.contains(.emphasized) == true
        })
    }

    /** Nested face, size, and color spans retain the innermost Android style per text run. */
    func testAttributedStringComposesNestedFontSizeAndColor() throws {
        let attributed = AttributedString(
            htmlBody: "<font face='serif' color='red'><big>A<span style='color:blue'>"
                + "<small>B</small></span></big></font>"
        )
        let outer = try XCTUnwrap(attributed.runs.first {
            String(attributed[$0.range].characters) == "A"
        })
        let inner = try XCTUnwrap(attributed.runs.first {
            String(attributed[$0.range].characters) == "B"
        })

        XCTAssertEqual(outer.font, .system(size: 20, design: .serif))
        XCTAssertEqual(inner.font, .system(size: 16, design: .serif))
        XCTAssertEqual(
            outer.foregroundColor,
            Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
        )
        XCTAssertEqual(
            inner.foregroundColor,
            Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1)
        )
    }

    /** Native block rendering draws the pixel geometry pinned by AOSP BulletSpan and QuoteSpan. */
    @MainActor
    func testAndroidHTMLTextRendersListAndQuoteParagraphs() {
        let bulletImage = renderedImage(
            html: "<ul><li>&nbsp;</li></ul>",
            size: CGSize(width: 40, height: 40)
        )
        let quoteImage = renderedImage(
            html: "<blockquote>&nbsp;</blockquote>",
            size: CGSize(width: 40, height: 40)
        )

        let bulletBounds = nonWhitePixelBounds(in: bulletImage)
        XCTAssertEqual(bulletBounds?.minX, 0)
        XCTAssertEqual(bulletBounds?.width, 8)
        XCTAssertEqual(bulletBounds?.height, 8)
        let quoteBounds = bluePixelBounds(in: quoteImage)
        XCTAssertEqual(quoteBounds?.minX, 0)
        XCTAssertEqual(quoteBounds?.width, 2)
        XCTAssertGreaterThanOrEqual(quoteBounds?.height ?? 0, 16)

        let nestedBulletImage = renderedImage(
            html: "<ul><li><font color='white'>Outer</font><ul><li>&nbsp;</li></ul></li></ul>",
            size: CGSize(width: 60, height: 80)
        )
        let nestedBulletGlyphs = darkPixelComponents(in: nestedBulletImage)
            .filter { $0.width <= 8 && $0.height <= 8 }
            .sorted { $0.minY < $1.minY }
        XCTAssertEqual(
            nestedBulletGlyphs.count,
            2,
            "Expected one visible bullet glyph for each nested list paragraph"
        )
        if nestedBulletGlyphs.count == 2 {
            XCTAssertEqual(nestedBulletGlyphs[1].minX - nestedBulletGlyphs[0].minX, 10)
        }
        let nestedQuoteBounds = bluePixelBounds(in: renderedImage(
            html: "<blockquote><blockquote>&nbsp;</blockquote></blockquote>",
            size: CGSize(width: 40, height: 40)
        ))
        XCTAssertEqual(nestedQuoteBounds?.minX, 0)
        XCTAssertEqual(nestedQuoteBounds?.width, 6)
    }

    /** Center alignment moves every wrapped line while owner defaults leave HTML colors intact. */
    @MainActor
    func testAndroidHTMLTextRendersMultilineAlignmentAndSourceColor() {
        let size = CGSize(width: 200, height: 80)
        let startBounds = nonWhitePixelBounds(in: renderedImage(
            html: "<p style='text-align:start'>Short<br>A much longer line</p>",
            size: size
        ))
        let centeredBounds = nonWhitePixelBounds(in: renderedImage(
            html: "<p style='text-align:center'>Short<br>A much longer line</p>",
            size: size
        ))
        XCTAssertGreaterThan(
            centeredBounds?.minX ?? 0,
            (startBounds?.minX ?? 0) + 10
        )

        let colored = renderedImage(
            html: "<font color='red'>Visible red</font>",
            size: size,
            baseForegroundColor: .green
        )
        XCTAssertNotNil(redPixelBounds(in: colored))
        XCTAssertNil(greenPixelBounds(in: colored))
    }

    /** Renders one Android HTML view into a fixed one-pixel-per-point bitmap. */
    @MainActor
    private func renderedImage(
        html: String,
        size: CGSize,
        baseForegroundColor: Color? = nil
    ) -> UIImage? {
        let renderer = ImageRenderer(
            content: AndroidHTMLText(
                htmlBody: html,
                foregroundColor: baseForegroundColor
            )
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .foregroundStyle(Color.black)
                .background(Color.white)
        )
        renderer.scale = 1
        return renderer.uiImage
    }

    /** Returns the bounding box of every non-white pixel in a deterministic RGBA bitmap. */
    private func nonWhitePixelBounds(in image: UIImage?) -> CGRect? {
        pixelBounds(in: image) { red, green, blue, alpha in
            alpha > 200 && (red < 240 || green < 240 || blue < 240)
        }
    }

    /** Returns the bounding box of AOSP QuoteSpan's opaque blue stripe. */
    private func bluePixelBounds(in image: UIImage?) -> CGRect? {
        pixelBounds(in: image) { red, green, blue, alpha in
            alpha > 200 && red < 32 && green < 32 && blue > 220
        }
    }

    /** Returns the bounding box of explicit opaque-red HTML text. */
    private func redPixelBounds(in image: UIImage?) -> CGRect? {
        pixelBounds(in: image) { red, green, blue, alpha in
            alpha > 200 && red > 220 && green < 48 && blue < 48
        }
    }

    /** Returns the bounding box of a green owner default that source HTML should override. */
    private func greenPixelBounds(in image: UIImage?) -> CGRect? {
        pixelBounds(in: image) { red, green, blue, alpha in
            alpha > 200 && red < 48 && green > 96 && blue < 48
        }
    }

    /** Converts a rendered image to RGBA and bounds pixels accepted by one independent oracle. */
    private func pixelBounds(
        in image: UIImage?,
        accepted: (UInt8, UInt8, UInt8, UInt8) -> Bool
    ) -> CGRect? {
        guard let cgImage = image?.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drewImage = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        var minimumX = width
        var minimumY = height
        var maximumX = -1
        var maximumY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard accepted(
                    pixels[offset],
                    pixels[offset + 1],
                    pixels[offset + 2],
                    pixels[offset + 3]
                ) else { continue }
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }

    /** Finds disconnected dark glyph cores so nested list bullets are counted independently. */
    private func darkPixelComponents(in image: UIImage?) -> [CGRect] {
        guard let cgImage = image?.cgImage else { return [] }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drewImage = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return [] }

        func isDark(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return pixels[offset + 3] > 200
                && pixels[offset] < 64
                && pixels[offset + 1] < 64
                && pixels[offset + 2] < 64
        }

        var visited = [Bool](repeating: false, count: width * height)
        var components: [CGRect] = []
        for y in 0..<height {
            for x in 0..<width where isDark(x, y) && !visited[y * width + x] {
                var queue = [(x, y)]
                visited[y * width + x] = true
                var cursor = 0
                var minimumX = x
                var minimumY = y
                var maximumX = x
                var maximumY = y
                while cursor < queue.count {
                    let point = queue[cursor]
                    cursor += 1
                    minimumX = min(minimumX, point.0)
                    minimumY = min(minimumY, point.1)
                    maximumX = max(maximumX, point.0)
                    maximumY = max(maximumY, point.1)
                    for neighbor in [
                        (point.0 - 1, point.1),
                        (point.0 + 1, point.1),
                        (point.0, point.1 - 1),
                        (point.0, point.1 + 1),
                    ] where neighbor.0 >= 0 && neighbor.0 < width
                        && neighbor.1 >= 0 && neighbor.1 < height {
                        let neighborIndex = neighbor.1 * width + neighbor.0
                        if !visited[neighborIndex], isDark(neighbor.0, neighbor.1) {
                            visited[neighborIndex] = true
                            queue.append(neighbor)
                        }
                    }
                }
                components.append(CGRect(
                    x: minimumX,
                    y: minimumY,
                    width: maximumX - minimumX + 1,
                    height: maximumY - minimumY + 1
                ))
            }
        }
        return components
    }
}
