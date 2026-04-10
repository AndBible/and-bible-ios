import SwiftUI

/// Renders one packaged toolbar icon using template tinting for Android-parity glyphs.
struct ToolbarAssetIcon: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        Image(name, bundle: .module)
            .renderingMode(.template)
            .interpolation(.high)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
