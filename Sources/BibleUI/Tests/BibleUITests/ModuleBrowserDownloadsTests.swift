import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import SwordKit

/**
 App-host-free package coverage for Downloads browser presentation and Android filter behavior.

 These tests exercise `ModuleBrowserView` row messages, status projection, language/category
 defaults, auto-refresh decisions, and localized error copy without booting the app. Failures mean
 the Downloads screen can drift from Android behavior even when repository installs still work.
 */
final class ModuleBrowserDownloadsTests: XCTestCase {
    override func tearDown() {
        ModuleBrowserDownloadMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /**
     Verifies module About metadata remains a shared Android-dialog payload rather than a sheet-local
     form.

     Android builds the About dialog from the selected document's real metadata and omits unavailable
     fields. This test covers the iOS payload boundary directly: Downloads and the reader picker both
     consume `ModuleBrowserModuleDetails`, so SWORD About fields, version rows, repository, and OSIS ID
     must be present while iOS-only category/language/install-state rows stay absent.
     */
    func testModuleBrowserModuleDetailsRowsPreserveAvailableRemoteAndInstalledMetadata() {
        let details = ModuleBrowserModuleDetails(
            module: RemoteModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "2.1",
                installSizeBytes: 2_500_000
            ),
            installedModule: ModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                version: "2.0",
                isEncrypted: true,
                isUnlocked: false,
                aboutMetadata: ModuleAboutMetadata(
                    about: "Installed about text",
                    shortCopyright: "Short copyright",
                    history: ["1.0 First release", "2.0 Second release"],
                    versification: "KJVA",
                    osisId: "KJV",
                    repository: "CrossWire",
                    swordVersionDate: "2023-07-19"
                )
            )
        )

        XCTAssertEqual(
            details.androidAboutRows.map(\.kind),
            [
                .about,
                .copyright,
                .latestVersion,
                .installedVersion,
                .versionHistory,
                .versification,
                .osisId,
                .repository
            ]
        )
        XCTAssertEqual(details.androidAboutRows.first { $0.kind == .about }?.value, "Installed about text")
        XCTAssertEqual(details.androidAboutRows.first { $0.kind == .copyright }?.value, "Short copyright")
        XCTAssertEqual(details.androidAboutRows.first { $0.kind == .latestVersion }?.value, "2.1 (-)")
        XCTAssertEqual(details.androidAboutRows.first { $0.kind == .installedVersion }?.value, "2.0 (2023-07-19)")
        XCTAssertEqual(
            details.androidAboutRows.first { $0.kind == .versionHistory }?.value,
            "2.0 Second release\n1.0 First release"
        )
        XCTAssertEqual(details.androidAboutRows.first { $0.kind == .versification }?.value, "KJVA")
        XCTAssertEqual(details.androidAboutRows.first { $0.kind == .osisId }?.value, "KJV")
        XCTAssertEqual(details.androidAboutRows.first { $0.kind == .repository }?.value, "CrossWire")
        XCTAssertNil(details.androidAboutRows.first { $0.kind == .category })
        XCTAssertNil(details.androidAboutRows.first { $0.kind == .language })
        XCTAssertNil(details.androidAboutRows.first { $0.kind == .installSize })
        XCTAssertNil(details.androidAboutRows.first { $0.kind == .installedState })
        XCTAssertNil(details.androidAboutRows.first { $0.kind == .encryptionState })
    }

    /**
     Verifies the rendered About body follows Android's `CommonUtils.showAbout(...)` message shape.

     Android does not render a form/table for About metadata; it builds one message beginning with the
     document name, then appends available metadata sections with blank-line separation and adjacent
     latest/installed version lines. A failure means iOS can have the right fields but still present a
     materially different About dialog.
     */
    func testModuleBrowserModuleDetailsMessageUsesAndroidAboutBodyShape() {
        let details = ModuleBrowserModuleDetails(
            module: RemoteModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "2.1"
            ),
            installedModule: ModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                version: "2.0",
                aboutMetadata: ModuleAboutMetadata(
                    about: "Installed\\par about text",
                    shortPromo: "Short promo",
                    shortCopyright: "Short copyright",
                    distributionLicense: "GPL",
                    unlockInfo: "Request a key",
                    history: ["1.0 First release", "2.0 Second release"],
                    versification: "KJVA",
                    osisId: "KJV",
                    repository: "CrossWire",
                    isBadDocument: true,
                    swordVersionDate: "2023-07-19"
                )
            )
        )

        XCTAssertEqual(
            details.androidAboutMessage,
            """
            King James Version

            Warning: This document might be (at least partially) bad technical quality.

            Installed
             about text

            Short promo

            Copyright: Short copyright

            GPL

            Encrypted module unlock info

            Request a key

            Latest version: 2.1 (-)
            Installed version: 2.0 (2023-07-19)

            Version history:\(" ")
            2.0 Second release
            1.0 First release

            Versification: KJVA

            OSIS ID: KJV

            Distribution server: CrossWire
            """
        )
        XCTAssertEqual(
            details.androidAboutHTMLMessage,
            "<b>King James Version</b><br><br><b>Warning: This document might be (at least partially) bad technical quality.</b><br><br>Installed<br> about text<br><br>Short promo<br><br>Copyright: Short copyright<br><br>GPL<br><br><b>Encrypted module unlock info</b><br><br>Request a key<br><br>Latest version: 2.1 (-)<br>Installed version: 2.0 (2023-07-19)<br><br>Version history: <br>2.0 Second release<br>1.0 First release<br><br>Versification: KJVA<br><br>OSIS ID: KJV<br><br>Distribution server: CrossWire"
        )
    }

    /**
     Verifies long copyright-only metadata keeps Android's paragraph spacing.

     Android's `CommonUtils.showAbout(...)` prefixes long `Copyright` and `DistributionLicense`
     fragments with blank paragraphs when `ShortCopyright` is absent. The iOS message assembly must
     preserve that shape instead of normalizing it into a cleaner iOS-only single-line copyright row.
     A failure means the dialog text can drift even though the same source-backed metadata fields are
     present.
     */
    func testModuleBrowserModuleDetailsMessagePreservesAndroidCopyrightSpacingWithoutShortCopyright() {
        let details = ModuleBrowserModuleDetails(
            module: RemoteModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                sourceName: "CrossWire"
            ),
            installedModule: ModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                aboutMetadata: ModuleAboutMetadata(
                    copyright: "Long copyright",
                    distributionLicense: "GPL"
                )
            )
        )

        XCTAssertEqual(
            details.androidAboutRows.first { $0.kind == .copyright }?.message,
            """
            Copyright:\(" ")

            Long copyright

            GPL
            """
        )
    }

    /**
     Verifies SWORD `History_*` metadata preserves the original config suffix before About rendering.

     JSword projects `History_1.0=value` as `1.0 value`; iOS must avoid lowercasing the raw suffix
     while keeping config lookup case-insensitive. A failure means version-history rows can drift from
     Android for non-numeric suffixes even when the dialog assembly is correct.
     */
    func testModuleBrowserAboutMetadataPreservesHistorySuffixCase() throws {
        let config = try XCTUnwrap(SwordModuleConfig.parse("""
        [TEST]
        Description=Test Bible
        Category=Biblical Texts
        ModDrv=zText
        Lang=en
        History_Beta=Beta release
        History_1.0=First release
        """))

        XCTAssertEqual(config.moduleInfo.aboutMetadata.history, ["Beta Beta release", "1.0 First release"])
    }

    /**
     Verifies unavailable About metadata is omitted instead of rendered as empty iOS-only rows.

     Android's About dialog only includes fields backed by actual `BookMetaData` values. The iOS
     payload must follow the same rule for optional metadata so the dialog stays honest when a
     repository catalog has sparse SWORD fields.
     */
    func testModuleBrowserModuleDetailsRowsOmitUnavailableOptionalMetadata() {
        let details = ModuleBrowserModuleDetails(
            module: RemoteModuleInfo(
                name: "EMPTY",
                description: "   ",
                category: .dictionary,
                language: "",
                sourceName: "   ",
                version: "   ",
                installSizeBytes: nil
            ),
            installedModule: nil
        )

        XCTAssertEqual(
            details.androidAboutRows.map(\.kind),
            [
                .osisId
            ]
        )
        XCTAssertEqual(details.androidAboutRows.first { $0.kind == .osisId }?.value, "EMPTY")
    }

    /**
     Verifies installed document About details do not pass through a fake Downloads catalog row.

     Android reader-picker About uses the installed `BookMetaData` directly and does not invent a
     repository source or latest-version row. The iOS reader picker must therefore build an installed-only
     payload; failures here mean installed modules can show artificial metadata or duplicate version rows.
     */
    func testModuleBrowserModuleDetailsRowsForInstalledDocumentDoNotInventRemoteMetadata() {
        let details = ModuleBrowserModuleDetails(
            installedModule: ModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                version: "2.0",
                isEncrypted: false,
                isUnlocked: true
            )
        )

        XCTAssertEqual(
            details.androidAboutRows.map(\.kind),
            [
                .latestVersion,
                .osisId
            ]
        )
        XCTAssertEqual(details.androidAboutRows.first { $0.kind == .latestVersion }?.value, "2.0 (-)")
        XCTAssertEqual(details.androidAboutRows.first { $0.kind == .osisId }?.value, "KJV")
        XCTAssertNil(details.androidAboutRows.first { $0.kind == .source })
        XCTAssertNil(details.androidAboutRows.first { $0.kind == .installedVersion })
        XCTAssertNil(details.androidAboutRows.first { $0.kind == .category })
        XCTAssertNil(details.androidAboutRows.first { $0.kind == .language })
        XCTAssertNil(details.androidAboutRows.first { $0.kind == .installSize })
        XCTAssertNil(details.androidAboutRows.first { $0.kind == .installedState })
        XCTAssertNil(details.androidAboutRows.first { $0.kind == .encryptionState })
    }

    /**
     Guards Downloads row About against regressing to native iOS sheet chrome.

     Android invokes `CommonUtils.showAbout(...)`, which displays a non-cancelable `AlertDialog`
     message from the row About action. A failure means the Downloads path has drifted back to a
     SwiftUI sheet or stopped using the shared dialog presenter.
     */
    func testModuleBrowserAboutUsesSharedAndroidDialogInsteadOfSheet() throws {
        let downloadsSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift"
        )
        let detailsSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserRowActionPresentation.swift"
        )

        XCTAssertTrue(downloadsSource.contains(".moduleBrowserModuleDetailsDialog("))
        XCTAssertFalse(downloadsSource.contains(".sheet(item: $selectedModuleDetails)"))
        XCTAssertTrue(detailsSource.contains("struct ModuleBrowserModuleDetailsDialog: View"))
        XCTAssertTrue(detailsSource.contains("AndroidDialogSurfacePalette"))
        XCTAssertTrue(detailsSource.contains("moduleDetailsDialogScreen"))
        XCTAssertTrue(detailsSource.contains("moduleDetailsOKButton"))
        XCTAssertTrue(detailsSource.contains(".accessibilityAddTraits(.isModal)"))
        XCTAssertTrue(detailsSource.contains("Text(details.androidAboutAttributedMessage)"))
        XCTAssertTrue(detailsSource.contains("NSAttributedString.DocumentType.html"))
        XCTAssertTrue(detailsSource.contains(".onTapGesture {}"))
        XCTAssertFalse(detailsSource.contains("ForEach(details.androidAboutRows)"))
        XCTAssertFalse(detailsSource.contains("private func detailRow("))
        XCTAssertFalse(detailsSource.contains("@Environment(\\.dismiss) private var dismiss"))
        XCTAssertFalse(detailsSource.contains("Form {"))
        XCTAssertFalse(detailsSource.contains(".navigationTitle(String(localized: \"about\"))"))
    }

    /**
     Verifies destructive Downloads row confirmations use module descriptions instead of initials.

     Android confirms removal/index deletion with the visible document name. The iOS row model must
     use the friendly description so uninstall and delete-index prompts do not regress to terse module
     codes when a catalog row includes richer metadata.
     */
    func testModuleBrowserRowActionConfirmationUsesFriendlyModuleDescription() {
        let module = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            sourceName: "CrossWire"
        )

        let uninstall = ModuleBrowserRowActionConfirmation(kind: .uninstall, module: module)
        let deleteIndex = ModuleBrowserRowActionConfirmation(kind: .deleteIndex, module: module)

        XCTAssertEqual(uninstall.message, "Remove King James Version from this device?")
        XCTAssertEqual(deleteIndex.message, "Delete the search index for King James Version?")
    }

    /**
     Verifies Downloads status-slot icons preserve Android's NOT_INSTALLED versus UPGRADE_AVAILABLE
     distinction.

     Android `DocumentListItem.updateControlState` clears the status icon for
     `DocumentInstallStatus.NOT_INSTALLED` and only shows `ic_arrow_upward_amber_24dp` for
     `UPGRADE_AVAILABLE`. A failure means iOS is visually reporting ordinary installable modules as
     updates even though row taps should still install them.
     */
    func testModuleBrowserStatusSlotPresentationKeepsInstallableDistinctFromUpdate() {
        XCTAssertEqual(
            ModuleBrowserStatusSlotPresentation(status: .installable).statusIconSystemName,
            nil
        )
        XCTAssertFalse(ModuleBrowserStatusSlotPresentation(status: .installable).isActionControl)
        XCTAssertEqual(
            ModuleBrowserStatusSlotPresentation(status: .updateAvailable).statusIconSystemName,
            "arrow.up.circle.fill"
        )
        XCTAssertTrue(ModuleBrowserStatusSlotPresentation(status: .updateAvailable).isActionControl)
    }

    /**
     Verifies active and failed Downloads activity drives Android-style status ordering on rebuild.

     Android promotes active installs and update rows when `filterDocuments()` recomputes the list,
     while preserving visible failure state. iOS must keep in-progress percentages and failure
     messages tied to row status instead of flattening those rows into ordinary installable
     documents.
     */
    func testModuleBrowserDownloadActivityDrivesAndroidProgressAndErrorStatus() {
        let modules = [
            RemoteModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
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
                description: "Active warning module",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
            ),
            RemoteModuleInfo(
                name: "FAIL",
                description: "Failed module",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
            )
        ]
        let installed = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en", version: "1.0"),
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en", version: "1.0")
        ]
        let recommended = ModuleDownloadConfiguration(
            bibles: ["en": ["REC::CrossWire"]]
        )
        let activities: [String: ModuleBrowserDownloadActivity] = [
            "WARN": .inProgress(0.37),
            "FAIL": .failed("testdict.idx download failed (HTTP 500)")
        ]

        let filtered = ModuleBrowserView.filteredDownloadModules(
            modules,
            selectedCategory: nil,
            selectedLanguage: "en",
            searchText: "",
            installedModules: installed,
            downloadActivities: activities,
            recommendedDocuments: recommended,
            badDocuments: nil
        )

        XCTAssertEqual(filtered.map(\.name), ["WARN", "WEB", "KJV", "REC", "FAIL"])
        XCTAssertEqual(
            ModuleBrowserView.displayStatus(
                for: modules[3],
                installedModules: installed,
                downloadActivities: activities
            ),
            .beingInstalled(progressPercent: 37)
        )
        XCTAssertEqual(
            ModuleBrowserView.displayStatus(
                for: modules[4],
                installedModules: installed,
                downloadActivities: activities
            ),
            .errorDownloading(message: "testdict.idx download failed (HTTP 500)")
        )
    }

    /**
     Verifies Downloads update confirmation warns when installed generic bookmarks exist.

     Android checks installed documents for generic bookmarks before `doDownload(...)` and routes
     those rows through `documentUpgradeConfirmation`, including failed update retries. A failure
     means iOS can overwrite a module with dictionary/book notes without Android's data-safety
     warning.
     */
    func testModuleBrowserWarnsBeforeUpdatingInstalledGenericBookmarkDocument() {
        XCTAssertTrue(
            ModuleBrowserView.shouldShowGenericBookmarkUpdateWarning(
                status: .updateAvailable,
                isInstalled: true,
                hasGenericBookmarks: true
            )
        )
        XCTAssertTrue(
            ModuleBrowserView.shouldShowGenericBookmarkUpdateWarning(
                status: .errorDownloading(message: "Previous update failed"),
                isInstalled: true,
                hasGenericBookmarks: true
            )
        )
        XCTAssertFalse(
            ModuleBrowserView.shouldShowGenericBookmarkUpdateWarning(
                status: .installable,
                isInstalled: false,
                hasGenericBookmarks: true
            )
        )
        XCTAssertFalse(
            ModuleBrowserView.shouldShowGenericBookmarkUpdateWarning(
                status: .updateAvailable,
                isInstalled: true,
                hasGenericBookmarks: false
            )
        )
        XCTAssertFalse(
            ModuleBrowserView.shouldShowGenericBookmarkUpdateWarning(
                status: .beingInstalled(progressPercent: 10),
                isInstalled: true,
                hasGenericBookmarks: true
            )
        )
    }

    /**
     Verifies the Downloads update-warning lookup matches Android's document-initials count.

     Android queries `GenericBookmarkWithNotes` by `bookInitials`, but that view left-joins note
     payloads, so bookmarks without notes still trigger the installed-document warning. This seeds
     in-memory SwiftData generic bookmarks directly and proves iOS does not accidentally require a
     note row or match a neighboring document.
     */
    func testModuleBrowserGenericBookmarkLookupMatchesDocumentInitials() throws {
        let container = try makeBookmarkListModelContainer()
        let context = ModelContext(container)
        context.insert(GenericBookmark(key: "entry-one", bookInitials: "DICT"))
        context.insert(GenericBookmark(key: "entry-two", bookInitials: "OTHER"))
        try context.save()

        XCTAssertTrue(ModuleBrowserView.hasGenericBookmarks(for: "DICT", in: context))
        XCTAssertFalse(ModuleBrowserView.hasGenericBookmarks(for: "KJV", in: context))
    }

    /**
     Verifies Downloads row activity updates do not recompute visible row order.

     Android `DownloadActivity.doDownload` enqueues the document and calls `notifyDataSetChanged()`;
     it does not rerun `DocumentSelectionBase.filterDocuments()`. That means the tapped row updates
     progress in place, while a later explicit filter rebuild can still apply Android's
     active-download-first sort. iOS must keep the same split so live progress state does not make
     the selected row disappear from the current scroll position.
     */
    func testModuleBrowserKeepsDownloadRowOrderStableUntilFilterRebuild() {
        let modules = [
            RemoteModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
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
                description: "Active warning module",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
            )
        ]
        let installed = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en", version: "1.0"),
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en", version: "1.0")
        ]
        let recommended = ModuleDownloadConfiguration(
            bibles: ["en": ["REC::CrossWire"]]
        )

        let initialSortSnapshot = ModuleBrowserView.downloadListSortSnapshot(
            installedModules: installed,
            downloadActivities: [:]
        )
        let visibleBeforeInstall = ModuleBrowserView.filteredDownloadModules(
            modules,
            selectedCategory: nil,
            selectedLanguage: "en",
            searchText: "",
            installedModules: initialSortSnapshot.installedModules,
            downloadActivities: initialSortSnapshot.downloadActivities,
            recommendedDocuments: recommended,
            badDocuments: nil
        )

        let liveActivities: [String: ModuleBrowserDownloadActivity] = [
            "WARN": .inProgress(0.25)
        ]
        let visibleAfterRowActivity = ModuleBrowserView.filteredDownloadModules(
            modules,
            selectedCategory: nil,
            selectedLanguage: "en",
            searchText: "",
            installedModules: initialSortSnapshot.installedModules,
            downloadActivities: initialSortSnapshot.downloadActivities,
            recommendedDocuments: recommended,
            badDocuments: nil
        )

        XCTAssertEqual(visibleBeforeInstall.map(\.name), ["WEB", "KJV", "REC", "WARN"])
        XCTAssertEqual(visibleAfterRowActivity.map(\.name), ["WEB", "KJV", "REC", "WARN"])
        XCTAssertEqual(
            ModuleBrowserView.displayStatus(
                for: modules[3],
                installedModules: installed,
                downloadActivities: liveActivities
            ),
            .beingInstalled(progressPercent: 25)
        )

        let rebuiltSortSnapshot = ModuleBrowserView.downloadListSortSnapshot(
            installedModules: installed,
            downloadActivities: liveActivities
        )
        let visibleAfterFilterRebuild = ModuleBrowserView.filteredDownloadModules(
            modules,
            selectedCategory: nil,
            selectedLanguage: "en",
            searchText: "",
            installedModules: rebuiltSortSnapshot.installedModules,
            downloadActivities: rebuiltSortSnapshot.downloadActivities,
            recommendedDocuments: recommended,
            badDocuments: nil
        )

        XCTAssertEqual(visibleAfterFilterRebuild.map(\.name), ["WARN", "WEB", "KJV", "REC"])
    }

    /**
     Verifies Downloads filtering and sort order match Android's document browser rules.

     Android keeps active warnings first after a filter rebuild, then updates, installed rows,
     recommended rows, copyright placeholder rows, and finally other matching documents while hiding
     hard-hidden bad documents. iOS must keep that same ordering contract across Bible rows, add-ons,
     pseudo rows, version comparisons, and install-size formatting without app-host state.
     */
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

    /**
     Verifies failed source refreshes keep Android-visible cached rows for those sources only.

     Android restores usable cached catalog rows when a repository refresh fails, but it does not
     reintroduce rows from unrelated sources or duplicate rows already refreshed successfully. A
     failure here means Downloads can either hide still-installable cached documents or leak stale
     rows from sources that refreshed cleanly.
     */
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

    /**
     Verifies startup default downloads only run after a catalog contains installable rows.

     Android avoids starting the default-document flow when the startup catalog is empty or only
     contains copyright placeholder rows. iOS must preserve that guard so unavailable pseudo modules
     do not satisfy the startup-download precondition.
     */
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

    /**
     Verifies Downloads only auto-refreshes missing or stale repository catalogs.

     Android loads cached metadata first and refreshes when a source has no usable cache or the cache
     is stale. The iOS predicate must avoid refresh loops for empty source lists or fresh caches.
     */
    func testModuleBrowserAutoRefreshesOnlyMissingOrStaleCatalogs() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "TestRepo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw"
        )
        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        XCTAssertFalse(
            ModuleBrowserView.shouldAutoRefreshCatalogs(sources: [], repository: repository),
            "Downloads should not start a refresh loop when no repository sources are configured."
        )
        XCTAssertTrue(
            ModuleBrowserView.shouldAutoRefreshCatalogs(sources: [source], repository: repository),
            "Missing source cache should refresh after the sheet opens, matching Android's first-load behavior."
        )

        try writeModuleRepositoryCatalogCache(sourceName: source.name, timestamp: Date(), under: tempDir)
        XCTAssertFalse(
            ModuleBrowserView.shouldAutoRefreshCatalogs(sources: [source], repository: repository),
            "Recent source cache should open from cache without immediately refreshing."
        )

        try writeModuleRepositoryCatalogCache(
            sourceName: source.name,
            timestamp: Date(timeIntervalSinceNow: -(ModuleBrowserView.downloadCatalogStaleInterval + 1)),
            under: tempDir
        )
        XCTAssertTrue(
            ModuleBrowserView.shouldAutoRefreshCatalogs(sources: [source], repository: repository),
            "Stale source cache should refresh after the cached list has been restored."
        )
    }

    /**
     Verifies normal Downloads opens with Android's default document-type filter.

     Android persists the selected document filter and uses index 0 (`All types`) for a fresh
     Downloads browser. iOS previously defaulted to Bibles, hiding commentaries, dictionaries, books,
     and maps until the user changed filters.
     */
    func testModuleBrowserInitialCategoryDefaultsToAndroidAllTypes() {
        XCTAssertNil(
            ModuleBrowserView.initialSelectedCategory(
                initialSearchText: "",
                defaultDownloadMode: .disabled
            )
        )
        XCTAssertNil(
            ModuleBrowserView.initialSelectedCategory(
                initialSearchText: "KJV",
                defaultDownloadMode: .disabled
            )
        )
        XCTAssertNil(
            ModuleBrowserView.initialSelectedCategory(
                initialSearchText: "",
                defaultDownloadMode: .englishStartup
            )
        )
        XCTAssertEqual(
            ModuleBrowserView.initialSelectedCategory(
                initialSearchText: "",
                defaultDownloadMode: .disabled,
                storedFilterIndex: 2
            ),
            .commentary
        )
        XCTAssertNil(
            ModuleBrowserView.initialSelectedCategory(
                initialSearchText: "KJV",
                defaultDownloadMode: .disabled,
                storedFilterIndex: 2
            )
        )
        XCTAssertNil(
            ModuleBrowserView.initialSelectedCategory(
                initialSearchText: "",
                defaultDownloadMode: .englishStartup,
                storedFilterIndex: 2
            )
        )
        XCTAssertEqual(ModuleBrowserView.androidFilterIndex(for: .commentary), 2)
        XCTAssertEqual(ModuleBrowserView.category(forAndroidFilterIndex: 6), .addon)
        XCTAssertNil(ModuleBrowserView.category(forAndroidFilterIndex: 99))
    }

    /**
     Verifies default-download mode selects the expected repository package policy.

     Normal Downloads must follow Android's package-first installer while retaining iOS raw-file
     fallback for legacy repositories. Startup Easy Start defaults require package ZIPs so a missing
     default Bible cannot publish a partial raw install.
     */
    func testModuleBrowserDefaultDownloadModeSelectsPackageInstallPolicy() {
        XCTAssertEqual(
            ModuleBrowserDefaultDownloadMode.disabled.modulePackageInstallPolicy,
            .preferPackageThenRaw
        )
        XCTAssertEqual(
            ModuleBrowserDefaultDownloadMode.englishStartup.modulePackageInstallPolicy,
            .requirePackage
        )
    }

    /**
     Verifies Downloads default language selection follows Android's priority order.

     Android `DocumentSelectionBase.defaultLanguage` first reuses a valid sticky language, then the
     device language when that language has Bible rows, then an installed Bible language, then English
     or the first available language. iOS should not preserve its own all-language default when Android
     would select a concrete language.
     */
    func testModuleBrowserDefaultLanguageMatchesAndroidPriority() {
        let englishBible = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            sourceName: "CrossWire"
        )
        let frenchBible = RemoteModuleInfo(
            name: "LSG",
            description: "Louis Segond",
            category: .bible,
            language: "fr",
            sourceName: "CrossWire"
        )
        let germanCommentary = RemoteModuleInfo(
            name: "GERCOM",
            description: "German Commentary",
            category: .commentary,
            language: "de",
            sourceName: "CrossWire"
        )

        XCTAssertEqual(
            ModuleBrowserView.defaultLanguageCode(
                availableModules: [englishBible, frenchBible],
                installedModules: [],
                availableLanguages: ["en", "fr"],
                localeLanguageCode: "en",
                stickyLanguageCode: "fr"
            ),
            "fr"
        )
        XCTAssertEqual(
            ModuleBrowserView.defaultLanguageCode(
                availableModules: [englishBible, frenchBible],
                installedModules: [],
                availableLanguages: ["en", "fr"],
                localeLanguageCode: "fr",
                stickyLanguageCode: nil
            ),
            "fr"
        )
        XCTAssertEqual(
            ModuleBrowserView.defaultLanguageCode(
                availableModules: [germanCommentary],
                installedModules: [
                    ModuleInfo(
                        name: "GER",
                        description: "German Bible",
                        category: .bible,
                        language: "de"
                    )
                ],
                availableLanguages: ["de", "fr"],
                localeLanguageCode: "fr",
                stickyLanguageCode: nil
            ),
            "de"
        )
        XCTAssertEqual(
            ModuleBrowserView.defaultLanguageCode(
                availableModules: [germanCommentary],
                installedModules: [],
                availableLanguages: ["de", "en"],
                localeLanguageCode: "fr",
                stickyLanguageCode: nil
            ),
            "en"
        )
        XCTAssertEqual(
            ModuleBrowserView.defaultLanguageCode(
                availableModules: [germanCommentary],
                installedModules: [],
                availableLanguages: ["de"],
                localeLanguageCode: "fr",
                stickyLanguageCode: nil
            ),
            "de"
        )
    }

    /**
     Verifies Android sticky-language state only records explicit user language choices.

     Android stores `DocumentSelectionBase.lastSelectedLanguage` from the language item-click handler.
     Its default-language routine updates the spinner text but does not make the computed default
     sticky. iOS must preserve that distinction so a device/default language does not override future
     default-language resolution as if the user had selected it.
     */
    func testModuleBrowserStickyLanguageRecordsOnlyExplicitSelection() {
        ModuleBrowserView.resetExplicitSelectedLanguageForTesting()
        defer { ModuleBrowserView.resetExplicitSelectedLanguageForTesting() }

        _ = ModuleBrowserView.defaultLanguageCode(
            availableModules: [
                RemoteModuleInfo(
                    name: "GER",
                    description: "German Bible",
                    category: .bible,
                    language: "de",
                    sourceName: "CrossWire"
                )
            ],
            installedModules: [],
            availableLanguages: ["de"],
            localeLanguageCode: "de",
            stickyLanguageCode: ModuleBrowserView.explicitSelectedLanguageForTesting()
        )

        XCTAssertNil(ModuleBrowserView.explicitSelectedLanguageForTesting())

        ModuleBrowserView.rememberExplicitSelectedLanguage("")
        XCTAssertNil(ModuleBrowserView.explicitSelectedLanguageForTesting())

        ModuleBrowserView.rememberExplicitSelectedLanguage("fr")
        XCTAssertEqual(ModuleBrowserView.explicitSelectedLanguageForTesting(), "fr")
    }

    /**
     Verifies iOS picker cancellation is ignored like Android's Install ZIP cancel path.

     Android returns from the Install ZIP activity without showing a download error when the user
     backs out. SwiftUI reports the same user action as a file-importer failure, so iOS must classify
     the Cocoa cancellation code separately from real importer failures.
     */
    func testModuleBrowserInstallZipCancellationMatchesAndroidNoErrorBehavior() {
        XCTAssertTrue(
            ModuleBrowserView.isFileImporterCancellation(
                NSError(domain: NSCocoaErrorDomain, code: CocoaError.userCancelled.rawValue)
            )
        )
        XCTAssertFalse(
            ModuleBrowserView.isFileImporterCancellation(
                NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue)
            )
        )
        XCTAssertFalse(
            ModuleBrowserView.isFileImporterCancellation(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            )
        )
    }

    /**
     Verifies refresh errors do not erase prior install/import errors.

     Android tracks document install errors and metadata/repository errors independently. The
     Downloads overflow should keep earlier install failures visible after a later catalog refresh
     while still de-duplicating repeated repository errors.
     */
    func testModuleBrowserDownloadErrorsMergeRefreshFailures() {
        XCTAssertEqual(
            ModuleBrowserView.mergedDownloadErrors(
                existing: [" Install failed ", "Metadata failed"],
                refreshErrors: ["Repo failed", "", "Install failed", " Repo failed "]
            ),
            ["Install failed", "Metadata failed", "Repo failed"]
        )
    }

    /**
     Verifies install failures reuse the localized download-failure prefix.

     Android surfaces install failures through the same Download errors affordance as repository
     failures. iOS should keep that shared error contract and avoid introducing hard-coded English
     prefixes inside the overflow dialog.
     */
    func testModuleBrowserDownloadFailureMessageUsesLocalizedPrefix() {
        let prefix = String(localized: "error_download_failed", defaultValue: "Download failed")

        XCTAssertEqual(
            ModuleBrowserView.downloadFailureMessage("Network unavailable"),
            "\(prefix): Network unavailable"
        )
        XCTAssertEqual(
            ModuleBrowserView.downloadFailureMessage(moduleName: "KJV", message: "Network unavailable"),
            "\(prefix): KJV: Network unavailable"
        )
    }

    /**
     Verifies Downloads failure fallbacks use stable localization keys.

     Android routes repository, install, and uninstall failures through user-visible Downloads
     surfaces. iOS should keep the same behavior without hard-coded English fallback messages.
     */
    func testModuleBrowserFailureFallbackMessagesUseLocalization() {
        XCTAssertEqual(
            ModuleBrowserView.noRepositorySourcesConfiguredMessage(),
            String(localized: "no_sources_configured", defaultValue: "No repository sources configured.")
        )
        XCTAssertEqual(
            ModuleBrowserView.moduleUnavailableForInstallationMessage(moduleName: "KJV"),
            String(localized: "module_unavailable_for_installation \("KJV")")
        )
        XCTAssertEqual(
            ModuleBrowserView.moduleSourceNotFoundMessage(moduleName: "KJV"),
            String(localized: "module_source_not_found \("KJV")")
        )
        XCTAssertEqual(
            ModuleBrowserView.uninstallFailureMessage("Disk locked"),
            String(localized: "uninstall_failed \("Disk locked")")
        )
    }

    private func makeModuleRepositoryDownloadMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleBrowserDownloadMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func writeModuleRepositoryCatalogCache(sourceName: String, timestamp: Date, under baseDir: URL) throws {
        let cacheDir = baseDir.appendingPathComponent("catalog-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let json = """
        {
          "timestamp": \(timestamp.timeIntervalSinceReferenceDate),
          "modules": []
        }
        """
        try Data(json.utf8).write(to: cacheDir.appendingPathComponent("\(sourceName).json"))
    }

}

/**
 URL protocol test double for Downloads browser catalog-refresh predicates.

 Tests install a request handler before creating a `URLSession`, allowing repository cache checks
 to run without network I/O while still constructing a real `ModuleRepository`.
 */
private final class ModuleBrowserDownloadMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("ModuleBrowserDownloadMockURLProtocol.requestHandler must be set before use")
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
