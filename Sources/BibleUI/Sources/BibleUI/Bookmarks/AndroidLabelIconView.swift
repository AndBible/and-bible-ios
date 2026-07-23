// AndroidLabelIconView.swift -- Exact Android label-icon resource presentation

import BibleCore
import SwiftUI

/**
 Resolves Android's persisted custom-label icon names to the exact packaged vector resources.

 The mapping intentionally lives in BibleUI: canonical names remain a cross-platform persistence
 contract in BibleCore, while asset names and rendering are presentation concerns. Every resource
 is ported from Android's `customIconMap`; callers do not redraw those glyphs or substitute an SF
 Symbol for a known Android name.
 */
enum AndroidLabelIconAsset {
    /// Exact Android fallback shown by Label Edit when no custom icon is selected.
    static let defaultBookmarkAssetName = "LabelIconDefaultBookmark"

    /// Exact asset-catalog name for Android's explicit no-icon glyph.
    static let disabledAssetName = "LabelIconDisabled"

    /// Complete Android canonical-name to packaged-vector mapping.
    static let canonicalAssetNames: [String: String] = [
        "book": "LabelIconBook",
        "book-bible": "LabelIconBookBible",
        "cross": "LabelIconCross",
        "church": "LabelIconChurch",
        "star-of-david": "LabelIconStarOfDavid",
        "person-praying": "LabelIconPersonPraying",
        "info": "LabelIconInfo",
        "question": "LabelIconQuestion",
        "exclamation": "LabelIconExclamation",
        "lightbulb": "LabelIconLightbulb",
        "bell": "LabelIconBell",
        "flag": "LabelIconFlag",
        "star": "LabelIconStar",
        "tag": "LabelIconTag",
        "envelope": "LabelIconEnvelope",
        "comment": "LabelIconComment",
        "share-nodes": "LabelIconShareNodes",
        "link": "LabelIconLink",
        "handshake": "LabelIconHandshake",
        "clock": "LabelIconClock",
        "map-marker": "LabelIconMapMarker",
        "globe": "LabelIconGlobe",
        "landmark": "LabelIconLandmark",
        "calendar": "LabelIconCalendar",
        "user": "LabelIconUser",
        "music": "LabelIconMusic",
        "microphone": "LabelIconMicrophone",
        "key": "LabelIconKey",
        "crown": "LabelIconCrown",
        "heart": "LabelIconHeart",
        "heart-crack": "LabelIconHeartCrack",
        "robot": "LabelIconRobot",
    ]

    /**
     Returns the exact packaged asset for a persisted Android icon name.

     - Parameter canonicalName: Persisted Android `customIconMap` key.
     - Returns: Packaged vector asset name, or nil for legacy/unknown values.
     - Side effects: none.
     - Failure modes: Unknown values deliberately return nil so the renderer can preserve the
       older iOS SF-Symbol compatibility path without misrepresenting it as Android parity.
     */
    static func assetName(for canonicalName: String) -> String? {
        canonicalAssetNames[canonicalName]
    }
}

/**
 Renders one persisted label icon using Android's exact vector geometry.

 Inputs: canonical or legacy persisted icon name and the requested square size

 Output: template-tinted Android vector for canonical values, or the explicit legacy SF-Symbol
 compatibility fallback for values saved by older iOS builds

 Side effects: loads one packaged BibleUI resource when SwiftUI resolves the body

 Failure modes: an invalid legacy SF-Symbol name follows SwiftUI's missing-symbol behavior
 */
struct AndroidLabelIconView: View {
    /// Android canonical icon key or a legacy persisted iOS SF-Symbol value.
    let name: String

    /// Square rendered size in points.
    var size: CGFloat = 24

    @ViewBuilder
    var body: some View {
        if let assetName = AndroidLabelIconAsset.assetName(for: name) {
            AndBibleIconView(name: assetName, size: size)
        } else if let legacySymbol = BibleCore.Label.sfSymbol(for: name) {
            Image(systemName: legacySymbol)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}
