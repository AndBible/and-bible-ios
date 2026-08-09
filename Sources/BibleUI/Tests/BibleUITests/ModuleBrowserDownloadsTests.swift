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
     Verifies Downloads exposes Android's Unlock action for an installed encrypted row.

     - Setup: Supplies the row planner with locked installed metadata and no active install.
     - Expected result: Unlock appears after Android's About, Delete, and Delete Index actions.
     - Failure meaning: Downloads has diverged from the reader picker or suppressed Android's cipher
       flow again.
     - Side effects: None.
     */
    func testDownloadsRowsExposeUnlockForEncryptedInstalledModules() {
        let lockedModule = ModuleInfo(
            name: "LOCKED",
            description: "Locked Bible",
            category: .bible,
            language: "en",
            moduleDriver: "RawText",
            isEncrypted: true,
            isUnlocked: false
        )
        let secondBible = ModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en"
        )

        XCTAssertEqual(
            ModuleBrowserView.rowActions(
                installedModule: lockedModule,
                isBeingInstalled: false,
                installedModules: [lockedModule, secondBible]
            ),
            [.about, .uninstall, .deleteIndex, .unlock]
        )
    }

    /**
     Verifies Downloads does not offer removal for the final installed Bible.

     - Setup: Supplies the Downloads row planner with one installed Bible as both the row and the
       complete Android-compatible inventory.
     - Expected result: About and Delete Index remain available while Uninstall is absent.
     - Failure meaning: The Downloads row can invite an operation that Android and the repository
       service reject in order to preserve a readable Bible.
     - Side effects: None.
     */
    func testDownloadsRowsHideUninstallForFinalInstalledBible() {
        let onlyBible = ModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en"
        )

        XCTAssertEqual(
            ModuleBrowserView.rowActions(
                installedModule: onlyBible,
                isBeingInstalled: false,
                installedModules: [onlyBible]
            ),
            [.about, .deleteIndex]
        )
    }

    /**
     Verifies Downloads wires Unlock through the shared manager-backed submission contract.

     - Setup: Extracts the production Downloads submission function.
     - Expected result: It delegates key validation to `SwordManager`, refreshes installed rows only
       from accepted work, and re-presents the module with shared invalid-key feedback on rejection.
     - Failure meaning: Downloads can diverge from the reader picker by bypassing key verification,
       omitting its successful refresh, or silently swallowing an invalid passphrase.
     - Side effects: Reads production source through the test source locator.
     */
    func testDownloadsUnlockUsesSharedManagerRefreshAndRetryContract() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift"
        )
        let unlockSource = try BibleUITestSourceLocator.extractFunction(
            named: "attemptUnlock",
            from: source
        )

        XCTAssertTrue(unlockSource.contains("ModuleUnlockActionCoordinator.submit"))
        XCTAssertTrue(unlockSource.contains("swordManager?.unlockModule"))
        XCTAssertTrue(unlockSource.contains("refreshInstalledList()"))
        XCTAssertTrue(unlockSource.contains("ModuleUnlockActionCoordinator.failureMessage"))
        XCTAssertTrue(unlockSource.contains("pendingUnlockModule = module"))
        XCTAssertFalse(unlockSource.contains("setCipherKey"))
    }

    /**
     Verifies same-initials rows retain independent Android repository identities and row state.

     Setup:
     - creates two `KJV` rows from different repositories
     - assigns active extraction to one and a retained error to the other
     - marks only the first repository as the installed origin

     Expected result:
     - de-duplication preserves both rows
     - each row resolves only its repository-scoped activity
     - an installed origin does not make the other repository row appear installed

     Failure meaning:
     - starting, cancelling, retrying, or displaying one repository's module can mutate the other,
       recreating Android parity finding 2.1.
     */
    func testModuleBrowserKeepsSameInitialsRepositoriesIndependent() {
        let crossWire = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            sourceName: "CrossWire",
            version: "2.0"
        )
        let mirror = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version mirror",
            category: .bible,
            language: "en",
            sourceName: "Mirror",
            version: "2.0"
        )
        let activities: [RemoteModuleIdentity: ModuleBrowserDownloadActivity] = [
            crossWire.installIdentity: .inProgress(ModuleInstallProgress(phase: .extracting)),
            mirror.installIdentity: .failed("mirror unavailable"),
        ]
        let installed = ModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            version: "2.0",
            aboutMetadata: ModuleAboutMetadata(repository: "CrossWire")
        )

        let rows = ModuleBrowserView.deduplicatedModules(from: [crossWire, mirror, crossWire])

        XCTAssertEqual(rows.map(\.installIdentity), [crossWire.installIdentity, mirror.installIdentity])
        XCTAssertEqual(crossWire.installIdentity.rawValue, "CrossWire--KJV")
        XCTAssertEqual(
            ModuleBrowserView.displayStatus(
                for: crossWire,
                installedModules: [installed],
                downloadActivities: activities
            ),
            .beingInstalled(progress: ModuleInstallProgress(phase: .extracting))
        )
        XCTAssertEqual(
            ModuleBrowserView.displayStatus(
                for: mirror,
                installedModules: [installed],
                downloadActivities: activities
            ),
            .errorDownloading(message: "mirror unavailable")
        )
        XCTAssertEqual(
            ModuleBrowserView.displayStatus(
                for: mirror,
                installedModules: [installed],
                downloadActivities: [:]
            ),
            .installable
        )
        XCTAssertTrue(
            ModuleBrowserView.isModuleInstalledFromSelectedRepository(
                crossWire,
                installedModules: [installed]
            )
        )
        XCTAssertFalse(
            ModuleBrowserView.isModuleInstalledFromSelectedRepository(
                mirror,
                installedModules: [installed]
            )
        )
    }

    /**
     Verifies Easy Start storage estimation sums only valid catalog byte counts and fails closed on
     overflow.

     Failure means the startup flow can skip Android's low-space gate when all sizes are unknown or
     underestimate a multi-module batch before downloads begin.
     */
    func testModuleBrowserCombinesKnownEasyStartInstallSizes() {
        let known = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            sourceName: "CrossWire",
            installSizeBytes: 12_000
        )
        let second = RemoteModuleInfo(
            name: "NASB",
            description: "New American Standard Bible",
            category: .bible,
            language: "en",
            sourceName: "Lockman",
            installSizeBytes: 8_000
        )
        let unknown = RemoteModuleInfo(
            name: "WEB",
            description: "World English Bible",
            category: .bible,
            language: "en",
            sourceName: "CrossWire"
        )

        XCTAssertEqual(
            ModuleBrowserView.combinedInstallSizeBytes(for: [known, unknown, second]),
            20_000
        )
        XCTAssertNil(ModuleBrowserView.combinedInstallSizeBytes(for: [unknown]))
        let maximum = RemoteModuleInfo(
            name: "MAX",
            description: "Maximum",
            category: .bible,
            language: "en",
            sourceName: "Test",
            installSizeBytes: Int64.max
        )
        let oneMore = RemoteModuleInfo(
            name: "ONE",
            description: "One more",
            category: .bible,
            language: "en",
            sourceName: "Test",
            installSizeBytes: 1
        )
        XCTAssertEqual(
            ModuleBrowserView.combinedInstallSizeBytes(for: [maximum, oneMore]),
            Int64.max
        )
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
     message from the row About action. The feature must wire its payload through the shared dialog
     window/scaffold/action family, which owns the palette, scrim, and modal accessibility behavior.
     A failure means the Downloads path has drifted back to a SwiftUI sheet or bypassed shared UI.
     */
    func testModuleBrowserAboutUsesSharedAndroidDialogInsteadOfSheet() throws {
        let downloadsSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift"
        )
        let detailsSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserRowActionPresentation.swift"
        )
        let dialogWindowSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Shared/AndroidDialogWindow.swift"
        )
        let dialogScaffoldSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Shared/AndroidDialogScaffold.swift"
        )

        XCTAssertTrue(downloadsSource.contains(".moduleBrowserModuleDetailsDialog("))
        XCTAssertFalse(downloadsSource.contains(".sheet(item: $selectedModuleDetails)"))
        XCTAssertTrue(detailsSource.contains("struct ModuleBrowserModuleDetailsDialog: View"))
        XCTAssertTrue(detailsSource.contains("AndroidDialogWindow("))
        XCTAssertTrue(detailsSource.contains("AndroidDialogScaffold(title:"))
        XCTAssertTrue(detailsSource.contains("AndroidDialogTextAction("))
        XCTAssertTrue(detailsSource.contains("moduleDetailsDialogScreen"))
        XCTAssertTrue(detailsSource.contains("moduleDetailsOKButton"))
        XCTAssertTrue(detailsSource.contains("Text(details.androidAboutAttributedMessage)"))
        XCTAssertTrue(detailsSource.contains("NSAttributedString.DocumentType.html"))
        XCTAssertTrue(dialogWindowSource.contains("AndroidDialogSurfacePalette.background(for: colorScheme)"))
        XCTAssertTrue(dialogWindowSource.contains("guard allowsOutsideDismissal else { return }"))
        XCTAssertTrue(dialogScaffoldSource.contains(".accessibilityAddTraits(.isModal)"))
        XCTAssertFalse(detailsSource.contains("ForEach(details.androidAboutRows)"))
        XCTAssertFalse(detailsSource.contains("private func detailRow("))
        XCTAssertFalse(detailsSource.contains("@Environment(\\.dismiss) private var dismiss"))
        XCTAssertFalse(detailsSource.contains("Form {"))
        XCTAssertFalse(detailsSource.contains(".navigationTitle(String(localized: \"about\"))"))
    }

    /**
     Verifies destructive Downloads row confirmations match Android's exact message/button contract.

     Android formats `delete_doc` and `delete_search_index_doc` with `Book.name` (module initials),
     uses message-only dialogs, and pairs Yes/No with document deletion and OK/Cancel with index
     deletion. A failure means iOS has reintroduced invented copy or platform-specific actions.
     */
    func testModuleBrowserRowActionConfirmationMatchesAndroidMessageAndButtons() {
        let module = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            sourceName: "CrossWire"
        )

        let uninstall = ModuleBrowserRowActionConfirmation(kind: .uninstall, module: module)
        let deleteIndex = ModuleBrowserRowActionConfirmation(kind: .deleteIndex, module: module)

        XCTAssertEqual(uninstall.title, "")
        XCTAssertEqual(uninstall.message, "Delete KJV?")
        XCTAssertEqual(uninstall.confirmButtonTitle, "Yes")
        XCTAssertEqual(uninstall.cancelButtonTitle, "No")
        XCTAssertEqual(deleteIndex.title, "")
        XCTAssertEqual(deleteIndex.message, "Delete index of KJV?")
        XCTAssertEqual(deleteIndex.confirmButtonTitle, "OK")
        XCTAssertEqual(deleteIndex.cancelButtonTitle, "Cancel")
    }

    /**
     Verifies Downloads status-slot icons preserve Android's NOT_INSTALLED versus UPGRADE_AVAILABLE
     distinction.

     Android `DocumentListItem.updateControlState` clears the status icon for
     `DocumentInstallStatus.NOT_INSTALLED` and only shows `ic_arrow_upward_amber_24dp` for
     `UPGRADE_AVAILABLE`. A failure means iOS is visually reporting ordinary installable modules as
     updates even though row taps should still install them.
     */
    func testModuleBrowserStatusSlotPresentationUsesExactAndroidAssetsAndRowTapOwnership() {
        XCTAssertEqual(
            ModuleBrowserStatusSlotPresentation(status: .installable).statusIconAssetName,
            nil
        )
        XCTAssertFalse(ModuleBrowserStatusSlotPresentation(status: .installable).isActionControl)
        XCTAssertEqual(
            ModuleBrowserStatusSlotPresentation(status: .updateAvailable).statusIconAssetName,
            "DocumentUpdateStatus"
        )
        XCTAssertFalse(ModuleBrowserStatusSlotPresentation(status: .updateAvailable).isActionControl)
        XCTAssertEqual(
            ModuleBrowserStatusSlotPresentation(
                status: .errorDownloading(message: "Network")
            ).statusIconAssetName,
            "DocumentErrorStatus"
        )
        XCTAssertFalse(
            ModuleBrowserStatusSlotPresentation(
                status: .errorDownloading(message: "Network")
            ).isActionControl
        )
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
        let activities: [RemoteModuleIdentity: ModuleBrowserDownloadActivity] = [
            modules[3].installIdentity: .inProgress(0.37),
            modules[4].installIdentity: .failed("testdict.idx download failed (HTTP 500)")
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
            .beingInstalled(progress: ModuleInstallProgress(phase: .downloading, fraction: 0.37))
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
                status: .beingInstalled(
                    progress: ModuleInstallProgress(phase: .downloading, fraction: 0.10)
                ),
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

        let liveActivities: [RemoteModuleIdentity: ModuleBrowserDownloadActivity] = [
            modules[3].installIdentity: .inProgress(0.25)
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
            .beingInstalled(progress: ModuleInstallProgress(phase: .downloading, fraction: 0.25))
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
            downloadActivities: [
                RemoteModuleIdentity(repository: "CrossWire", initials: "WARN"): .inProgress(0.25)
            ],
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
     Verifies same-repository malformed versions stay updateable while blank versions compare as 1.0.

     Android constructs both values with JSword `Version`; a constructor failure deliberately
     returns `UPGRADE_AVAILABLE`, but a *missing* version never reaches the constructor because
     `SwordBookMetaData` defaults it to `1.0` at read time. This test covers the blank read-time
     default (including catalog caches persisted before the default existed), malformed,
     excessive-component, and overflowing metadata, JSword's arbitrary single-character separator,
     rejected line terminators, and `-1` ordering for omitted components. A failure either hides
     the reinstall/update affordance for damaged metadata or reports a phantom update forever for
     versionless modules such as BDBT.
     - Side effects: None.
     */
    func testSameRepositoryInvalidVersionsRemainUpdateableLikeAndroid() {
        let malformedRemote = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            sourceName: "CrossWire",
            version: "not-a-version"
        )
        let versionlessRemote = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            sourceName: "CrossWire",
            version: ""
        )
        let installed = ModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            version: "1.0",
            aboutMetadata: ModuleAboutMetadata(repository: "CrossWire")
        )
        let differentRepositoryRemote = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version mirror",
            category: .bible,
            language: "en",
            sourceName: "Mirror",
            version: ""
        )

        XCTAssertEqual(
            ModuleBrowserView.displayStatus(
                for: malformedRemote,
                installedModules: [installed],
                downloadActivities: [:]
            ),
            .updateAvailable
        )
        XCTAssertEqual(
            ModuleBrowserView.displayStatus(
                for: versionlessRemote,
                installedModules: [installed],
                downloadActivities: [:]
            ),
            .installed
        )
        XCTAssertEqual(
            ModuleBrowserView.displayStatus(
                for: differentRepositoryRemote,
                installedModules: [installed],
                downloadActivities: [:]
            ),
            .installable
        )
        XCTAssertFalse(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "", installedVersion: ""))
        XCTAssertFalse(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "1.0", installedVersion: ""))
        XCTAssertTrue(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "2.0", installedVersion: ""))
        XCTAssertTrue(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "invalid", installedVersion: "1.0"))
        XCTAssertTrue(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "1.0", installedVersion: "invalid"))
        XCTAssertTrue(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "1.2.3.4.5", installedVersion: "1.0"))
        XCTAssertTrue(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "2147483648", installedVersion: "1.0"))
        XCTAssertFalse(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "1a2", installedVersion: "1.2"))
        XCTAssertTrue(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "1a3", installedVersion: "1.2"))
        XCTAssertTrue(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "1\n2", installedVersion: "1.2"))
        XCTAssertTrue(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "1.0", installedVersion: "1"))
        XCTAssertFalse(ModuleBrowserView.isRemoteVersionNewer(remoteVersion: "1", installedVersion: "1.0"))
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

    /** Partial repository failures stay in Download Errors instead of impersonating install failures. */
    func testCatalogRefreshInlineErrorRequiresACompletelyEmptyCatalog() {
        let errors = ["eBible: timed out", "AndBible Extra: cancelled"]

        XCTAssertNil(
            ModuleBrowserView.catalogRefreshInlineError(
                availableModuleCount: 6,
                errors: errors
            )
        )
        XCTAssertEqual(
            ModuleBrowserView.catalogRefreshInlineError(
                availableModuleCount: 0,
                errors: errors
            ),
            "Failed to load catalogs:\neBible: timed out\nAndBible Extra: cancelled"
        )
        XCTAssertNil(
            ModuleBrowserView.catalogRefreshInlineError(
                availableModuleCount: 0,
                errors: []
            )
        )
    }

    /**
     Verifies install failures reuse Android's localized install-failure sentence.

     Android surfaces install failures through the same Download errors affordance as repository
     failures. iOS should keep that shared error contract and avoid introducing hard-coded English
     prefixes inside the overflow dialog.
     */
    func testModuleBrowserDownloadFailureMessageUsesLocalizedPrefix() {
        let format = String(
            localized: "install_failed_reason",
            defaultValue: "Installing module failed for the following reason: %@."
        )

        XCTAssertEqual(
            ModuleBrowserView.downloadFailureMessage("Network unavailable"),
            String(format: format, "Network unavailable")
        )
        XCTAssertEqual(
            ModuleBrowserView.downloadFailureMessage(moduleName: "KJV", message: "Network unavailable"),
            String(format: format, "KJV: Network unavailable")
        )
    }

    /**
     Verifies phase labels use the Android-backed module-install localization contract.

     Failure means a durable install phase can regress to an English-only key in shipped locales.
     */
    func testModuleBrowserInstallPhaseTextUsesLocalizedContracts() {
        XCTAssertEqual(
            ModuleBrowserView.installPhaseText(.queued, progressPercent: nil),
            String(localized: "module_install_phase_queued", defaultValue: "Please wait…")
        )
        XCTAssertEqual(
            ModuleBrowserView.installPhaseText(.downloading, progressPercent: 42),
            "\(String(localized: "module_install_phase_downloading", defaultValue: "Download")) 42%"
        )
        XCTAssertEqual(
            ModuleBrowserView.installPhaseText(.extracting, progressPercent: nil),
            String(localized: "extracting_zip_file", defaultValue: "Extracting Zip file now…")
        )
        XCTAssertEqual(
            ModuleBrowserView.installPhaseText(.committing, progressPercent: nil),
            String(
                localized: "module_install_phase_committing",
                defaultValue: "Please wait. Loading modules from a file."
            )
        )
        XCTAssertEqual(
            ModuleBrowserView.installPhaseText(.complete, progressPercent: nil),
            String(
                localized: "install_zip_successfull",
                defaultValue: "Module was installed successfully"
            )
        )
    }

    /**
     Verifies cancellation stops being available once live-tree commit begins.

     Failure means Downloads can clear a row as cancelled while publication or rollback is active.
     */
    func testModuleInstallProgressCancellationBoundaryMatchesTransactionContract() {
        XCTAssertTrue(ModuleInstallProgress(phase: .queued).isCancellable)
        XCTAssertTrue(ModuleInstallProgress(phase: .downloading).isCancellable)
        XCTAssertTrue(ModuleInstallProgress(phase: .extracting).isCancellable)
        XCTAssertFalse(ModuleInstallProgress(phase: .committing).isCancellable)
        XCTAssertFalse(ModuleInstallProgress(phase: .complete).isCancellable)
    }

    /**
     Verifies insufficient-storage errors are localized before entering row or alert state.

     Failure means technical English repository descriptions can bypass module-install locale resources.
     */
    func testModuleInstallStorageFailureUsesAndroidLocalizedWarning() {
        XCTAssertEqual(
            ModuleInstallErrorPresentation.detail(for: ModuleRepositoryError.insufficientStorage(
                requiredBytes: 2_000,
                availableBytes: 1_000
            )),
            String(
                localized: "storage_space_warning",
                defaultValue: "Insufficient local storage space."
            )
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

    /**
     Prevents Downloads' Custom repositories route from hiding native iOS structure below an
     app-owned parent screen.

     Android renders `CustomRepositories` and `CustomRepositoryEditor` as dedicated activities:
     the list contains custom rows only, the empty card owns Add and Information commands, and the
     editor toolbar owns Save, Delete, and Help. A failure means iOS has reintroduced `List`,
     `Form`, swipe actions, native toolbar presentation, SF-symbol facsimiles, or invented default
     repository/reset sections inside the Downloads workflow.
     */
    func testCustomRepositoriesReuseAndroidActivityStructureAndOwnerPalette() throws {
        let repositorySource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Downloads/RepositoryManagerView.swift"
        )
        let downloadsSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift"
        )

        XCTAssertTrue(repositorySource.contains("AndroidActivityTopAppBar("))
        XCTAssertTrue(repositorySource.contains("AndroidRaisedTextButton("))
        XCTAssertTrue(repositorySource.contains("AndroidActivityTextInput("))
        XCTAssertTrue(repositorySource.contains(".asset(\"ActivityAddCircle\")"))
        XCTAssertTrue(repositorySource.contains(".asset(\"DrawerHelp\")"))
        XCTAssertTrue(repositorySource.contains(".asset(\"ActivitySave\")"))
        XCTAssertTrue(repositorySource.contains(".asset(\"ActivityDelete\")"))
        XCTAssertTrue(repositorySource.contains("AndBibleIconView(name: \"ActivityPaste\""))
        XCTAssertTrue(repositorySource.contains("custom_repositories_empty_list_message"))
        XCTAssertTrue(repositorySource.contains("custom_repositories_create_button_label"))
        XCTAssertTrue(repositorySource.contains("custom_repositories_info_button_label"))
        XCTAssertTrue(repositorySource.contains("delete_custom_repository"))
        XCTAssertTrue(repositorySource.contains("discard_changes_confirmation"))
        XCTAssertTrue(repositorySource.contains("surfacePalette: ReaderThemeSurfacePalette"))
        XCTAssertTrue(downloadsSource.contains("RepositoryManagerView(surfacePalette: surfacePalette)"))

        for forbidden in [
            "List {",
            "Form {",
            ".toolbar {",
            ".swipeActions",
            ".contextMenu",
            "Image(systemName:",
            "defaultRepositoriesSection",
            "resetSection",
            "resetToDefaults()",
        ] {
            XCTAssertFalse(repositorySource.contains(forbidden), "Unexpected native/invented repository UI: \(forbidden)")
        }
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
