// AndroidMyDocumentListComponents.swift -- Shared rows for Android My Documents activities

import SwiftUI

/**
 Renders the common RecyclerView-style row used by Android's document and document-page managers.

 The row reuses packaged Android drag, AI, and overflow assets. It deliberately exposes separate
 open, drag, and popup controls so callers can preserve Android's interaction boundaries while
 retaining their own draft-session mutations and anchored popup state.

 Inputs: title, subtitle, AI marker visibility, drag payload, owner palette, and explicit actions

 Output: one flat app-owned management row with Android's 60-point drag area and 48-point menu area

 Side effects: starts a system drag for the supplied string payload or invokes an owner command

 Failure modes: none; a failed external drop leaves the caller's ordered collection unchanged
 */
struct AndroidMyDocumentManagementRow: View {
    let title: String
    let subtitle: String
    let showsAIIndicator: Bool
    let dragPayload: String
    let menuAnchorID: String
    let surfacePalette: ReaderThemeSurfacePalette
    let accessibilityIdentifier: String
    let accessibilityValue: String
    let onOpen: () -> Void
    let onShowMenu: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            AndBibleIconView(name: "MyDocumentDragHandle", size: 32)
                .foregroundStyle(AndroidResourcePalette.grey500)
                .frame(width: 60)
                .frame(minHeight: 68)
                .contentShape(Rectangle())
                .draggable(dragPayload)
                .accessibilityLabel(String(localized: "reorder", defaultValue: "Re-order"))

            if showsAIIndicator {
                AndBibleIconView(name: "MyDocumentAI", size: 24)
                    .foregroundStyle(AndroidResourcePalette.grey500)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("AI")
            }

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 18))
                        .foregroundStyle(surfacePalette.foregroundColor)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            AndroidActivityTopAppBarActionButton(
                icon: .asset("ToolbarOverflow"),
                accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                accessibilityIdentifier: "\(accessibilityIdentifier)MenuButton",
                foregroundColor: surfacePalette.secondaryForegroundColor,
                action: onShowMenu
            )
            .androidPopupMenuAnchor(id: menuAnchorID)
        }
        .frame(minHeight: 68)
        .background(surfacePalette.backgroundColor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityValue(accessibilityValue)
    }
}

/** Sanitizes My Documents values into stable cross-screen UI-test tokens. */
func myDocumentsAccessibilitySegment(_ value: String) -> String {
    value.replacingOccurrences(
        of: "[^A-Za-z0-9]+",
        with: "_",
        options: .regularExpression
    )
    .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}
