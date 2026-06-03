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
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

extension AndBibleTests {
    func testAppPreferenceRegistryHasDefinitionForAllKeys() {
        let keys = AppPreferenceKey.allCases
        XCTAssertEqual(keys.count, 36)
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
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .openLinksInSpecialWindowPref), true)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .enableBluetoothPref), true)
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

    func testBibleReaderActiveSheetContentBuildsDownloadsSheet() {
        let view = BibleReaderActiveSheetContent(
            sheet: .downloads,
            controller: nil,
            readingProgressInitialTab: .reading,
            chapterReadHistoryTarget: nil,
            downloadsInitialSearchText: "",
            onDismiss: {}
        )

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderActiveSheetContent"))
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

    func testCatalogModuleConvertsSwordInstallSizeKilobytes() {
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
            size: "1260"
        )

        XCTAssertEqual(module.remoteModuleInfo.installSizeBytes, 1_290_240)
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
