// ContentView.swift — Root navigation container

import SwiftUI
import SwiftData
import BibleUI
import BibleCore

/// Root content view managing the app's navigation structure.
///
/// On iPhone: Single-column navigation
/// On iPad/Mac: Sidebar navigation with split view
struct ContentView: View {
    @State private var selectedTab: Tab? = .bible
    @State private var showSettings = false
    @State private var showWorkspaces = false
    @Environment(\.modelContext) private var modelContext
    @State private var displaySettings: TextDisplaySettings = .appDefaults
    @State private var nightMode = false

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
        .preferredColorScheme(nightMode ? .dark : nil)
        .onAppear {
            let store = SettingsStore(modelContext: modelContext)
            nightMode = store.getBool("night_mode")
        }
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
            NavigationLink(value: Tab.bookmarks) {
                Label("Bookmarks", systemImage: "bookmark")
            }
            NavigationLink(value: Tab.search) {
                Label("Search", systemImage: "magnifyingglass")
            }
            NavigationLink(value: Tab.readingPlan) {
                Label("Reading Plans", systemImage: "calendar")
            }

            Section {
                NavigationLink {
                    ModuleBrowserView()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                NavigationLink {
                    SettingsView(
                        displaySettings: $displaySettings,
                        nightMode: $nightMode
                    )
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .navigationTitle("AndBible")
    }
}
