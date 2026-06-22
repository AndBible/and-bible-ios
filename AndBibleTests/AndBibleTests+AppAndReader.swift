import XCTest
import AVFoundation
@testable import BibleCore
import CLibSword
@testable import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI
@testable import BibleView
import struct SwiftUI.Binding
import enum SwiftUI.ColorScheme
import struct SwiftUI.EdgeInsets
import struct SwiftUI.EmptyView
import struct SwiftUI.Text
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

extension AndBibleTests {
    func testAppPreferenceRegistryHasDefinitionForAllKeys() {
        let keys = AppPreferenceKey.allCases
        XCTAssertEqual(keys.count, 40)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(AppPreferenceRegistry.definitions.count, keys.count)

        for key in keys {
            XCTAssertEqual(AppPreferenceRegistry.definition(for: key).key, key)
        }
    }

    func testCriticalPreferenceDefaultsMatchParityContract() {
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .nightModePref3), "system")
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .toolbarButtonActions), "default")
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .bibleViewSwipeMode), "CHAPTER")
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .notesContentType), "HTML")
        XCTAssertEqual(AppPreferenceRegistry.intDefault(for: .fontSizeMultiplier), 100)
        XCTAssertEqual(AppPreferenceRegistry.intRange(for: .fontSizeMultiplier), 10...500)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .openLinksInSpecialWindowPref), true)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .enableBluetoothPref), true)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .bookGridLeftToRight), false)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .bookGridGroupByCategory), false)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .bookGridShowLongName), false)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .bookGridShowProgress), true)
    }

    func testNotesContentTypeNormalizerUsesAndroidSupportedValues() {
        XCTAssertEqual(AppPreferenceValueNormalizer.notesContentType("HTML"), "HTML")
        XCTAssertEqual(AppPreferenceValueNormalizer.notesContentType("MARKDOWN"), "MARKDOWN")
        XCTAssertEqual(AppPreferenceValueNormalizer.notesContentType("markdown"), "HTML")
        XCTAssertEqual(AppPreferenceValueNormalizer.notesContentType("PLAINTEXT"), "HTML")
        XCTAssertEqual(AppPreferenceValueNormalizer.notesContentType(""), "HTML")
    }

    func testActionPreferencesUseActionShape() {
        let actionKeys: [AppPreferenceKey] = [
            .discreteHelp,
            .openLinks,
            .crashApp,
        ]

        for key in actionKeys {
            let definition = AppPreferenceRegistry.definition(for: key)
            if case .action = definition.storage {
                // expected
            } else {
                XCTFail("Expected .action storage for \(key.rawValue)")
            }
            if case .action = definition.valueType {
                // expected
            } else {
                XCTFail("Expected .action valueType for \(key.rawValue)")
            }
            XCTAssertNil(definition.defaultValue)
        }
    }

    func testApplicationPreferencesResetContractExcludesActionRowsAndIncludesVisibleParityKeys() {
        let resetKeys = AppPreferenceRegistry.applicationPreferencesResetKeys

        XCTAssertTrue(resetKeys.contains(.navigateToVersePref))
        XCTAssertTrue(resetKeys.contains(.volumeKeysScroll))
        XCTAssertTrue(resetKeys.contains(.localePref))
        XCTAssertTrue(resetKeys.contains(.calculatorPin))
        XCTAssertTrue(resetKeys.contains(.experimentalFeatures))
        XCTAssertFalse(resetKeys.contains(.discreteHelp))
        XCTAssertFalse(resetKeys.contains(.openLinks))
        XCTAssertFalse(resetKeys.contains(.crashApp))
        XCTAssertEqual(Set(resetKeys).count, resetKeys.count)
    }

    func testSettingsStoreResetApplicationPreferencesRestoresRegistryDefaults() throws {
        let userDefaultsKeys: [AppPreferenceKey] = [.localePref, .showCalculator, .calculatorPin, .discreteMode]
        userDefaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0.rawValue) }
        defer {
            userDefaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0.rawValue) }
        }

        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setBool(.navigateToVersePref, value: true)
        settingsStore.setString(.toolbarButtonActions, value: "swap-menu")
        settingsStore.setString(.notesContentType, value: "MARKDOWN")
        settingsStore.setInt(.fontSizeMultiplier, value: 180)
        settingsStore.setStringSet(.experimentalFeatures, values: ["feature_b", "feature_a"])
        settingsStore.setString(.localePref, value: "fi")
        settingsStore.setBool(.showCalculator, value: true)
        settingsStore.setString(.calculatorPin, value: "9999")
        settingsStore.setBool(.discreteMode, value: true)
        settingsStore.setString(SettingsStore.globalTextDisplaySettingsKey, value: #"{"fontSize":22}"#)

        settingsStore.resetApplicationPreferences()

        XCTAssertEqual(settingsStore.getBool(.navigateToVersePref), false)
        XCTAssertEqual(settingsStore.getString(.toolbarButtonActions), "default")
        XCTAssertEqual(settingsStore.getString(.notesContentType), "HTML")
        XCTAssertEqual(settingsStore.getInt(.fontSizeMultiplier), 100)
        XCTAssertEqual(settingsStore.getStringSet(.experimentalFeatures), [])
        XCTAssertEqual(settingsStore.getString(.localePref), "")
        XCTAssertEqual(settingsStore.getBool(.showCalculator), false)
        XCTAssertEqual(settingsStore.getString(.calculatorPin), "1234")
        XCTAssertEqual(settingsStore.getBool(.discreteMode), false)
        XCTAssertNotNil(settingsStore.getString(SettingsStore.globalTextDisplaySettingsKey))
    }

    func testSettingsSearchMatcherRequiresAllNormalizedTermsAcrossEntryText() {
        let entry = AndBibleSettingsSearchEntry(
            identifier: "settingsReadingProgressLink",
            title: "Reading Progress Settings",
            summary: "Configure automatic reading tracking",
            detail: "Memorization",
            keywords: ["features", "progress"]
        )

        XCTAssertTrue(AndBibleSettingsSearchMatcher.matches(query: "", entry: entry))
        XCTAssertTrue(AndBibleSettingsSearchMatcher.matches(query: "reading tracking", entry: entry))
        XCTAssertTrue(AndBibleSettingsSearchMatcher.matches(query: "FEATURES progress", entry: entry))
        XCTAssertFalse(AndBibleSettingsSearchMatcher.matches(query: "sync tracking", entry: entry))
    }

    func testSettingsSearchMatcherFiltersExactRenderedRowsWithinMatchingSection() {
        let entries = [
            AndBibleSettingsSearchEntry(
                identifier: "monochrome_mode",
                title: "Black & white mode",
                summary: "Use application in monochrome mode"
            ),
            AndBibleSettingsSearchEntry(
                identifier: "disable_animations",
                title: "Disable animations",
                summary: "Disable smooth scrolling animations"
            ),
        ]

        XCTAssertTrue(entries.contains { AndBibleSettingsSearchMatcher.matches(query: "monochrome", entry: $0) })
        XCTAssertTrue(
            AndBibleSettingsSearchMatcher.matchesIdentifier(
                "monochrome_mode",
                query: "monochrome",
                entries: entries
            )
        )
        XCTAssertFalse(
            AndBibleSettingsSearchMatcher.matchesIdentifier(
                "disable_animations",
                query: "monochrome",
                entries: entries
            )
        )
        XCTAssertFalse(
            AndBibleSettingsSearchMatcher.matchesIdentifier(
                "missing_row",
                query: "monochrome",
                entries: entries
            )
        )
        XCTAssertTrue(
            AndBibleSettingsSearchMatcher.matchesIdentifier(
                "missing_row",
                query: "",
                entries: entries
            )
        )
    }

    func testTextDisplayAppDefaultsStartWithStrongsDisabled() {
        XCTAssertEqual(TextDisplaySettings.appDefaults.strongsMode, 0)
    }

    func testTextDisplaySettingsInheritanceUsesGlobalBeforeDefaults() {
        var windowSettings = TextDisplaySettings()
        windowSettings.fontSize = 18

        var workspaceSettings = TextDisplaySettings()
        workspaceSettings.fontSize = 16
        workspaceSettings.fontFamily = "serif"

        var globalSettings = TextDisplaySettings()
        globalSettings.lineSpacing = 125

        var defaults = TextDisplaySettings()
        defaults.fontSize = 14
        defaults.fontFamily = "sans-serif"
        defaults.lineSpacing = 150

        XCTAssertEqual(
            TextDisplaySettings.resolved(
                \.fontSize,
                window: windowSettings,
                workspace: workspaceSettings,
                global: globalSettings,
                defaults: defaults
            ),
            18
        )
        XCTAssertEqual(
            TextDisplaySettings.resolved(
                \.fontFamily,
                window: windowSettings,
                workspace: workspaceSettings,
                global: globalSettings,
                defaults: defaults
            ),
            "serif"
        )
        XCTAssertEqual(
            TextDisplaySettings.resolved(
                \.lineSpacing,
                window: windowSettings,
                workspace: workspaceSettings,
                global: globalSettings,
                defaults: defaults
            ),
            125
        )
        XCTAssertNil(
            TextDisplaySettings.resolved(
                \.topMargin,
                window: windowSettings,
                workspace: workspaceSettings,
                global: globalSettings,
                defaults: defaults
            )
        )
    }

    func testTextDisplaySettingsFullyResolvedUsesGlobalBeforeDefaults() {
        let dayBackground = Int(Int32(bitPattern: 0xFFFAF4E8))
        let nightTextColor = Int(Int32(bitPattern: 0xFFF1E7D0))
        let workspaceNightTextColor = Int(Int32(bitPattern: 0xFFCCCCCC))

        var globalSettings = TextDisplaySettings()
        globalSettings.dayBackground = dayBackground
        globalSettings.nightTextColor = nightTextColor

        var workspaceSettings = TextDisplaySettings()
        workspaceSettings.nightTextColor = workspaceNightTextColor

        let resolved = TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: workspaceSettings,
            global: globalSettings
        )

        XCTAssertEqual(resolved.dayBackground, dayBackground)
        XCTAssertEqual(resolved.nightTextColor, workspaceNightTextColor)
        XCTAssertEqual(resolved.dayTextColor, TextDisplaySettings.appDefaults.dayTextColor)
    }

    func testTextDisplaySettingsChangedFieldsOnlyClearMatchingDirtyOverrides() {
        var previousGlobal = TextDisplaySettings()
        previousGlobal.fontSize = 18
        previousGlobal.lineSpacing = 10
        previousGlobal.showVerseNumbers = true

        var currentGlobal = previousGlobal
        currentGlobal.fontSize = 20
        currentGlobal.showVerseNumbers = false

        let changedFields = TextDisplaySettings.changedFields(
            from: previousGlobal,
            to: currentGlobal
        )

        var childOverrides = TextDisplaySettings()
        childOverrides.fontSize = 20
        childOverrides.lineSpacing = 10
        childOverrides.showVerseNumbers = false

        XCTAssertTrue(
            childOverrides.clearOverridesMatchingParent(
                currentGlobal,
                only: changedFields
            )
        )
        XCTAssertNil(childOverrides.fontSize)
        XCTAssertNil(childOverrides.showVerseNumbers)
        XCTAssertEqual(childOverrides.lineSpacing, 10)
    }

    func testReaderWindowControlsAvoidanceInsetsStayOffForFullscreenIPad() {
        let insets = ReaderWindowControlsAvoidanceMetrics.documentHeaderInsets(
            isPad: true,
            sceneSize: CGSize(width: 834, height: 1194),
            screenWidth: 834,
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
        )

        XCTAssertEqual(insets, EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    func testReaderWindowControlsAvoidanceInsetsReserveSpaceForWindowedIPad() {
        let insets = ReaderWindowControlsAvoidanceMetrics.documentHeaderInsets(
            isPad: true,
            sceneSize: CGSize(width: 700, height: 980),
            screenWidth: 834,
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
        )

        XCTAssertEqual(insets.top, 10)
        XCTAssertEqual(insets.leading, 56)
        XCTAssertEqual(insets.bottom, 0)
        XCTAssertEqual(insets.trailing, 0)
    }

    func testReaderWindowControlsAvoidanceInsetsOnlyTopUpMissingSafeAreaClearance() {
        let insets = ReaderWindowControlsAvoidanceMetrics.documentHeaderInsets(
            isPad: true,
            sceneSize: CGSize(width: 700, height: 980),
            screenWidth: 834,
            safeAreaInsets: EdgeInsets(top: 36, leading: 20, bottom: 20, trailing: 0)
        )

        XCTAssertEqual(insets.top, 0)
        XCTAssertEqual(insets.leading, 36)
    }

    func testBibleReaderDocumentHeaderBuildsBibleModeWithWindowControlInsets() {
        let view = BibleReaderDocumentHeader(
            mode: .bible(
                title: "Genesis 1:1",
                subtitle: "King James Version",
                hasPrevious: false,
                hasNext: true
            ),
            currentReference: "Genesis 1",
            avoidanceInsets: EdgeInsets(top: 10, leading: 56, bottom: 0, trailing: 0),
            onOpenNavigationDrawer: {},
            onNavigatePrevious: {},
            onShowBookChooser: {},
            onNavigateNext: {},
            onReturnFromMyNotes: {},
            onReturnFromStudyPad: {},
            onReturnFromAuxiliary: {},
            onBrowseAuxiliary: {}
        ) {
            EmptyView()
        }

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderDocumentHeader"))
    }

    func testBibleReaderToolbarActionsBuildCompactStrongsConfiguration() {
        let view = BibleReaderToolbarActions(
            usesCompactToolbar: true,
            preferredSingleAccessory: .search,
            moduleHasStrongs: true,
            strongsIconAssetName: "ToolbarStrongsHebrewLinks",
            strongsMode: StrongsMode.inline.rawValue,
            strongsEnabled: true,
            isBibleActive: true,
            isCommentaryActive: false,
            searchEnabled: true,
            speakEnabled: true,
            moduleActionsEnabled: true,
            onShowSearch: {},
            onShowSpeak: {},
            onApplyStrongsMode: { _ in },
            onBibleTap: {},
            onBibleLongPress: {},
            onCommentaryTap: {},
            onCommentaryLongPress: {},
            onShowWorkspaces: {}
        ) {
            EmptyView()
        }

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderToolbarActions"))
    }

    /**
     Verifies Android-style toolbar popups share the same trailing menu rail.

     The Bible quick selector is triggered by the Bible toolbar icon, but Android presents toolbar
     popup menus from the trailing app-bar region. The selector therefore uses the trigger for
     vertical placement only and pins its right edge to the same trailing rail as the overflow menu.
     A failure means the selector can drift toward the middle of the reader on compact screens.
     */
    func testReaderToolbarPopupPlacementPinsQuickSelectorToTrailingMenuRail() {
        let containerSize = CGSize(width: 393, height: 852)
        let safeAreaInsets = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let bibleTrigger = CGRect(x: 292, y: 182, width: 24, height: 22)
        let overflowTrigger = CGRect(x: 360, y: 182, width: 24, height: 22)
        let quickSelectorWidth: CGFloat = 232
        let overflowMenuWidth: CGFloat = 236

        let quickPlacement = ReaderToolbarPopupPlacement.trailingToolbarPopup(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            triggerRect: bibleTrigger,
            popupWidth: quickSelectorWidth
        )
        let overflowPlacement = ReaderToolbarPopupPlacement.trailingToolbarPopup(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            triggerRect: overflowTrigger,
            popupWidth: overflowMenuWidth
        )

        XCTAssertEqual(quickPlacement.offset.width + quickSelectorWidth, 385, accuracy: 0.001)
        XCTAssertEqual(
            quickPlacement.offset.width + quickSelectorWidth,
            overflowPlacement.offset.width + overflowMenuWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(quickPlacement.offset.height, bibleTrigger.maxY + 6, accuracy: 0.001)
    }

    /**
     Verifies toolbar popups expose a bounded viewport height for long Android-style menus.

     Android's `PopupMenu` remains scrollable when many installed modules are available. The iOS
     quick selector must therefore receive a finite height between the toolbar trigger and the
     bottom safe area instead of expanding its full row stack off-screen.
     */
    func testReaderToolbarPopupPlacementBoundsQuickSelectorHeightToVisibleViewport() {
        let containerSize = CGSize(width: 393, height: 852)
        let safeAreaInsets = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let bibleTrigger = CGRect(x: 292, y: 182, width: 24, height: 22)

        let placement = ReaderToolbarPopupPlacement.trailingToolbarPopup(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            triggerRect: bibleTrigger,
            popupWidth: 232
        )

        XCTAssertEqual(placement.maximumHeight, 600, accuracy: 0.001)
    }

    /**
     Verifies toolbar popup placement stays inside horizontal safe areas.

     Android anchors popup menus to app-bar controls that are already laid out inside system insets.
     The iOS shared popup placement therefore needs to include horizontal safe-area insets when
     computing the trailing rail, especially in landscape where notches and system regions can
     consume non-zero leading or trailing space.
     */
    func testReaderToolbarPopupPlacementRespectsHorizontalSafeAreas() {
        let containerSize = CGSize(width: 852, height: 393)
        let safeAreaInsets = EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 47)
        let trigger = CGRect(x: 760, y: 42, width: 24, height: 22)
        let popupWidth: CGFloat = 236

        let placement = ReaderToolbarPopupPlacement.trailingToolbarPopup(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            triggerRect: trigger,
            popupWidth: popupWidth
        )

        XCTAssertEqual(placement.offset.width, 561, accuracy: 0.001)
        XCTAssertEqual(placement.offset.width + popupWidth, 797, accuracy: 0.001)
    }

    /**
     Verifies toolbar popup width calculation cannot feed negative dimensions into SwiftUI layout.

     SwiftUI may report transient zero-width geometry during popup presentation or device rotation.
     The reader uses the bounded width for both placement and `.frame(width:)`, so the shared width
     helper must clamp undersized containers to zero, account for safe-area insets before SwiftUI
     receives a frame width, and preserve normal Android-style popup sizing when enough space
     exists.
     */
    func testReaderToolbarPopupWidthClampHandlesTransientNarrowGeometry() {
        XCTAssertEqual(
            ReaderToolbarPopupPlacement.boundedWidth(
                containerWidth: 0,
                preferredWidth: 236,
                maximumWidth: 236
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderToolbarPopupPlacement.boundedWidth(
                containerWidth: 8,
                preferredWidth: 236,
                maximumWidth: 236
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderToolbarPopupPlacement.boundedWidth(
                containerWidth: 393,
                preferredWidth: max(CGFloat(393) * 0.42, 156),
                maximumWidth: 232
            ),
            CGFloat(165.06),
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderToolbarPopupPlacement.boundedWidth(
                containerWidth: 200,
                safeAreaInsets: EdgeInsets(top: 0, leading: 80, bottom: 0, trailing: 80),
                preferredWidth: 236,
                maximumWidth: 236
            ),
            24,
            accuracy: 0.001
        )
    }

    func testBibleReaderOverflowMenuBuildsWithBibleDisplayOptions() {
        let state = BibleReaderOverflowMenuState(
            isFullScreen: false,
            showsNightModeToggle: true,
            nightMode: false,
            showsTiltToScrollToggle: true,
            tiltToScrollEnabled: false,
            showsReverseSplitModeToggle: true,
            reverseSplitModeEnabled: false,
            windowPinningEnabled: false,
            showsBibleDisplayOptions: true,
            sectionTitlesEnabled: true,
            moduleHasStrongs: true,
            strongsMenuIconAssetName: "ToolbarStrongsHebrew",
            verseNumbersEnabled: true
        )
        let view = BibleReaderOverflowMenu(
            state: state,
            colorScheme: ColorScheme.light,
            onAction: { _ in }
        )

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderOverflowMenu"))
    }

    /**
     Verifies Downloads is modeled as a reader destination rather than a top-level sheet.

     Android opens `Download Documents` as an activity-style route with its own back app bar. The iOS
     reader should therefore expose Downloads through destination routing, leaving `ReaderSheet` for
     genuinely modal reader surfaces.
     */
    func testBibleReaderDownloadsUsesReaderDestinationRoute() {
        XCTAssertEqual(BibleReaderView.ReaderDestination.downloads.rawValue, "downloads")
        XCTAssertEqual(BibleReaderView.ReaderDestination.downloads.id, "downloads")
    }

    func testBibleReaderKeyboardShortcutsBuildCommandSurface() {
        let view = BibleReaderKeyboardShortcuts(
            onSearch: {},
            onShowBookChooser: {},
            onOpenBookmarks: {},
            onNavigatePrevious: {},
            onNavigateNext: {},
            onCloseClientModal: {},
            onOpenDownloads: {},
            onOpenSettings: {}
        )

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderKeyboardShortcuts"))
    }

    func testModuleBrowserFiltersAndSortsAndroidDownloadRows() {
        let modules = [
            RemoteModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0",
                installSizeBytes: 1_260_000
            ),
            RemoteModuleInfo(
                name: "WEB",
                description: "World English Bible",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "2.0"
            ),
            RemoteModuleInfo(
                name: "REC",
                description: "Recommended Bible",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
            ),
            RemoteModuleInfo(
                name: "WARN",
                description: "Known warning module",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
            ),
            RemoteModuleInfo(
                name: "HIDE",
                description: "Hidden module",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
            ),
            RemoteModuleInfo(
                name: "MHC",
                description: "Matthew Henry",
                category: .commentary,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
            ),
            RemoteModuleInfo(
                name: "ADDON",
                description: "Add-on font pack",
                category: .addon,
                language: "zxx",
                sourceName: "AndBible",
                version: "1.0"
            ),
            RemoteModuleInfo(
                name: "PSEUDO",
                description: "Unavailable translation",
                category: .bible,
                language: "en",
                sourceName: "Not Available",
                availability: .unavailable,
                unavailableReason: "Unavailable",
                version: "0.0"
            )
        ]
        let installed = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en", version: "1.0"),
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en", version: "1.0")
        ]
        let recommended = ModuleDownloadConfiguration(
            bibles: ["en": ["REC::CrossWire"]]
        )
        let bad = ModuleDownloadConfiguration(
            bibles: ["en": ["WARN::CrossWire::1.0::W", "HIDE::CrossWire::1.0::H"]]
        )

        let filtered = ModuleBrowserView.filteredDownloadModules(
            modules,
            selectedCategory: nil,
            selectedLanguage: "en",
            searchText: "",
            installedModules: installed,
            downloadActivities: ["WARN": .inProgress(0.25)],
            recommendedDocuments: recommended,
            badDocuments: bad
        )

        XCTAssertEqual(filtered.map(\.name), ["WARN", "WEB", "KJV", "REC", "PSEUDO", "MHC"])
        let addonFiltered = ModuleBrowserView.filteredDownloadModules(
            modules,
            selectedCategory: .addon,
            selectedLanguage: "en",
            searchText: "",
            installedModules: installed,
            downloadActivities: [:],
            recommendedDocuments: recommended,
            badDocuments: bad
        )
        XCTAssertEqual(addonFiltered.map(\.name), ["ADDON"])
        XCTAssertEqual(
            ModuleBrowserView.displayStatus(
                for: modules[1],
                installedModules: installed,
                downloadActivities: [:]
            ),
            .updateAvailable
        )
        XCTAssertEqual(ModuleBrowserView.installSizeText(for: modules[0].installSizeBytes), "1.3 MB")
        XCTAssertTrue(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "1.10", installedVersion: "1.9"))
        XCTAssertFalse(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "1.0", installedVersion: "1.0"))
        XCTAssertFalse(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "", installedVersion: "1.0"))
        XCTAssertNil(ModuleBrowserView.installSizeText(for: 0))
        XCTAssertNil(ModuleBrowserView.installSizeText(for: -1))
    }

    func testModuleBrowserMergesCachedCatalogRowsForFailedSources() {
        let refreshedModules = [
            RemoteModuleInfo(
                name: "ASV",
                description: "American Standard Version",
                category: .bible,
                language: "en",
                sourceName: "AndBible"
            ),
            RemoteModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                sourceName: "CrossWire"
            )
        ]
        let cachedModules = [
            RemoteModuleInfo(
                name: "ASV",
                description: "American Standard Version",
                category: .bible,
                language: "en",
                sourceName: "AndBible"
            ),
            RemoteModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                sourceName: "CrossWire"
            ),
            RemoteModuleInfo(
                name: "MHC",
                description: "Matthew Henry",
                category: .commentary,
                language: "en",
                sourceName: "CrossWire"
            ),
            RemoteModuleInfo(
                name: "WEB",
                description: "World English Bible",
                category: .bible,
                language: "en",
                sourceName: "CustomSource"
            )
        ]

        let merged = ModuleBrowserView.modulesByAddingCachedCatalogsForFailedSources(
            refreshedModules: refreshedModules,
            cachedModules: cachedModules,
            failedSourceNames: ["CrossWire"]
        )

        XCTAssertEqual(merged.map(\.id), ["AndBible:ASV", "CrossWire:KJV", "CrossWire:MHC"])
    }

    func testModuleBrowserStartupDefaultsRequireInstallableCatalogRows() {
        let unavailableModules = [
            RemoteModuleInfo(
                name: "PSEUDO",
                description: "Unavailable translation",
                category: .bible,
                language: "en",
                sourceName: "Not Available",
                availability: .unavailable,
                unavailableReason: "Unavailable"
            )
        ]
        let installableModules = [
            RemoteModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                sourceName: "CrossWire"
            )
        ]

        XCTAssertFalse(ModuleBrowserView.startupDefaultCatalogHasInstallableRows([]))
        XCTAssertFalse(ModuleBrowserView.startupDefaultCatalogHasInstallableRows(unavailableModules))
        XCTAssertTrue(ModuleBrowserView.startupDefaultCatalogHasInstallableRows(installableModules))
    }

    func testDownloadConfigurationDecodesAndroidMetadataEntries() throws {
        let data = """
        {
          "bibles": {"en": ["KJV::CrossWire", "ASV"]},
          "commentaries": {},
          "dictionaries": {},
          "books": {},
          "maps": {},
          "addons": {"en": ["AddonFonts::AndBible"]}
        }
        """.data(using: .utf8)!
        let recommended = try JSONDecoder().decode(ModuleDownloadConfiguration.self, from: data)
        let bad = ModuleDownloadConfiguration(
            bibles: ["en": ["KJV::CrossWire::2.3::W", "WEB::CrossWire::1.0::H"]],
            addons: ["en": ["AddonFonts::AndBible::1.0::W"]]
        )
        let kjv = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            sourceName: "CrossWire",
            version: "2.3"
        )
        let asv = RemoteModuleInfo(
            name: "ASV",
            description: "American Standard Version",
            category: .bible,
            language: "en",
            sourceName: "Different",
            version: "1.0"
        )
        let web = RemoteModuleInfo(
            name: "WEB",
            description: "World English Bible",
            category: .bible,
            language: "en",
            sourceName: "CrossWire",
            version: "1.0"
        )
        let addon = RemoteModuleInfo(
            name: "AddonFonts",
            description: "Add-on font pack",
            category: .addon,
            language: "zxx",
            sourceName: "AndBible",
            version: "1.0"
        )

        XCTAssertTrue(recommended.contains(kjv))
        XCTAssertTrue(recommended.contains(asv))
        XCTAssertTrue(recommended.contains(addon))
        XCTAssertEqual(recommended.addons, ["en": ["AddonFonts::AndBible"]])
        XCTAssertEqual(bad.badDocumentAction(for: kjv), .warn)
        XCTAssertEqual(bad.badDocumentAction(for: addon), .warn)
        XCTAssertEqual(bad.badDocumentAction(for: web), .hide)
        XCTAssertEqual(bad.badDocumentAction(for: asv), .none)
    }

    func testRecommendedDocumentRefreshPreservesCachedMetadataAfterFailures() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validData = """
        {
          "bibles": {"en": ["KJV::CrossWire"]},
          "commentaries": {},
          "dictionaries": {},
          "books": {},
          "maps": {}
        }
        """.data(using: .utf8)!
        let malformedData = Data("<html>temporary failure</html>".utf8)
        var responses = [
            (statusCode: 200, data: validData),
            (statusCode: 200, data: malformedData),
            (statusCode: 500, data: Data("temporary failure".utf8))
        ]

        MockURLProtocol.requestHandler = { request in
            let responsePayload = responses.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: responsePayload.statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responsePayload.data)
        }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeMockedURLSession()
        )

        let refreshedMetadata = try await repository.refreshRecommendedDocuments()
        XCTAssertEqual(refreshedMetadata.bibles["en"], ["KJV::CrossWire"])
        XCTAssertEqual(repository.loadCachedRecommendedDocuments()?.bibles["en"], ["KJV::CrossWire"])

        do {
            _ = try await repository.refreshRecommendedDocuments()
            XCTFail("Expected malformed recommended-document metadata to fail decoding.")
        } catch {
            XCTAssertEqual(repository.loadCachedRecommendedDocuments()?.bibles["en"], ["KJV::CrossWire"])
        }

        do {
            _ = try await repository.refreshRecommendedDocuments()
            XCTFail("Expected non-200 recommended-document metadata to fail downloading.")
        } catch {
            XCTAssertEqual(repository.loadCachedRecommendedDocuments()?.bibles["en"], ["KJV::CrossWire"])
        }
    }

    /**
     Verifies iOS preserves Android's `InstallSize` units when rendering Downloads sizes.

     Android reads SWORD `KEY_INSTALL_SIZE` directly as bytes and formats that value as megabytes.
     iOS must not multiply it by 1024, because that inflates catalog sizes by three orders of
     magnitude and makes the Downloads browser disagree with Android for the same repository row.
     */
    func testCatalogModulePreservesAndroidInstallSizeBytes() {
        let module = CatalogModule(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            modDrv: "zText",
            dataPath: "modules/texts/ztext/kjv/",
            confContent: "",
            sourceName: "CrossWire",
            version: "1.0",
            size: "1260000"
        )

        XCTAssertEqual(module.remoteModuleInfo.installSizeBytes, 1_260_000)
        XCTAssertEqual(ModuleBrowserView.installSizeText(for: module.remoteModuleInfo.installSizeBytes), "1.3 MB")
    }

    func testBibleReaderModulePickerBuildsForBibleCategory() {
        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        let view = BibleReaderModulePicker(
            controller: controller,
            category: .bible,
            onDismiss: {},
            onOpenDownloads: {},
            onOpenDictionaryBrowser: {},
            onOpenGeneralBookBrowser: {},
            onOpenMapBrowser: {}
        )

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderModulePicker"))
    }

    func testBibleReaderModulePickerFiltersAndroidChooserCategoriesAndSearch() {
        let modules = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en"),
            ModuleInfo(name: "MHC", description: "Matthew Henry", category: .commentary, language: "en"),
            ModuleInfo(name: "StrongsHebrew", description: "Strong's Hebrew", category: .dictionary, language: "he"),
            ModuleInfo(name: "BookA", description: "General reference book", category: .generalBook, language: "fr"),
            ModuleInfo(name: "MapA", description: "Bible maps", category: .map, language: "en"),
            ModuleInfo(name: "Devotion", description: "Daily devotional", category: .dailyDevotion, language: "en")
        ]

        XCTAssertEqual(
            BibleReaderModulePicker.filteredModules(
                modules,
                selectedCategory: nil,
                selectedLanguage: "",
                searchText: ""
            ).map(\.name),
            ["KJV", "MHC", "StrongsHebrew", "BookA", "MapA"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredModules(
                modules,
                selectedCategory: .dictionary,
                selectedLanguage: "",
                searchText: ""
            ).map(\.name),
            ["StrongsHebrew"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredModules(
                modules,
                selectedCategory: nil,
                selectedLanguage: "en",
                searchText: ""
            ).map(\.name),
            ["KJV", "MHC", "MapA"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredModules(
                modules,
                selectedCategory: .bible,
                selectedLanguage: "he",
                searchText: ""
            ).map(\.name),
            []
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredModules(
                modules,
                selectedCategory: nil,
                selectedLanguage: "",
                searchText: "strong"
            ).map(\.name),
            ["StrongsHebrew"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.availableLanguages(from: modules),
            ["en", "fr", "he"]
        )
        let bibleOnlyModules = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en")
        ]
        XCTAssertTrue(
            BibleReaderModulePicker.shouldShowCategoryEmptyState(
                bibleOnlyModules,
                selectedCategory: .dictionary
            )
        )
        XCTAssertFalse(
            BibleReaderModulePicker.shouldShowCategoryEmptyState(
                bibleOnlyModules,
                selectedCategory: .bible
            )
        )
        XCTAssertFalse(
            BibleReaderModulePicker.shouldShowCategoryEmptyState(
                modules,
                selectedCategory: nil
            )
        )
    }

    func testBibleReaderModulePickerMapsAndroidDocumentTypeCategories() {
        XCTAssertEqual(BibleReaderModulePicker.initialCategoryFilter(for: .bible), .bible)
        XCTAssertEqual(BibleReaderModulePicker.initialCategoryFilter(for: .commentary), .commentary)
        XCTAssertEqual(BibleReaderModulePicker.initialCategoryFilter(for: .dictionary), .dictionary)
        XCTAssertEqual(BibleReaderModulePicker.initialCategoryFilter(for: .generalBook), .generalBook)
        XCTAssertEqual(BibleReaderModulePicker.initialCategoryFilter(for: .map), .map)
        XCTAssertNil(BibleReaderModulePicker.initialCategoryFilter(for: .epub))
        XCTAssertNil(BibleReaderModulePicker.initialCategoryFilter(for: .dailyDevotion))

        XCTAssertEqual(BibleReaderModulePicker.documentCategory(for: .bible), .bible)
        XCTAssertEqual(BibleReaderModulePicker.documentCategory(for: .commentary), .commentary)
        XCTAssertEqual(BibleReaderModulePicker.documentCategory(for: .dictionary), .dictionary)
        XCTAssertEqual(BibleReaderModulePicker.documentCategory(for: .generalBook), .generalBook)
        XCTAssertEqual(BibleReaderModulePicker.documentCategory(for: .map), .map)
        XCTAssertNil(BibleReaderModulePicker.documentCategory(for: .dailyDevotion))
        XCTAssertNil(BibleReaderModulePicker.documentCategory(for: .glossary))
        XCTAssertNil(BibleReaderModulePicker.documentCategory(for: .unknown))
    }

    /**
     Protects Android `MainBibleActivity.menuForDocs` parity for the Bible toolbar quick menu.

     Android sorts quick-menu entries by language code and then book abbreviation, renders labels as
     abbreviation plus language code in parentheses, and disables the current document instead of
     re-selecting it. This test uses the pure presentation contract so future UI refactors cannot
     accidentally restore the old iOS full-sheet semantics or sort by localized description.
     */
    func testBibleQuickModuleSelectorRowsMirrorAndroidOrderingLabelsAndDisabledCurrentDocument() {
        let modules = [
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en"),
            ModuleInfo(name: "FinRK", description: "Finnish Revised Version", category: .bible, language: "fi"),
            ModuleInfo(name: "AB", description: "Another Bible", category: .bible, language: "en")
        ]

        let rows = BibleReaderQuickModuleSelectorPresentation.rows(
            for: modules,
            activeModuleName: "WEB"
        )

        XCTAssertEqual(rows.map(\.module.name), ["AB", "WEB", "FinRK"])
        XCTAssertEqual(rows.map(\.title), ["AB (en)", "WEB (en)", "FinRK (fi)"])
        XCTAssertEqual(rows.map(\.isEnabled), [true, false, true])
    }

    /**
     Protects the quick-selector row equality contract used by presentation tests.

     Row equality should cover only visible and behavior-significant fields: selected module name,
     rendered title, and enabled state. Metadata such as description, category, or language is
     normalized into the title before rendering and should not make tests fail when behavior is
     unchanged.
     */
    func testBibleQuickModuleSelectorRowEqualityIgnoresNonVisibleModuleMetadata() {
        let lhs = BibleReaderQuickModuleSelectorPresentation.Row(
            module: ModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en"
            ),
            title: "KJV (en)",
            isEnabled: true
        )
        let rhs = BibleReaderQuickModuleSelectorPresentation.Row(
            module: ModuleInfo(
                name: "KJV",
                description: "Different catalog description",
                category: .commentary,
                language: "fi"
            ),
            title: "KJV (en)",
            isEnabled: true
        )

        XCTAssertEqual(lhs, rhs)
    }

    /**
     Protects long quick-selector lists from becoming unscrollable off-screen stacks.

     Users can install dozens of Bible modules. Android renders those entries through a popup menu
     that can scroll; the SwiftUI parity renderer must likewise be backed by a scroll container so
     all available modules can be reached without falling back to the full iOS sheet.
     */
    func testBibleQuickModuleSelectorUsesScrollContainerForLongInstalledModuleLists() throws {
        let rows = (0..<60).map { index in
            BibleReaderQuickModuleSelectorPresentation.Row(
                module: ModuleInfo(
                    name: String(format: "MOD%02d", index),
                    description: "Module \(index)",
                    category: .bible,
                    language: "en"
                ),
                title: String(format: "MOD%02d (en)", index),
                isEnabled: true
            )
        }
        let view = BibleReaderQuickModuleSelector(
            rows: rows,
            colorScheme: .light,
            onSelect: { _ in }
        )

        XCTAssertTrue(String(describing: type(of: view.body)).contains("ScrollView"))
        let selectorSource = try bibleUISource(named: "BibleReaderQuickModuleSelector.swift")
        XCTAssertTrue(selectorSource.contains("LazyVStack(alignment: .leading, spacing: 0)"))
        XCTAssertTrue(selectorSource.contains("Button {"))
        XCTAssertTrue(selectorSource.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(selectorSource.contains(".disabled(!row.isEnabled)"))
        XCTAssertFalse(selectorSource.contains("            VStack(alignment: .leading, spacing: 0)"))
    }

    /**
     Protects Android's exactly-two-document shortcut in `menuForDocs`.

     When only two Bible modules are available, Android switches directly to the other document and
     does not show a popup. The iOS toolbar action must keep that shortcut while replacing only the
     three-or-more path with the compact quick selector.
     */
    func testBibleQuickModuleSelectorActionMirrorsAndroidTwoDocumentShortcut() {
        let modules = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en"),
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en")
        ]

        let action = BibleReaderQuickModuleSelectorPresentation.action(
            for: modules,
            activeModuleName: "KJV"
        )

        guard case .switchDirectly(let row) = action else {
            XCTFail("Expected Android's exactly-two-module shortcut to select the alternate Bible.")
            return
        }
        XCTAssertEqual(row.module.name, "WEB")
        XCTAssertEqual(row.module.category, .bible)
    }

    /**
     Protects Android's popup threshold in `menuForDocs`.

     Three or more Bible modules must show the compact anchored quick selector, not the full
     document picker sheet. The sorted rows are part of the action payload so the UI layer cannot
     accidentally diverge from Android ordering while still showing a popup.
     */
    func testBibleQuickModuleSelectorActionShowsPopupForMoreThanTwoModules() {
        let modules = [
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en"),
            ModuleInfo(name: "FinRK", description: "Finnish Revised Version", category: .bible, language: "fi"),
            ModuleInfo(name: "AB", description: "Another Bible", category: .bible, language: "en")
        ]

        let action = BibleReaderQuickModuleSelectorPresentation.action(
            for: modules,
            activeModuleName: "WEB"
        )

        XCTAssertEqual(
            action,
            .showPopup([
                BibleReaderQuickModuleSelectorPresentation.Row(
                    module: modules[2],
                    title: "AB (en)",
                    isEnabled: true
                ),
                BibleReaderQuickModuleSelectorPresentation.Row(
                    module: modules[0],
                    title: "WEB (en)",
                    isEnabled: false
                ),
                BibleReaderQuickModuleSelectorPresentation.Row(
                    module: modules[1],
                    title: "FinRK (fi)",
                    isEnabled: true
                )
            ])
        )
    }

    /**
     Protects Android's non-two-document popup rule for single available Bible modules.

     Android only special-cases exactly two documents. With one available Bible it still shows the
     popup, and if the current document is not that Bible then the row remains enabled so the toolbar
     can switch from commentary or another category back to Bible mode.
     */
    func testBibleQuickModuleSelectorActionShowsPopupForSingleModuleWhenBibleIsNotCurrentDocument() {
        let modules = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en")
        ]

        let action = BibleReaderQuickModuleSelectorPresentation.action(
            for: modules,
            activeModuleName: nil
        )

        XCTAssertEqual(
            action,
            .showPopup([
                BibleReaderQuickModuleSelectorPresentation.Row(
                    module: modules[0],
                    title: "KJV (en)",
                    isEnabled: true
                )
            ])
        )
    }

    /**
     Protects the quick selector's selected-row side effect contract.

     Android's popup selection calls the same current-document switch path used elsewhere in the
     reader. iOS should likewise route selected quick-menu modules through
     `BibleReaderController.switchBibleDocument(to:)` and persist the chosen Bible document plus
     Bible category on the pane's `PageManager`, rather than maintaining separate quick-selector
     state.
     */
    @MainActor
    func testBibleQuickModuleSelectorSelectionUsesControllerSwitchPathAndPersistsPaneDocument() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        try seedBibleAliasModule(
            named: "WEB",
            description: "World English Bible",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window

        let action = BibleReaderQuickModuleSelectorPresentation.action(
            for: controller.installedBibleModules,
            activeModuleName: controller.activeModuleName
        )
        guard case .switchDirectly(let row) = action else {
            XCTFail("Expected Android's exactly-two-module shortcut to select the alternate Bible.")
            return
        }

        controller.switchBibleDocument(to: row.module.name)

        XCTAssertEqual(controller.activeModuleName, "WEB")
        XCTAssertEqual(pageManager.bibleDocument, "WEB")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.bible.pageManagerKey)
    }

    /**
     Protects Android `MainBibleActivity.commentaryClick` candidate and row semantics.

     The Android default commentary toolbar tap calls `menuForDocs` with unlocked commentaries plus
     general books plus dictionaries, then `menuForDocs` sorts by language code and abbreviation and
     renders compact `initials (language)` rows. This test keeps that category mix in the shared
     quick-selector presentation contract so iOS cannot regress to the full commentary-only chooser
     sheet or sort by localized descriptions.
     */
    func testCommentaryQuickModuleSelectorRowsIncludeAndroidDocumentCategories() {
        let commentary = ModuleInfo(
            name: "MHC",
            description: "Matthew Henry",
            category: .commentary,
            language: "en"
        )
        let dictionary = ModuleInfo(
            name: "BDBT",
            description: "Brown Driver Briggs",
            category: .dictionary,
            language: "en"
        )
        let generalBook = ModuleInfo(
            name: "Pilgrim",
            description: "Pilgrim's Progress",
            category: .generalBook,
            language: "en"
        )
        let finnishCommentary = ModuleInfo(
            name: "FinComm",
            description: "Finnish Commentary",
            category: .commentary,
            language: "fi"
        )

        let rows = BibleReaderQuickModuleSelectorPresentation.rows(
            for: [generalBook, finnishCommentary, commentary, dictionary],
            activeModuleName: "BDBT"
        )

        XCTAssertEqual(rows.map(\.module.category), [.dictionary, .commentary, .generalBook, .commentary])
        XCTAssertEqual(rows.map(\.title), ["BDBT (en)", "MHC (en)", "Pilgrim (en)", "FinComm (fi)"])
        XCTAssertEqual(rows.map(\.isEnabled), [false, true, true, true])
    }

    /**
     Protects Android's atomic current-document switch behavior for commentary quick selections.

     Android `menuForDocs` delegates the selected commentary `Book` to `setCurrentDocument(book)`,
     which updates the active document and visible category together. iOS must provide the same
     controller-level contract for the quick selector instead of switching module and category in
     separate calls that can reload stale content or persist partial pane state.
     */
    @MainActor
    func testCommentaryDocumentSwitchPersistsModuleAndCategoryTogether() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        try seedEmptyRawCommentaryModule(named: "UITestComm", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.switchCommentaryDocument(to: "UITestComm")

        XCTAssertEqual(controller.currentCategory, .commentary)
        XCTAssertEqual(controller.activeCommentaryModuleName, "UITestComm")
        XCTAssertEqual(pageManager.commentaryDocument, "UITestComm")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.commentary.pageManagerKey)
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects Android's atomic current-document switch behavior for dictionary quick selections.

     Android routes dictionaries from the commentary quick popup through `setCurrentDocument(book)`.
     iOS must therefore persist the selected dictionary, clear stale dictionary entry state, and
     switch the visible category in one controller call rather than splitting module and category
     updates across separate mutations.
     */
    @MainActor
    func testDictionaryDocumentSwitchPersistsModuleCategoryAndClearsKeyTogether() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        try seedEmptyRawDictionaryModule(named: "UITestDict", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.dictionaryKey = "stale-key"
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.switchDictionaryDocument(to: "UITestDict")

        XCTAssertEqual(controller.currentCategory, .dictionary)
        XCTAssertEqual(controller.activeDictionaryModuleName, "UITestDict")
        XCTAssertNil(controller.currentDictionaryKey)
        XCTAssertEqual(pageManager.dictionaryDocument, "UITestDict")
        XCTAssertNil(pageManager.dictionaryKey)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.dictionary.pageManagerKey)
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects Android's atomic current-document switch behavior for general-book quick selections.

     Android includes general books in the commentary quick popup and applies selections through the
     same current-document transition. The iOS controller must persist module/category and clear the
     stale general-book key together so quick selection cannot leave mixed pane state behind.
     */
    @MainActor
    func testGeneralBookDocumentSwitchPersistsModuleCategoryAndClearsKeyTogether() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        try seedEmptyRawGeneralBookModule(named: "UITestGB", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.generalBookKey = "stale-key"
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.switchGeneralBookDocument(to: "UITestGB")

        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.activeGeneralBookModuleName, "UITestGB")
        XCTAssertNil(controller.currentGeneralBookKey)
        XCTAssertEqual(pageManager.generalBookDocument, "UITestGB")
        XCTAssertNil(pageManager.generalBookKey)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects Android's atomic current-document switch behavior for Bible quick selections.

     Android `MainBibleActivity.menuForDocs` delegates selected Bible rows to
     `CurrentPageManager.setCurrentDocument(book)`, which updates the active document and page
     category as one transition. iOS must not first reload the current non-Bible category and then
     reload the selected Bible, because that creates unnecessary WebView work and visible flicker.
     */
    @MainActor
    func testBibleDocumentSwitchFromCommentaryReloadsSelectedBibleOnce() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        try seedBibleAliasModule(
            named: "WEB",
            description: "World English Bible",
            in: modulePath
        )
        try seedEmptyRawCommentaryModule(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.switchCategory(to: .commentary)
        controller.bridgeDidSetClientReady(bridge)
        let baselineScriptCount = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.switchBibleDocument(to: "WEB")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentScripts = recordedScripts()
            .dropFirst(baselineScriptCount)
            .filter { $0.contains("emit('add_documents'") }
        XCTAssertEqual(addDocumentScripts.count, 1)
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: Array(addDocumentScripts), event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["bookCategory"] as? String, "BIBLE")
        XCTAssertEqual(payload["bookInitials"] as? String, "WEB")
        XCTAssertEqual(controller.currentCategory, .bible)
        XCTAssertEqual(controller.activeModuleName, "WEB")
        XCTAssertEqual(pageManager.bibleDocument, "WEB")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.bible.pageManagerKey)
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects the controller-level Bible switch API from accepting non-Bible modules.

     The quick selector and module picker currently pass Bible-filtered rows, but
     `BibleReaderController.switchBibleDocument(to:)` is public controller API and mirrors Android's
     current-document transition only for Bible documents. A non-Bible SWORD module must therefore
     leave the active Bible, document category, PageManager state, and persistence callbacks
     unchanged. A failure means an accidental non-Bible caller can corrupt pane state by forcing the
     reader into Bible mode with a commentary/dictionary module name.
     */
    @MainActor
    func testBibleDocumentSwitchRejectsNonBibleModulesWithoutStateMutation() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        try seedEmptyRawCommentaryModule(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.switchCategory(to: .commentary)
        let baselineCategory = controller.currentCategory
        let baselineBibleModuleName = controller.activeModuleName
        let baselineBibleDocument = pageManager.bibleDocument
        let baselineCategoryName = pageManager.currentCategoryName
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.switchBibleDocument(to: "UITestComm")

        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(controller.activeModuleName, baselineBibleModuleName)
        XCTAssertEqual(pageManager.bibleDocument, baselineBibleDocument)
        XCTAssertEqual(pageManager.currentCategoryName, baselineCategoryName)
        XCTAssertEqual(persistCount, 0)
    }

    /**
     Protects the extracted document-switch category guard used by Android-style current-document
     changes.

     A Bible document switch must not accept a commentary module because that would persist a Bible
     page identity with non-Bible initials. The controller's public API logs the failure; this
     collaborator-level contract keeps the rule isolated from logging and WebView reload concerns.
     */
    func testReaderModuleSwitchCoordinatorRejectsMismatchedDocumentCategory() {
        let coordinator = BibleReaderModuleSwitchCoordinator()

        let result = coordinator.documentSwitchPlan(
            moduleName: "MHC",
            moduleCategory: .commentary,
            targetCategory: .bible
        )

        XCTAssertEqual(
            result,
            .failure(.categoryMismatch(moduleName: "MHC", expected: .bible, actual: .commentary))
        )
    }

    /**
     Protects Android's atomic dictionary document switch persistence contract.

     Selecting a dictionary from the commentary/document chooser updates the visible category and
     selected dictionary together while clearing a stale dictionary key. A failure here means the
     controller could again split module selection from category persistence.
     */
    func testReaderModuleSwitchCoordinatorPersistsDictionaryDocumentAndClearsStaleKey() throws {
        let coordinator = BibleReaderModuleSwitchCoordinator()
        let pageManager = PageManager(currentCategoryName: DocumentCategory.bible.pageManagerKey)
        pageManager.dictionaryDocument = "OldDict"
        pageManager.dictionaryKey = "stale-key"

        let plan = try coordinator.documentSwitchPlan(
            moduleName: "BDBT",
            moduleCategory: .dictionary,
            targetCategory: .dictionary
        ).get()

        plan.apply(to: pageManager)

        XCTAssertEqual(plan.category, .dictionary)
        XCTAssertTrue(plan.updatesVisibleCategory)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.dictionary.pageManagerKey)
        XCTAssertEqual(pageManager.dictionaryDocument, "BDBT")
        XCTAssertNil(pageManager.dictionaryKey)
    }

    /**
     Protects module-only switching as separate from visible category switching.

     The full module picker currently selects a map by first switching the map module and then
     switching category. This legacy two-call path is still present in the UI, so a module-only plan
     must update the selected map and clear the stale key without changing the visible page category.
     */
    func testReaderModuleSwitchCoordinatorModuleOnlyPlanDoesNotChangeVisibleCategory() {
        let coordinator = BibleReaderModuleSwitchCoordinator()
        let pageManager = PageManager(currentCategoryName: DocumentCategory.bible.pageManagerKey)
        pageManager.mapDocument = "OldMap"
        pageManager.mapKey = "stale-map-key"

        let plan = coordinator.moduleOnlySwitchPlan(
            moduleName: "BibleMap",
            targetCategory: .map
        )

        plan.apply(to: pageManager)

        XCTAssertEqual(plan.category, .map)
        XCTAssertFalse(plan.updatesVisibleCategory)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.bible.pageManagerKey)
        XCTAssertEqual(pageManager.mapDocument, "BibleMap")
        XCTAssertNil(pageManager.mapKey)
    }

    /**
     Protects category-only reload decisions from being hidden inside controller code.

     Switching to the same category should persist the category but not request a WebView reload;
     switching to a different category should request one. The controller remains responsible for
     checking client readiness before actually reloading.
     */
    func testReaderModuleSwitchCoordinatorCategoryPlanRequestsReloadOnlyWhenCategoryChanges() {
        let coordinator = BibleReaderModuleSwitchCoordinator()

        let unchanged = coordinator.categorySwitchPlan(from: .bible, to: .bible)
        let changed = coordinator.categorySwitchPlan(from: .bible, to: .commentary)

        XCTAssertFalse(unchanged.shouldReloadContent)
        XCTAssertTrue(changed.shouldReloadContent)
    }

    /**
     Guards the reader coordinator against regressing to the iOS sheet for the quick-menu path.

     The coordinator state is intentionally private, so this source-level test checks the routing
     contract at the function boundary: Android's `menuForDocs` equivalent must route the resolved
     quick-selector rows into the popup, the toolbar button must publish anchor geometry for an
     in-reader popup, and module actions must be disabled until the focused pane controller exists,
     including accessibility exposure. Row selection must also dismiss the popup before checking
     whether the captured controller still exists. Bible/commentary toolbar gestures must dispatch
     tap or long-press exclusively so Android's quick-menu and full-chooser paths cannot both fire
     for one press. A failure means the user-visible selector likely drifted back toward the old
     full-sheet behavior, can accept taps before the Android-equivalent document state is available,
     can leave a stale popup onscreen after pane teardown, or can fire both selector paths from one
     toolbar gesture.
     */
    func testBibleToolbarMenuRoutesThroughAnchoredQuickSelectorInsteadOfSheet() throws {
        let readerSource = try bibleUISource(named: "BibleReaderView.swift")
        let toolbarSource = try bibleUISource(named: "BibleReaderToolbarActions.swift")
        let menuActionSource = try extractFunction(
            named: "performBibleMenuAction",
            from: readerSource
        )
        let selectionSource = try extractFunction(
            named: "selectBibleQuickModule",
            from: readerSource
        )

        XCTAssertTrue(menuActionSource.contains("case .showPopup(let rows):"))
        XCTAssertTrue(menuActionSource.contains("presentBibleQuickSelector(controller, rows: rows)"))
        XCTAssertFalse(menuActionSource.contains("performBibleChooserAction()"))
        XCTAssertTrue(readerSource.contains("@State private var bibleQuickModuleSelectorRows"))
        XCTAssertTrue(readerSource.contains("@State private var bibleQuickModuleSelectorTargetWindowId"))
        XCTAssertTrue(readerSource.contains("bibleQuickModuleSelectorTargetWindowId = resolvedTargetWindowId"))
        XCTAssertTrue(readerSource.contains("bibleQuickModuleSelectorTargetWindowId = nil"))
        XCTAssertTrue(readerSource.contains("let rows = bibleQuickModuleSelectorRows"))
        XCTAssertTrue(readerSource.contains("let targetWindowId = bibleQuickModuleSelectorTargetWindowId"))
        XCTAssertTrue(readerSource.contains("selectBibleQuickModule(module, targetWindowId: targetWindowId)"))
        XCTAssertTrue(readerSource.contains("moduleActionsEnabled: controller != nil"))
        XCTAssertTrue(readerSource.contains("ReaderBibleToolbarButtonBoundsPreferenceKey"))
        XCTAssertTrue(
            toolbarSource.contains(
                ".anchorPreference(key: ReaderBibleToolbarButtonBoundsPreferenceKey.self"
            )
        )
        XCTAssertTrue(toolbarSource.contains(".disabled(!moduleActionsEnabled)"))
        XCTAssertFalse(toolbarSource.contains(".simultaneousGesture(LongPressGesture"))
        XCTAssertTrue(toolbarSource.contains("LongPressGesture().exclusively(before: TapGesture())"))
        XCTAssertFalse(readerSource.contains("suppressBibleTapAfterLongPress"))
        XCTAssertFalse(readerSource.contains("suppressCommentaryTapAfterLongPress"))
        XCTAssertEqual(toolbarSource.components(separatedBy: "moduleToolbarAction(").count - 1, 2)
        XCTAssertTrue(toolbarSource.contains(".accessibilityHidden(!moduleActionsEnabled)"))
        XCTAssertTrue(selectionSource.contains("let controller = controller(for: targetWindowId)"))
        let resolveIndex = try XCTUnwrap(selectionSource.range(of: "let controller = controller(for: targetWindowId)")?.lowerBound)
        let dismissIndex = try XCTUnwrap(selectionSource.range(of: "dismissBibleQuickSelector()")?.lowerBound)
        XCTAssertLessThan(resolveIndex, dismissIndex)
    }

    /**
     Guards the commentary toolbar quick-menu route against preserving the old iOS sheet.

     Android default commentary taps show an anchored `PopupMenu` with commentaries, general books,
     and dictionaries while the reader remains visible. Long press remains the full
     `ChooseDocument` activity path except for Android's `swap-menu` setting. The SwiftUI
     coordinator state is private, so this source-level contract checks the same boundary as the
     Bible quick-menu test: commentary tap must resolve rows, show the anchored popup, anchor from
     the commentary toolbar button, and route selections through category-specific current-document
     switch methods.
     */
    func testCommentaryToolbarMenuRoutesThroughAnchoredQuickSelectorInsteadOfSheet() throws {
        let readerSource = try bibleUISource(named: "BibleReaderView.swift")
        let toolbarSource = try bibleUISource(named: "BibleReaderToolbarActions.swift")
        let menuActionSource = try extractFunction(
            named: "performCommentaryMenuAction",
            from: readerSource
        )
        let selectionSource = try extractFunction(
            named: "selectCommentaryQuickModule",
            from: readerSource
        )

        XCTAssertTrue(menuActionSource.contains("BibleReaderQuickModuleSelectorPresentation.action("))
        XCTAssertTrue(menuActionSource.contains("commentaryQuickSelectorModules("))
        XCTAssertTrue(menuActionSource.contains("presentCommentaryQuickSelector(controller, rows: rows)"))
        XCTAssertFalse(menuActionSource.contains("performCommentaryChooserAction()"))
        XCTAssertTrue(readerSource.contains("performCommentaryMenuAction(controller, includeAuxiliaryDocuments: false)"))
        XCTAssertTrue(readerSource.contains("modules += controller.installedGeneralBookModules"))
        XCTAssertTrue(readerSource.contains("modules += controller.installedDictionaryModules"))
        XCTAssertTrue(readerSource.contains("controller.installedCommentaryModules.filter(\\.isUnlocked)"))
        XCTAssertTrue(readerSource.contains("@State private var commentaryQuickModuleSelectorRows"))
        XCTAssertTrue(readerSource.contains("@State private var commentaryQuickModuleSelectorTargetWindowId"))
        XCTAssertTrue(readerSource.contains("commentaryQuickModuleSelectorTargetWindowId = resolvedTargetWindowId"))
        XCTAssertTrue(readerSource.contains("commentaryQuickModuleSelectorTargetWindowId = nil"))
        XCTAssertTrue(readerSource.contains("commentaryQuickModuleSelectorOverlay(anchor: anchor)"))
        XCTAssertTrue(readerSource.contains("ReaderCommentaryToolbarButtonBoundsPreferenceKey"))
        XCTAssertTrue(
            toolbarSource.contains(
                ".anchorPreference(key: ReaderCommentaryToolbarButtonBoundsPreferenceKey.self"
            )
        )
        XCTAssertTrue(selectionSource.contains("case .commentary:"))
        XCTAssertTrue(selectionSource.contains("controller.switchCommentaryDocument(to: module.name)"))
        XCTAssertTrue(selectionSource.contains("case .dictionary:"))
        XCTAssertTrue(selectionSource.contains("controller.switchDictionaryDocument(to: module.name)"))
        XCTAssertTrue(selectionSource.contains("case .generalBook:"))
        XCTAssertTrue(selectionSource.contains("controller.switchGeneralBookDocument(to: module.name)"))
        XCTAssertTrue(selectionSource.contains("dismissCommentaryQuickSelector()"))
    }

    /**
     Loads a Bible reader UI source file for source-level contract tests.

     Source assertions are used only where SwiftUI coordinator state is intentionally private and a
     pure behavior test cannot observe the routing boundary. The helper derives the path from the
     current test bundle so it works in local and CI checkouts without hard-coded absolute paths.
     */
    private func bibleUISource(named fileName: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("BibleUI")
            .appendingPathComponent("Sources")
            .appendingPathComponent("BibleUI")
            .appendingPathComponent("Bible")
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    /**
     Extracts one Swift function body from a source file for a focused source-contract assertion.

     The scanner balances braces after the named function declaration instead of checking arbitrary
     file-wide fragments, which keeps the tests tied to the specific behavior boundary they protect.
     */
    private func extractFunction(named functionName: String, from source: String) throws -> String {
        guard let functionRange = source.range(of: "func \(functionName)") else {
            throw NSError(
                domain: "AndBibleTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Function \(functionName) not found"]
            )
        }
        guard let openingBrace = source[functionRange.lowerBound...].firstIndex(of: "{") else {
            throw NSError(
                domain: "AndBibleTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Function \(functionName) has no body"]
            )
        }

        var depth = 0
        var current = openingBrace
        while current < source.endIndex {
            let character = source[current]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[functionRange.lowerBound...current])
                }
            }
            current = source.index(after: current)
        }

        throw NSError(
            domain: "AndBibleTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Function \(functionName) body was not balanced"]
        )
    }

    func testBibleReaderSpeakMiniPlayerBuildsWithSpeakService() {
        let view = BibleReaderSpeakMiniPlayer(
            speakService: SpeakService(),
            currentReference: "Genesis 1",
            onShowControls: {}
        )

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderSpeakMiniPlayer"))
    }

    func testBibleReaderNavigationDrawerBuildsWithActionHandler() {
        let view = BibleReaderNavigationDrawer(
            width: 306,
            colorScheme: ColorScheme.dark,
            versionText: "Version 1.0 (1)",
            onAction: { _ in }
        )

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderNavigationDrawer"))
    }

    /**
     Verifies the reader navigation drawer is hosted by the shared slide-out presentation shell.

     Android's hamburger menu remains a narrow left drawer over a dimmed reader. Passage selection
     is a separate full-screen chooser activity, so this shared shell should be reserved for the
     hamburger drawer and similar left navigation surfaces only.
     */
    func testReaderSideDrawerOverlayBuildsWithInjectedContent() {
        let view = ReaderSideDrawerOverlay(
            colorScheme: ColorScheme.light,
            dismissAreaIdentifier: "testDismissArea",
            onDismiss: {}
        ) { width in
            Text("Drawer \(Int(width))")
        }

        XCTAssertTrue(String(describing: type(of: view)).contains("ReaderSideDrawerOverlay"))
    }

    /**
     Verifies the passage chooser uses its Android-style full-screen shell.

     Android presents book/chapter/verse selection as a full-screen dark chooser with its own
     toolbar, not as the narrow hamburger drawer. Failure means iOS is artificially preserving a
     platform-specific presentation that hides part of the picker behind the reader surface.
     */
    func testPassageChooserUsesFullScreenChooserShell() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readerViewURL = repoRoot.appendingPathComponent(
            "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )

        let source = try String(contentsOf: readerViewURL, encoding: .utf8)
        let overlayStart = try XCTUnwrap(source.range(of: "private var bookChooserDrawerOverlay"))
        let overlayEnd = try XCTUnwrap(source[overlayStart.lowerBound...].range(of: "private func dismissReaderNavigationDrawer"))
        let overlaySource = String(source[overlayStart.lowerBound..<overlayEnd.lowerBound])

        XCTAssertTrue(overlaySource.contains("ReaderPassageChooserOverlay"))
        XCTAssertFalse(overlaySource.contains("ReaderSideDrawerOverlay"))
        XCTAssertFalse(overlaySource.contains("onCancel: dismissBookChooser"))
    }

    /**
     Verifies the passage chooser overlay does not expose an unused cancellation API.

     Dismissal belongs to `BookChooserView` through its explicit back button callback. Keeping a dead
     `onCancel` parameter on the overlay makes the reader shell look like it handles cancellation
     while the value is never read, so future call sites can drift into false safety.
     */
    func testReaderPassageChooserOverlayDoesNotExposeDeadCancellationAPI() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let overlayURL = repoRoot.appendingPathComponent(
            "Sources/BibleUI/Sources/BibleUI/Bible/ReaderPassageChooserOverlay.swift"
        )

        let source = try String(contentsOf: overlayURL, encoding: .utf8)

        XCTAssertFalse(source.contains("onCancel"))
    }

    /**
     Verifies all reader-hosted passage chooser entry points carry the active workspace title.

     Android appends `SharedActivityState.currentWorkspaceName` to the book chooser activity title.
     The SwiftUI chooser should receive the same workspace context from `BibleReaderView` wherever
     that chooser is hosted, rather than only for one visible entry point. Failure means a caller can
     drift back to an iOS-only title that hides the target workspace.
     */
    func testReaderPassageChooserCallSitesUseSharedWorkspaceTitleSource() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readerViewURL = repoRoot.appendingPathComponent(
            "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )

        let source = try String(contentsOf: readerViewURL, encoding: .utf8)
        let occurrences = source.components(separatedBy: "workspaceName: activePassageChooserWorkspaceName").count - 1

        XCTAssertEqual(occurrences, 2)
    }

    /**
     Verifies the drawer-hosted passage chooser does not depend on native navigation bars.

     Android's chooser activity owns its visible app bar as chooser content. `BibleReaderView`
     hides native navigation chrome for the reader, so the reader-hosted chooser must not try to
     recover by forcing a nested SwiftUI navigation bar visible. Failure means the app can regress
     to a brittle host-level toolbar that disappears under the reader shell.
     */
    func testPassageChooserDrawerDoesNotDependOnNativeNavigationBarInsideReader() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readerViewURL = repoRoot.appendingPathComponent(
            "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )

        let source = try String(contentsOf: readerViewURL, encoding: .utf8)
        guard let drawerStart = source.range(of: "private var bookChooserDrawerContent"),
              let nextSection = source.range(of: "/// Search sheet", range: drawerStart.upperBound..<source.endIndex) else {
            return XCTFail("Could not locate book chooser drawer content in BibleReaderView.swift")
        }

        let drawerSource = source[drawerStart.lowerBound..<nextSection.lowerBound]

        XCTAssertTrue(drawerSource.contains("BookChooserView("))
        XCTAssertFalse(drawerSource.contains(".toolbar(.visible, for: .navigationBar)"))
    }

    /**
     Verifies reader-hosted passage choosers store progress snapshots once per presentation.

     Reading and memorization snapshots decode persisted store payloads. The chooser progress
     closures run for many grid cells, and `BibleReaderView` can re-render while a chooser is open.
     The reader should therefore store a captured context at presentation time instead of rebuilding
     it from computed properties during unrelated renders.
     */
    func testReaderPassageChooserProgressProvidersCaptureSnapshotsOnce() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readerViewURL = repoRoot.appendingPathComponent(
            "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )

        let source = try String(contentsOf: readerViewURL, encoding: .utf8)
        let contextOccurrences = source.components(separatedBy: "let progressContext = passageChooserProgressContext").count - 1
        let captureOccurrences = source.components(separatedBy: "passageChooserProgressContext = makePassageChooserProgressContext()").count - 1

        XCTAssertTrue(source.contains("@State private var passageChooserProgressContext = PassageChooserProgressContext.empty"))
        XCTAssertTrue(source.contains("private func makePassageChooserProgressContext() -> PassageChooserProgressContext"))
        XCTAssertFalse(source.contains("private var passageChooserProgressContext: PassageChooserProgressContext"))
        XCTAssertEqual(contextOccurrences, 2)
        XCTAssertEqual(captureOccurrences, 2)
        XCTAssertTrue(source.contains("passageChooserProgressContext = .empty"))
        XCTAssertFalse(source.contains("passageBookProgress(for: book)"))
        XCTAssertFalse(source.contains("passageChapterProgress(for: book, chapter: chapter)"))
        XCTAssertFalse(source.contains("passageVerseProgress(for: book, chapter: chapter, verse: verse)"))
    }

    #if os(iOS)
    func testWindowingControlPolicyUsesMinimalStyleOnlyOnIPad() {
        XCTAssertTrue(
            AndBibleWindowingControlPolicy.shouldUseMinimalStyle(userInterfaceIdiom: .pad)
        )
        XCTAssertFalse(
            AndBibleWindowingControlPolicy.shouldUseMinimalStyle(userInterfaceIdiom: .phone)
        )
    }

    func testApplicationDelegateSceneConfigurationUsesWindowSceneDelegate() {
        let configuration = AndBibleApplicationDelegate.sceneConfiguration(
            sessionRole: UISceneSession.Role.windowApplication
        )

        XCTAssertEqual(
            ObjectIdentifier(configuration.delegateClass!),
            ObjectIdentifier(AndBibleWindowSceneDelegate.self)
        )
        XCTAssertNil(configuration.name)
    }

    func testWindowingControlPolicyChoosesMinimalStyleOnlyOnIPad() {
        XCTAssertEqual(
            AndBibleWindowingControlPolicy.preferredWindowingControlStyleChoice(userInterfaceIdiom: .pad),
            .minimal
        )
        XCTAssertEqual(
            AndBibleWindowingControlPolicy.preferredWindowingControlStyleChoice(userInterfaceIdiom: .phone),
            .automatic
        )
    }

    func testWindowSceneDelegateSelectorChoiceChoosesMinimalStyleOnlyOnIPad() {
        XCTAssertEqual(
            AndBibleWindowSceneDelegate.preferredWindowingControlStyleSelectorName(userInterfaceIdiom: .pad),
            "minimalStyle"
        )
        XCTAssertEqual(
            AndBibleWindowSceneDelegate.preferredWindowingControlStyleSelectorName(userInterfaceIdiom: .phone),
            "automaticStyle"
        )
    }

    func testContentViewDoesNotContainLegacyRootSidebarShell() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentViewURL = repoRoot.appendingPathComponent("AndBible/ContentView.swift")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: contentViewURL.path),
            "Could not locate AndBible/ContentView.swift at expected path: \(contentViewURL.path). Update this regression test if the project layout changes."
        )

        guard FileManager.default.fileExists(atPath: contentViewURL.path) else {
            return
        }

        let source = try String(contentsOf: contentViewURL, encoding: .utf8)

        let searchTerm = "NavigationSplitView"
        var searchStartIndex = source.startIndex
        var foundLegacyRootSidebarShell = false

        while searchStartIndex < source.endIndex,
              let navigationSplitViewRange = source.range(
                  of: searchTerm,
                  range: searchStartIndex..<source.endIndex
              ) {
            let contextStart = source.index(
                navigationSplitViewRange.lowerBound,
                offsetBy: -1200,
                limitedBy: source.startIndex
            ) ?? source.startIndex
            let contextEnd = source.index(
                navigationSplitViewRange.upperBound,
                offsetBy: 1200,
                limitedBy: source.endIndex
            ) ?? source.endIndex
            let navigationSplitViewContext = String(source[contextStart..<contextEnd])

            if navigationSplitViewContext.contains("contentTabBible")
                && navigationSplitViewContext.contains("contentSettingsLink") {
                foundLegacyRootSidebarShell = true
                break
            }

            searchStartIndex = navigationSplitViewRange.upperBound
        }

        XCTAssertFalse(
            foundLegacyRootSidebarShell,
            "ContentView.swift appears to contain the legacy root sidebar shell pattern: NavigationSplitView with contentTabBible/contentSettingsLink in the same root layout region."
        )
    }

    func testColorARGBByteClampsIntermediatePickerComponents() {
        XCTAssertEqual(Color.clampedARGBByte(-0.25), 0)
        XCTAssertEqual(Color.clampedARGBByte(0.5), 128)
        XCTAssertEqual(Color.clampedARGBByte(1.2), 255)
        XCTAssertEqual(Color.clampedARGBByte(.nan), 0)
        XCTAssertEqual(Color.clampedARGBByte(.infinity), 0)
    }

    func testColorARGBIntClampsOutOfRangeComponents() {
        let color = Color(.sRGB, red: -0.25, green: 0.5, blue: 1.2, opacity: 1.0)
        XCTAssertEqual(color.argbInt, Int(Int32(bitPattern: 0xFF0080FF)))
    }

    func testBibleWebViewMapsDeviceClassFromInterfaceIdiom() {
        XCTAssertEqual(BibleWebView.iosDeviceClass(for: .phone), "ios-phone")
        XCTAssertEqual(BibleWebView.iosDeviceClass(for: .pad), "ios-pad")
    }

    func testBibleWebViewInjectsPlatformDeviceClassIntoUserScript() {
        let expectedDeviceClass = "ios-phone"
        let platformScript = BibleWebView.platformBootstrapScriptSource(deviceClass: expectedDeviceClass)

        XCTAssertTrue(platformScript.contains("window.__PLATFORM__ = 'ios';"))
        XCTAssertTrue(platformScript.contains("window.__IOS_DEVICE_CLASS__ = '\(expectedDeviceClass)';"))
        XCTAssertTrue(platformScript.contains("document.documentElement.classList.add('platform-ios');"))
        XCTAssertTrue(platformScript.contains("document.documentElement.classList.add('\(expectedDeviceClass)');"))
    }
    #endif

}
