// AndroidReadingPlanSelectorView.swift -- App-owned ReadingPlanSelectorList presentation

import BibleCore
import SwiftUI

/**
 Renders Android's flat “Choose a Reading Plan” activity from the shared application components.

 The selector intentionally contains only Android's two-line catalog rows. It does not recreate the
 previous iOS Active/Completed sections, cards, swipe actions, import section, or native context menu.
 Long press opens the Android Reset context command through the shared anchored popup surface.
 */
struct AndroidReadingPlanSelectorView: View {
    private enum PopupAnchor {
        static func plan(_ code: String) -> String {
            "readingPlanSelector::\(readingPlanAccessibilitySegment(code))"
        }
    }

    let templates: [ReadingPlanTemplate]
    let startedPlanCodes: Set<String>
    let surfacePalette: ReaderThemeSurfacePalette
    let onBack: () -> Void
    let onSelect: (ReadingPlanTemplate) -> Void
    let onReset: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var contextPlanCode: String?
    @State private var showsContextMenu = false

    /** Builds the exact app bar, flat list, and long-press context surface. */
    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivityScreen(
                title: String(
                    localized: "rdg_plan_selector_title",
                    defaultValue: "Choose a Reading Plan"
                ),
                accessibilityIdentifier: "readingPlanSelectorAppBar",
                palette: surfacePalette,
                onBack: onBack
            ) {
                EmptyView()
            } content: {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(templates) { template in
                            templateRow(template)
                            Divider().overlay(surfacePalette.inactiveBorderColor)
                        }
                    }
                }
            }

            AndroidActivityAccessibilityMarker(
                label: String(
                    localized: "rdg_plan_selector_title",
                    defaultValue: "Choose a Reading Plan"
                ),
                accessibilityIdentifier: "availablePlansScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .androidAnchoredPopupMenu(
            anchorID: contextPlanCode.map(PopupAnchor.plan) ?? "readingPlanSelector::none",
            isPresented: $showsContextMenu,
            menuWidth: 210,
            estimatedMenuHeight: 50,
            accessibilityIdentifier: "readingPlanSelectorContextMenu"
        ) { contextMenu }
    }

    /**
     Builds Android's `simple_list_item_2` projection for one definition.

     A direct tap starts/selects the plan. A long press owns the source context-menu gesture without
     delegating presentation to iOS.
     */
    private func templateRow(_ template: ReadingPlanTemplate) -> some View {
        Button {
            showsContextMenu = false
            onSelect(template)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(template.name)
                    .font(.system(size: 18))
                    .foregroundStyle(surfacePalette.foregroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(template.description)
                    .font(.system(size: 16))
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            contextPlanCode = template.code
            showsContextMenu = true
        })
        .androidPopupMenuAnchor(id: PopupAnchor.plan(template.code))
        .accessibilityIdentifier("readingPlanTemplateButton")
        .accessibilityLabel(template.name)
        .accessibilityValue(template.code)
        .accessibilityAction(named: String(localized: "reset_generic", defaultValue: "Reset")) {
            onReset(template.code)
        }
    }

    /// Shared Android popup containing the selector's single source context-menu command.
    private var contextMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "readingPlanSelectorContextMenuSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            AndroidPopupMenuRow(
                title: String(localized: "reset_generic", defaultValue: "Reset"),
                icon: .asset("ActivityReset"),
                accessibilityIdentifier: "readingPlanSelectorResetButton",
                accessibilityValue: contextPlanCode.map {
                    startedPlanCodes.contains($0) ? "started" : "not-started"
                }
            ) {
                guard let contextPlanCode else { return }
                showsContextMenu = false
                onReset(contextPlanCode)
                self.contextPlanCode = nil
            }
        }
    }
}
