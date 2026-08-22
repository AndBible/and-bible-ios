import XCTest
import BibleCore
@testable import BibleUI
import SwordKit
import UniformTypeIdentifiers

/**
 Thread-safe probe for the injectable external document installers.

 The production service accepts `@Sendable` closures because app-open handling can call it from a
 detached task. The probe records synchronous calls behind a lock so tests can assert the routing
 contract without depending on real SWORD or EPUB file contents.
 */
private final class ExternalDocumentImportProbe: @unchecked Sendable {
    /// Lock protecting recorded installer URLs.
    private let lock = NSLock()

    /// URLs passed to the module installer.
    private var moduleURLs: [URL] = []

    /// URLs passed to the EPUB installer.
    private var epubURLs: [URL] = []

    /// URLs passed to the TTF font installer.
    private var fontURLs: [(url: URL, displayName: String?)] = []

    /// URLs passed to the Android module-backup installer.
    private var androidModuleBackupURLs: [URL] = []

    /// URLs passed to the Android module-backup archive detector.
    private var androidModuleBackupDetectionURLs: [URL] = []

    /// Number of ZIP archive detector calls.
    private var epubArchiveDetectionCount = 0

    /**
     Records a SWORD module installer call and returns a deterministic module name.

     - Parameter url: URL routed to the module installer.
     - Returns: Stable module name used for feedback assertions.
     - Side effects: Appends `url` to the module-call log.
     - Failure modes: This test double does not throw.
     */
    func installModule(from url: URL) throws -> String {
        lock.lock()
        moduleURLs.append(url)
        lock.unlock()
        return "FinRK"
    }

    /**
     Records an EPUB installer call and returns a deterministic document title.

     - Parameter url: URL routed to the EPUB installer.
     - Returns: Stable EPUB title used for feedback assertions.
     - Side effects: Appends `url` to the EPUB-call log.
     - Failure modes: This test double does not throw.
     */
    func installEpub(from url: URL) throws -> String {
        lock.lock()
        epubURLs.append(url)
        lock.unlock()
        return "Study Notes"
    }

    /**
     Records a TTF font installer call and returns a deterministic font name.

     - Parameters:
       - url: URL routed to the font installer.
       - displayName: Provider filename passed through to preserve Android's display-name behavior.
     - Returns: Stable font name used for feedback assertions.
     - Side effects: Appends the call to the font-call log.
     - Failure modes: This test double does not throw.
     */
    func installFont(from url: URL, displayName: String?) throws -> String {
        lock.lock()
        fontURLs.append((url, displayName))
        lock.unlock()
        return "Gentium"
    }

    /**
     Records an Android module-backup installer call and returns a deterministic restore report.

     - Parameter url: URL routed to the Android module-backup installer.
     - Returns: Stable restore report used for feedback and routing assertions.
     - Side effects: Appends `url` to the Android module-backup call log.
     - Failure modes: This test double does not throw.
     */
    func installAndroidModuleBackup(from url: URL) throws -> AndroidModuleBackupRestoreReport {
        lock.lock()
        androidModuleBackupURLs.append(url)
        lock.unlock()
        return AndroidModuleBackupRestoreReport(
            installedModuleNames: ["ESV2001", "ESV2011"],
            installedEntryCount: 14
        )
    }

    /**
     Records Android module-backup detection and classifies the archive as a backup.

     - Parameter url: ZIP URL inspected before generic module installation.
     - Returns: `true` so the service routes the file to the Android backup installer.
     - Side effects: Appends `url` to the Android module-backup detector log.
     - Failure modes: This test double cannot fail.
     */
    func detectAndroidModuleBackup(_ url: URL) -> Bool {
        lock.lock()
        androidModuleBackupDetectionURLs.append(url)
        lock.unlock()
        return true
    }

    /**
     Records an EPUB archive detection pass and classifies the archive as a SWORD ZIP.

     - Parameter url: URL inspected by the ZIP classifier.
     - Returns: `false` so the service continues to the module installer branch.
     - Side effects: Increments the archive-detection count under a lock.
     - Failure modes: This test double cannot fail.
     */
    func detectNonEpubArchive(_ url: URL) -> Bool {
        _ = url
        lock.lock()
        epubArchiveDetectionCount += 1
        lock.unlock()
        return false
    }

    /**
     Returns the recorded installer calls.

     - Returns: Module, EPUB, font, Android module-backup, backup-detection, and EPUB archive
       detection records captured so far.
     - Side effects: Reads test-double state under a lock.
     - Failure modes: This helper cannot fail.
     */
    func snapshot() -> (
        moduleURLs: [URL],
        epubURLs: [URL],
        fontURLs: [(url: URL, displayName: String?)],
        androidModuleBackupURLs: [URL],
        androidModuleBackupDetectionURLs: [URL],
        epubArchiveDetectionCount: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            moduleURLs,
            epubURLs,
            fontURLs,
            androidModuleBackupURLs,
            androidModuleBackupDetectionURLs,
            epubArchiveDetectionCount
        )
    }
}

/** Thread-safe recorder for Android raw-family external document routes. */
private final class ExternalAndroidFamilyImportProbe: @unchecked Sendable {
    /// One recorded raw-family installer invocation.
    struct Call: Equatable {
        /// Source URL selected by the importer.
        let url: URL

        /// Provider-visible basename forwarded to transactional restore.
        let displayName: String

        /// Android registrar selected by the routing matrix.
        let family: AndroidModuleBackupExternalFileFamily

        /// Explicit overwrite authorization supplied by the caller.
        let overwritePolicy: LocalSwordZipOverwritePolicy
    }

    /// Lock protecting the call log across `@Sendable` installer closures.
    private let lock = NSLock()

    /// Ordered raw-family installer calls.
    private var calls: [Call] = []

    /**
     Records one raw-family installation and returns deterministic initials.

     - Parameters:
       - url: Routed source URL.
       - displayName: Sanitized provider basename.
       - family: Selected Android family.
       - overwritePolicy: Caller-authorized conflict behavior.
     - Returns: Stable initials used by result assertions.
     - Side effects: Appends one call under `lock`.
     - Failure modes: This test double does not throw.
     */
    func install(
        _ url: URL,
        displayName: String,
        family: AndroidModuleBackupExternalFileFamily,
        overwritePolicy: LocalSwordZipOverwritePolicy
    ) throws -> String {
        lock.lock()
        calls.append(Call(
            url: url,
            displayName: displayName,
            family: family,
            overwritePolicy: overwritePolicy
        ))
        lock.unlock()
        return displayName
    }

    /** Returns an ordered snapshot of every recorded raw-family call. */
    func snapshot() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/**
 Thread-safe probe for ordinary SWORD ZIP preflight and policy-aware installation.

 The shared import service invokes these closures from `@Sendable` contexts. This probe records the
 read-only inspection and subsequent explicit overwrite authorization without relying on mutable
 closure captures.
 */
private final class ExternalDocumentModulePolicyProbe: @unchecked Sendable {
    /// Lock protecting all recorded calls and progress values.
    private let lock = NSLock()

    /// Inspection returned for every candidate archive.
    private let inspection: LocalSwordZipInspection

    /// URLs inspected before installation.
    private var inspectedURLs: [URL] = []

    /// Policy-aware installer calls.
    private var installCalls: [(url: URL, policy: LocalSwordZipOverwritePolicy)] = []

    /// Structured progress values sent through the installer callback.
    private var emittedProgress: [ModuleInstallProgress] = []

    /**
     Creates a probe with a deterministic inspection result.

     - Parameter inspection: Read-only result returned by `inspect(_:)`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(inspection: LocalSwordZipInspection) {
        self.inspection = inspection
    }

    /** Records one read-only archive inspection. */
    func inspect(_ url: URL) throws -> LocalSwordZipInspection {
        lock.lock()
        inspectedURLs.append(url)
        lock.unlock()
        return inspection
    }

    /**
     Records explicit overwrite authorization and emits representative durable phases.

     - Parameters:
       - url: Archive URL passed by the shared import service.
       - policy: Explicit overwrite policy selected by the caller.
       - progressState: Optional phase observer forwarded by the caller.
     - Returns: Stable module initials for result assertions.
     - Side effects: Records the call and synchronously emits extraction through completion.
     - Failure modes: This test double does not throw.
     */
    func install(
        _ url: URL,
        policy: LocalSwordZipOverwritePolicy,
        progressState: (@Sendable (ModuleInstallProgress) -> Void)?
    ) throws -> String {
        lock.lock()
        installCalls.append((url, policy))
        lock.unlock()
        let phases = [
            ModuleInstallProgress(phase: .extracting, fraction: 0.5),
            ModuleInstallProgress(phase: .committing),
            ModuleInstallProgress(phase: .complete, fraction: 1),
        ]
        for progress in phases {
            progressState?(progress)
        }
        return "FinRK"
    }

    /** Records one progress event received by the caller. */
    func recordProgress(_ progress: ModuleInstallProgress) {
        lock.lock()
        emittedProgress.append(progress)
        lock.unlock()
    }

    /** Returns coherent snapshots of all recorded inspection, install, and progress calls. */
    func snapshot() -> (
        inspectedURLs: [URL],
        installCalls: [(url: URL, policy: LocalSwordZipOverwritePolicy)],
        emittedProgress: [ModuleInstallProgress]
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (inspectedURLs, installCalls, emittedProgress)
    }
}

/**
 Error thrown by installer test doubles when validating failure feedback.

 The localized description is deterministic so the service's shared error-prefix formatting can be
 asserted without depending on platform-specific NSError text.
 */
private enum ExternalDocumentImportTestError: LocalizedError {
    /// Simulates an installer rejecting a handled document.
    case rejected

    /// User-visible error body returned to the service.
    var errorDescription: String? {
        "installer rejected file"
    }
}

/**
 Package-level tests for Android-parity external document import routing.

 The suite validates the BibleUI service that classifies documents opened from Files, share sheets,
 and settings import surfaces. Pure SWORD font repository filesystem behavior lives in
 `SwordKitTests`; this suite owns routing, feedback, provider metadata normalization, and installer
 selection.
 */
final class ExternalDocumentImportTests: XCTestCase {
    /**
     Creates an external-document import service wired to a thread-safe test probe.

     The helper keeps installer closure construction identical across routing tests and preserves the
     production service's `@Sendable` closure contract.

     - Parameters:
       - probe: Probe that records module, EPUB, and TTF installer calls.
       - androidModuleBackupDetector: Optional archive classifier override for renamed backup ZIPs.
       - epubArchiveDetector: Optional ZIP classifier override for EPUB fallback tests.
     - Returns: Service instance with deterministic installer outputs.
     - Side effects: none during construction.
     - Failure modes: This helper cannot fail.
     */
    private func makeExternalDocumentImportService(
        probe: ExternalDocumentImportProbe,
        androidModuleBackupDetector: ExternalDocumentImportService.AndroidModuleBackupDetector? = nil,
        epubArchiveDetector: ExternalDocumentImportService.EpubArchiveDetector? = nil
    ) -> ExternalDocumentImportService {
        ExternalDocumentImportService(
            moduleInstaller: { url in try probe.installModule(from: url) },
            epubInstaller: { url in try probe.installEpub(from: url) },
            fontInstaller: { url, displayName in try probe.installFont(from: url, displayName: displayName) },
            androidModuleBackupInstaller: { url in try probe.installAndroidModuleBackup(from: url) },
            androidModuleBackupDetector: androidModuleBackupDetector,
            epubArchiveDetector: epubArchiveDetector
        )
    }

    /**
     Creates an isolated ordinary-ZIP input that cannot inherit archive contents from another test.

     - Parameter label: Human-readable scenario prefix used only in the temporary filename.
     - Returns: A unique `.zip` URL whose path does not exist when returned.
     - Side effects: Reads filesystem existence once for the XCTest invariant; it creates no file.
     - Failure modes: Records an XCTest failure if a UUID collision unexpectedly resolves to an
       existing path, because default archive detectors would then observe unowned input.
     - Note: UUID uniqueness keeps parallel and repeated suite runs independent without cleanup.
     */
    private func makeUniqueNonexistentZIPURL(label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "Expected an unowned ZIP fixture path."
        )
        return url
    }

    /**
     ZIP files are Android's SWORD module package path and must call only the module installer.

     - Setup: Uses a unique nonexistent temporary ZIP URL so the production default archive
       detectors classify only this test input and cannot consume a real archive left in shared
       `/tmp` by another suite.
     - Expected result: Android's SWORD module installer alone receives the URL and reports the
       generic `install_zip_successfull` short-toast contract.
     - Failure meaning: Files/Mail routing drifted from Backup & Restore, arbitrary ZIP handling no
       longer uses the SWORD repository path, or the test again depends on shared filesystem state.
     - Side effects: None; the unique URL is never created and the installers are in-memory probes.
     */
    func testExternalDocumentImportZipUsesModuleInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = makeUniqueNonexistentZIPURL(label: "ordinary-sword-module")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedModule(name: "FinRK"))
        XCTAssertEqual(result.feedbackMessage, "Module was installed successfully")
        XCTAssertTrue(result.usesAndroidInstallToastFeedback)
        XCTAssertEqual(probe.snapshot().moduleURLs, [url])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
        XCTAssertEqual(probe.snapshot().androidModuleBackupURLs, [])
    }

    /**
     Ordinary SWORD ZIP preflight reports exact conflicts without invoking the installer.

     Failure means a Files or Settings import can overwrite module data before the user sees the
     same destination list Android presents for confirmation.
     */
    func testExternalDocumentImportPreflightRequiresConfirmationForExactModuleConflicts() {
        let inspection = LocalSwordZipInspection(
            moduleNames: ["FinRK"],
            conflictingPaths: [
                "mods.d/finrk.conf",
                "modules/texts/ztext/finrk/nt.bzs",
            ],
            installableEntryCount: 4,
            estimatedExpandedBytes: 12_345,
            archiveSHA256: String(repeating: "a", count: 64)
        )
        let probe = ExternalDocumentModulePolicyProbe(inspection: inspection)
        let service = ExternalDocumentImportService(
            moduleInspector: { try probe.inspect($0) },
            moduleInstallerWithPolicy: { url, policy, progressState in
                try probe.install(url, policy: policy, progressState: progressState)
            },
            androidModuleBackupDetector: { _ in false },
            epubArchiveDetector: { _ in false }
        )
        let request = ExternalDocumentImportRequest(url: URL(fileURLWithPath: "/tmp/FinRK.zip"))

        XCTAssertEqual(service.preflightDocument(request), .moduleOverwriteRequired(inspection))
        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.inspectedURLs, [request.url])
        XCTAssertTrue(snapshot.installCalls.isEmpty)
    }

    /**
     Confirmed local replacement forwards explicit authorization and structured progress.

     Failure means the UI confirmation can be discarded before reaching storage or durable phases
     can be lost between the repository and the importing surface.
     */
    func testExternalDocumentImportConfirmedReplacementForwardsPolicyAndProgress() {
        let inspection = LocalSwordZipInspection(
            moduleNames: ["FinRK"],
            conflictingPaths: ["mods.d/finrk.conf"],
            installableEntryCount: 2,
            estimatedExpandedBytes: 512,
            archiveSHA256: String(repeating: "b", count: 64)
        )
        let probe = ExternalDocumentModulePolicyProbe(inspection: inspection)
        let service = ExternalDocumentImportService(
            moduleInspector: { try probe.inspect($0) },
            moduleInstallerWithPolicy: { url, policy, progressState in
                try probe.install(url, policy: policy, progressState: progressState)
            },
            androidModuleBackupDetector: { _ in false },
            epubArchiveDetector: { _ in false }
        )
        let request = ExternalDocumentImportRequest(url: URL(fileURLWithPath: "/tmp/FinRK.zip"))

        let result = service.importDocument(
            request,
            moduleOverwritePolicy: .replaceExisting(inspection.overwriteAuthorization),
            progressState: { probe.recordProgress($0) }
        )

        XCTAssertEqual(result, .installedModule(name: "FinRK"))
        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.installCalls.count, 1)
        XCTAssertEqual(snapshot.installCalls.first?.url, request.url)
        XCTAssertEqual(
            snapshot.installCalls.first?.policy,
            .replaceExisting(inspection.overwriteAuthorization)
        )
        XCTAssertEqual(snapshot.emittedProgress.map(\.phase), [.extracting, .committing, .complete])
    }

    /**
     An Android backup filename cannot replace structural archive recognition.

     The unreadable fixture has the conventional `.abmd.zip` suffix but no recognized module
     structure. Android routes by opened ZIP content, so the generic archive installer must retain
     ownership and the backup installer must remain untouched.
     */
    func testExternalDocumentImportBackupSuffixCannotReplaceArchiveRecognition() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/ESV.abmd.zip")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedModule(name: "FinRK"))
        XCTAssertEqual(result.feedbackMessage, "Module was installed successfully")
        XCTAssertTrue(result.usesAndroidInstallToastFeedback)
        XCTAssertEqual(probe.snapshot().androidModuleBackupURLs, [])
        XCTAssertEqual(probe.snapshot().moduleURLs, [url])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     Android module-backup success presentation follows InstallZip instead of listing modules.

     Android's `InstallZip` posts the generic `install_zip_successfull` toast after a successful
     module or document backup install. The iOS restore report can contain many module names, but
     the completion copy must remain generic so large Android backups do not produce a blocking,
     scroll-sized module list.

     Failure means the Settings restore path can drift from Android's visible behavior even when
     the underlying restore report is correct.
     */
    func testAndroidModuleBackupPresentationUsesGenericInstallSuccessCopy() {
        let report = AndroidModuleBackupRestoreReport(
            installedModuleNames: ["BDBT", "HebrewGreek", "StrongsHebrew"],
            installedEntryCount: 124
        )

        let message = AndroidModuleBackupPresentation.localizedRestoreSuccessMessage(for: report)

        XCTAssertEqual(message, "Module was installed successfully")
        XCTAssertFalse(message.contains("BDBT"))
    }

    /**
     Provider display names cannot promote an arbitrary ZIP into Android backup restore.

     Some providers preserve an `.abmd.zip` display name beside an unreadable or unrelated temporary
     URL. The name remains presentation metadata; only archive structure may select backup restore.
     */
    func testExternalDocumentImportProviderBackupSuffixCannotReplaceArchiveRecognition() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/provider-temporary.zip")
        let request = ExternalDocumentImportRequest(
            url: url,
            suggestedFileName: "  Backups/ESV.abmd.zip  "
        )

        let result = service.importDocument(request)

        XCTAssertEqual(result, .installedModule(name: "FinRK"))
        XCTAssertEqual(probe.snapshot().androidModuleBackupURLs, [])
        XCTAssertEqual(probe.snapshot().moduleURLs, [url])
    }

    /**
     Manifest detection preserves Android backup routing when iOS rewrites repeated filenames.

     Files can copy repeated external opens into Inbox-style names such as `ESV.abmd-1.zip`, which
     no longer satisfy Android's literal `.abmd.zip` suffix. The router must inspect ZIP contents
     before generic module installation so backup semantics are preserved even when the provider
     filename changes.

     Failure means repeated imports can silently fall back to the plain SWORD ZIP installer and
     report only the last module installed, as the simulator did with `ESV.abmd-1.zip`.
     */
    func testExternalDocumentImportAndroidModuleBackupUsesManifestWhenFileNameChanges() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(
            probe: probe,
            androidModuleBackupDetector: { url in probe.detectAndroidModuleBackup(url) }
        )
        let url = URL(fileURLWithPath: "/tmp/ESV.abmd-1.zip")

        let result = service.importDocument(at: url)

        XCTAssertEqual(
            result,
            .installedAndroidModuleBackup(moduleNames: ["ESV2001", "ESV2011"], installedEntryCount: 14)
        )
        XCTAssertEqual(probe.snapshot().androidModuleBackupDetectionURLs, [url])
        XCTAssertEqual(probe.snapshot().androidModuleBackupURLs, [url])
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
    }

    /**
     A ZIP with Android's database manifest stays on the generic archive path.

     The generic `.zip` filename and otherwise installable SWORD entries make the fallback branch
     observable: Android's first-manifest parser abandons typed module-backup routing for
     `DB_BACKUP`, then continues generic ZIP installation. The external classifier must not call the
     module-backup service merely because the remaining entries form a valid SWORD archive.

     The test writes only to UUID-scoped temporary directories and removes them on exit.
     */
    func testExternalDocumentImportDatabaseBackupManifestFallsThroughGenericZipRoute() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let moduleDirectory = tempDirectory.appendingPathComponent("sword", isDirectory: true)
        let stagingDirectory = tempDirectory.appendingPathComponent("staging", isDirectory: true)
        let archiveURL = tempDirectory.appendingPathComponent("provider-copy.zip")
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let configuration = Data(
            """
            [ROUTING]
            Description=Routing fixture
            Category=Biblical Texts
            ModDrv=RawText
            DataPath=./modules/texts/rawtext/routing/
            Versification=KJV

            """.utf8
        )
        let archiveData = try ZipArchiveWriter.storedArchive(entries: [
            ZipArchiveWriterEntry(
                name: "AndBibleBackupManifest.json",
                data: Data(#"{"backupType":"DB_BACKUP","manifestVersion":1}"#.utf8)
            ),
            ZipArchiveWriterEntry(name: "mods.d/routing.conf", data: configuration),
            ZipArchiveWriterEntry(
                name: "modules/texts/rawtext/routing/ot",
                data: Data("would-install-as-sword".utf8)
            ),
        ])
        try archiveData.write(to: archiveURL)

        let probe = ExternalDocumentImportProbe()
        let service = ExternalDocumentImportService(
            moduleInstaller: { url in try probe.installModule(from: url) },
            androidModuleBackupInstaller: { url in
                _ = try probe.installAndroidModuleBackup(from: url)
                return try AndroidModuleBackupService(
                    moduleDirectory: moduleDirectory,
                    temporaryDirectory: stagingDirectory
                ).restoreArchive(fromArchiveAt: url)
            },
            epubArchiveDetector: { _ in false }
        )

        let result = service.importDocument(at: archiveURL)

        XCTAssertEqual(result, .installedModule(name: "FinRK"))
        XCTAssertEqual(probe.snapshot().androidModuleBackupURLs, [])
        XCTAssertEqual(probe.snapshot().moduleURLs, [archiveURL])
        XCTAssertFalse(fileManager.fileExists(
            atPath: moduleDirectory.appendingPathComponent("mods.d/routing.conf").path
        ))
    }

    /**
     EPUB files are imported through the EPUB reader store and must not be treated as SWORD ZIPs.

     Android's EPUB fallback still reports success through the generic InstallZip toast. Failure
     indicates that the scene-open path no longer matches the existing Settings document import
     branch for EPUB documents or that successful EPUB installs drifted back to iOS-specific alert
     copy.
     */
    func testExternalDocumentImportEpubUsesEpubInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/StudyNotes.epub")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedEpub(title: "Study Notes"))
        XCTAssertEqual(result.feedbackMessage, "Module was installed successfully")
        XCTAssertTrue(result.usesAndroidInstallToastFeedback)
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [url])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     TTF files follow Android's app-owned font installer route.

     Android stores fonts under `modulesDir/ttf` and reports success through the generic InstallZip
     toast. Failure indicates that iOS advertises Android's font document type without backing it
     with the same storage semantics or that successful font installs use an iOS-specific alert.
     */
    func testExternalDocumentImportTtfUsesFontInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/custom.ttf")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedFont(name: "Gentium"))
        XCTAssertEqual(result.feedbackMessage, "Module was installed successfully")
        XCTAssertTrue(result.usesAndroidInstallToastFeedback)
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [url])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.displayName), ["custom.ttf"])
    }

    /**
     Provider display names are normalized once before confirmation and TTF installation.

     Failure means iOS document-provider metadata could show whitespace in the Android-style
     confirmation prompt or create drift between the displayed name and installed font metadata.
     */
    func testExternalDocumentImportTrimsProviderDisplayNameForFontInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/provider-source.ttf")
        let request = ExternalDocumentImportRequest(
            url: url,
            suggestedFileName: "  Folder/Gentium.ttf  \n"
        )

        let result = service.importDocument(request)

        XCTAssertEqual(result, .installedFont(name: "Gentium"))
        XCTAssertEqual(request.displayFileName, "Gentium.ttf")
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [url])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.displayName), ["Gentium.ttf"])
    }

    /**
     Verifies Android's complete non-archive external-file matrix reaches the matching registrar.

     Images and CSV files route by provider-visible extension or specific UTType. SQLite families
     additionally require the SQLite 3 header before `.SQLite3`, `.mybible`, `.bblx`, or `.bbli`
     selects its Android database reader. Every route forwards the normalized basename and fail-safe
     overwrite policy to the transactional installer.

     - Side effects: Creates and removes UUID-scoped fixture files; records installer calls.
     - Failure modes: File I/O is thrown; a missing, swapped, or extension-only database route fails
       the ordered call assertions.
     */
    func testExternalDocumentImportRoutesEveryAndroidRawFileFamily() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-android-family-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ExternalAndroidFamilyImportProbe()
        let service = ExternalDocumentImportService(
            moduleInstaller: { _ in "unexpected-module" },
            epubInstaller: { _ in "unexpected-epub" },
            fontInstaller: { _, _ in "unexpected-font" },
            androidFamilyFileInstaller: { url, displayName, family, policy in
                try probe.install(
                    url,
                    displayName: displayName,
                    family: family,
                    overwritePolicy: policy
                )
            }
        )
        let sqliteData = Data("SQLite format 3\0fixture".utf8)
        let csvType = try XCTUnwrap(UTType(filenameExtension: "csv"))
        let fixtures: [(String, Data, String?, String?, AndroidModuleBackupExternalFileFamily)] = [
            ("wallpaper.png", Data("png".utf8), nil, nil, .background),
            ("wallpaper.jpg", Data("jpg".utf8), nil, nil, .background),
            ("wallpaper.jpeg", Data("jpeg".utf8), nil, nil, .background),
            ("wallpaper.webp", Data("webp".utf8), nil, nil, .background),
            (
                "provider-image.data",
                Data("image".utf8),
                UTType.png.identifier,
                "cover.png",
                .background
            ),
            ("prompts.csv", Data("name;promptTemplate".utf8), nil, nil, .prompts),
            (
                "provider-prompts.data",
                Data("name;promptTemplate".utf8),
                csvType.identifier,
                "provider-prompts.csv",
                .prompts
            ),
            ("reader.SQLite3", sqliteData, nil, nil, .myBible),
            ("reader.mybible", sqliteData, nil, nil, .mySword),
            ("reader.bblx", sqliteData, nil, nil, .eSword),
            ("reader.bbli", sqliteData, nil, nil, .eSword),
        ]

        for (fileName, data, contentType, suggestedName, _) in fixtures {
            let url = root.appendingPathComponent(fileName)
            try data.write(to: url)
            let result = service.importDocument(ExternalDocumentImportRequest(
                url: url,
                contentTypeIdentifier: contentType,
                suggestedFileName: suggestedName
            ))
            XCTAssertEqual(result, .installedModule(name: suggestedName ?? fileName), fileName)
        }

        XCTAssertEqual(
            probe.snapshot().map(\.displayName),
            fixtures.map { $0.3 ?? $0.0 }
        )
        XCTAssertEqual(probe.snapshot().map(\.family), fixtures.map(\.4))
        XCTAssertEqual(
            probe.snapshot().map(\.overwritePolicy),
            Array(repeating: .reject, count: fixtures.count)
        )

        let fakeDatabaseURL = root.appendingPathComponent("not-a-database.SQLite3")
        try Data("not sqlite".utf8).write(to: fakeDatabaseURL)
        XCTAssertEqual(
            service.importDocument(at: fakeDatabaseURL),
            .unsupportedFormat(fileExtension: "sqlite3")
        )
        XCTAssertEqual(probe.snapshot().count, fixtures.count)
    }

    /**
     Unsupported extensions return feedback without invoking any installer.

     Failure means the importer could claim a document type it cannot actually install.
     */
    func testExternalDocumentImportUnsupportedDocumentDoesNotCallInstallers() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)

        let result = service.importDocument(at: URL(fileURLWithPath: "/tmp/custom.txt"))

        XCTAssertEqual(result, .unsupportedFormat(fileExtension: "txt"))
        XCTAssertEqual(result.feedbackMessage, "Error: Unsupported file format (txt)")
        XCTAssertFalse(result.usesAndroidInstallToastFeedback)
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     Non-file URLs are not importable documents, even when their path looks like a handled type.

     SwiftUI `.onOpenURL` can receive unrelated app links. The shared service must keep the import
     contract file-only so those links do not mutate SWORD, EPUB, or font storage.
     */
    func testExternalDocumentImportNonFileURLDoesNotCallInstallers() throws {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = try XCTUnwrap(URL(string: "https://example.invalid/custom.ttf"))

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .unsupportedFormat(fileExtension: "ttf"))
        XCTAssertFalse(result.usesAndroidInstallToastFeedback)
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     Generic `public.data` metadata is accepted by the picker but must not identify a font.

     The Settings importer includes `.data` so provider-backed files remain selectable. Routing must
     still rely on specific document types, filename extensions, or archive inspection before
     invoking an installer.
     */
    func testExternalDocumentImportGenericDataContentTypeDoesNotRouteToFontInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/provider-data.bin")
        let request = ExternalDocumentImportRequest(
            url: url,
            contentTypeIdentifier: UTType.data.identifier
        )

        let result = service.importDocument(request)

        XCTAssertEqual(result, .unsupportedFormat(fileExtension: "bin"))
        XCTAssertFalse(result.usesAndroidInstallToastFeedback)
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     ZIP-looking EPUB archives are rerouted to the EPUB installer before SWORD module install.

     Android's `installZip` catches EPUB packages that arrive through the ZIP path and calls
     `installEpub`. This test protects that fallback for providers that expose only a ZIP-like URL.
     */
    func testExternalDocumentImportZipEpubFallbackUsesEpubInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(
            probe: probe,
            epubArchiveDetector: { _ in true }
        )
        let url = URL(fileURLWithPath: "/tmp/StudyNotes.zip")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedEpub(title: "Study Notes"))
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [url])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     The production ZIP classifier reroutes ZIP-looking EPUB archives without an injected detector.

     Setup:
     - writes a real stored ZIP with EPUB's `META-INF/container.xml` marker
     - imports it through the `.zip` path using the default archive classifier

     Expected result:
     - the EPUB installer receives the URL
     - the SWORD module installer is not called

     Failure meaning:
     - iOS no longer mirrors Android's `installZip` fallback that detects EPUB structure from ZIP
       entries before attempting a module install.
     */
    func testExternalDocumentImportZipEpubFallbackUsesProductionZipClassifier() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let url = tempDir.appendingPathComponent("StudyNotes.zip")
        let archiveData = try ZipArchiveWriter.storedArchive(entries: [
            ZipArchiveWriterEntry(name: "mimetype", data: Data("application/epub+zip".utf8)),
            ZipArchiveWriterEntry(name: "META-INF/container.xml", data: Data("<container/>".utf8)),
        ])
        try archiveData.write(to: url)
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedEpub(title: "Study Notes"))
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [url])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     Verifies the production ZIP router uses Android's exact EPUB fallback and bounded backup gate.

     The matrix combines valid SWORD ownership with exact, backslash, lowercase, dot-prefixed, and
     mimetype-only EPUB markers. Only Android's exact normalized container path may preempt module
     backup detection. A valid SWORD archive routes to backup restore, while arbitrary and
     resource-only `.abmd.zip` files remain generic ZIP installs.

     - Side effects: Writes and removes deterministic stored ZIP fixtures; records installer calls.
     - Failure modes: ZIP I/O is thrown; marker broadening, suffix-only backup detection, or reversed
       EPUB/backup precedence fails the per-archive result assertions.
     */
    func testExternalDocumentImportUsesExactEpubFallbackBeforeBackupRecognition() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-zip-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let configuration = Data(
            """
            [ROUTING]
            Description=Routing fixture
            Category=Biblical Texts
            ModDrv=RawText
            DataPath=./modules/texts/rawtext/routing/
            Versification=KJV

            """.utf8
        )
        let swordEntries = [
            ZipArchiveWriterEntry(name: "mods.d/routing.conf", data: configuration),
            ZipArchiveWriterEntry(
                name: "modules/texts/rawtext/routing/ot",
                data: Data("routing payload".utf8)
            ),
        ]
        let markerCases: [(String, String, ExternalDocumentImportResult)] = [
            (
                "exact",
                "META-INF/container.xml",
                .installedEpub(title: "Study Notes")
            ),
            (
                "backslash",
                "META-INF\\container.xml",
                .installedEpub(title: "Study Notes")
            ),
            (
                "lowercase",
                "meta-inf/container.xml",
                .installedModule(name: "FinRK")
            ),
            (
                "dot-prefix",
                "./META-INF/container.xml",
                .installedModule(name: "FinRK")
            ),
            (
                "mimetype-only",
                "mimetype",
                .installedModule(name: "FinRK")
            ),
        ]

        for (name, marker, expectedResult) in markerCases {
            let url = root.appendingPathComponent("\(name).zip")
            let data = try ZipArchiveWriter.storedArchive(entries: swordEntries + [
                ZipArchiveWriterEntry(name: marker, data: Data("marker".utf8)),
            ])
            try data.write(to: url)
            XCTAssertEqual(service.importDocument(at: url), expectedResult, name)
        }

        let validBackupURL = root.appendingPathComponent("valid.abmd.zip")
        try ZipArchiveWriter.storedArchive(entries: swordEntries).write(to: validBackupURL)
        XCTAssertEqual(
            service.importDocument(at: validBackupURL),
            .installedAndroidModuleBackup(
                moduleNames: ["ESV2001", "ESV2011"],
                installedEntryCount: 14
            )
        )

        let arbitraryURL = root.appendingPathComponent("arbitrary.abmd.zip")
        try ZipArchiveWriter.storedArchive(entries: [
            ZipArchiveWriterEntry(name: "documents/readme.txt", data: Data("notes".utf8)),
        ]).write(to: arbitraryURL)
        XCTAssertEqual(
            service.importDocument(at: arbitraryURL),
            .installedModule(name: "FinRK")
        )

        let resourceOnlyURL = root.appendingPathComponent("resource-only.abmd.zip")
        try ZipArchiveWriter.storedArchive(entries: [
            ZipArchiveWriterEntry(name: "background/theme.png", data: Data("image".utf8)),
        ]).write(to: resourceOnlyURL)
        XCTAssertEqual(
            service.importDocument(at: resourceOnlyURL),
            .installedModule(name: "FinRK")
        )
    }

    /**
     ZIP archive classification is cached during a single module-install attempt.

     - Setup: Uses an isolated nonexistent ZIP, a rejecting module installer, and an instrumented
       non-EPUB detector so a real shared Android backup cannot intercept the request.
     - Expected result: The module error is returned and archive classification runs exactly once.
     - Failure meaning: A failed SWORD install rescans the same ZIP, falls through to EPUB, or the
       test has regained shared-filesystem dependence.
     - Side effects: None; the unique URL is never created and all collaborators are in-memory.
     */
    func testExternalDocumentImportZipModuleFailureDoesNotReinspectArchive() {
        let probe = ExternalDocumentImportProbe()
        let service = ExternalDocumentImportService(
            moduleInstaller: { _ in throw ExternalDocumentImportTestError.rejected },
            epubInstaller: { url in try probe.installEpub(from: url) },
            fontInstaller: { url, displayName in try probe.installFont(from: url, displayName: displayName) },
            epubArchiveDetector: { url in probe.detectNonEpubArchive(url) }
        )

        let result = service.importDocument(
            at: makeUniqueNonexistentZIPURL(label: "rejected-sword-module")
        )

        XCTAssertEqual(result, .failed(message: "installer rejected file"))
        XCTAssertFalse(result.usesAndroidInstallToastFeedback)
        XCTAssertEqual(probe.snapshot().epubArchiveDetectionCount, 1)
        XCTAssertEqual(probe.snapshot().epubURLs, [])
    }

    /**
     Multiple import requests are processed in Android `ACTION_SEND_MULTIPLE` order.

     - Setup: Starts with an isolated nonexistent ordinary ZIP, followed by font and EPUB requests,
       so a shared Android backup archive cannot take ownership of the first item.
     - Expected result: Module, font, and EPUB installers run once in request order.
     - Failure meaning: A multi-file share/open flow reorders side effects, stops after the first
       handled file, or depends on unrelated temporary archive contents.
     - Side effects: None; the unique ZIP is never created and installers are in-memory probes.
     */
    func testExternalDocumentImportMultipleDocumentsPreservesOrder() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let requests = [
            ExternalDocumentImportRequest(
                url: makeUniqueNonexistentZIPURL(label: "shared-ordinary-sword-module")
            ),
            ExternalDocumentImportRequest(url: URL(fileURLWithPath: "/tmp/custom.ttf")),
            ExternalDocumentImportRequest(url: URL(fileURLWithPath: "/tmp/StudyNotes.epub")),
        ]

        let results = service.importDocuments(requests)

        XCTAssertEqual(results, [
            .installedModule(name: "FinRK"),
            .installedFont(name: "Gentium"),
            .installedEpub(title: "Study Notes"),
        ])
        XCTAssertEqual(probe.snapshot().moduleURLs, [requests[0].url])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [requests[1].url])
        XCTAssertEqual(probe.snapshot().epubURLs, [requests[2].url])
    }

    /**
     Installer failures retain the existing import/export error-prefix surface.

     Failure means handled external documents could fail silently or show a different feedback shape
     than the in-app Backup & Restore importer. Errors must not use the Android success-toast path.
     */
    func testExternalDocumentImportInstallerFailureUsesSharedErrorFeedback() {
        let service = ExternalDocumentImportService(
            moduleInstaller: { _ in throw ExternalDocumentImportTestError.rejected },
            epubInstaller: { _ in "unused" },
            fontInstaller: { _, _ in "unused" }
        )

        let result = service.importDocument(at: URL(fileURLWithPath: "/tmp/invalid.zip"))

        XCTAssertEqual(result, .failed(message: "installer rejected file"))
        XCTAssertEqual(result.feedbackMessage, "Error: installer rejected file")
        XCTAssertFalse(result.usesAndroidInstallToastFeedback)
    }
}
