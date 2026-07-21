import Foundation
import XCTest
@testable import BibleCore
@testable import BibleView

/**
 Contract tests for the custom EPUB resource URL boundary shared by native HTML and WebKit.

 These tests keep the package identity in every route and attack path decoding before a request can
 reach `EpubReader`. Package-member containment itself is covered by `EpubReaderParityTests`.
 */
final class EpubResourceRouteTests: XCTestCase {
    /// Deterministic opaque generation token used by route fixtures.
    private let generation = "11111111-2222-3333-4444-555555555555"

    /**
     Verifies identical package paths remain scoped to the initials encoded by their source EPUB.

     Two generated URLs differ only by book initials. Parsing must retain those identities and the
     exact canonical path. A failure means the scheme handler could resolve shared paths through a
     different active EPUB instead of the document that emitted the resource reference.
     */
    func testResourceRoutePreservesBookIdentityForOverlappingPaths() throws {
        let canonicalPath = "OPS/images/shared cover.png"
        let alphaURL = try XCTUnwrap(URL(string: EpubResourceLocator.resourceURLString(
            identity: EpubResourceIdentity(
                bookInitials: "Epub-Alpha-1111",
                generationIdentifier: generation
            ),
            canonicalPath: canonicalPath
        )))
        let betaURL = try XCTUnwrap(URL(string: EpubResourceLocator.resourceURLString(
            identity: EpubResourceIdentity(
                bookInitials: "Epub-Beta-2222",
                generationIdentifier: generation
            ),
            canonicalPath: canonicalPath
        )))

        XCTAssertNotEqual(alphaURL, betaURL)
        XCTAssertEqual(
            EpubResourceRoute.parse(alphaURL),
            .resource(
                bookInitials: "Epub-Alpha-1111",
                generationIdentifier: generation,
                canonicalPath: canonicalPath
            )
        )
        XCTAssertEqual(
            EpubResourceRoute.parse(betaURL),
            .resource(
                bookInitials: "Epub-Beta-2222",
                generationIdentifier: generation,
                canonicalPath: canonicalPath
            )
        )

        let androidRangeInitials = "Epub-[x]\\^_epub"
        let punctuationURL = try XCTUnwrap(URL(string: EpubResourceLocator.resourceURLString(
            identity: EpubResourceIdentity(
                bookInitials: androidRangeInitials,
                generationIdentifier: generation
            ),
            canonicalPath: "OPS/images/shared.png"
        )))
        XCTAssertEqual(
            EpubResourceRoute.parse(punctuationURL),
            .resource(
                bookInitials: androidRangeInitials,
                generationIdentifier: generation,
                canonicalPath: "OPS/images/shared.png"
            )
        )
    }

    /**
     Verifies generated EPUB stylesheets use the same custom origin as nested fonts and images.

     The fixture uses Android's unusual retained backslash from its `A-z` regex. The active numeric
     key remains part of the typed route, while the reserved path segment keeps it distinct from
     ordinary package members. A failure can reject a portable Android identity, make WebKit block
     contained font URLs as cross-origin requests, or serve a stylesheet through the wrong EPUB.
     */
    func testStyleSheetRouteUsesBookScopedEpubOrigin() throws {
        let androidRangeInitials = "Epub-[x]\\^_epub"
        let url = try XCTUnwrap(URL(string: EpubResourceLocator.styleSheetURLString(
            identity: EpubResourceIdentity(
                bookInitials: androidRangeInitials,
                generationIdentifier: generation
            ),
            key: "27"
        )))

        XCTAssertEqual(url.host, "epub")
        XCTAssertEqual(
            EpubResourceRoute.parse(url),
            .styleSheet(
                bookInitials: androidRangeInitials,
                generationIdentifier: generation,
                key: "27"
            )
        )
    }

    /**
     Verifies custom routes reject encoded traversal, separators, NULs, and identity switching.

     Each URL is syntactically acceptable to Foundation but unsafe as a package route. The parser
     must reject it before opening an EPUB. A double-encoded slash is retained as a literal `%2F`
     filename, proving the boundary decodes once rather than conflating a filename with a separator.
     */
    func testResourceRouteRejectsAmbiguousEncodedPaths() throws {
        let malicious = [
            "andbible-resource://module-style/epub/Epub-Alpha/27/style.css",
            "andbible-resource://epub/Epub-Alpha/%2e%2e/OPS/secret.png",
            "andbible-resource://epub/Epub-Alpha/\(generation)/OPS%2F..%2FEpub-Beta/secret.png",
            "andbible-resource://epub/Epub-Alpha/\(generation)/%5C..%5CEpub-Beta/secret.png",
            "andbible-resource://epub/Epub-Alpha/\(generation)/OPS/images/%00.png",
            "andbible-resource://epub/Epub-Alpha/not%2Fa-generation/OPS/image.png"
        ]
        for rawURL in malicious {
            let url = try XCTUnwrap(URL(string: rawURL), rawURL)
            XCTAssertNil(EpubResourceRoute.parse(url), rawURL)
        }

        let literalURL = try XCTUnwrap(URL(
            string: "andbible-resource://epub/Epub-Alpha/\(generation)/OPS/images/literal%252Fname.png"
        ))
        XCTAssertEqual(
            EpubResourceRoute.parse(literalURL),
            .resource(
                bookInitials: "Epub-Alpha",
                generationIdentifier: generation,
                canonicalPath: "OPS/images/literal%2Fname.png"
            )
        )
    }
}
