// EpubResourceLocator.swift -- EPUB custom-scheme URL construction

import Foundation

/**
 Generates custom-scheme URLs consumed by `BibleView`'s EPUB resource handler.

 The Android-visible book initials, immutable generation token, and each path segment are percent
 encoded independently. Readers therefore keep package and index resources on one generation even
 while an exact-name reinstall atomically selects a newer generation for future readers.
 */
public enum EpubResourceLocator {
    /// Custom scheme registered on the app's `WKWebViewConfiguration`.
    public static let scheme = "andbible-resource"

    /**
     Builds a resource URL for one installed EPUB member.

     - Parameters:
       - identity: Android-visible initials plus the immutable iOS generation token.
       - canonicalPath: Package-contained resource path.
       - fragment: Optional decoded resource fragment retained for SVG/media references.
     - Returns: Absolute custom-scheme URL string.
     - Side effects: None.
     - Failure modes: Invalid scalar sequences are retained through URL path percent encoding.
     */
    public static func resourceURLString(
        identity: EpubResourceIdentity,
        canonicalPath: String,
        fragment: String? = nil
    ) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "epub"
        components.path = "/\(identity.bookInitials)/\(identity.generationIdentifier)/\(canonicalPath)"
        components.fragment = fragment
        return components.url?.absoluteString ?? ""
    }

    /**
     Builds the stylesheet endpoint used by the shared Vue custom-CSS registration path.

     - Parameters:
       - identity: Android-visible initials plus the immutable iOS generation token.
       - key: Active EPUB manifest key.
     - Returns: Absolute custom-scheme URL string.
     - Side effects: None.
     */
    public static func styleSheetURLString(identity: EpubResourceIdentity, key: String) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "epub"
        components.path = "/\(identity.bookInitials)/\(identity.generationIdentifier)/.module-style/\(key)/style.css"
        return components.url?.absoluteString ?? ""
    }
}
