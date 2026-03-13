// ContentView.swift — Root navigation container

import SwiftUI
import SwiftData
import BibleUI
import BibleCore

/**
 Root content view managing the app's navigation structure.

 On iPhone: Single-column navigation
 On iPad/Mac: Sidebar navigation with split view
 */
struct ContentView: View {
    @State private var selectedTab: Tab? = .bible
    @State private var showSettings = false
    @State private var showWorkspaces = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var displaySettings: TextDisplaySettings = .appDefaults
    @State private var nightMode = false
    @State private var nightModeMode = AppPreferenceRegistry.stringDefault(for: .nightModePref3) ?? NightModeSetting.system.rawValue

    enum Tab: Hashable {
        case bible
        case bookmarks
        case search
        case readingPlan
    }

    var body: some View {
        Group {
            #if os(macOS)
            macLayout
            #else
            adaptiveLayout
            #endif
        }
        .preferredColorScheme(preferredColorSchemeOverride)
        .onAppear {
            reloadNightModePreferences()
        }
        .onChange(of: colorScheme) { _, _ in
            reloadNightModePreferences()
        }
    }

    private var preferredColorSchemeOverride: ColorScheme? {
        switch NightModeSettingsResolver.effectiveMode(from: nightModeMode) {
        case .system:
            return nil
        case .automatic, .manual:
            return nightMode ? .dark : .light
        }
    }

    private func reloadNightModePreferences() {
        let store = SettingsStore(modelContext: modelContext)
        nightModeMode = store.getString(.nightModePref3)
        let manualNightMode = store.getBool("night_mode")
        nightMode = NightModeSettingsResolver.isNightMode(
            rawValue: nightModeMode,
            manualNightMode: manualNightMode,
            systemIsDark: colorScheme == .dark
        )
    }

    // MARK: - iOS Layout (adapts for iPhone vs iPad)

    #if os(iOS)
    @ViewBuilder
    private var adaptiveLayout: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NavigationSplitView {
                sidebar
            } detail: {
                detailView
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack {
                BibleReaderView()
            }
        }
    }
    #endif

    // MARK: - Mac Layout

    #if os(macOS)
    private var macLayout: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
    }
    #endif

    // MARK: - Detail View (driven by sidebar selection)

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .bible, .none:
            BibleReaderView()
        case .bookmarks:
            NavigationStack {
                BookmarkListView { book, chapter in
                    selectedTab = .bible
                }
            }
        case .search:
            NavigationStack {
                SearchView(swordModule: nil) { book, chapter in
                    selectedTab = .bible
                }
            }
        case .readingPlan:
            NavigationStack {
                ReadingPlanListView()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedTab) {
            NavigationLink(value: Tab.bible) {
                Label("Bible", systemImage: "book")
            }
            .accessibilityIdentifier("contentTabBible")
            NavigationLink(value: Tab.bookmarks) {
                Label("Bookmarks", systemImage: "bookmark")
            }
            .accessibilityIdentifier("contentTabBookmarks")
            NavigationLink(value: Tab.search) {
                Label("Search", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("contentTabSearch")
            NavigationLink(value: Tab.readingPlan) {
                Label("Reading Plans", systemImage: "calendar")
            }
            .accessibilityIdentifier("contentTabReadingPlans")

            Section {
                NavigationLink {
                    ModuleBrowserView()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("contentDownloadsLink")
                NavigationLink {
                    SettingsView(
                        displaySettings: $displaySettings,
                        nightMode: $nightMode,
                        nightModeMode: $nightModeMode
                    )
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                .accessibilityIdentifier("contentSettingsLink")
            }
        }
        .navigationTitle("AndBible")
    }
}
