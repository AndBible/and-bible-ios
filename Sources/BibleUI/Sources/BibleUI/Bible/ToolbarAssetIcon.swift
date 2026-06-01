import SwiftUI

/**
 Compatibility wrapper for existing reader toolbar, drawer, and overflow icon call sites.

 The wrapper preserves the reader-facing type while delegating shared template-image behavior to
 `AndBibleIconView`, allowing settings icons to use the same rendering contract without a broad
 rename across reader surfaces.

 - Parameters:
   - name: Asset catalog image name available in the `BibleUI` module bundle.
   - size: Square point size used for the rendered icon frame.
 - Returns: A template-tinted packaged icon constrained to `size` by `size` points.
 - Side effects: Loads image data from the module bundle when SwiftUI resolves the image.
 - Failure modes: Missing assets follow SwiftUI image placeholder behavior; this wrapper does not
   validate asset names at construction time.
 */
struct ToolbarAssetIcon: View {
    /// Asset catalog image name available in the `BibleUI` module bundle.
    let name: String

    /// Square point size used for the rendered icon frame.
    var size: CGFloat = 18

    /// Template-tinted image body provided by the shared AndBible icon renderer.
    var body: some View {
        AndBibleIconView(name: name, size: size)
    }
}
