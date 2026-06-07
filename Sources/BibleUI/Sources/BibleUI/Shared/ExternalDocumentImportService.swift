// ExternalDocumentImportService.swift -- shared installer for documents opened from Files or Settings

import Foundation
import UniformTypeIdentifiers
import BibleCore
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
}

/**
 Installs user-selected documents that Android exposes through its external document intents.

 Android routes shared/opened module packages through `InstallZip`; iOS uses this shared service
 from both the Backup & Restore document picker and the SwiftUI scene `.onOpenURL` entry point so
 the same ZIP/EPUB/TTF semantics are applied regardless of where the file came from.

 Side effects:
 - reads security-scoped file URLs while access is active
 - installs SWORD ZIP modules through `ModuleRepository`
 - installs EPUB archives through `EpubReader`
 - installs app-owned TTF font addons through `TtfFontRepository`

 Failure modes:
 - unsupported document types return `.unsupportedFormat` without touching installers
 - installer errors are converted to `.failed` so callers can show the existing localized feedback
 */
public struct ExternalDocumentImportService: Sendable {
    /// Closure used to install SWORD ZIP modules; injectable for focused tests.
    public typealias ModuleInstaller = @Sendable (URL) throws -> String

    /// Closure used to install EPUB archives; injectable for focused tests.
    public typealias EpubInstaller = @Sendable (URL) throws -> String

    /// Closure used to install Android-style app-owned TTF font files; injectable for tests.
    public typealias FontInstaller = @Sendable (URL, String?) throws -> String

    /// Closure used to detect EPUB files that arrive through ZIP-looking providers.
    public typealias EpubArchiveDetector = @Sendable (URL) -> Bool

    /// Content types accepted by the Android-parity documents importer.
    public static var supportedContentTypes: [UTType] {
        [.zip, .epub, trueTypeFontType, .data]
    }

    /// Dynamic UTType for TrueType fonts, with `.data` as a conservative fallback.
    private static var trueTypeFontType: UTType {
        UTType("public.truetype-ttf-font") ?? UTType(filenameExtension: "ttf") ?? .data
    }

    /// SWORD module installer called for `.zip` files.
    private let moduleInstaller: ModuleInstaller

    /// EPUB installer called for `.epub` files.
    private let epubInstaller: EpubInstaller

    /// TTF font installer called for Android's font import path.
    private let fontInstaller: FontInstaller

    /// EPUB detector used for Android's ZIP-to-EPUB fallback behavior.
    private let epubArchiveDetector: EpubArchiveDetector

    /**
      Creates a document import service.

      - Parameters:
          - moduleInstaller: Installer for ZIP-backed SWORD modules. The default mutates the app's
              SWORD module storage and returns the installed module identifier.
          - epubInstaller: Installer for EPUB archives. The default mutates the app's EPUB storage and
              returns the installed EPUB title, falling back to the stable identifier when metadata cannot
              be reopened.
          - fontInstaller: Installer for TTF font files. The default copies the font into the SWORD
              `ttf` directory and writes Android-style addon metadata.
          - epubArchiveDetector: ZIP inspector used to reroute EPUB archives that arrive as ZIP.
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
        },
        fontInstaller: @escaping FontInstaller = { url, displayName in
            try TtfFontRepository().installFont(from: url, displayName: displayName).fontName
        },
        epubArchiveDetector: EpubArchiveDetector? = nil
    ) {
        self.moduleInstaller = moduleInstaller
        self.epubInstaller = epubInstaller
        self.fontInstaller = fontInstaller
        self.epubArchiveDetector = epubArchiveDetector ?? Self.defaultEpubArchiveDetector(_:)
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
        withSecurityScopedAccess(to: request.url) {
            switch documentKind(for: request) {
            case .archive:
                return installArchive(at: request.url)
            case .epub:
                return installEpub(at: request.url)
            case .font:
                return installFont(at: request.url, displayName: request.suggestedFileName)
            case .unsupported:
                return .unsupportedFormat(fileExtension: request.url.pathExtension.lowercased())
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
        let ext = request.url.pathExtension.lowercased()
        let contentTypes = resolvedContentTypes(for: request)
        if ext == "epub" || contentTypes.contains(where: isEpubContentType(_:)) {
            return .epub
        }
        if ext == "ttf" || contentTypes.contains(where: isFontContentType(_:)) {
            return .font
        }
        if ext == "zip" || contentTypes.contains(where: isZipContentType(_:)) {
            return .archive
        }
        return .unsupported
    }

    /**
      Installs one archive, rerouting EPUB ZIPs before module installation.

      - Parameter url: URL for a candidate SWORD ZIP or EPUB archive.
      - Returns: Module or EPUB success, or failure feedback.
      - Side effects: Mutates local SWORD module storage through `ModuleRepository`.
      - Failure modes: Installer errors are captured in the returned failure result.
      */
    private func installArchive(at url: URL) -> ExternalDocumentImportResult {
        if epubArchiveDetector(url) {
            return installEpub(at: url)
        }
        do {
            let moduleName = try moduleInstaller(url)
            return .installedModule(name: moduleName)
        } catch {
            if epubArchiveDetector(url) {
                return installEpub(at: url)
            }
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
            let title = try epubInstaller(url)
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
private enum ExternalDocumentKind {
    case archive
    case epub
    case font
    case unsupported
}

/**
 Identifies EPUB archives that arrive through ZIP-looking iOS document providers.

 Android's `installZip` can reroute EPUB packages after opening them as ZIP. This classifier reads
 ZIP structure, not filename fragments, and looks for the EPUB `mimetype` or
 `META-INF/container.xml` entries before the service decides which installer should own the file.
 */
private struct ZipArchiveDocumentClassifier: Sendable {
    /**
     Tests whether a ZIP archive has EPUB structure.

     - Parameter url: ZIP-like archive URL.
     - Returns: `true` when central-directory or local-header metadata identifies EPUB content.
     - Side effects: Reads ZIP metadata from `url`.
     - Failure modes: Malformed or unreadable archives return `false`.
     */
    func isEpubArchive(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return false
        }
        let names = centralDirectoryEntryNames(in: data)
        let entryNames = names.isEmpty ? localHeaderEntryNames(in: data) : names
        return entryNames.contains { $0 == "mimetype" }
            || entryNames.contains { $0 == "meta-inf/container.xml" }
    }

    /**
     Reads ZIP central-directory entry names.

     - Parameter data: Complete ZIP file bytes.
     - Returns: Lowercased, normalized entry names or an empty list when no central directory is
       available.
     */
    private func centralDirectoryEntryNames(in data: Data) -> [String] {
        guard let endRecordOffset = endOfCentralDirectoryOffset(in: data) else {
            return []
        }
        let centralDirectorySize = Int(readUInt32(data, at: endRecordOffset + 12))
        let centralDirectoryOffset = Int(readUInt32(data, at: endRecordOffset + 16))
        guard centralDirectoryOffset >= 0,
              centralDirectorySize >= 0,
              centralDirectoryOffset + centralDirectorySize <= data.count else {
            return []
        }

        var names: [String] = []
        var offset = centralDirectoryOffset
        let endOffset = centralDirectoryOffset + centralDirectorySize
        while offset + 46 <= endOffset {
            guard data[offset] == 0x50,
                  data[offset + 1] == 0x4b,
                  data[offset + 2] == 0x01,
                  data[offset + 3] == 0x02 else {
                break
            }
            let nameLength = Int(readUInt16(data, at: offset + 28))
            let extraLength = Int(readUInt16(data, at: offset + 30))
            let commentLength = Int(readUInt16(data, at: offset + 32))
            let nameStart = offset + 46
            let nextOffset = nameStart + nameLength + extraLength + commentLength
            guard nameStart + nameLength <= data.count, nextOffset <= data.count else {
                break
            }
            if let name = String(data: data[nameStart..<(nameStart + nameLength)], encoding: .utf8) {
                names.append(normalizedEntryName(name))
            }
            offset = nextOffset
        }
        return names
    }

    /**
     Reads local ZIP-header entry names when no central directory can be used.

     - Parameter data: Complete ZIP file bytes.
     - Returns: Lowercased, normalized entry names from local headers.
     */
    private func localHeaderEntryNames(in data: Data) -> [String] {
        var names: [String] = []
        var offset = 0
        while offset + 30 <= data.count {
            guard data[offset] == 0x50,
                  data[offset + 1] == 0x4b,
                  data[offset + 2] == 0x03,
                  data[offset + 3] == 0x04 else {
                break
            }
            let flags = readUInt16(data, at: offset + 6)
            let compressedSize = Int(readUInt32(data, at: offset + 18))
            let nameLength = Int(readUInt16(data, at: offset + 26))
            let extraLength = Int(readUInt16(data, at: offset + 28))
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extraLength
            guard nameStart + nameLength <= data.count, dataStart <= data.count else {
                break
            }
            if let name = String(data: data[nameStart..<(nameStart + nameLength)], encoding: .utf8) {
                names.append(normalizedEntryName(name))
            }
            if flags & 0x08 != 0 {
                break
            }
            let nextOffset = dataStart + compressedSize
            guard nextOffset > offset, nextOffset <= data.count else {
                break
            }
            offset = nextOffset
        }
        return names
    }

    /**
     Finds the ZIP end-of-central-directory record.

     - Parameter data: Complete ZIP file bytes.
     - Returns: Offset of the EOCD record, or `nil` when absent.
     */
    private func endOfCentralDirectoryOffset(in data: Data) -> Int? {
        guard data.count >= 22 else {
            return nil
        }
        let lowerBound = max(0, data.count - 22 - 65_535)
        for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
            if data[offset] == 0x50,
               data[offset + 1] == 0x4b,
               data[offset + 2] == 0x05,
               data[offset + 3] == 0x06 {
                return offset
            }
        }
        return nil
    }

    /**
     Normalizes a ZIP entry name for classifier comparisons.

     - Parameter name: Raw ZIP entry name.
     - Returns: Lowercased entry name without a leading `./`.
     */
    private func normalizedEntryName(_ name: String) -> String {
        var normalized = name.lowercased()
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        return normalized
    }

    /// Reads a little-endian `UInt16` without assuming pointer alignment.
    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 1 < data.count else {
            return 0
        }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    /// Reads a little-endian `UInt32` without assuming pointer alignment.
    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 3 < data.count else {
            return 0
        }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
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
        case .installedFont(let name):
            return String(
                format: String(localized: "installed_font_%@", defaultValue: "Installed font: %@"),
                name
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
