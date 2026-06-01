import SwiftUI

/**
 Renders one packaged AndBible image asset as a template-tinted SwiftUI icon.

 This view centralizes the rendering behavior shared by Android-sourced toolbar, drawer, overflow,
 and settings glyphs. Callers provide an asset name from a packaged `BibleUI` asset catalog and keep
 ownership of row sizing, color, accessibility labels, and interaction state at the call site.

 - Parameters:
   - name: Asset catalog image name available in the `BibleUI` module bundle.
   - size: Square point size used for the rendered icon frame.
 - Returns: A resizable SwiftUI image constrained to `size` by `size` points.
 - Side effects: Loads image data from the module bundle when SwiftUI resolves the image.
 - Failure modes: A missing asset renders as SwiftUI's default missing-image placeholder behavior;
   this type does not crash or validate the catalog at construction time.
 */
struct AndBibleIconView: View {
    /// Asset catalog image name available in the `BibleUI` module bundle.
    let name: String

    /// Square point size used for the rendered icon frame.
    var size: CGFloat = 18

    /// Template-tinted image body resolved from the module resource bundle.
    var body: some View {
        Image(name, bundle: .module)
            .renderingMode(.template)
            .interpolation(.high)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
