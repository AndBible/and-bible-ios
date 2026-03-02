// BibleReaderView.swift — Main Bible reading screen (coordinator)
//
// This view coordinates the toolbar, sheets, and overlays for multi-window
// Bible reading. Each window's WebView is rendered by a BibleWindowPane.

import SwiftUI
import SwiftData
import BibleView
import BibleCore
import SwordKit
#if os(iOS)
import StoreKit
#endif

#if os(iOS)
/// Present a CompareView sheet using UIKit directly.
/// Same reason as Strong's — triggered from WKScriptMessageHandler.
func presentCompareView(book: String, chapter: Int, currentModuleName: String, startVerse: Int? = nil, endVerse: Int? = nil, osisBookId: String? = nil) {
    guard let windowScene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first,
          let rootVC = windowScene.windows.first?.rootViewController else { return }

    var topVC = rootVC
    while let presented = topVC.presentedViewController {
        topVC = presented
    }

    let content = CompareView(book: book, chapter: chapter, currentModuleName: currentModuleName, startVerse: startVerse, endVerse: endVerse, resolvedOsisBookId: osisBookId)
    let hostingVC = UIHostingController(rootView: NavigationStack { content })
    hostingVC.modalPresentationStyle = .pageSheet
    if let sheet = hostingVC.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    topVC.present(hostingVC, animated: true)
}

// Label assignment is now presented via SwiftUI .sheet() in BibleWindowPane
// (no UIKit hosting needed — avoids gesture/toolbar conflicts)
#else
func presentCompareView(book: String, chapter: Int, currentModuleName: String, startVerse: Int? = nil, endVerse: Int? = nil, osisBookId: String? = nil) {
    // macOS: no-op for now
}
// Label assignment presented via SwiftUI .sheet() in BibleWindowPane (cross-platform)
#endif

/// The primary Bible reading view — coordinates toolbar, sheets, and multi-window split content.
/// Each window is rendered by a `BibleWindowPane` with its own bridge/controller/WebView.
public struct BibleReaderView: View {
    @Environment(WindowManager.self) private var windowManager
    @Environment(SearchIndexService.self) private var searchIndexService
    @Environment(\.modelContext) private var modelContext
    @State private var showBookChooser = false
    @State private var showSearch = false
    @State private var showBookmarks = false
    @State private var showSettings = false
    @State private var showDownloads = false
    @State private var showHistory = false
    @State private var showCompare = false
    @State private var showReadingPlans = false
    @State private var showSpeakControls = false
    @State private var displaySettings: TextDisplaySettings = .appDefaults
    @State private var nightMode = false
    @StateObject private var speakService = SpeakService()
    @State private var shareText: String?
    @State private var crossReferences: [CrossReference]?
    @State private var showModulePicker = false
    @State private var pickerCategory: DocumentCategory = .bible
    @State private var showWorkspaces = false
    @State private var toastMessage: String?
    @State private var toastWorkItem: DispatchWorkItem?
    @State private var isFullScreen = false
    @State private var showDictionaryBrowser = false
    @State private var showGeneralBookBrowser = false
    @State private var showMapBrowser = false
    @State private var showEpubLibrary = false
    @State private var showEpubBrowser = false
    @State private var showEpubSearch = false
    @State private var searchInitialQuery = ""
    @State private var showLabelManager = false
    @State private var showHelp = false
    @State private var showAbout = false
    @State private var showRefChooser = false
    @State private var refChooserCompletion: ((String?) -> Void)?
    #if os(iOS)
    @State private var tiltScrollService = TiltScrollService()
    #endif

    /// The focused window's controller — reads from WindowManager's single source of truth.
    /// References `controllerVersion` to guarantee SwiftUI re-evaluates when controllers
    /// are registered/unregistered (dictionary subscript mutations alone are unreliable).
    private var focusedController: BibleReaderController? {
        _ = windowManager.controllerVersion
        guard let activeId = windowManager.activeWindow?.id else { return nil }
        return windowManager.controllers[activeId] as? BibleReaderController
    }

    private var currentReference: String {
        guard let ctrl = focusedController else { return "Genesis 1" }
        return "\(ctrl.currentBook) \(ctrl.currentChapter)"
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Document header bar — hidden in fullscreen mode
            if !isFullScreen {
                documentHeader
            }

            // Split content — one BibleWindowPane per visible window
            splitContent

            // Persistent mini-player when speaking (visible even in fullscreen)
            if speakService.isSpeaking {
                speakMiniPlayer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Bottom window tab bar — hidden in fullscreen mode
            if !isFullScreen {
                WindowTabBar(
                    onShowToast: { text in
                        toastWorkItem?.cancel()
                        withAnimation { toastMessage = text }
                        let work = DispatchWorkItem {
                            withAnimation { toastMessage = nil }
                        }
                        toastWorkItem = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
                    },
                    onShowBookChooser: {
                        showBookChooser = true
                    },
                    onGoToTypedRef: { window, text in
                        guard let ctrl = windowManager.controllers[window.id] as? BibleReaderController else { return false }
                        return ctrl.navigateToRef(text)
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFullScreen)
        .overlay(alignment: .bottom) {
            if let message = toastMessage {
                Text(message)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 4)
                    .padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toastMessage)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            // Load persisted settings
            let store = SettingsStore(modelContext: modelContext)
            nightMode = store.getBool("night_mode")

            // Wire TTS settings persistence and restore saved speed
            speakService.settingsStore = store
            speakService.restoreSettings()

            // Resolve display settings from workspace inheritance chain
            let workspace = windowManager.activeWorkspace
            let window = windowManager.activeWindow
            displaySettings = TextDisplaySettings.fullyResolved(
                window: window?.pageManager?.textDisplaySettings,
                workspace: workspace?.textDisplaySettings
            )

            // TTS callbacks — dynamically resolve the focused controller so TTS
            // always operates on the active window (not the last-initialized pane).
            let wm = windowManager
            speakService.onRequestNext = {
                if let activeId = wm.activeWindow?.id,
                   let ctrl = wm.controllers[activeId] as? BibleReaderController {
                    ctrl.navigateNext()
                    ctrl.speakCurrentChapter()
                }
            }
            speakService.onRequestPrevious = {
                if let activeId = wm.activeWindow?.id,
                   let ctrl = wm.controllers[activeId] as? BibleReaderController {
                    ctrl.navigatePrevious()
                    ctrl.speakCurrentChapter()
                }
            }
            speakService.onFinishedSpeaking = {
                if let activeId = wm.activeWindow?.id,
                   let ctrl = wm.controllers[activeId] as? BibleReaderController {
                    guard ctrl.hasNext else { return }
                    ctrl.navigateNext()
                    ctrl.speakCurrentChapter()
                }
            }

            // Set up synchronized scrolling callback
            windowManager.onSyncVerseChanged = { [weak windowManager] sourceWindow, ordinal, key in
                guard let wm = windowManager else { return }
                let syncTargets = wm.syncedWindows(for: sourceWindow)
                    .filter { $0.id != sourceWindow.id }
                for target in syncTargets {
                    if let ctrl = wm.controllers[target.id] as? BibleReaderController {
                        // Same book+chapter: scroll to verse. Different: navigate.
                        let sourceBook = sourceWindow.pageManager?.bibleBibleBook
                        let sourceChapter = sourceWindow.pageManager?.bibleChapterNo
                        let targetBook = target.pageManager?.bibleBibleBook
                        let targetChapter = target.pageManager?.bibleChapterNo
                        if sourceBook == targetBook && sourceChapter == targetChapter {
                            ctrl.scrollToOrdinal(ordinal)
                        } else {
                            // Parse key like "Gen.3.5" to navigate
                            let parts = key.split(separator: ".")
                            if parts.count >= 2,
                               let chapter = Int(parts[1]) {
                                let osisBook = String(parts[0])
                                if let bookName = ctrl.bookName(forOsisId: osisBook) {
                                    ctrl.navigateTo(book: bookName, chapter: chapter)
                                }
                            }
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .onAppear {
            // Auto-start tilt scroll if workspace has it enabled
            if windowManager.activeWorkspace?.workspaceSettings?.enableTiltToScroll ?? false {
                startTiltToScroll()
            }
        }
        .onDisappear {
            tiltScrollService.stop()
        }
        #endif
        .preferredColorScheme(nightMode ? .dark : nil)
        .sheet(isPresented: $showBookChooser) {
            NavigationStack {
                BookChooserView(books: focusedController?.bookList ?? BibleReaderController.defaultBooks) { book, chapter in
                    showBookChooser = false
                    focusedController?.navigateTo(book: book, chapter: chapter)
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                SearchView(
                    swordModule: focusedController?.activeModule,
                    swordManager: focusedController?.swordManager,
                    searchIndexService: searchIndexService,
                    installedBibleModules: focusedController?.installedBibleModules ?? [],
                    currentBook: focusedController?.currentBook ?? "Genesis",
                    currentOsisBookId: focusedController?.osisBookId(for: focusedController?.currentBook ?? "Genesis") ?? BibleReaderController.osisBookId(for: focusedController?.currentBook ?? "Genesis"),
                    initialQuery: searchInitialQuery,
                    onNavigate: { book, chapter in
                        showSearch = false
                        focusedController?.navigateTo(book: book, chapter: chapter)
                    }
                )
            }
            .onDisappear { searchInitialQuery = "" }
        }
        .sheet(isPresented: $showBookmarks) {
            NavigationStack {
                BookmarkListView(
                    onNavigate: { book, chapter in
                        showBookmarks = false
                        focusedController?.navigateTo(book: book, chapter: chapter)
                    },
                    onOpenStudyPad: { labelId in
                        showBookmarks = false
                        focusedController?.loadStudyPadDocument(labelId: labelId)
                    }
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(
                    displaySettings: $displaySettings,
                    nightMode: $nightMode,
                    onSettingsChanged: {
                        // Persist display settings to workspace
                        if let workspace = windowManager.activeWorkspace {
                            workspace.textDisplaySettings = displaySettings
                            try? modelContext.save()
                        }
                        // Push updated config to all visible windows' controllers
                        for window in windowManager.visibleWindows {
                            if let ctrl = windowManager.controllers[window.id] as? BibleReaderController {
                                ctrl.updateDisplaySettings(displaySettings, nightMode: nightMode)
                            }
                        }
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "done")) { showSettings = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showCompare) {
            NavigationStack {
                CompareView(
                    book: focusedController?.currentBook ?? "Genesis",
                    chapter: focusedController?.currentChapter ?? 1,
                    currentModuleName: focusedController?.activeModuleName ?? "",
                    resolvedOsisBookId: focusedController.flatMap { $0.osisBookId(for: $0.currentBook) }
                )
            }
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                HistoryView(
                    bookNameResolver: { [weak ctrl = focusedController] osisId in
                        ctrl?.bookName(forOsisId: osisId)
                    }
                ) { book, chapter in
                    showHistory = false
                    focusedController?.navigateTo(book: book, chapter: chapter)
                }
            }
        }
        .sheet(isPresented: $showDownloads, onDismiss: {
            // Refresh installed modules list in all controllers after downloads
            for (_, ctrl) in windowManager.controllers {
                (ctrl as? BibleReaderController)?.refreshInstalledModules()
            }
        }) {
            NavigationStack {
                ModuleBrowserView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showDownloads = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showReadingPlans) {
            NavigationStack {
                ReadingPlanListView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showReadingPlans = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showSpeakControls) {
            SpeakControlView(speakService: speakService)
                .presentationDetents([.height(400), .large])
        }
        .sheet(isPresented: Binding(
            get: { shareText != nil },
            set: { if !$0 { shareText = nil } }
        )) {
            if let text = shareText {
                ShareSheet(items: [text])
            }
        }
        .sheet(isPresented: $showModulePicker) {
            modulePicker
        }
        .sheet(isPresented: $showWorkspaces) {
            NavigationStack {
                WorkspaceSelectorView()
            }
        }
        .sheet(isPresented: Binding(
            get: { crossReferences != nil },
            set: { if !$0 { crossReferences = nil } }
        )) {
            if let refs = crossReferences {
                CrossReferenceView(references: refs) { book, chapter in
                    crossReferences = nil
                    focusedController?.navigateTo(book: book, chapter: chapter)
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showDictionaryBrowser) {
            if let module = focusedController?.activeDictionaryModule {
                DictionaryBrowserView(module: module) { key in
                    showDictionaryBrowser = false
                    focusedController?.loadDictionaryEntry(key: key)
                }
            }
        }
        .sheet(isPresented: $showGeneralBookBrowser) {
            if let module = focusedController?.activeGeneralBookModule {
                GeneralBookBrowserView(
                    module: module,
                    title: focusedController?.activeGeneralBookModuleName ?? String(localized: "general_book")
                ) { key in
                    showGeneralBookBrowser = false
                    focusedController?.loadGeneralBookEntry(key: key)
                }
            }
        }
        .sheet(isPresented: $showMapBrowser) {
            if let module = focusedController?.activeMapModule {
                GeneralBookBrowserView(
                    module: module,
                    title: focusedController?.activeMapModuleName ?? String(localized: "map")
                ) { key in
                    showMapBrowser = false
                    focusedController?.loadMapEntry(key: key)
                }
            }
        }
        .sheet(isPresented: $showEpubLibrary) {
            EpubLibraryView { identifier in
                showEpubLibrary = false
                focusedController?.switchEpub(identifier: identifier)
                focusedController?.switchCategory(to: .epub)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showEpubBrowser = true
                }
            }
        }
        .sheet(isPresented: $showEpubBrowser) {
            if let reader = focusedController?.activeEpubReader {
                EpubBrowserView(reader: reader) { href in
                    showEpubBrowser = false
                    focusedController?.loadEpubEntry(href: href)
                }
            } else {
                // No EPUB loaded — redirect to library
                EpubLibraryView { identifier in
                    showEpubBrowser = false
                    focusedController?.switchEpub(identifier: identifier)
                    focusedController?.switchCategory(to: .epub)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showEpubBrowser = true
                    }
                }
            }
        }
        .sheet(isPresented: $showEpubSearch) {
            if let reader = focusedController?.activeEpubReader {
                EpubSearchView(reader: reader) { href in
                    showEpubSearch = false
                    focusedController?.loadEpubEntry(href: href)
                }
            } else {
                // No EPUB loaded — dismiss
                Text(String(localized: "reader_no_epub_loaded"))
                    .padding()
            }
        }
        .sheet(isPresented: $showLabelManager) {
            NavigationStack {
                LabelManagerView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showLabelManager = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                HelpView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showHelp = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showAbout) {
            NavigationStack {
                AboutView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showAbout = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showRefChooser) {
            NavigationStack {
                BookChooserView(books: focusedController?.bookList ?? BibleReaderController.defaultBooks) { book, chapter in
                    showRefChooser = false
                    let osisId = focusedController?.osisBookId(for: book) ?? BibleReaderController.osisBookId(for: book)
                    refChooserCompletion?("\(osisId).\(chapter)")
                    refChooserCompletion = nil
                }
            }
            .presentationDetents([.large])
        }
        // MARK: - Keyboard Shortcuts (iPad/Mac)
        .background {
            Group {
                Button("") { showSearch = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { showBookChooser = true }
                    .keyboardShortcut("g", modifiers: .command)
                Button("") { showBookmarks = true }
                    .keyboardShortcut("b", modifiers: .command)
                Button("") { focusedController?.navigatePrevious() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("") { focusedController?.navigateNext() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("") { showDownloads = true }
                    .keyboardShortcut("d", modifiers: .command)
                Button("") { showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Split Content

    private var splitContent: some View {
        GeometryReader { geometry in
            let windows = windowManager.visibleWindows
            let naturalHorizontal = geometry.size.width > geometry.size.height
            let reverse = windowManager.activeWorkspace?.workspaceSettings?.enableReverseSplitMode ?? false
            let isHorizontal = reverse ? !naturalHorizontal : naturalHorizontal
            let totalWeight = windows.map(\.layoutWeight).reduce(0, +)
            let normalizedTotal = max(totalWeight, 0.001) // avoid division by zero

            // Always use the same VStack/HStack container regardless of window count.
            // Switching between branches (single vs multi) destroys existing panes,
            // killing their WebView and controller state.
            if isHorizontal {
                HStack(spacing: 0) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        paneView(for: window)
                            .frame(width: windows.count > 1
                                ? geometry.size.width * CGFloat(window.layoutWeight / normalizedTotal)
                                : nil)

                        if index < windows.count - 1 {
                            WindowSeparator(
                                window1: window,
                                window2: windows[index + 1],
                                isVertical: false,
                                totalPaneCount: windows.count,
                                parentSize: geometry.size.width
                            )
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        paneView(for: window)
                            .frame(height: windows.count > 1
                                ? geometry.size.height * CGFloat(window.layoutWeight / normalizedTotal)
                                : nil)

                        if index < windows.count - 1 {
                            WindowSeparator(
                                window1: window,
                                window2: windows[index + 1],
                                isVertical: true,
                                totalPaneCount: windows.count,
                                parentSize: geometry.size.height
                            )
                        }
                    }
                }
            }
        }
    }

    private func paneView(for window: Window) -> some View {
        BibleWindowPane(
            window: window,
            isFocused: window.id == windowManager.activeWindow?.id,
            displaySettings: displaySettings,
            nightMode: nightMode,
            speakService: speakService,
            onShowBookChooser: { showBookChooser = true },
            onShowSearch: { showSearch = true },
            onShowBookmarks: { showBookmarks = true },
            onShowSettings: { showSettings = true },
            onShowDownloads: { showDownloads = true },
            onShowHistory: { showHistory = true },
            onShowCompare: { showCompare = true },
            onShowReadingPlans: { showReadingPlans = true },
            onShowSpeakControls: { showSpeakControls = true },
            onShareText: { text in shareText = text },
            onShowCrossReferences: { refs in crossReferences = refs },
            onShowModulePicker: { category in
                pickerCategory = category
                showModulePicker = true
            },
            onShowToast: { text in
                toastWorkItem?.cancel()
                withAnimation { toastMessage = text }
                let work = DispatchWorkItem {
                    withAnimation { toastMessage = nil }
                }
                toastWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
            },
            onShowWorkspaces: { showWorkspaces = true },
            onToggleFullScreen: {
                withAnimation { isFullScreen.toggle() }
            },
            onSearchForStrongs: { strongsNum in
                searchInitialQuery = strongsNum
                showSearch = true
            },
            onShowStrongsSheet: { json, config in
                #if os(iOS)
                if let ctrl = focusedController {
                    let d = TextDisplaySettings.appDefaults
                    let bgInt = nightMode
                        ? (displaySettings.nightBackground ?? d.nightBackground ?? -16777216)
                        : (displaySettings.dayBackground ?? d.dayBackground ?? -1)
                    presentStrongsSheet(
                        multiDocJSON: json,
                        configJSON: config,
                        backgroundColorInt: bgInt,
                        controller: ctrl,
                        onFindAll: { strongsNum in
                            searchInitialQuery = strongsNum
                            showSearch = true
                        }
                    )
                }
                #endif
            },
            onRefChooserDialog: { completion in
                // Present book chooser and return OSIS ref
                refChooserCompletion = completion
                showRefChooser = true
            }
        )
    }

    // MARK: - Module Picker

    private var modulePicker: some View {
        NavigationStack {
            List {
                let modules = focusedController?.installedModules(for: pickerCategory) ?? []
                let activeNameForCategory = focusedController?.activeModuleName(for: pickerCategory)
                let emptyMessage: String = {
                    switch pickerCategory {
                    case .commentary: return String(localized: "picker_no_commentary_modules")
                    case .dictionary: return String(localized: "picker_no_dictionary_modules")
                    case .generalBook: return String(localized: "picker_no_general_book_modules")
                    case .map: return String(localized: "picker_no_map_modules")
                    default: return String(localized: "picker_no_bible_modules")
                    }
                }()
                if modules.isEmpty {
                    VStack(spacing: 12) {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "download_modules")) {
                            showModulePicker = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                showDownloads = true
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                } else {
                    ForEach(modules, id: \.name) { (module: ModuleInfo) in
                        Button {
                            switch pickerCategory {
                            case .commentary:
                                focusedController?.switchCommentaryModule(to: module.name)
                                if focusedController?.currentCategory != .commentary {
                                    focusedController?.switchCategory(to: .commentary)
                                }
                            case .dictionary:
                                focusedController?.switchDictionaryModule(to: module.name)
                                focusedController?.switchCategory(to: .dictionary)
                                showModulePicker = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showDictionaryBrowser = true
                                }
                                return
                            case .generalBook:
                                focusedController?.switchGeneralBookModule(to: module.name)
                                focusedController?.switchCategory(to: .generalBook)
                                showModulePicker = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showGeneralBookBrowser = true
                                }
                                return
                            case .map:
                                focusedController?.switchMapModule(to: module.name)
                                focusedController?.switchCategory(to: .map)
                                showModulePicker = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showMapBrowser = true
                                }
                                return
                            default:
                                focusedController?.switchModule(to: module.name)
                                if focusedController?.currentCategory != .bible {
                                    focusedController?.switchCategory(to: .bible)
                                }
                            }
                            showModulePicker = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(module.name)
                                        .font(.headline)
                                    Text(module.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(Locale.current.localizedString(forLanguageCode: module.language) ?? module.language)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if module.name == activeNameForCategory {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .fontWeight(.semibold)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle({
                switch pickerCategory {
                case .commentary: return String(localized: "picker_select_commentary")
                case .dictionary: return String(localized: "picker_select_dictionary")
                case .generalBook: return String(localized: "picker_select_general_book")
                case .map: return String(localized: "picker_select_map")
                default: return String(localized: "picker_select_translation")
                }
            }())
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { showModulePicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Speak Mini Player

    private var speakMiniPlayer: some View {
        Button(action: { showSpeakControls = true }) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Text(speakService.currentTitle ?? currentReference)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer()

                Button {
                    speakService.skipBackward()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }

                Button {
                    if speakService.isPaused {
                        speakService.resume()
                    } else {
                        speakService.pause()
                    }
                } label: {
                    Image(systemName: speakService.isPaused ? "play.fill" : "pause.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }

                Button {
                    speakService.skipForward()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }

                Button {
                    speakService.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
    }

    // MARK: - Document Header

    private var documentHeader: some View {
        let controller = focusedController
        return VStack(spacing: 0) {
            HStack {
                if controller?.showingMyNotes == true {
                    // My Notes mode: show back button
                    Button(action: { controller?.returnFromMyNotes() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                            Text(currentReference)
                                .font(.subheadline)
                        }
                    }
                    .accessibilityLabel(String(localized: "back_to_bible"))

                    Spacer()

                    Text(String(localized: "my_notes"))
                        .font(.headline)

                    Spacer()
                    Color.clear.frame(width: 80, height: 1)
                } else if controller?.showingStudyPad == true {
                    // StudyPad mode: show back button
                    Button(action: { controller?.returnFromStudyPad() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                            Text(currentReference)
                                .font(.subheadline)
                        }
                    }
                    .accessibilityLabel(String(localized: "back_to_bible"))

                    Spacer()

                    Text(controller?.activeStudyPadLabelName ?? String(localized: "study_pad"))
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()
                    Color.clear.frame(width: 80, height: 1)
                } else if controller?.currentCategory == .dictionary ||
                          controller?.currentCategory == .generalBook ||
                          controller?.currentCategory == .map ||
                          controller?.currentCategory == .epub {
                    // Dictionary/GenBook/Map/EPUB mode: show back button + module/key
                    Button(action: { controller?.switchCategory(to: .bible) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                            Text(currentReference)
                                .font(.subheadline)
                        }
                    }
                    .accessibilityLabel(String(localized: "back_to_bible"))

                    Spacer()

                    VStack(spacing: 1) {
                        Text(controller?.activeModuleName(for: controller?.currentCategory ?? .dictionary) ?? "")
                            .font(.headline)
                            .lineLimit(1)
                        if let key = controller?.currentCategory == .dictionary ? controller?.currentDictionaryKey :
                                      controller?.currentCategory == .generalBook ? controller?.currentGeneralBookKey :
                                      controller?.currentCategory == .epub ? controller?.currentEpubTitle :
                                      controller?.currentMapKey {
                            Text(key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Browse button to open key browser
                    Button {
                        switch controller?.currentCategory {
                        case .dictionary: showDictionaryBrowser = true
                        case .generalBook: showGeneralBookBrowser = true
                        case .map: showMapBrowser = true
                        case .epub: showEpubBrowser = true
                        default: break
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.body)
                    }
                } else {
                    // Normal Bible mode — navigation + action buttons in one bar
                    // Previous chapter
                    Button(action: { controller?.navigatePrevious() }) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(controller?.hasPrevious == true ? .primary : .tertiary)
                    }
                    .disabled(controller?.hasPrevious != true)
                    .accessibilityLabel(String(localized: "previous_chapter"))

                    Button(action: { showBookChooser = true }) {
                        HStack(spacing: 4) {
                            Text(currentReference)
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bookChooserButton")

                    // Next chapter
                    Button(action: { controller?.navigateNext() }) {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(controller?.hasNext == true ? .primary : .tertiary)
                    }
                    .disabled(controller?.hasNext != true)
                    .accessibilityLabel(String(localized: "next_chapter"))

                    Spacer()

                    // Action buttons — matching Android toolbar order
                    HStack(spacing: 14) {
                        // Search
                        Button(action: { showSearch = true }) {
                            Image(systemName: "magnifyingglass")
                                .font(.body)
                        }

                        // Strong's toggle — shown when module has Strong's data
                        // (matching Android MainBibleActivity.kt:1134).
                        // Tap cycles Off→Inline→Links, long-press shows all 4 modes.
                        if moduleHasStrongs {
                            Menu {
                                ForEach(StrongsMode.allCases) { mode in
                                    Button {
                                        applyStrongsMode(mode.rawValue)
                                    } label: {
                                        if displaySettings.strongsMode ?? 0 == mode.rawValue {
                                            SwiftUI.Label(mode.label, systemImage: "checkmark")
                                        } else {
                                            Text(mode.label)
                                        }
                                    }
                                }
                            } label: {
                                strongsIcon
                                    .opacity(strongsEnabled ? 1.0 : 0.4)
                            } primaryAction: {
                                // Tap cycles through Off(0) → Inline(1) → Links(2) → Off(0)
                                // matching Android's 3-mode quick toggle
                                let current = displaySettings.strongsMode ?? 0
                                let next = (current + 1) % 3
                                applyStrongsMode(next)
                            }
                            .accessibilityLabel(String(localized: "toggle_strongs_numbers"))
                        }

                        // TTS
                        Button {
                            if speakService.isSpeaking {
                                showSpeakControls = true
                            } else {
                                controller?.speakCurrentChapter()
                                showSpeakControls = true
                            }
                        } label: {
                            Image(systemName: "headphones")
                                .font(.body)
                        }

                        // Bible
                        Button {
                            if controller?.currentCategory == .bible {
                                pickerCategory = .bible
                                showModulePicker = true
                            } else {
                                controller?.switchCategory(to: .bible)
                            }
                        } label: {
                            Image(systemName: "book.fill")
                                .font(.body)
                                .opacity(controller?.currentCategory == .bible ? 1.0 : 0.4)
                        }

                        // Commentary
                        Button {
                            if controller?.currentCategory == .commentary {
                                pickerCategory = .commentary
                                showModulePicker = true
                            } else {
                                if controller?.activeCommentaryModuleName == nil {
                                    pickerCategory = .commentary
                                    showModulePicker = true
                                } else {
                                    controller?.switchCategory(to: .commentary)
                                }
                            }
                        } label: {
                            Image(systemName: "text.book.closed.fill")
                                .font(.body)
                                .opacity(controller?.currentCategory == .commentary ? 1.0 : 0.4)
                        }

                        // Ellipsis menu
                        Menu {
                            // Quick toggles
                            Toggle(isOn: Binding(
                                get: { isFullScreen },
                                set: { newValue in
                                    withAnimation(.easeInOut(duration: 0.2)) { isFullScreen = newValue }
                                }
                            )) {
                                SwiftUI.Label(String(localized: "fullscreen"), systemImage: "arrow.up.left.and.arrow.down.right")
                            }

                            Toggle(isOn: Binding(
                                get: { nightMode },
                                set: { newValue in
                                    nightMode = newValue
                                    let store = SettingsStore(modelContext: modelContext)
                                    store.setBool("night_mode", value: newValue)
                                    for window in windowManager.visibleWindows {
                                        if let ctrl = windowManager.controllers[window.id] as? BibleReaderController {
                                            ctrl.updateDisplaySettings(displaySettings, nightMode: nightMode)
                                        }
                                    }
                                }
                            )) {
                                SwiftUI.Label(String(localized: "night_mode"), systemImage: "moon.fill")
                            }

                            #if os(iOS)
                            Toggle(isOn: Binding(
                                get: { windowManager.activeWorkspace?.workspaceSettings?.enableTiltToScroll ?? false },
                                set: { newValue in
                                    updateWorkspaceSettings { $0.enableTiltToScroll = newValue }
                                    if newValue {
                                        startTiltToScroll()
                                    } else {
                                        tiltScrollService.stop()
                                    }
                                }
                            )) {
                                SwiftUI.Label(String(localized: "tilt_to_scroll"), systemImage: "gyroscope")
                            }
                            #endif

                            if windowManager.visibleWindows.count > 1 {
                                Toggle(isOn: Binding(
                                    get: { windowManager.activeWorkspace?.workspaceSettings?.enableReverseSplitMode ?? false },
                                    set: { newValue in
                                        updateWorkspaceSettings { $0.enableReverseSplitMode = newValue }
                                    }
                                )) {
                                    SwiftUI.Label(String(localized: "reversed_split_mode"), systemImage: "rectangle.split.1x2")
                                }
                            }

                            Toggle(isOn: Binding(
                                get: { windowManager.activeWorkspace?.workspaceSettings?.autoPin ?? false },
                                set: { newValue in
                                    updateWorkspaceSettings { $0.autoPin = newValue }
                                }
                            )) {
                                SwiftUI.Label(String(localized: "window_pinning"), systemImage: "pin.fill")
                            }

                            Divider()

                            Button(String(localized: "label_settings"), systemImage: "tag") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showLabelManager = true
                                }
                            }

                            Button(String(localized: "all_text_options"), systemImage: "textformat.size") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showSettings = true
                                }
                            }

                            Divider()

                            Button(String(localized: "bookmarks"), systemImage: "bookmark") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showBookmarks = true
                                }
                            }
                            Button(String(localized: "history"), systemImage: "clock") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showHistory = true
                                }
                            }
                            Button(String(localized: "compare"), systemImage: "rectangle.split.2x1") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showCompare = true
                                }
                            }
                            Button(String(localized: "reading_plans"), systemImage: "calendar") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showReadingPlans = true
                                }
                            }
                            Button(String(localized: "settings"), systemImage: "gear") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showSettings = true
                                }
                            }
                            Divider()
                            Button(String(localized: "workspaces"), systemImage: "square.stack") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showWorkspaces = true
                                }
                            }
                            Button(String(localized: "downloads"), systemImage: "arrow.down.circle") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showDownloads = true
                                }
                            }
                            if !(controller?.installedDictionaryModules.isEmpty ?? true) {
                                Divider()
                                Button(String(localized: "dictionary"), systemImage: "character.book.closed") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        let modules = controller?.installedDictionaryModules ?? []
                                        if modules.count == 1 {
                                            controller?.switchDictionaryModule(to: modules[0].name)
                                            controller?.switchCategory(to: .dictionary)
                                            showDictionaryBrowser = true
                                        } else {
                                            pickerCategory = .dictionary
                                            showModulePicker = true
                                        }
                                    }
                                }
                            }
                            if !(controller?.installedGeneralBookModules.isEmpty ?? true) {
                                Button(String(localized: "general_book"), systemImage: "books.vertical") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        let modules = controller?.installedGeneralBookModules ?? []
                                        if modules.count == 1 {
                                            controller?.switchGeneralBookModule(to: modules[0].name)
                                            controller?.switchCategory(to: .generalBook)
                                            showGeneralBookBrowser = true
                                        } else {
                                            pickerCategory = .generalBook
                                            showModulePicker = true
                                        }
                                    }
                                }
                            }
                            if !(controller?.installedMapModules.isEmpty ?? true) {
                                Button(String(localized: "map"), systemImage: "map") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        let modules = controller?.installedMapModules ?? []
                                        if modules.count == 1 {
                                            controller?.switchMapModule(to: modules[0].name)
                                            controller?.switchCategory(to: .map)
                                            showMapBrowser = true
                                        } else {
                                            pickerCategory = .map
                                            showModulePicker = true
                                        }
                                    }
                                }
                            }
                            if !EpubReader.installedEpubs().isEmpty {
                                Button(String(localized: "epub_library"), systemImage: "book") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        showEpubLibrary = true
                                    }
                                }
                            }
                            if controller?.activeEpubReader != nil {
                                Button(String(localized: "epub_contents"), systemImage: "list.bullet") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        showEpubBrowser = true
                                    }
                                }
                                Button(String(localized: "search_epub"), systemImage: "magnifyingglass") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        showEpubSearch = true
                                    }
                                }
                            }
                            Divider()
                            Button(String(localized: "help_tips"), systemImage: "questionmark.circle") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showHelp = true
                                }
                            }
                            Button(String(localized: "sponsor_development"), systemImage: "heart") {
                                if let url = URL(string: "https://shop.andbible.org") {
                                    #if os(iOS)
                                    UIApplication.shared.open(url)
                                    #elseif os(macOS)
                                    NSWorkspace.shared.open(url)
                                    #endif
                                }
                            }
                            Divider()
                            Button(String(localized: "about"), systemImage: "info.circle") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showAbout = true
                                }
                            }
                            Button(String(localized: "rate_app"), systemImage: "star") {
                                #if os(iOS)
                                if let scene = UIApplication.shared.connectedScenes
                                    .compactMap({ $0 as? UIWindowScene }).first {
                                    SKStoreReviewController.requestReview(in: scene)
                                }
                                #endif
                            }
                            Button(String(localized: "report_bug"), systemImage: "ladybug") {
                                if let url = URL(string: "https://github.com/AndBible/and-bible/issues") {
                                    #if os(iOS)
                                    UIApplication.shared.open(url)
                                    #elseif os(macOS)
                                    NSWorkspace.shared.open(url)
                                    #endif
                                }
                            }
                            Button(String(localized: "tell_friend"), systemImage: "square.and.arrow.up") {
                                #if os(iOS)
                                let text = String(localized: "tell_friend_message")
                                guard let windowScene = UIApplication.shared.connectedScenes
                                    .compactMap({ $0 as? UIWindowScene }).first,
                                      let rootVC = windowScene.windows.first?.rootViewController else { return }
                                var topVC = rootVC
                                while let presented = topVC.presentedViewController { topVC = presented }
                                let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                                topVC.present(activityVC, animated: true)
                                #endif
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.body)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// Strong's icon matching Android's "xα'" style.
    private var strongsIcon: some View {
        HStack(spacing: 0) {
            Text("x")
                .font(.system(size: 13, weight: .bold, design: .serif))
                .italic()
            Text("α")
                .font(.system(size: 13, weight: .bold, design: .serif))
            Text("\u{2032}")
                .font(.system(size: 10, weight: .bold))
                .baselineOffset(4)
        }
        .frame(width: 24, height: 22)
    }

    /// Whether the Strong's toggle should be shown (matching Android's `isStrongsInBook`).
    /// Checks the actual module's features via controller.hasStrongs.
    private var moduleHasStrongs: Bool {
        focusedController?.hasStrongs ?? false
    }

    /// Whether Strong's numbers are currently enabled (strongsMode > 0).
    private var strongsEnabled: Bool {
        (displaySettings.strongsMode ?? 0) > 0
    }

    /// Mutate workspace settings and persist to SwiftData.
    private func updateWorkspaceSettings(_ transform: (inout WorkspaceSettings) -> Void) {
        guard let workspace = windowManager.activeWorkspace else { return }
        var settings = workspace.workspaceSettings ?? WorkspaceSettings()
        transform(&settings)
        workspace.workspaceSettings = settings
        try? modelContext.save()
    }

    /// Apply a Strong's mode value, persist to workspace, and update all WebViews.
    private func applyStrongsMode(_ mode: Int) {
        displaySettings.strongsMode = mode
        if let workspace = windowManager.activeWorkspace {
            workspace.textDisplaySettings = displaySettings
            try? modelContext.save()
        }
        // Update all visible windows
        for window in windowManager.visibleWindows {
            if let ctrl = windowManager.controllers[window.id] as? BibleReaderController {
                ctrl.updateDisplaySettings(displaySettings, nightMode: nightMode)
            }
        }
    }

    #if os(iOS)
    /// Start tilt-to-scroll by wiring CoreMotion to the focused WebView.
    private func startTiltToScroll() {
        tiltScrollService.onScroll = { [weak windowManager] pixels in
            guard let wm = windowManager,
                  let activeId = wm.activeWindow?.id,
                  let ctrl = wm.controllers[activeId] as? BibleReaderController else { return }
            ctrl.bridge.webView?.evaluateJavaScript("window.scrollBy(0, \(pixels))", completionHandler: nil)
        }
        tiltScrollService.start()
    }
    #endif
}

/// Strong's number display modes matching Android's `strongsModeEntries`.
/// Vue.js config values: off=0, inline=1, links=2, hidden=3.
enum StrongsMode: Int, CaseIterable, Identifiable {
    case off = 0
    case inline = 1
    case links = 2
    case hidden = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "strongs_off")
        case .inline: String(localized: "strongs_inline")
        case .links: String(localized: "strongs_links")
        case .hidden: String(localized: "strongs_hidden")
        }
    }
}
