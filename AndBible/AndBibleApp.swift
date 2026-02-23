// AndBibleApp.swift — Main app entry point

import SwiftUI
import SwiftData
import BibleCore
import BibleUI
import SwordKit
#if os(iOS)
import UIKit
#endif

/// AndBible iOS — Powerful offline Bible study app.
///
/// Universal SwiftUI app for iPhone, iPad, and Mac.
@main
struct AndBibleApp: App {
    /// SwiftData model container for all persisted entities.
    let modelContainer: ModelContainer

    /// Core services shared across the app.
    @State private var windowManager: WindowManager
    private let speakService = SpeakService()
    @State private var syncService = SyncService()
    @State private var searchIndexService = SearchIndexService()

    /// Discrete mode persists across launches. The unlock just reveals Bible for this session.
    @AppStorage("discrete_mode") private var isDiscreteMode = false
    /// Temporary unlock for the current session — does NOT change the persisted setting.
    @State private var isUnlocked = false

    init() {
        // Configure SwiftData with all model types
        let schema = Schema([
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
            ReadingPlan.self,
            ReadingPlanDay.self,
            Repository.self,
            Setting.self,
        ])

        let modelConfiguration = ModelConfiguration(
            "AndBible",
            schema: schema,
            isStoredInMemoryOnly: false
        )

        // Set up SWORD module directory before creating any SwordManager
        SwordSetup.ensureModulesReady()

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            self.modelContainer = container

            // Initialize services that need ModelContext
            let context = ModelContext(container)
            let workspaceStore = WorkspaceStore(modelContext: context)
            let windowMgr = WindowManager(workspaceStore: workspaceStore)
            self._windowManager = State(initialValue: windowMgr)

            // Ensure at least one workspace exists
            let settingsStore = SettingsStore(modelContext: context)
            if let activeId = settingsStore.activeWorkspaceId,
               let workspace = workspaceStore.workspace(id: activeId) {
                windowMgr.setActiveWorkspace(workspace)
            } else {
                let workspaces = workspaceStore.workspaces()
                if let first = workspaces.first {
                    windowMgr.setActiveWorkspace(first)
                    settingsStore.activeWorkspaceId = first.id
                } else {
                    let newWorkspace = workspaceStore.createWorkspace(name: "Default")
                    windowMgr.setActiveWorkspace(newWorkspace)
                    settingsStore.activeWorkspaceId = newWorkspace.id
                }
            }

            // Seed default labels on first launch (matches Android)
            let bookmarkStore = BookmarkStore(modelContext: context)
            let bookmarkService = BookmarkService(store: bookmarkStore)
            bookmarkService.prepareDefaultLabels()
        } catch {
            fatalError("Failed to initialize SwiftData: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if isDiscreteMode && !isUnlocked {
                    CalculatorView {
                        withAnimation {
                            isUnlocked = true
                        }
                    }
                } else {
                    ContentView()
                        .environment(windowManager)
                        .environment(syncService)
                        .environment(searchIndexService)
                }
            }
            .onChange(of: isDiscreteMode) { _, newValue in
                // When user turns off discrete mode in Settings, clear unlock state
                if !newValue {
                    isUnlocked = false
                }
                updateAppIcon(discrete: newValue)
            }
        }
        .modelContainer(modelContainer)
    }

    private func updateAppIcon(discrete: Bool) {
        #if os(iOS)
        let iconName: String? = discrete ? "CalculatorIcon" : nil
        guard UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != iconName else { return }
        UIApplication.shared.setAlternateIconName(iconName)
        #endif
    }
}
