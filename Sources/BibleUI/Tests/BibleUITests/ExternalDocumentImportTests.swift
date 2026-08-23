import XCTest
@testable import BibleCore
@testable import BibleUI
import SwiftData
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
    /// Simulates complete-registry ownership of one EPUB identity.
    case epubIdentityOwned(String)

    /// User-visible error body returned to the service.
    var errorDescription: String? {
        switch self {
        case .rejected:
            "installer rejected file"
        case .epubIdentityOwned(let initials):
            "Cannot import this EPUB because an installed document already owns module identity \(initials)."
        }
    }
}

/**
 Two-party barrier that forces concurrent import workers to begin from the same caller-visible state.

 The condition protects arrival count and releases both workers only after both have arrived. A
 bounded deadline prevents a scheduler failure from hanging the test process; timeout is reported
 through the return value rather than mutating XCTest state from a background queue.
 */
private final class ConcurrentExternalDocumentImportStartGate: @unchecked Sendable {
    /// Condition protecting participant arrival and release.
    private let condition = NSCondition()

    /// Required arrivals before every waiting worker is released.
    private let participantCount: Int

    /// Number of workers that reached the gate.
    private var arrivedCount = 0

    /**
     Creates a barrier for a fixed positive participant count.

     - Parameter participantCount: Number of workers that must arrive before release.
     - Side effects: Allocates one in-memory synchronization primitive.
     - Failure modes: Non-positive values violate the test helper precondition.
     */
    init(participantCount: Int) {
        precondition(participantCount > 0)
        self.participantCount = participantCount
    }

    /**
     Records one arrival and waits for all participants with a bounded deadline.

     - Parameter timeout: Maximum wait after this worker arrives.
     - Returns: `true` when every participant arrived, or `false` after timeout.
     - Side effects: Blocks only the calling test worker and broadcasts once the barrier fills.
     - Failure modes: Scheduler starvation returns `false`; no worker remains permanently blocked.
     */
    func arriveAndWait(timeout: TimeInterval = 10) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        arrivedCount += 1
        if arrivedCount == participantCount {
            condition.broadcast()
            return true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while arrivedCount < participantCount {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}

/**
 Thread-safe ordered result log for concurrent external document imports.

 The log records completion order only; it deliberately adds no ordering between installers and
 performs no assertions from worker queues. Callers take one locked snapshot after joining workers.
 */
private final class ConcurrentExternalDocumentImportResultLog: @unchecked Sendable {
    /** One source/result pair recorded after an import returns. */
    struct Record: Sendable {
        /// Exact archive URL passed to the service.
        let url: URL

        /// Structured import result returned for that archive.
        let result: ExternalDocumentImportResult
    }

    /// Lock protecting `records` across concurrent worker completion.
    private let lock = NSLock()

    /// Completion-order result storage.
    private var records: [Record] = []

    /**
     Records one completed import under the result lock.

     - Parameters:
       - url: Exact candidate URL whose import completed.
       - result: Structured service result returned for the candidate.
     - Side effects: Appends one entry to the in-memory completion-order log.
     - Failure modes: This helper cannot fail.
     */
    func append(url: URL, result: ExternalDocumentImportResult) {
        lock.lock()
        records.append(Record(url: url, result: result))
        lock.unlock()
    }

    /**
     Returns a coherent completion-order result snapshot.

     - Returns: Copy of all recorded entries in lock-observed completion order.
     - Side effects: Briefly acquires the result lock without mutating the log.
     - Failure modes: This helper cannot fail.
     */
    func snapshot() -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

/**
 Package-level tests for Android-parity external document import routing.

 The suite validates the BibleUI service that classifies documents opened from Files, share sheets,
 and settings import surfaces. Pure SWORD font repository filesystem behavior lives in
 `SwordKitTests`; this suite owns routing, feedback, provider metadata normalization, and installer
 selection.
 */
final class ExternalDocumentImportTests: BibleUISwordFixtureTestCase {
    /**
     Creates an external-document import service wired to a thread-safe test probe.

     The helper keeps installer closure construction identical across routing tests and preserves the
     production service's `@Sendable` closure contract.

     - Parameters:
       - probe: Probe that records module, EPUB, and TTF installer calls.
       - androidModuleBackupDetector: Optional archive classifier override for renamed backup ZIPs.
       - epubArchiveDetector: Optional ZIP classifier override for EPUB fallback tests.
       - epubCandidateAdmission: Typed EPUB admission predicate evaluated before fixture mutation.
     - Returns: Service instance with deterministic installer outputs.
     - Side effects: none during construction.
     - Failure modes: This helper cannot fail.
     */
    private func makeExternalDocumentImportService(
        probe: ExternalDocumentImportProbe,
        androidModuleBackupDetector: ExternalDocumentImportService.AndroidModuleBackupDetector? = nil,
        epubArchiveDetector: ExternalDocumentImportService.EpubArchiveDetector? = nil,
        epubCandidateAdmission: @escaping ExternalDocumentImportService.EpubCandidateAdmission = {
            _ in
        }
    ) -> ExternalDocumentImportService {
        ExternalDocumentImportService(
            moduleInstaller: { url in try probe.installModule(from: url) },
            epubInstaller: { url in try probe.installEpub(from: url) },
            epubCandidateAdmission: epubCandidateAdmission,
            fontInstaller: { url, displayName in try probe.installFont(from: url, displayName: displayName) },
            androidModuleBackupInstaller: { url in try probe.installAndroidModuleBackup(from: url) },
            androidModuleBackupDetector: androidModuleBackupDetector,
            epubArchiveDetector: epubArchiveDetector
        )
    }

    /**
     Rejects an EPUB owned by Android's complete book registry before installer mutation.

     - Setup: The admission predicate owns the exact initials generated from a decomposed provider
       filename and the injected installer records every invocation.
     - Expected: Import returns a stable identity failure and the EPUB installer is never called.
     - Failure meaning: A native, SQLite, EPUB, or My Documents owner can be bypassed by importing a
       hidden colliding EPUB, or canonical filename normalization drifts from `EpubReader`.
     - Side effects: Uses only an in-memory installer probe; no archive or library file is written.
     */
    func testExternalDocumentImportRejectsGloballyOwnedEpubBeforeInstallerRuns() {
        let probe = ExternalDocumentImportProbe()
        let url = URL(fileURLWithPath: "/tmp/Cafe\u{301}.epub")
        let expectedInitials = EpubReader.initials(
            forDisplayFileName: url.lastPathComponent.precomposedStringWithCanonicalMapping
        )
        let service = makeExternalDocumentImportService(
            probe: probe,
            epubCandidateAdmission: { candidate in
                guard candidate.initials != expectedInitials else {
                    throw ExternalDocumentImportTestError.epubIdentityOwned(candidate.initials)
                }
            }
        )

        let result = service.importDocument(at: url)

        XCTAssertEqual(
            result,
            .failed(
                message: "Cannot import this EPUB because an installed document already owns module identity \(expectedInitials)."
            )
        )
        XCTAssertEqual(probe.snapshot().epubURLs, [])
    }

    /**
     Wires the production importer to current My Documents ownership rather than an opt-in caller.

     - Setup: Persists a My Documents row whose initials equal a unique incoming EPUB filename's
       Android identity, then constructs the same registry-aware service used by every UI boundary.
     - Expected: The nonexistent EPUB is rejected for identity ownership before archive access.
     - Failure meaning: Production factory/call-site wiring can install a hidden EPUB even though the
       pure admission predicate works in isolation.
     - Side effects: Writes only to an in-memory SwiftData container; no EPUB installer is reached.
     */
    @MainActor
    func testRegistryAwareExternalImportRejectsMyDocumentOwnedEpubInitials() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let url = URL(fileURLWithPath: "/tmp/Owned-\(UUID().uuidString).epub")
        let initials = EpubReader.initials(
            forDisplayFileName: url.lastPathComponent.precomposedStringWithCanonicalMapping
        )
        context.insert(MyDocument(name: "Existing owner", initials: initials))
        try context.save()
        let service = ExternalDocumentImportService.androidRegistryAware(modelContext: context)

        let result = service.importDocument(at: url)

        XCTAssertEqual(
            result,
            .failed(
                message: "Cannot import this EPUB because an installed document already owns module identity \(initials)."
            )
        )
    }

    /**
     Allows an exact stable-identifier EPUB reinstall while retaining one published identity.

     - Setup: Imports a uniquely named valid EPUB, rewrites the same source URL with different
       package metadata, and imports it again through the production registry-aware service.
     - Expected: Both imports succeed, the stable identifier is unchanged, and one current EPUB
       registration exposes the replacement title.
     - Failure meaning: Treating every existing initials owner as foreign blocks Android-compatible
       updates of the same source, or replacement publishes a duplicate registration.
     - Side effects: Writes one temporary archive and one default-library generation, both removed
       during cleanup.
     */
    @MainActor
    func testRegistryAwareExactIdentifierEpubReinstallIsAdmittedAsUpdate() throws {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let archiveURL = try makeMinimalEpubArchive(
            fileName: "SameID\(token).epub",
            title: "First same-ID title"
        )
        let candidate = EpubReader.installCandidate(forEpubURL: archiveURL)
        defer {
            if EpubReader.installedEpubs().contains(where: {
                $0.identifier == candidate.identifier
            }) {
                try? EpubReader.delete(identifier: candidate.identifier)
            }
            try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent())
        }
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeMyDocumentModelContainer()
        let service = ExternalDocumentImportService.androidRegistryAware(
            modelContext: ModelContext(container),
            swordManager: manager
        )

        XCTAssertEqual(
            service.importDocument(at: archiveURL),
            .installedEpub(title: "First same-ID title")
        )
        try writeMinimalEpubArchive(at: archiveURL, title: "Replacement same-ID title")
        XCTAssertEqual(
            service.importDocument(at: archiveURL),
            .installedEpub(title: "Replacement same-ID title")
        )

        let matching = EpubReader.installedEpubs().filter {
            $0.identifier == candidate.identifier
        }
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.title, "Replacement same-ID title")
    }

    /**
     Rejects a different stable EPUB identifier that generates the exact same Android initials.

     - Setup: Imports `A-B.epub`, then attempts the punctuation-variant `A_B.epub`; Android's
       sanitizer maps both filenames to the same initials while the exact-source digest differs.
     - Expected: The first book remains installed and the second is rejected before its manifest,
       generation container, legacy package, or index path exists.
     - Failure meaning: Same-ID update allowance was widened into same-initials replacement and can
       hide or overwrite an unrelated Android book.
     - Side effects: Writes two temporary archives and removes the winning default-library EPUB.
     */
    @MainActor
    func testRegistryAwareDifferentIdentifierWithSameInitialsIsRejected() throws {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let firstURL = try makeMinimalEpubArchive(
            fileName: "Exact-\(token).epub",
            title: "Exact initials owner"
        )
        let secondURL = try makeMinimalEpubArchive(
            fileName: "Exact_\(token).epub",
            title: "Different stable identity"
        )
        let firstCandidate = EpubReader.installCandidate(forEpubURL: firstURL)
        let secondCandidate = EpubReader.installCandidate(forEpubURL: secondURL)
        XCTAssertNotEqual(firstCandidate.identifier, secondCandidate.identifier)
        XCTAssertEqual(firstCandidate.initials, secondCandidate.initials)
        defer {
            for candidate in [firstCandidate, secondCandidate]
            where EpubReader.installedEpubs().contains(where: {
                $0.identifier == candidate.identifier
            }) {
                try? EpubReader.delete(identifier: candidate.identifier)
            }
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeMyDocumentModelContainer()
        let service = ExternalDocumentImportService.androidRegistryAware(
            modelContext: ModelContext(container),
            swordManager: manager
        )

        XCTAssertEqual(
            service.importDocument(at: firstURL),
            .installedEpub(title: "Exact initials owner")
        )
        XCTAssertEqual(
            service.importDocument(at: secondURL),
            .failed(
                message: "Cannot import this EPUB because an installed document already owns module identity \(secondCandidate.initials)."
            )
        )

        let libraryRoot = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("epub", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: EpubReader.generationManifestURL(
            identifier: secondCandidate.identifier,
            libraryRootURL: libraryRoot
        ).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: EpubReader.generationContainerURL(
            identifier: secondCandidate.identifier,
            libraryRootURL: libraryRoot
        ).path))
    }

    /**
     Serializes concurrent case-variant EPUB admission through publication like Android `Books`.

     - Setup: Creates two valid EPUBs whose filenames generate Java-case-equivalent but exact-
       distinct initials, constructs one production registry-aware service, and releases two
       background imports from a two-party barrier.
     - Expected: Exactly one archive publishes. The second sees the first in a fresh combined
       registry while holding the EPUB library lock and fails before receiving any manifest,
       generation container, legacy package, or index path.
     - Failure meaning: Detached callers can validate one stale registry snapshot, publish two
       case-equivalent Android books, and leave one installed archive hidden by JSword lookup.
     - Side effects: Writes two temporary EPUB archives and one uniquely named default-library
       generation, then deletes every candidate identity during cleanup.
     - Note: The barrier controls caller start only; the production library lock deliberately
       determines which candidate wins, so assertions are symmetric in the two filenames.
     */
    @MainActor
    func testRegistryAwareConcurrentCaseVariantEpubImportsPublishExactlyOne() throws {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let upperURL = try makeMinimalEpubArchive(
            fileName: "Atomic\(token).epub",
            title: "Upper atomic import"
        )
        let lowerURL = try makeMinimalEpubArchive(
            fileName: "atomic\(token.lowercased()).epub",
            title: "Lower atomic import"
        )
        let urls = [upperURL, lowerURL]
        let identifiers = Dictionary(uniqueKeysWithValues: urls.map { url in
            (
                url,
                EpubReader.stableIdentifier(
                    forSourceFileName: url.lastPathComponent.precomposedStringWithCanonicalMapping
                )
            )
        })
        defer {
            for identifier in identifiers.values
            where EpubReader.installedEpubs().contains(where: { $0.identifier == identifier }) {
                try? EpubReader.delete(identifier: identifier)
            }
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeMyDocumentModelContainer()
        let service = ExternalDocumentImportService.androidRegistryAware(
            modelContext: ModelContext(container),
            swordManager: manager
        )
        let gate = ConcurrentExternalDocumentImportStartGate(participantCount: urls.count)
        let resultLog = ConcurrentExternalDocumentImportResultLog()
        let completion = DispatchGroup()
        let queue = DispatchQueue(
            label: "org.andbible.tests.concurrent-epub-admission",
            qos: .userInitiated,
            attributes: .concurrent
        )

        for url in urls {
            completion.enter()
            queue.async {
                defer { completion.leave() }
                guard gate.arriveAndWait() else {
                    resultLog.append(
                        url: url,
                        result: .failed(message: "concurrent import start barrier timed out")
                    )
                    return
                }
                resultLog.append(url: url, result: service.importDocument(at: url))
            }
        }

        XCTAssertEqual(completion.wait(timeout: .now() + 45), .success)
        let records = resultLog.snapshot()
        let successes = records.filter {
            if case .installedEpub = $0.result { return true }
            return false
        }
        let failures = records.filter {
            if case .failed = $0.result { return true }
            return false
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(failures.count, 1)

        let losingRecord = try XCTUnwrap(failures.first)
        let losingInitials = EpubReader.initials(
            forDisplayFileName: losingRecord.url.lastPathComponent.precomposedStringWithCanonicalMapping
        )
        XCTAssertEqual(
            losingRecord.result,
            .failed(
                message: "Cannot import this EPUB because an installed document already owns module identity \(losingInitials)."
            )
        )
        let losingIdentifier = try XCTUnwrap(identifiers[losingRecord.url])
        let winningIdentifier = try XCTUnwrap(identifiers[try XCTUnwrap(successes.first).url])
        let installedCandidateIDs = Set(
            EpubReader.installedEpubs()
                .map(\.identifier)
                .filter { identifiers.values.contains($0) }
        )
        XCTAssertEqual(installedCandidateIDs, Set([winningIdentifier]))

        let libraryRoot = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("epub", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: EpubReader.generationManifestURL(
            identifier: losingIdentifier,
            libraryRootURL: libraryRoot
        ).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: EpubReader.generationContainerURL(
            identifier: losingIdentifier,
            libraryRootURL: libraryRoot
        ).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: EpubReader.legacyIndexURL(
            identifier: losingIdentifier,
            libraryRootURL: libraryRoot
        ).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(
            losingIdentifier,
            isDirectory: true
        ).path))
    }

    /**
     Rechecks native exact-full-name ownership added after importer construction.

     - Setup: Constructs the production service from an empty native snapshot, then publishes a
       valid native descriptor whose `Description` exactly equals the candidate EPUB initials before
       running the import in the same detached shape used by app entry points.
     - Expected: A fresh manager and combined registry reject the EPUB before manifest/generation
       paths exist, even though the original service instance predates the native owner.
     - Failure meaning: EPUB admission still captures factory-time native metadata and can publish a
       local book that Android's later `Books.getBook(candidate.initials)` resolves to native.
     - Side effects: Writes one temporary SWORD alias and EPUB archive; no EPUB library candidate
       survives, and cleanup removes one accidental publication if the regression returns.
     */
    @MainActor
    func testRegistryAwareImportRejectsNativeFullNameAddedAfterServiceConstruction() async throws {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let archiveURL = try makeMinimalEpubArchive(
            fileName: "LateOwner\(token).epub",
            title: "Late native ownership candidate"
        )
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let sourceFileName = archiveURL.lastPathComponent.precomposedStringWithCanonicalMapping
        let initials = EpubReader.initials(forDisplayFileName: sourceFileName)
        let identifier = EpubReader.stableIdentifier(forSourceFileName: sourceFileName)
        defer {
            if EpubReader.installedEpubs().contains(where: { $0.identifier == identifier }) {
                try? EpubReader.delete(identifier: identifier)
            }
        }

        let modulePath = try makeTemporarySwordFixturePath()
        let originalManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeMyDocumentModelContainer()
        let service = ExternalDocumentImportService.androidRegistryAware(
            modelContext: ModelContext(container),
            swordManager: originalManager
        )
        try seedBibleAliasModule(
            named: "LateNative\(token)",
            description: initials,
            in: modulePath
        )
        let moduleCacheURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/modules-conf.cache", isDirectory: false)
        if FileManager.default.fileExists(atPath: moduleCacheURL.path) {
            try FileManager.default.removeItem(at: moduleCacheURL)
        }
        let refreshedManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertTrue(refreshedManager.installedModules().contains {
            $0.description == initials
        })

        let result = await Task.detached(priority: .userInitiated) {
            service.importDocument(at: archiveURL)
        }.value

        XCTAssertEqual(
            result,
            .failed(
                message: "Cannot import this EPUB because an installed document already owns module identity \(initials)."
            )
        )
        let libraryRoot = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("epub", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: EpubReader.generationManifestURL(
            identifier: identifier,
            libraryRootURL: libraryRoot
        ).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: EpubReader.generationContainerURL(
            identifier: identifier,
            libraryRootURL: libraryRoot
        ).path))
    }

    /**
     Fails EPUB admission closed when one discovered SQLite registration is malformed.

     - Setup: Places an unreadable MyBible candidate beneath the live SWORD root, then imports an
       otherwise valid uniquely identified EPUB through the production registry-aware service.
     - Expected: Strict SQLite discovery surfaces its diagnostic and the candidate receives no
       manifest, generation container, legacy package, or index artifact.
     - Failure meaning: Suppressing a broken SQLite registration can admit an EPUB identity without
       proving whether Android's earlier SQLite driver would own it.
     - Side effects: Writes and removes one temporary malformed database plus one EPUB archive; the
       default EPUB library is read only.
     */
    @MainActor
    func testRegistryAwareImportRejectsUnreadableSQLiteRegistryWithoutArtifacts() throws {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let archiveURL = try makeMinimalEpubArchive(
            fileName: "UnreadableSQLite\(token).epub",
            title: "Strict SQLite admission candidate"
        )
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let candidate = EpubReader.installCandidate(forEpubURL: archiveURL)
        defer {
            if EpubReader.installedEpubs().contains(where: {
                $0.identifier == candidate.identifier
            }) {
                try? EpubReader.delete(identifier: candidate.identifier)
            }
        }

        let modulePath = try makeTemporarySwordFixturePath()
        let myBibleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mybible", isDirectory: true)
        try FileManager.default.createDirectory(
            at: myBibleRoot,
            withIntermediateDirectories: true
        )
        let malformedDatabase = myBibleRoot.appendingPathComponent("Broken.SQLite3")
        try Data("not a SQLite database".utf8).write(to: malformedDatabase)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeMyDocumentModelContainer()
        let service = ExternalDocumentImportService.androidRegistryAware(
            modelContext: ModelContext(container),
            swordManager: manager
        )
        let libraryRoot = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("epub", isDirectory: true)
        let libraryRootExistedBefore = FileManager.default.fileExists(atPath: libraryRoot.path)

        let result = service.importDocument(at: archiveURL)

        guard case .failed(let message) = result else {
            return XCTFail("Expected strict SQLite registration failure, received \(result)")
        }
        XCTAssertTrue(message.contains("installed document registry could not be read"))
        XCTAssertTrue(message.contains(malformedDatabase.lastPathComponent))
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: libraryRoot.path),
            libraryRootExistedBefore
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: EpubReader.generationManifestURL(
            identifier: candidate.identifier,
            libraryRootURL: libraryRoot
        ).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: EpubReader.generationContainerURL(
            identifier: candidate.identifier,
            libraryRootURL: libraryRoot
        ).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: EpubReader.legacyIndexURL(
            identifier: candidate.identifier,
            libraryRootURL: libraryRoot
        ).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(
            candidate.identifier,
            isDirectory: true
        ).path))
    }

    /**
     Allows EPUB publication when valid SQLite siblings collide only during Android replay.

     - Setup: Installs the matching `.bblx`/`.bbli` fixtures that produce one deterministic
       duplicate diagnostic, then imports a uniquely identified EPUB through production wiring.
     - Expected result: Strict discovery retains both candidates, replay omits the later duplicate,
       and the unrelated EPUB publishes successfully.
     - Failure meaning: A normal Android-resolved duplicate makes strict iOS admission globally
       unusable even though no SQLite ownership is uncertain.
     - Side effects: Copies two SQLite fixtures and publishes/removes one default-library EPUB.
     */
    @MainActor
    func testRegistryAwareImportAllowsDeterministicSQLiteDuplicateDiagnostic() throws {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let archiveURL = try makeMinimalEpubArchive(
            fileName: "ValidDuplicate\(token).epub",
            title: "Valid duplicate SQLite registry"
        )
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let candidate = EpubReader.installCandidate(forEpubURL: archiveURL)
        defer {
            if EpubReader.installedEpubs().contains(where: {
                $0.identifier == candidate.identifier
            }) {
                try? EpubReader.delete(identifier: candidate.identifier)
            }
        }
        let modulePath = try makeTemporarySwordFixturePath()
        try installDeterministicDuplicateSQLiteFixtures(modulePath: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeMyDocumentModelContainer()
        let service = ExternalDocumentImportService.androidRegistryAware(
            modelContext: ModelContext(container),
            swordManager: manager
        )

        XCTAssertEqual(
            service.importDocument(at: archiveURL),
            .installedEpub(title: "Valid duplicate SQLite registry")
        )
        XCTAssertTrue(EpubReader.installedEpubs().contains {
            $0.identifier == candidate.identifier
        })
    }

    /**
     Allows strict My Documents publication beside an Android-resolved SQLite duplicate.

     - Setup: Installs two readable same-identity e-Sword fixtures and prepares one unique draft.
     - Expected result: Combined strict replay admits the draft and commits exactly one row.
     - Failure meaning: Typed non-blocking duplicate diagnostics are not propagated through the
       production My Documents admission path.
     - Side effects: Copies fixtures and writes one row to an in-memory SwiftData container.
     */
    @MainActor
    func testStrictRegistryMyDocumentSaveAllowsDeterministicSQLiteDuplicateDiagnostic() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installDeterministicDuplicateSQLiteFixtures(modulePath: modulePath)
        let container = try makeMyDocumentModelContainer()
        let store = MyDocumentLibraryStore(
            modelContext: ModelContext(container),
            moduleStoreRootURL: URL(fileURLWithPath: modulePath, isDirectory: true)
        )
        var session = try store.loadSession()
        let initials = "DuplicateSafeMyDoc\(UUID().uuidString)"
        _ = try session.createDocument(name: "Duplicate-safe My Document", initials: initials)

        try saveMyDocumentThroughStrictRegistry(
            &session,
            store: store,
            modelContainer: container,
            modulePath: modulePath
        )

        XCTAssertEqual(try store.loadSession().documents.map(\.initials), [initials])
    }

    /**
     Allows first-time AI Documents publication beside an Android-resolved SQLite duplicate.

     - Setup: Installs two readable same-identity e-Sword fixtures and wires the generated-page
       store to the same strict combined snapshot used by the app.
     - Expected result: The AI Documents row, page, content, and cache entry commit together.
     - Failure meaning: Deterministic duplicate diagnostics remain an accidental global outage for
       an identity publisher other than EPUB or interactive My Documents.
     - Side effects: Copies fixtures and writes one generated graph to in-memory SwiftData.
     */
    @MainActor
    func testStrictRegistryAIDocumentsSaveAllowsDeterministicSQLiteDuplicateDiagnostic() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installDeterministicDuplicateSQLiteFixtures(modulePath: modulePath)
        let container = try makeMyDocumentModelContainer()
        let store = AIGeneratedPageStore(
            modelContext: ModelContext(container),
            moduleStoreRootURL: URL(fileURLWithPath: modulePath, isDirectory: true),
            isDocumentInitialsUnavailable: { initials in
                try BibleReaderInstalledDocumentRegistrySnapshot.capture(
                    modelContainer: container,
                    modulePath: modulePath
                ).ownsDocument(named: initials)
            }
        )

        let location = try store.save(
            content: "Generated beside a deterministic SQLite duplicate",
            title: "Generated",
            promptID: UUID(),
            context: CacheableContext(
                kjvOrdinalStart: nil,
                kjvOrdinalEnd: nil,
                activeDocumentInitials: "KJV",
                selectedContent: nil,
                selectedText: nil,
                highlightedText: nil,
                selectionStartOffset: nil,
                selectionEndOffset: nil
            ),
            usedWriteTools: false,
            sourceModelName: nil
        )

        let verification = ModelContext(container)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<MyDocument>()).map(\.initials),
            [AIGeneratedPageStore.documentInitials]
        )
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<MyDocumentPage>()).map(\.id),
            [location.pageID]
        )
        XCTAssertEqual(try verification.fetch(FetchDescriptor<AiPageCacheEntry>()).count, 1)
    }

    /**
     Publishes a new My Documents identity when every Android registry source is readable.

     - Setup: Creates one uniquely identified draft against an isolated healthy SWORD root and an
       empty in-memory My Documents store, then saves through the production strict snapshot.
     - Expected: The save commits exactly one row and advances the editable session baseline.
     - Failure meaning: Fail-closed admission blocks ordinary My Documents creation even though the
       complete native, SQLite, EPUB, and My Documents registry can be captured.
     - Side effects: Persists one row only in an in-memory SwiftData container.
     */
    @MainActor
    func testStrictRegistryMyDocumentSavePublishesWhenEverySourceIsReadable() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let container = try makeMyDocumentModelContainer()
        let store = MyDocumentLibraryStore(
            modelContext: ModelContext(container),
            moduleStoreRootURL: URL(fileURLWithPath: modulePath, isDirectory: true)
        )
        var session = try store.loadSession()
        let initials = "StrictMyDoc\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        _ = try session.createDocument(name: "Strict registry document", initials: initials)

        try saveMyDocumentThroughStrictRegistry(
            &session,
            store: store,
            modelContainer: container,
            modulePath: modulePath
        )

        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(try store.loadSession().documents.map(\.initials), [initials])
    }

    /**
     Rejects a My Documents publication when SQLite ownership cannot be enumerated completely.

     - Setup: Adds one malformed MyBible database to an isolated live SWORD root and prepares one
       new My Documents draft before invoking the production strict snapshot under the global gate.
     - Expected: Save throws a typed registry error naming the malformed file, leaves the session
       dirty, preserves the corrupt fixture byte-for-byte, and persists no document.
     - Failure meaning: My Documents can claim an identity while an earlier Android SQLite driver
       has unknown ownership, or validation mutates storage before it knows admission is safe.
     - Side effects: Writes one temporary malformed SQLite fixture; SwiftData remains empty.
     */
    @MainActor
    func testStrictRegistryMyDocumentSaveRejectsMalformedSQLiteWithoutPersistence() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let moduleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
        let myBibleRoot = moduleRoot.appendingPathComponent("mybible", isDirectory: true)
        try FileManager.default.createDirectory(at: myBibleRoot, withIntermediateDirectories: true)
        let malformedDatabase = myBibleRoot.appendingPathComponent(
            "Broken-MyDocument-\(UUID().uuidString).SQLite3"
        )
        let malformedBytes = Data("not a SQLite database".utf8)
        try malformedBytes.write(to: malformedDatabase)

        let container = try makeMyDocumentModelContainer()
        let store = MyDocumentLibraryStore(
            modelContext: ModelContext(container),
            moduleStoreRootURL: moduleRoot
        )
        var session = try store.loadSession()
        _ = try session.createDocument(
            name: "Rejected SQLite uncertainty",
            initials: "RejectedSQLite\(UUID().uuidString)"
        )

        XCTAssertThrowsError(try saveMyDocumentThroughStrictRegistry(
            &session,
            store: store,
            modelContainer: container,
            modulePath: modulePath
        )) { error in
            guard let registryError = error as? BibleReaderInstalledDocumentRegistrySnapshotError
            else {
                return XCTFail("Expected strict registry error, received \(error)")
            }
            XCTAssertTrue(registryError.detail.contains(malformedDatabase.lastPathComponent))
        }

        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(try store.loadSession().documents.isEmpty)
        XCTAssertEqual(try Data(contentsOf: malformedDatabase), malformedBytes)
    }

    /**
     Rejects a My Documents publication when the current EPUB registry is corrupt.

     - Setup: Writes one uniquely named malformed generation pointer into the app EPUB library and
       prepares one new draft against an otherwise healthy isolated SWORD root.
     - Expected: Strict admission throws before the SwiftData delta is applied, leaves the draft
       dirty, keeps the malformed pointer unchanged, and persists no document or page.
     - Failure meaning: A corrupt earlier EPUB registration can be treated as missing and allow a
       hidden My Documents owner, or failed admission can leak a partial durable graph.
     - Side effects: Temporarily writes one malformed pointer and removes only that exact fixture;
       the in-memory SwiftData container remains empty.
     */
    @MainActor
    func testStrictRegistryMyDocumentSaveRejectsCorruptEpubWithoutPersistence() throws {
        let fileManager = FileManager.default
        let libraryRoot = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("epub", isDirectory: true)
        let libraryRootExistedBefore = fileManager.fileExists(atPath: libraryRoot.path)
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let corruptIdentifier = "corrupt-mydoc-\(UUID().uuidString)"
        let corruptPointer = EpubReader.generationManifestURL(
            identifier: corruptIdentifier,
            libraryRootURL: libraryRoot
        )
        let corruptBytes = Data("not a generation manifest".utf8)
        XCTAssertFalse(fileManager.fileExists(atPath: corruptPointer.path))
        try corruptBytes.write(to: corruptPointer)
        defer {
            try? fileManager.removeItem(at: corruptPointer)
            if !libraryRootExistedBefore,
               let remainingChildren = try? fileManager.contentsOfDirectory(
                   at: libraryRoot,
                   includingPropertiesForKeys: nil
               ),
               remainingChildren.isEmpty {
                try? fileManager.removeItem(at: libraryRoot)
            }
        }

        let modulePath = try makeTemporarySwordFixturePath()
        let container = try makeMyDocumentModelContainer()
        let store = MyDocumentLibraryStore(
            modelContext: ModelContext(container),
            moduleStoreRootURL: URL(fileURLWithPath: modulePath, isDirectory: true)
        )
        var session = try store.loadSession()
        _ = try session.createDocument(
            name: "Rejected EPUB uncertainty",
            initials: "RejectedEpub\(UUID().uuidString)"
        )

        XCTAssertThrowsError(try saveMyDocumentThroughStrictRegistry(
            &session,
            store: store,
            modelContainer: container,
            modulePath: modulePath
        )) { error in
            XCTAssertTrue(error is BibleReaderInstalledDocumentRegistrySnapshotError)
        }

        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(try store.loadSession().documents.isEmpty)
        XCTAssertEqual(try Data(contentsOf: corruptPointer), corruptBytes)
    }

    /**
     Installs the readable e-Sword fixtures whose shared identity yields one Android omission.

     - Parameter modulePath: Isolated SWORD root that receives an `esword` family directory.
     - Side effects: Creates the family root and copies the checked-in `.bblx` and `.bbli` files.
     - Throws: Filesystem discovery, directory creation, or copy failures.
     */
    private func installDeterministicDuplicateSQLiteFixtures(modulePath: String) throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureRoot = repositoryRoot
            .appendingPathComponent("Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders")
        let destinationRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("esword", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        for name in ["sample.bblx", "sample.bbli"] {
            try FileManager.default.copyItem(
                at: fixtureRoot.appendingPathComponent(name),
                to: destinationRoot.appendingPathComponent(name)
            )
        }
    }

    /**
     Saves one management session through the production complete-registry admission contract.

     - Parameters:
       - session: Editable My Documents graph to validate and publish.
       - store: Transactional publisher configured for the same `modulePath` root.
       - modelContainer: Current My Documents storage included in registry replay.
       - modulePath: Canonical SWORD root containing native and SQLite registrations.
     - Side effects: Acquires the global book mutation lease, captures every registry source for
       each new initials candidate, and commits the session only when no owner resolves.
     - Throws: Strict native, SQLite, EPUB, My Documents, validation, or persistence failures.
     */
    @MainActor
    private func saveMyDocumentThroughStrictRegistry(
        _ session: inout MyDocumentManagementSession,
        store: MyDocumentLibraryStore,
        modelContainer: ModelContainer,
        modulePath: String
    ) throws {
        try store.save(&session, checkingInitialsWith: { initials in
            try BibleReaderInstalledDocumentRegistrySnapshot.capture(
                modelContainer: modelContainer,
                modulePath: modulePath
            ).ownsDocument(named: initials)
        })
    }

    /**
     Writes one minimal valid EPUB 3 archive at a caller-controlled identity-bearing filename.

     - Parameters:
       - fileName: Basename whose exact spelling drives stable identifier and Android initials.
       - title: Package title used to distinguish concurrent success results.
     - Returns: Archive URL inside a unique caller-owned temporary directory.
     - Side effects: Creates the directory and writes one stored ZIP containing OCF, OPF, nav, and
       XHTML spine entries.
     - Throws: Filesystem and deterministic ZIP-writer errors.
     */
    private func makeMinimalEpubArchive(fileName: String, title: String) throws -> URL {
        precondition((fileName as NSString).lastPathComponent == fileName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "external-epub-admission-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent(fileName)
        try writeMinimalEpubArchive(at: archiveURL, title: title)
        return archiveURL
    }

    /**
     Writes the minimal valid EPUB fixture at an exact caller-owned source URL.

     - Parameters:
       - archiveURL: Exact archive path whose basename controls EPUB identity.
       - title: Package title persisted into the generated index.
     - Side effects: Atomically creates or replaces one stored ZIP archive.
     - Throws: Deterministic ZIP serialization or filesystem write errors.
     */
    private func writeMinimalEpubArchive(at archiveURL: URL, title: String) throws {
        let entries: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles>
                <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """),
            ("OPS/package.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(title)</dc:title><dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="page" href="page.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="page"/></spine>
            </package>
            """),
            ("OPS/nav.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
              <body><nav epub:type="toc"><ol><li><a href="page.xhtml">Page</a></li></ol></nav></body>
            </html>
            """),
            ("OPS/page.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml"><body><p>Atomic admission body.</p></body></html>
            """),
        ]
        try ZipArchiveWriter.storedArchive(entries: entries.map {
            ZipArchiveWriterEntry(name: $0.0, data: Data($0.1.utf8))
        }).write(to: archiveURL, options: .atomic)
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
            epubCandidateAdmission: { _ in },
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
            epubCandidateAdmission: { _ in },
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
            epubCandidateAdmission: { _ in },
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
            epubCandidateAdmission: { _ in },
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
            epubCandidateAdmission: { _ in },
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
            epubCandidateAdmission: { _ in },
            fontInstaller: { _, _ in "unused" }
        )

        let result = service.importDocument(at: URL(fileURLWithPath: "/tmp/invalid.zip"))

        XCTAssertEqual(result, .failed(message: "installer rejected file"))
        XCTAssertEqual(result.feedbackMessage, "Error: installer rejected file")
        XCTAssertFalse(result.usesAndroidInstallToastFeedback)
    }
}
