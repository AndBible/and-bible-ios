// ExternalDocumentImportService.swift -- shared installer for documents opened from Files or Settings

import Foundation
import BibleCore
import SwordKit

/// Installs user-selected documents that Android exposes through its external document intents.
///
/// Android routes shared/opened module packages through `InstallZip`; iOS uses this shared service
/// from both the Backup & Restore document picker and the SwiftUI scene `.onOpenURL` entry point so
/// the same ZIP/EPUB semantics are applied regardless of where the file came from.
///
/// Side effects:
/// - reads security-scoped file URLs while access is active
/// - installs SWORD ZIP modules through `ModuleRepository`
/// - installs EPUB archives through `EpubReader`
///
/// Failure modes:
/// - unsupported extensions return `.unsupportedFormat` without touching installers
/// - installer errors are converted to `.failed` so callers can show the existing localized feedback
public struct ExternalDocumentImportService: Sendable {
    /// Closure used to install SWORD ZIP modules; injectable for focused tests.
    public typealias ModuleInstaller = @Sendable (URL) throws -> String

    /// Closure used to install EPUB archives; injectable for focused tests.
    public typealias EpubInstaller = @Sendable (URL) throws -> String

    /// SWORD module installer called for `.zip` files.
    private let moduleInstaller: ModuleInstaller

    /// EPUB installer called for `.epub` files.
    private let epubInstaller: EpubInstaller

    /**
      Creates a document import service.

      - Parameters:
          - moduleInstaller: Installer for ZIP-backed SWORD modules. The default mutates the app's
              SWORD module storage and returns the installed module identifier.
          - epubInstaller: Installer for EPUB archives. The default mutates the app's EPUB storage and
              returns the installed EPUB title, falling back to the stable identifier when metadata cannot
              be reopened.
      - Side effects: none during initialization; installer closures perform file I/O when invoked.
      - Failure modes: This initializer cannot fail.
      */
    public init(
        moduleInstaller: @escaping ModuleInstaller = { url in
            try ModuleRepository().installFromZip(at: url)
        },
        epubInstaller: @escaping EpubInstaller = { url in
            let identifier = try EpubReader.install(epubURL: url)
            return EpubReader(identifier: identifier)?.title ?? identifier
        }
    ) {
        self.moduleInstaller = moduleInstaller
        self.epubInstaller = epubInstaller
    }

    /**
      Imports a supported external document URL.

      The service mirrors Android's implemented document installer behavior for SWORD ZIP packages
      and EPUB archives. It deliberately does not claim TTF support because iOS currently has no
      app-owned font installation path to back Android's font MIME types.

      - Parameter url: File URL supplied by Files, Mail, Share, or the in-app document picker.
      - Returns: Structured result that callers can convert to localized feedback.
      - Side effects:
          - starts security-scoped access while the selected file is read
          - installs module or EPUB data into app-managed storage when the extension is supported
      - Failure modes: Unsupported extensions and installer errors are represented in the returned
          value instead of thrown.
      */
    public func importDocument(at url: URL) -> ExternalDocumentImportResult {
        switch url.pathExtension.lowercased() {
        case "zip":
            return installModule(at: url)
        case "epub":
            return installEpub(at: url)
        default:
            return .unsupportedFormat(fileExtension: url.pathExtension.lowercased())
        }
    }

    /**
      Installs one SWORD module ZIP while security-scoped access is active.

      - Parameter url: URL for a candidate SWORD ZIP package.
      - Returns: `.installedModule` on success or `.failed` with the installer error description.
      - Side effects: Mutates local SWORD module storage through `ModuleRepository`.
      - Failure modes: Installer validation, ZIP parsing, and file-I/O errors are captured in the
          returned failure result.
      */
    private func installModule(at url: URL) -> ExternalDocumentImportResult {
        do {
            let moduleName = try withSecurityScopedAccess(to: url) {
                try moduleInstaller(url)
            }
            return .installedModule(name: moduleName)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /**
      Installs one EPUB archive while security-scoped access is active.

      - Parameter url: URL for a candidate EPUB archive.
      - Returns: `.installedEpub` on success or `.failed` with the installer error description.
      - Side effects: Mutates local EPUB extracted storage and index files through `EpubReader`.
      - Failure modes: EPUB validation, ZIP parsing, index creation, and file-I/O errors are captured
          in the returned failure result.
      */
    private func installEpub(at url: URL) -> ExternalDocumentImportResult {
        do {
            let title = try withSecurityScopedAccess(to: url) {
                try epubInstaller(url)
            }
            return .installedEpub(title: title)
        } catch {
            return .failed(message: error.localizedDescription)
        }
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

/// Structured outcome for an external document import attempt.
///
/// The enum keeps import semantics separate from presentation so Settings, app-scene open handling,
/// and tests can reason about the branch taken while still sharing the same localized feedback text.
public enum ExternalDocumentImportResult: Equatable, Sendable {
    /// A SWORD module ZIP installed successfully; associated value is the installed module name.
    case installedModule(name: String)

    /// An EPUB archive installed successfully; associated value is the installed EPUB title.
    case installedEpub(title: String)

    /// The file extension is not handled by iOS' implemented document installer path.
    case unsupportedFormat(fileExtension: String)

    /// The selected file matched a handled extension, but the installer rejected or could not read it.
    case failed(message: String)

    /**
      Localized user-visible feedback for the import result.

      - Returns: Success, unsupported-format, or error text using the existing import/export
          localization keys with English defaults for package tests and missing translations.
      - Side effects: none.
      - Failure modes: Missing localization entries fall back to the supplied default strings.
      */
    public var feedbackMessage: String {
        switch self {
        case .installedModule(let name):
            return String(
                format: String(localized: "installed_module_%@", defaultValue: "Installed module: %@"),
                name
            )
        case .installedEpub(let title):
            return String(
                format: String(localized: "installed_epub_%@", defaultValue: "Installed EPUB: %@"),
                title
            )
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
}
