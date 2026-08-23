// ExternalDocumentImportService.swift -- shared installer for documents opened from Files or Settings

import Foundation
import UniformTypeIdentifiers
import BibleCore
import SwiftData
import SwordKit

/**
 File-open request delivered by iOS document interaction or an in-app picker.

 The request carries the URL plus optional provider metadata so routing can prefer MIME/UTType
 information when iOS supplies it, while still falling back to filename and archive inspection for
 Files/Mail providers that only expose a temporary file URL.
 */
public struct ExternalDocumentImportRequest: Equatable, Sendable {
    /// Local or security-scoped URL for the selected document.
    public let url: URL

    /// Optional UTType identifier supplied by a document provider.
    public let contentTypeIdentifier: String?

    /// Optional provider display name used by Android-parity font installation.
    public let suggestedFileName: String?

    /**
     Normalized display filename used by confirmation prompts and font installation metadata.

     Provider metadata can arrive with leading/trailing whitespace or path-like separators. The
     importer treats that metadata as a display filename, not an arbitrary path, and falls back to
     the URL basename when the provider value is missing or blank.

     - Returns: Non-empty basename from provider metadata or the URL, or `nil` when both are empty.
     - Side effects: none.
     - Failure modes: This normalization cannot fail.
     */
    public var displayFileName: String? {
        Self.normalizedFileDisplayName(suggestedFileName)
            ?? Self.normalizedFileDisplayName(url.lastPathComponent)
    }

    /**
     Creates an import request from a document URL and optional provider metadata.

     - Parameters:
       - url: File URL delivered by document open, share, or file importer surfaces.
       - contentTypeIdentifier: Optional UTType identifier such as `public.zip-archive`.
       - suggestedFileName: Optional provider display name when it differs from the URL basename.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(url: URL, contentTypeIdentifier: String? = nil, suggestedFileName: String? = nil) {
        self.url = url
        self.contentTypeIdentifier = contentTypeIdentifier
        self.suggestedFileName = suggestedFileName
    }

    /**
     Converts an external provider filename into a stable non-empty basename.

     - Parameter value: Optional provider or URL-derived filename.
     - Returns: Trimmed basename, or `nil` when the candidate is absent or blank.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func normalizedFileDisplayName(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let baseName = (value as NSString).lastPathComponent
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/** Fail-closed identity conflicts detected before an external document mutates local storage. */
private enum ExternalDocumentRegistryAdmissionError: LocalizedError {
    /// Android's complete installed-book registry already resolves the candidate EPUB initials.
    case epubIdentityOwned(String)

    /// One current registry source could not be read completely enough to make a safe decision.
    case registryUnavailable(String)

    /// User-facing failure surfaced by every external import entry point.
    var errorDescription: String? {
        switch self {
        case .epubIdentityOwned(let initials):
            return "Cannot import this EPUB because an installed document already owns module identity \(initials)."
        case .registryUnavailable(let message):
            return "Cannot import this EPUB because the installed document registry could not be read: \(message)"
        }
    }
}

/**
 Installs user-selected documents that Android exposes through its external document intents.

 Android routes shared/opened module packages through `InstallZip`; iOS uses this shared service
 from both the Backup & Restore document picker and the SwiftUI scene `.onOpenURL` entry point so
 the same ZIP/EPUB/TTF/image/CSV/SQLite semantics are applied regardless of where the file came from.

 Side effects:
 - reads security-scoped file URLs while access is active
 - installs SWORD ZIP modules through `ModuleRepository`
 - inspects and transactionally restores Android module backups through `AndroidModuleBackupService`
 - installs EPUB archives through `EpubReader`
 - installs app-owned TTF font addons through `TtfFontRepository`
 - installs image, prompt, and SQLite families through `AndroidModuleBackupService`

 Failure modes:
 - unsupported document types return `.unsupportedFormat` without touching installers
 - installer errors are converted to `.failed` so callers can show the existing localized feedback
 */
public struct ExternalDocumentImportService: Sendable {
    /// Legacy closure used to install SWORD ZIP modules; retained for source-compatible tests.
    public typealias ModuleInstaller = @Sendable (URL) throws -> String

    /// Closure used to inspect SWORD ZIP layout, storage demand, and destination conflicts.
    public typealias ModuleInspector = @Sendable (URL) throws -> LocalSwordZipInspection

    /// Phase-aware SWORD installer that requires an explicit overwrite policy.
    public typealias ModuleInstallerWithPolicy = @Sendable (
        URL,
        LocalSwordZipOverwritePolicy,
        (@Sendable (ModuleInstallProgress) -> Void)?
    ) throws -> String

    /// Closure used to install EPUB archives; injectable for focused tests.
    public typealias EpubInstaller = @Sendable (URL) throws -> String

    /// Legacy initials-only predicate retained for source-compatible focused installer tests.
    public typealias EpubInitialsUnavailable = @Sendable (String) -> Bool

    /**
     Throwing live admission that can distinguish an exact EPUB update from another owner.

     - Parameter candidate: Stable source identifier plus Android-compatible EPUB initials.
     - Side effects: Production implementations read native, SQLite, EPUB, and My Documents state.
     - Throws: Identity ownership or registry availability errors before candidate mutation.
     */
    public typealias EpubCandidateAdmission = @Sendable (
        EpubReader.InstallCandidate
    ) throws -> Void

    /**
     Installs one EPUB using the resolved legacy or lock-aware production path.

     - Parameters:
       - url: Candidate archive URL.
       - admission: Live combined-registry validator evaluated before candidate mutation.
     - Returns: Installed title, falling back to the stable identifier when reopening fails.
     - Side effects: The production path stages and publishes one EPUB after admission.
     - Throws: Propagates registry-admission, validation, indexing, and filesystem errors.
     */
    private typealias RegistryAdmittingEpubInstaller = @Sendable (
        URL,
        EpubCandidateAdmission
    ) throws -> String

    /// Closure used to install Android-style app-owned TTF font files; injectable for tests.
    public typealias FontInstaller = @Sendable (URL, String?) throws -> String

    /// Closure used to install one Android raw-family file through transactional module publication.
    public typealias AndroidFamilyFileInstaller = @Sendable (
        URL,
        String,
        AndroidModuleBackupExternalFileFamily,
        LocalSwordZipOverwritePolicy
    ) throws -> String

    /**
     Legacy Android backup installer retained for source-compatible focused tests.

     The closure receives an archive URL and returns a restore report or throws. It has no overwrite
     policy input, so production callers must leave this injection `nil` and use the policy-aware
     default or `AndroidModuleBackupInstallerWithPolicy` instead.
     */
    public typealias AndroidModuleBackupInstaller = @Sendable (URL) throws -> AndroidModuleBackupRestoreReport

    /**
     Read-only Android backup inspector used before any restore is authorized.

     The closure receives a file-backed archive URL, returns its fully validated module/layout/conflict
     summary, performs archive and destination reads only, and propagates validation or I/O errors.
     */
    public typealias AndroidModuleBackupInspector = @Sendable (URL) throws -> AndroidModuleBackupInspection

    /**
     Android backup installer that receives the caller's explicit overwrite policy.

     The closure receives the archive URL plus reject-or-replace authorization, returns the committed
     restore report, may transactionally mutate module storage, and propagates validation, conflict,
     filesystem, or rollback errors.
     */
    public typealias AndroidModuleBackupInstallerWithPolicy = @Sendable (
        URL,
        LocalSwordZipOverwritePolicy
    ) throws -> AndroidModuleBackupRestoreReport

    /// Closure used to detect Android module backups when provider filenames are rewritten.
    public typealias AndroidModuleBackupDetector = @Sendable (URL) -> Bool

    /// Closure used to detect EPUB files that arrive through ZIP-looking providers.
    public typealias EpubArchiveDetector = @Sendable (URL) -> Bool

    /// Content types accepted by the Android-parity documents importer.
    public static var supportedContentTypes: [UTType] {
        [.zip, .epub, trueTypeFontType, .image, .data]
    }

    /// Dynamic UTType for TrueType fonts, with a non-generic fallback to avoid matching `.data`.
    private static var trueTypeFontType: UTType {
        UTType("public.truetype-ttf-font")
            ?? UTType(filenameExtension: "ttf")
            ?? UTType(exportedAs: "org.andbible.truetype-font", conformingTo: .data)
    }

    /// Read-only SWORD archive inspector called before UI confirmation.
    private let moduleInspector: ModuleInspector

    /// SWORD module installer called for `.zip` files after preflight.
    private let moduleInstaller: ModuleInstallerWithPolicy

    /**
     EPUB installer that evaluates complete-registry admission at its mutation boundary.

     The production implementation delegates to `EpubReader`'s library-lock-owned admission API.
     A legacy injected `EpubInstaller` is wrapped with a synchronous precheck immediately before
     invocation; that compatibility path does not promise cross-call serialization.
     */
    private let epubInstaller: RegistryAdmittingEpubInstaller

    /// Complete installed/local registry admission check evaluated before EPUB file mutation.
    private let epubCandidateAdmission: EpubCandidateAdmission

    /// TTF font installer called for Android's font import path.
    private let fontInstaller: FontInstaller

    /// Transactional installer for Android background, prompt, and SQLite families.
    private let androidFamilyFileInstaller: AndroidFamilyFileInstaller

    /// Read-only Android module-backup inspector called before UI confirmation.
    private let androidModuleBackupInspector: AndroidModuleBackupInspector

    /// Policy-aware Android module-backup installer called after preflight.
    private let androidModuleBackupInstaller: AndroidModuleBackupInstallerWithPolicy

    /// Android module-backup detector called for ZIP files whose names are not enough.
    private let androidModuleBackupDetector: AndroidModuleBackupDetector

    /// EPUB detector used for Android's ZIP-to-EPUB fallback behavior.
    private let epubArchiveDetector: EpubArchiveDetector

    /**
      Creates a document import service.

      - Parameters:
          - moduleInstaller: Optional source-compatible installer used by focused tests. Production
              callers leave it `nil` so policy-aware installation remains authoritative.
          - moduleInspector: Read-only inspector for ZIP-backed SWORD modules.
          - moduleInstallerWithPolicy: Optional policy-aware installer. The default mutates the
              app's SWORD module storage, reports durable phases, and returns the module identifier.
          - epubInstaller: Optional legacy installer for isolated routing tests. When supplied, the
              resolved typed admission runs synchronously immediately before this closure, but the
              injected closure owns serialization. This compatibility boundary cannot make a
              caller-provided installer atomic across concurrent invocations.
          - epubCandidateAdmission: Preferred throwing complete-registry validator. Production
              callers use `androidRegistryAware(modelContext:swordManager:)`, which rebuilds live
              ownership on every invocation and permits only an exact same-identifier EPUB update.
          - epubInitialsUnavailable: Legacy initials-only validator wrapped as a typed rejecting
              admission when `epubCandidateAdmission` is absent.
          - moduleStoreRootURL: Canonical SWORD root whose global coordinator serializes the
              production EPUB admission, staging, pointer publication, and rollback boundary.
          - fontInstaller: Installer for TTF font files. The default copies the font into the SWORD
              `ttf` directory and writes Android-style addon metadata.
          - androidFamilyFileInstaller: Installer for image, prompt, MyBible, MySword, and e-Sword
              files. The default streams one file through the Android backup transaction.
          - androidModuleBackupInstaller: Optional source-compatible Android backup installer used
              by focused tests. Production callers leave it `nil` so overwrite policy remains
              authoritative.
          - androidModuleBackupInspector: Read-only Android backup inspector that validates every
              entry and discovers canonical destination conflicts.
          - androidModuleBackupInstallerWithPolicy: Optional policy-aware Android backup installer.
              The default restores through `AndroidModuleBackupService` with overwrites disabled
              unless the caller supplies confirmed replacement authorization.
          - androidModuleBackupDetector: Read-only archive classifier for ZIPs whose provider
              filenames no longer preserve Android's `.abmd.zip` suffix.
          - epubArchiveDetector: ZIP inspector used to reroute EPUB archives that arrive as ZIP.
      - Side effects: none during initialization; installer closures perform file I/O when invoked.
      - Failure modes: This initializer cannot fail.
      */
    public init(
        moduleInstaller: ModuleInstaller? = nil,
        moduleInspector: @escaping ModuleInspector = { url in
            try ModuleRepository().inspectLocalSwordZip(at: url)
        },
        moduleInstallerWithPolicy: ModuleInstallerWithPolicy? = nil,
        epubInstaller: EpubInstaller? = nil,
        epubCandidateAdmission: EpubCandidateAdmission? = nil,
        epubInitialsUnavailable: @escaping EpubInitialsUnavailable = { _ in false },
        moduleStoreRootURL: URL = URL(
            fileURLWithPath: SwordManager.defaultModulePath(),
            isDirectory: true
        ),
        fontInstaller: @escaping FontInstaller = { url, displayName in
            try TtfFontRepository().installFont(from: url, displayName: displayName).fontName
        },
        androidFamilyFileInstaller: AndroidFamilyFileInstaller? = nil,
        androidModuleBackupInstaller: AndroidModuleBackupInstaller? = nil,
        androidModuleBackupInspector: @escaping AndroidModuleBackupInspector = { url in
            try AndroidModuleBackupService().inspectArchive(fromArchiveAt: url)
        },
        androidModuleBackupInstallerWithPolicy: AndroidModuleBackupInstallerWithPolicy? = nil,
        androidModuleBackupDetector: AndroidModuleBackupDetector? = nil,
        epubArchiveDetector: EpubArchiveDetector? = nil
    ) {
        self.moduleInspector = moduleInspector
        if let moduleInstallerWithPolicy {
            self.moduleInstaller = moduleInstallerWithPolicy
        } else if let moduleInstaller {
            self.moduleInstaller = { url, _, _ in
                try moduleInstaller(url)
            }
        } else {
            self.moduleInstaller = { url, overwritePolicy, progressState in
                try ModuleRepository().installFromZip(
                    at: url,
                    overwritePolicy: overwritePolicy,
                    progressState: progressState
                )
            }
        }
        let resolvedEpubAdmission: EpubCandidateAdmission = epubCandidateAdmission ?? { candidate in
            guard !epubInitialsUnavailable(candidate.initials) else {
                throw ExternalDocumentRegistryAdmissionError.epubIdentityOwned(candidate.initials)
            }
        }
        if let epubInstaller {
            self.epubInstaller = { url, admission in
                try admission(EpubReader.installCandidate(forEpubURL: url))
                return try epubInstaller(url)
            }
        } else {
            self.epubInstaller = { url, admission in
                let identifier = try EpubReader.install(
                    epubURL: url,
                    moduleStoreRootURL: moduleStoreRootURL,
                    admittingCandidateWith: admission
                )
                return EpubReader(identifier: identifier)?.title ?? identifier
            }
        }
        self.epubCandidateAdmission = resolvedEpubAdmission
        self.fontInstaller = fontInstaller
        self.androidFamilyFileInstaller = androidFamilyFileInstaller ?? { url, fileName, family, policy in
            let report = try AndroidModuleBackupService().restoreExternalFile(
                from: url,
                displayFileName: fileName,
                family: family,
                overwritePolicy: policy
            )
            guard let moduleName = report.installedModuleNames.first else {
                throw AndroidModuleBackupError.noSupportedModules([fileName])
            }
            return moduleName
        }
        self.androidModuleBackupInspector = androidModuleBackupInspector
        if let androidModuleBackupInstallerWithPolicy {
            self.androidModuleBackupInstaller = androidModuleBackupInstallerWithPolicy
        } else if let androidModuleBackupInstaller {
            self.androidModuleBackupInstaller = { url, _ in
                try androidModuleBackupInstaller(url)
            }
        } else {
            self.androidModuleBackupInstaller = { url, overwritePolicy in
                try AndroidModuleBackupService().restoreArchive(
                    fromArchiveAt: url,
                    overwritePolicy: overwritePolicy
                )
            }
        }
        self.androidModuleBackupDetector = androidModuleBackupDetector ?? { url in
            Self.defaultAndroidModuleBackupDetector(url)
        }
        self.epubArchiveDetector = epubArchiveDetector ?? { url in
            Self.defaultEpubArchiveDetector(url)
        }
    }

    /**
     Creates the production importer with Android's complete live EPUB registration admission.

     - Parameters:
       - modelContext: SwiftData context whose container owns current My Documents metadata.
       - swordManager: Manager whose module-storage path identifies the native registry. The
         supplied manager is not snapshotted; admission opens a fresh manager at that path.
     - Returns: Import service whose EPUB branch rejects any candidate initials currently resolved
       by native, SQLite, admitted EPUB, or admitted My Documents books, except an exact stable-ID
       reinstall of the EPUB that already owns the identity.
     - Side effects: Captures only the SwiftData container and SWORD module path; every EPUB
       admission opens fresh native, SQLite, EPUB, and My Documents snapshots in Android order
       while the global module-store lease and EPUB library lock are held. Later successful import
       calls perform their documented file writes.
     - Failure modes: Any existing registry read failure closes EPUB admission before candidate
       staging. Other document kinds preserve the default importer behavior.
     */
    @MainActor
    public static func androidRegistryAware(
        modelContext: ModelContext,
        swordManager: SwordManager? = nil
    ) -> ExternalDocumentImportService {
        let modelContainer = modelContext.container
        let modulePath = swordManager?.modulePath
            ?? SwordManager.defaultModulePath()
        let moduleRootURL = URL(fileURLWithPath: modulePath, isDirectory: true)
        return ExternalDocumentImportService(
            epubCandidateAdmission: { candidate in
                do {
                    let snapshot = try BibleReaderInstalledDocumentRegistrySnapshot.capture(
                        modelContainer: modelContainer,
                        modulePath: modulePath
                    )
                    guard snapshot.admitsEpub(candidate) else {
                        throw ExternalDocumentRegistryAdmissionError.epubIdentityOwned(
                            candidate.initials
                        )
                    }
                } catch let error as ExternalDocumentRegistryAdmissionError {
                    throw error
                } catch let error as BibleReaderInstalledDocumentRegistrySnapshotError {
                    throw ExternalDocumentRegistryAdmissionError.registryUnavailable(
                        error.detail
                    )
                } catch {
                    throw ExternalDocumentRegistryAdmissionError.registryUnavailable(
                        error.localizedDescription
                    )
                }
            },
            moduleStoreRootURL: moduleRootURL
        )
    }

    /**
     Default Android module-backup detector used when provider filenames have been rewritten.

     - Parameter url: ZIP-like file URL.
     - Returns: `true` when bounded inspection finds Android's external module-archive shape.
     - Side effects: Reads ZIP metadata plus manifest/config entries; does not write files.
     - Failure modes: Malformed, arbitrary, resource-only, and unowned archives return `false`.
     */
    private static func defaultAndroidModuleBackupDetector(_ url: URL) -> Bool {
        AndroidModuleBackupService.recognizesExternalModuleArchive(at: url)
    }

    /**
     Default ZIP-to-EPUB detector used when tests do not inject one.

     - Parameter url: ZIP-like file URL.
     - Returns: `true` when ZIP metadata identifies EPUB structure.
     - Side effects: Reads ZIP metadata from disk.
     - Failure modes: Malformed or unreadable archives return `false`.
     */
    private static func defaultEpubArchiveDetector(_ url: URL) -> Bool {
        ZipArchiveDocumentClassifier().isEpubArchive(url)
    }

    /**
      Imports a supported external document URL.

      The service mirrors Android's implemented document installer behavior for SWORD ZIP packages
      EPUB archives, and app-owned TTF fonts. ZIP files that contain EPUB structure are routed to
      the EPUB installer, matching Android's `installZip` fallback.

      - Parameter url: File URL supplied by Files, Mail, Share, or the in-app document picker.
      - Returns: Structured result that callers can convert to localized feedback.
      - Side effects:
          - starts security-scoped access while the selected file is read
          - installs module, EPUB, or TTF data into app-managed storage when the type is supported
      - Failure modes: Unsupported extensions and installer errors are represented in the returned
          value instead of thrown.
      */
    public func importDocument(at url: URL) -> ExternalDocumentImportResult {
        importDocument(ExternalDocumentImportRequest(url: url))
    }

    /**
     Imports a supported external document request.

     - Parameter request: URL plus optional provider metadata used for UTType/MIME-style routing.
     - Returns: Structured result for presentation.
     - Side effects: Opens security-scoped access while routing and installer file I/O run.
     - Failure modes: Unsupported types and installer failures are represented in the return value.
     */
    public func importDocument(_ request: ExternalDocumentImportRequest) -> ExternalDocumentImportResult {
        importDocument(request, moduleOverwritePolicy: .reject, progressState: nil)
    }

    /**
     Imports a document with explicit local-module overwrite authorization and phase progress.

     - Parameters:
       - request: URL plus optional provider metadata used for routing.
       - moduleOverwritePolicy: Authorization applied to ordinary SWORD ZIP and Android module-backup
         imports. Default entry points use `.reject`; UI surfaces may pass `.replaceExisting` only
         after presenting the preflight conflict list.
       - progressState: Optional durable module-install phase observer.
     - Returns: Structured result for presentation.
     - Side effects: Opens security-scoped access and may install module, EPUB, font, or Android
       module-backup data.
     - Failure modes: Unsupported types and installer failures are represented in the result.
     */
    public func importDocument(
        _ request: ExternalDocumentImportRequest,
        moduleOverwritePolicy: LocalSwordZipOverwritePolicy,
        progressState: (@Sendable (ModuleInstallProgress) -> Void)?
    ) -> ExternalDocumentImportResult {
        guard request.url.isFileURL else {
            return .unsupportedFormat(fileExtension: request.url.pathExtension.lowercased())
        }
        return withSecurityScopedAccess(to: request.url) {
            switch documentKind(for: request) {
            case .androidModuleBackup:
                return installAndroidModuleBackup(
                    at: request.url,
                    overwritePolicy: moduleOverwritePolicy
                )
            case .archive:
                return installArchive(
                    at: request.url,
                    overwritePolicy: moduleOverwritePolicy,
                    progressState: progressState
                )
            case .epub:
                return installEpub(at: request.url)
            case .font:
                return installFont(at: request.url, displayName: request.displayFileName)
            case .androidFamilyFile(let family):
                return installAndroidFamilyFile(
                    at: request.url,
                    displayName: request.displayFileName,
                    family: family,
                    overwritePolicy: moduleOverwritePolicy
                )
            case .unsupported:
                return .unsupportedFormat(fileExtension: request.url.pathExtension.lowercased())
            }
        }
    }

    /**
     Inspects a selected document before import so every SWORD overwrite requires consent.

     Ordinary SWORD ZIPs and Android module backups run their format-specific full validation and
     canonical destination conflict discovery. EPUB, font, and unsupported files return `.ready`
     because they do not write through either SWORD module transaction.

     - Parameter request: External document request to classify and inspect.
     - Returns: Ready state, an overwrite requirement with exact conflicting paths, or a validation
       failure suitable for immediate presentation.
     - Side effects: Opens security-scoped access and reads archive/destination metadata only.
     - Failure modes: SWORD ZIP and Android module-backup inspection failures are captured as
       `.failed` before an overwrite prompt or installer can run.
     */
    public func preflightDocument(
        _ request: ExternalDocumentImportRequest
    ) -> ExternalDocumentImportPreflightResult {
        guard request.url.isFileURL else {
            return .ready
        }
        return withSecurityScopedAccess(to: request.url) {
            switch documentKind(for: request) {
            case .androidModuleBackup:
                do {
                    let inspection = try androidModuleBackupInspector(request.url)
                    guard !inspection.existingEntryPaths.isEmpty else {
                        return .ready
                    }
                    return .moduleOverwriteRequired(
                        LocalSwordZipInspection(
                            moduleNames: inspection.supportedModuleNames,
                            conflictingPaths: inspection.existingEntryPaths,
                            installableEntryCount: inspection.supportedEntryCount,
                            estimatedExpandedBytes: inspection.estimatedExpandedBytes,
                            archiveSHA256: inspection.archiveSHA256
                        )
                    )
                } catch {
                    return .failed(message: ModuleInstallErrorPresentation.detail(for: error))
                }
            case .archive:
                do {
                    let inspection = try moduleInspector(request.url)
                    if inspection.requiresOverwriteConfirmation {
                        return .moduleOverwriteRequired(inspection)
                    }
                    return .ready
                } catch {
                    return .failed(message: error.localizedDescription)
                }
            case .epub, .font, .androidFamilyFile, .unsupported:
                return .ready
            }
        }
    }

    /**
      Imports multiple external documents in order.

      Android accepts `ACTION_SEND_MULTIPLE` streams for its install activity. iOS generally delivers
      document opens one URL at a time, but this batch API keeps the shared import contract capable
      of preserving Android's ordered multi-file behavior.

      - Parameter requests: Ordered external document requests.
      - Returns: One result per request in the same order.
      - Side effects: Runs the same installer side effects as `importDocument(_:)` for each request.
      - Failure modes: Individual failures are captured per result and do not stop later requests.
      */
    public func importDocuments(_ requests: [ExternalDocumentImportRequest]) -> [ExternalDocumentImportResult] {
        requests.map(importDocument(_:))
    }

    /**
      Resolves the Android installer branch for one request.

      - Parameter request: External document request with URL and optional type metadata.
      - Returns: Installer branch to execute.
      - Side effects: Reads URL resource metadata when available.
      - Failure modes: Missing or unrecognized metadata falls back to extension checks.
      */
    private func documentKind(for request: ExternalDocumentImportRequest) -> ExternalDocumentKind {
        let displayName = request.displayFileName ?? request.url.lastPathComponent
        let ext = (displayName as NSString).pathExtension.lowercased()
        let contentTypes = resolvedContentTypes(for: request)
        if ext == "epub" || contentTypes.contains(where: isEpubContentType(_:)) {
            return .epub
        }
        if ext == "ttf" || contentTypes.contains(where: isFontContentType(_:)) {
            return .font
        }
        if ["png", "jpg", "jpeg", "webp"].contains(ext)
            || contentTypes.contains(where: isImageContentType(_:)) {
            return .androidFamilyFile(.background)
        }
        if ext == "csv" || contentTypes.contains(where: isCSVContentType(_:)) {
            return .androidFamilyFile(.prompts)
        }

        let signature = documentContentSignature(at: request.url)
        let isZipDocument = ext == "zip"
            || contentTypes.contains(where: isZipContentType(_:))
            || signature == .zip
        if isZipDocument {
            if epubArchiveDetector(request.url) {
                return .epub
            }
            if androidModuleBackupDetector(request.url) {
                return .androidModuleBackup
            }
            return .archive
        }
        if signature == .sqlite {
            switch ext {
            case "sqlite3": return .androidFamilyFile(.myBible)
            case "mybible": return .androidFamilyFile(.mySword)
            case "bblx", "bbli": return .androidFamilyFile(.eSword)
            default: break
            }
        }
        return .unsupported
    }

    /**
      Restores one Android module backup archive through the backup service.

      Android's external install surface accepts document/module backup ZIPs alongside plain SWORD
      ZIPs. The backup branch must run before generic ZIP installation so manifest validation,
      unsupported Android-only payload reporting, and SWORD cache invalidation remain owned by
      `AndroidModuleBackupService`.

      - Parameters:
          - url: URL for a `.abmd.zip` archive.
          - overwritePolicy: `.reject` unless the user confirmed the exact preflight conflicts.
      - Returns: Android module-backup success or failure feedback.
      - Side effects: On success, transactionally mutates local SWORD module storage through
          `AndroidModuleBackupService`; rejected conflicts leave live storage unchanged.
      - Failure modes: Validation, conflict, and transactional restore errors are captured in the
          returned failure result.
      */
    private func installAndroidModuleBackup(
        at url: URL,
        overwritePolicy: LocalSwordZipOverwritePolicy
    ) -> ExternalDocumentImportResult {
        do {
            let report = try androidModuleBackupInstaller(url, overwritePolicy)
            return .installedAndroidModuleBackup(
                moduleNames: report.installedModuleNames,
                installedEntryCount: report.installedEntryCount
            )
        } catch {
            return .failed(message: ModuleInstallErrorPresentation.detail(for: error))
        }
    }

    /**
      Installs one archive after ZIP structure routing has completed.

      - Parameters:
          - url: URL for a candidate SWORD ZIP or EPUB archive.
          - overwritePolicy: Explicit conflict policy for ordinary SWORD module files.
          - progressState: Optional phase-aware progress observer for SWORD installation.
      - Returns: Module or EPUB success, or failure feedback.
      - Side effects: Mutates local SWORD module storage through `ModuleRepository`.
      - Failure modes: Installer errors are captured in the returned failure result.
      */
    private func installArchive(
        at url: URL,
        overwritePolicy: LocalSwordZipOverwritePolicy,
        progressState: (@Sendable (ModuleInstallProgress) -> Void)?
    ) -> ExternalDocumentImportResult {
        do {
            let moduleName = try moduleInstaller(url, overwritePolicy, progressState)
            return .installedModule(name: moduleName)
        } catch {
            return .failed(message: ModuleInstallErrorPresentation.detail(for: error))
        }
    }

    /**
      Installs one EPUB archive while security-scoped access is active.

      - Parameter url: URL for a candidate EPUB archive.
      - Returns: `.installedEpub` on success or `.failed` with the installer error description.
      - Side effects: Mutates local EPUB extracted storage and index files through `EpubReader`.
      - Failure modes: A complete-registry identity owner rejects the candidate before production
          staging; EPUB validation, ZIP parsing, index creation, and file-I/O errors are captured in
          the returned failure result. Legacy injected installers receive a pre-invocation check but
          retain responsibility for cross-call serialization.
      */
    private func installEpub(at url: URL) -> ExternalDocumentImportResult {
        do {
            let title = try epubInstaller(url, epubCandidateAdmission)
            return .installedEpub(title: title)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /**
      Installs one Android-style app-owned TTF font.

      - Parameters:
          - url: URL for a candidate `.ttf` font file.
          - displayName: Optional provider filename to preserve during installation.
      - Returns: `.installedFont` on success or `.failed` with the installer error description.
      - Side effects: Mutates the SWORD root's `ttf` and `mods.d` directories.
      - Failure modes: Font validation and file-I/O errors are captured in the returned failure
          result.
      */
    private func installFont(at url: URL, displayName: String?) -> ExternalDocumentImportResult {
        do {
            let fontName = try fontInstaller(url, displayName ?? url.lastPathComponent)
            return .installedFont(name: fontName)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /**
     Installs one Android background, prompt, or SQLite-family file.

     - Parameters:
       - url: Security-scoped source URL whose content signature was already classified.
       - displayName: Provider-visible basename used as the Android backing filename.
       - family: Raw Android registrar selected by the routing matrix.
       - overwritePolicy: Explicit conflict policy forwarded to transactional publication.
     - Returns: Generic installed-module success or normalized installation failure.
     - Side effects: Invokes the configured raw-family installer, which may publish module content.
     - Failure modes: Missing display names and installer errors become `.failed` results.
     */
    private func installAndroidFamilyFile(
        at url: URL,
        displayName: String?,
        family: AndroidModuleBackupExternalFileFamily,
        overwritePolicy: LocalSwordZipOverwritePolicy
    ) -> ExternalDocumentImportResult {
        guard let displayName, !displayName.isEmpty else {
            return .failed(message: "The selected Android module file has no display name.")
        }
        do {
            return .installedModule(name: try androidFamilyFileInstaller(
                url,
                displayName,
                family,
                overwritePolicy
            ))
        } catch {
            return .failed(message: ModuleInstallErrorPresentation.detail(for: error))
        }
    }

    /**
     Reads the bounded leading bytes Android uses to distinguish ZIP and SQLite documents.

     - Parameter url: Candidate local document URL.
     - Returns: ZIP, SQLite, or unknown signature without trusting filename or generic MIME metadata.
     - Side effects: Opens the source read-only and reads at most sixteen bytes.
     - Failure modes: Missing, unreadable, short, or unrecognized files return `.unknown`.
     */
    private func documentContentSignature(at url: URL) -> ExternalDocumentContentSignature {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 16)
        let zipSignatures: [[UInt8]] = [
            [0x50, 0x4b, 0x03, 0x04],
            [0x50, 0x4b, 0x05, 0x06],
            [0x50, 0x4b, 0x07, 0x08],
        ]
        if zipSignatures.contains(where: { data.starts(with: $0) }) {
            return .zip
        }
        if data.starts(with: Data("SQLite format 3\0".utf8)) {
            return .sqlite
        }
        return .unknown
    }

    /**
      Resolves provider and filesystem type metadata for a request.

      - Parameter request: External document request.
      - Returns: Candidate UTTypes ordered from provider metadata to filename fallback.
      - Side effects: Reads URL resource values when the filesystem can provide a content type.
      - Failure modes: Missing values are ignored.
      */
    private func resolvedContentTypes(for request: ExternalDocumentImportRequest) -> [UTType] {
        var contentTypes: [UTType] = []
        if let identifier = request.contentTypeIdentifier,
           let providerType = UTType(identifier) {
            contentTypes.append(providerType)
        }
        if let resourceType = try? request.url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            contentTypes.append(resourceType)
        }
        if let extensionType = UTType(filenameExtension: request.url.pathExtension) {
            contentTypes.append(extensionType)
        }
        return contentTypes
    }

    /**
      Tests whether a UTType represents an EPUB archive.

      - Parameter contentType: Candidate content type.
      - Returns: `true` for `org.idpf.epub-container` conforming types.
      */
    private func isEpubContentType(_ contentType: UTType) -> Bool {
        contentType.conforms(to: .epub)
    }

    /**
      Tests whether a UTType represents a ZIP archive.

      - Parameter contentType: Candidate content type.
      - Returns: `true` for public ZIP archive conforming types.
      */
    private func isZipContentType(_ contentType: UTType) -> Bool {
        contentType.conforms(to: .zip)
    }

    /**
      Tests whether a UTType represents an Android-supported TTF font file.

      - Parameter contentType: Candidate content type.
      - Returns: `true` for known TTF/font UTTypes.
      */
    private func isFontContentType(_ contentType: UTType) -> Bool {
        contentType.conforms(to: Self.trueTypeFontType)
            || contentType.identifier == "public.truetype-ttf-font"
    }

    /** Returns whether provider metadata identifies an Android background-image candidate. */
    private func isImageContentType(_ contentType: UTType) -> Bool {
        contentType.conforms(to: .image)
    }

    /** Returns whether provider metadata identifies an Android CSV prompt-pack candidate. */
    private func isCSVContentType(_ contentType: UTType) -> Bool {
        guard let csvType = UTType(filenameExtension: "csv") else { return false }
        return contentType.conforms(to: csvType)
            || contentType.identifier == "text/csv"
    }

    /**
      Runs file work with temporary security-scoped access when the URL requires it.

      - Parameters:
          - url: File URL received from iOS document interaction or a SwiftUI file importer.
          - operation: Synchronous file operation that must complete before access is released.
      - Returns: The value produced by `operation`.
      - Side effects: Calls `startAccessingSecurityScopedResource()` and balances it with
          `stopAccessingSecurityScopedResource()` when iOS grants scoped access.
      - Throws: Rethrows any error produced by `operation`.
      */
    private func withSecurityScopedAccess<T>(to url: URL, operation: () throws -> T) rethrows -> T {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }
}

/// Internal installer branch for Android-parity external document routing.
private enum ExternalDocumentKind: Equatable {
    case androidModuleBackup
    case archive
    case epub
    case font
    case androidFamilyFile(AndroidModuleBackupExternalFileFamily)
    case unsupported
}

/** Bounded content-magic result used after Android's MIME and display-name routes. */
private enum ExternalDocumentContentSignature: Equatable {
    /// ZIP local/empty/data-descriptor signature recognized before archive inspection.
    case zip

    /// SQLite 3 sixteen-byte database header.
    case sqlite

    /// Missing, unreadable, short, or unrecognized source content.
    case unknown
}

/**
 Read-only outcome produced before an external document import starts writing files.

 The overwrite case carries a common SWORD summary derived from either ordinary ZIP inspection or
 full Android module-backup inspection. This lets every interactive entry point show exact canonical
 conflicts while noninteractive entry points retain the fail-safe `.reject` default.

 Side effects:
 - none; values are immutable

 Failure modes:
 - validation errors are represented by `.failed` rather than thrown
 */
public enum ExternalDocumentImportPreflightResult: Equatable, Sendable {
    /// The request needs no SWORD module overwrite confirmation.
    case ready

    /// Existing SWORD destinations require explicit replacement consent.
    case moduleOverwriteRequired(LocalSwordZipInspection)

    /// Read-only archive validation failed before installation could start.
    case failed(message: String)
}

/**
 Identifies EPUB archives that arrive through ZIP-looking iOS document providers.

 Android's `installZip` reroutes a ZIP only when its otherwise-unowned entry list contains the exact
 `META-INF/container.xml` path. This classifier preserves Android's case-sensitive marker after the
 same backslash-to-slash normalization.
 */
private struct ZipArchiveDocumentClassifier: Sendable {
    /**
     Tests whether a ZIP archive has EPUB structure.

     - Parameter url: ZIP-like archive URL.
     - Returns: `true` when central-directory metadata contains Android's exact EPUB marker.
     - Side effects: Reads ZIP metadata from `url`.
     - Failure modes: Malformed or unreadable archives return `false`.
     */
    func isEpubArchive(_ url: URL) -> Bool {
        guard let entryNames = try? ZipArchiveReader.entryNames(inArchiveAt: url) else {
            return false
        }
        return entryNames.contains { normalizedEntryName($0) == "META-INF/container.xml" }
    }

    /**
     Normalizes a ZIP entry name for classifier comparisons.

     - Parameter name: Raw ZIP entry name.
     - Returns: Entry name with Android's accepted backslash separators converted to slashes.
     - Side effects: None.
     - Failure modes: None; archive path safety is validated by the selected installer.
     */
    private func normalizedEntryName(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/")
    }
}

/**
 Structured outcome for an external document import attempt.

 The enum keeps import semantics separate from presentation so Settings, app-scene open handling,
 and tests can reason about the branch taken while still sharing the same localized feedback text.
 */
public enum ExternalDocumentImportResult: Equatable, Sendable {
    /// A SWORD module ZIP installed successfully; associated value is the installed module name.
    case installedModule(name: String)

    /// An EPUB archive installed successfully; associated value is the installed EPUB title.
    case installedEpub(title: String)

    /// A TTF font installed successfully; associated value is the installed font name.
    case installedFont(name: String)

    /// An Android module backup restored successfully; associated values preserve restore details.
    case installedAndroidModuleBackup(moduleNames: [String], installedEntryCount: Int)

    /// The file extension is not handled by iOS' implemented document installer path.
    case unsupportedFormat(fileExtension: String)

    /// The selected file matched a handled extension, but the installer rejected or could not read it.
    case failed(message: String)

    /**
      Localized user-visible feedback for the import result.

      - Returns: Android's generic install-success text for handled successful installs, or
          unsupported-format/error text for failures using existing localization keys with English
          defaults for package tests and missing translations.
      - Side effects: none.
      - Failure modes: Missing localization entries fall back to the supplied default strings.
      */
    public var feedbackMessage: String {
        switch self {
        case .installedModule,
             .installedEpub,
             .installedFont,
             .installedAndroidModuleBackup:
            return AndroidModuleBackupPresentation.localizedInstallSuccessMessage
        case .unsupportedFormat(let fileExtension):
            return String(
                format: String(
                    localized: "error_unsupported_format_%@",
                    defaultValue: "Error: Unsupported file format (%@)"
                ),
                fileExtension
            )
        case .failed(let message):
            return String(
                format: NSLocalizedString(
                    "error_prefix_%@",
                    value: "Error: %@",
                    comment: "Import/export error prefix"
                ),
                message
            )
        }
    }

    /**
      Whether this result should use Android's transient install-success toast presentation.

      Android's `InstallZip` reports successful ZIP, EPUB, TTF, and module-backup installs by
      posting `ToastEvent(R.string.install_zip_successfull)`. Errors, invalid files, and unsupported
      formats remain interruptive feedback on iOS so users do not miss an action they may need to
      correct.

      - Returns: `true` for successful handled install results, otherwise `false`.
      - Side effects: none.
      - Failure modes: none.
      */
    public var usesAndroidInstallToastFeedback: Bool {
        switch self {
        case .installedModule,
             .installedEpub,
             .installedFont,
             .installedAndroidModuleBackup:
            return true
        case .unsupportedFormat,
             .failed:
            return false
        }
    }
}
