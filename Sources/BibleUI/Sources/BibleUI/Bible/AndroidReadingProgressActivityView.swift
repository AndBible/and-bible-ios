// AndroidReadingProgressActivityView.swift -- App-owned ReadingProgressActivity chrome

import SwiftUI

/// Stable in-content anchors used by Android-equivalent activity scroll commands.
enum AndroidReadingProgressScrollTarget: Hashable {
    case bibleOverview
}

/**
 Renders Android ReadingProgressActivity's shared activity chrome around caller-owned tab content.

 The shell composes the canonical app bar, fixed Material tabs, scroll viewport, and anchored
 overflow menu. It deliberately owns no progress data or mutation rules; `ReadingProgressView`
 remains the feature state owner while this type prevents native navigation bars, segmented pickers,
 and menus from leaking back into the route.

 Inputs: reader/workspace palette, selected tab binding, optional settings command, Help command,
 Back command, and tab-specific content

 Output: one full-screen app-owned Android activity surface

 Side effects: tab taps update the binding; app-bar/menu actions invoke the supplied callbacks

 Failure modes: a nil settings callback omits the unavailable settings row while retaining Help
 */
struct AndroidReadingProgressActivityView<Content: View>: View {
    /// Named popup origin shared by the action and anchored presentation modifier.
    private static var overflowAnchorID: String { "readingProgressOverflowAnchor" }

    /// Active reader/workspace appearance.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Parent-owned active Android tab.
    @Binding var selectedTab: ReadingProgressTab

    /// Android Up command.
    let onBack: () -> Void

    /// Optional settings destination command.
    let onOpenSettings: (() -> Void)?

    /// Feature Help command.
    let onOpenHelp: () -> Void

    /// Monotonic Android book-drill-down scroll request.
    let scrollToBibleOverviewRevision: Int

    /// Current tab's data-driven content.
    private let content: Content

    /// Active scheme used only to resolve the shared AppCompat accent.
    @Environment(\.colorScheme) private var colorScheme

    /// App-owned overflow visibility.
    @State private var showsOverflowMenu = false

    /**
     Creates the Reading Progress activity shell.

     - Parameters:
       - surfacePalette: Palette inherited from the launching reader/workspace.
       - selectedTab: Parent-owned Android tab binding.
       - onBack: Android Up command.
       - onOpenSettings: Optional route to Progress & memorization settings.
       - onOpenHelp: Feature Help command.
       - scrollToBibleOverviewRevision: Monotonic request to reveal the Bible Overview heading.
       - content: Current tab's vertically scrolling content.
     - Side effects: none until a tab or command is tapped.
     - Failure modes: none.
     */
    init(
        surfacePalette: ReaderThemeSurfacePalette,
        selectedTab: Binding<ReadingProgressTab>,
        onBack: @escaping () -> Void,
        onOpenSettings: (() -> Void)?,
        onOpenHelp: @escaping () -> Void,
        scrollToBibleOverviewRevision: Int,
        @ViewBuilder content: () -> Content
    ) {
        self.surfacePalette = surfacePalette
        _selectedTab = selectedTab
        self.onBack = onBack
        self.onOpenSettings = onOpenSettings
        self.onOpenHelp = onOpenHelp
        self.scrollToBibleOverviewRevision = scrollToBibleOverviewRevision
        self.content = content()
    }

    var body: some View {
        AndroidActivityScreen(
            title: String(
                localized: "reading_progress_title",
                defaultValue: "Read/Memory Progress"
            ),
            accessibilityIdentifier: "readingProgressAppBar",
            palette: surfacePalette,
            onBack: onBack
        ) {
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ToolbarOverflow"),
                accessibilityLabel: String(localized: "more_options", defaultValue: "More options"),
                accessibilityIdentifier: "readingProgressOverflowAction",
                foregroundColor: surfacePalette.toolbarForegroundColor
            ) {
                showsOverflowMenu.toggle()
            }
            .androidPopupMenuAnchor(id: Self.overflowAnchorID)
        } content: {
            VStack(spacing: 0) {
            AndroidFixedTabRow(
                items: ReadingProgressTab.allCases.map {
                    AndroidFixedTabItem(id: String($0.rawValue), value: $0, title: $0.title)
                },
                selection: $selectedTab,
                backgroundColor: surfacePalette.backgroundColor,
                foregroundColor: surfacePalette.foregroundColor,
                secondaryForegroundColor: surfacePalette.secondaryForegroundColor,
                accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme)
            )

            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: scrollToBibleOverviewRevision) { oldValue, newValue in
                    guard newValue != oldValue else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(AndroidReadingProgressScrollTarget.bibleOverview, anchor: .top)
                    }
                }
            }
            }
        }
        .androidAnchoredPopupMenu(
            anchorID: Self.overflowAnchorID,
            isPresented: $showsOverflowMenu,
            menuWidth: 260,
            estimatedMenuHeight: onOpenSettings == nil ? 50 : 100,
            accessibilityIdentifier: "readingProgressOverflowMenu"
        ) {
            overflowMenu
        }
    }

    /// Shared popup surface with Android menu order and exact resource labels.
    private var overflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "readingProgressOverflowMenuSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme)
        ) {
            if let onOpenSettings {
                AndroidPopupMenuRow(
                    title: String(
                        localized: "reading_progress_settings",
                        defaultValue: "Progress & memorization"
                    ),
                    accessibilityIdentifier: "readingProgressSettingsAction"
                ) {
                    showsOverflowMenu = false
                    onOpenSettings()
                }
            }

            AndroidPopupMenuRow(
                title: String(localized: "help", defaultValue: "Help"),
                accessibilityIdentifier: "readingProgressHelpAction"
            ) {
                showsOverflowMenu = false
                onOpenHelp()
            }
        }
    }
}
