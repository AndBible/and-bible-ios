// EpubResourceSchemeHandler.swift -- contained EPUB resources for the shared reader

import BibleCore
import Darwin
import Foundation
import SwordKit
import WebKit

/**
 Routes one custom EPUB URL to a package member or generated stylesheet.

 The route carries Android-compatible book initials plus an immutable iOS generation token, so
 resources cannot cross books or span package generations during an exact-name reinstall.
 */
enum EpubResourceRoute: Equatable, Sendable {
    /// One extracted package member addressed by canonical package path.
    case resource(bookInitials: String, generationIdentifier: String, canonicalPath: String)

    /// Sanitized linked stylesheets for one numeric general-book fragment key.
    case styleSheet(bookInitials: String, generationIdentifier: String, key: String)

    /// Generated CSS for every readable font claimed by one admitted add-on owner.
    case fontStyleSheet(moduleInitials: String)

    /// One exact readable font claimed by one admitted add-on owner.
    case fontResource(moduleInitials: String, relativePath: String)

    /**
     Parses one custom-scheme request URL.

     - Parameter url: URL emitted by `EpubResourceLocator`.
     - Returns: A typed contained route, or `nil` for malformed/unknown endpoints.
     - Side effects: None.
     - Failure modes: Empty identities, keys, and resource paths are rejected.
     */
    static func parse(_ url: URL) -> EpubResourceRoute? {
        guard url.scheme == EpubResourceLocator.scheme, let host = url.host else { return nil }
        let encodedComponents = (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedPath.lowercased() ?? "")
            .split(separator: "/", omittingEmptySubsequences: true)
        guard !encodedComponents.contains(where: { $0.contains("%2f") || $0.contains("%00") }),
              !encodedComponents.dropFirst().contains(where: { $0.contains("%5c") }) else {
            return nil
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let initials = components.first,
              !initials.isEmpty,
              initials != ".",
              initials != "..",
              !initials.contains("\0"),
              components.dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")
              }) else {
            return nil
        }
        switch host {
        case "epub":
            guard components.count >= 3,
                  isSafeGenerationIdentifier(components[1]) else { return nil }
            let generationIdentifier = components[1]
            if components.count == 5,
               components[2] == ".module-style",
               components[4] == "style.css",
               !initials.isEmpty,
               !components[3].isEmpty {
                return .styleSheet(
                    bookInitials: initials,
                    generationIdentifier: generationIdentifier,
                    key: components[3]
                )
            }
            let path = components.dropFirst(2).joined(separator: "/")
            guard !initials.isEmpty, !path.isEmpty else { return nil }
            return .resource(
                bookInitials: initials,
                generationIdentifier: generationIdentifier,
                canonicalPath: path
            )
        case "font":
            guard components.count >= 2 else { return nil }
            let resourcePath = components.dropFirst().joined(separator: "/")
            if resourcePath == "fonts.css" {
                return .fontStyleSheet(moduleInitials: initials)
            }
            return .fontResource(moduleInitials: initials, relativePath: resourcePath)
        default:
            return nil
        }
    }

    /// Restricts generation tokens to the opaque ASCII path contract emitted by BibleCore.
    private static func isSafeGenerationIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
                || value == 45
        }
    }
}

/**
 One ownership-pinned font descriptor opened only after live shared-projection authorization.

 The open descriptor retains the authorized inode while WebKit streams, so an uninstall or exact
 replacement after authorization cannot redirect the request to a different path owner.
 */
struct EpubAuthorizedFontResource {
    /// Exact authorized live file URL used for MIME classification.
    let fileURL: URL

    /// Size of the already-open descriptor, or -1 when it cannot fit in `Int`.
    let fileSize: Int

    /// Single owned descriptor consumed and closed by the scheme-handler stream.
    let handle: FileHandle
}

/// Native device/inode identity used to compare an open descriptor with its current live path.
private struct EpubFileSystemIdentity: Equatable {
    /// Filesystem device containing the file.
    let device: UInt64

    /// Inode retained by the open descriptor.
    let inode: UInt64
}

/**
 Serves installed EPUB packages and Android-admitted add-on fonts to `WKWebView` through one
 contained custom scheme.

 EPUB requests resolve the addressed package by stable initials/generation. Font requests replay the
 live shared add-on projection and expose only winning exact-name providers. WebKit cancellation
 stops later callbacks.
 */
final class EpubResourceSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    /// Serial state lock protecting cancellation ids shared with the worker queue.
    private let cancellationLock = NSLock()

    /// Request identities cancelled by WebKit before streaming completed.
    private var cancelledTasks = Set<ObjectIdentifier>()

    /// Background queue used so large media files never block the main actor.
    private let workerQueue = DispatchQueue(label: "org.andbible.epub-resources", qos: .userInitiated)

    /// Canonical SWORD root whose shared installed projection authorizes font resources.
    private let modulePath: String

    /// Test-only resolver override; production always builds a fresh shared manager projection.
    private let fontProviderResolver: ((String) -> [SwordAdmittedFont]?)?

    /**
     Creates the contained resource handler for one installed module root.

     - Parameters:
       - modulePath: SWORD root used for live admitted-font authorization. Production uses the same
         default root as `SwordManager`; tests may supply an isolated fixture root.
       - fontProviderResolver: Optional deterministic test seam invoked in place of manager
         construction. Production leaves it nil.
     - Side effects: None; managers and files are opened only for concrete requests.
     - Failure modes: None during initialization.
     */
    init(
        modulePath: String = SwordManager.defaultModulePath(),
        fontProviderResolver: ((String) -> [SwordAdmittedFont]?)? = nil
    ) {
        self.modulePath = modulePath
        self.fontProviderResolver = fontProviderResolver
        super.init()
    }

    /**
     Starts one resource request.

     - Parameter urlSchemeTask: WebKit request/response callback channel.
     - Side effects: Opens an EPUB index and may stream one package file or stylesheet to WebKit.
     - Failure modes: Malformed routes and missing resources fail with `NSURLErrorFileDoesNotExist`;
       read failures are forwarded to WebKit without exposing files outside the package root.
     */
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        cancellationLock.lock()
        cancelledTasks.remove(identifier)
        cancellationLock.unlock()

        workerQueue.async { [weak self] in
            self?.serve(urlSchemeTask, identifier: identifier)
        }
    }

    /**
     Cancels one in-flight resource stream.

     - Parameter urlSchemeTask: WebKit task that no longer needs callbacks.
     - Side effects: Records cancellation until the worker observes it.
     - Failure modes: None.
     */
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        cancellationLock.lock()
        cancelledTasks.insert(ObjectIdentifier(urlSchemeTask as AnyObject))
        cancellationLock.unlock()
    }

    /// Resolves and serves one typed request on the worker queue.
    private func serve(_ task: WKURLSchemeTask, identifier: ObjectIdentifier) {
        guard let url = task.request.url,
              let route = EpubResourceRoute.parse(url) else {
            fail(task, identifier: identifier, code: .badURL)
            return
        }
        switch route {
        case .resource(let initials, let generationIdentifier, let canonicalPath):
            guard let reader = EpubReader(
                initials: initials,
                generationIdentifier: generationIdentifier
            ) else {
                fail(task, identifier: identifier, code: .fileDoesNotExist)
                return
            }
            if URL(fileURLWithPath: canonicalPath).pathExtension.lowercased() == "css" {
                let data = reader.styleSheetData(forCanonicalPath: canonicalPath)
                guard !data.isEmpty else {
                    fail(task, identifier: identifier, code: .fileDoesNotExist)
                    return
                }
                send(data, mimeType: "text/css", requestURL: url, task: task, identifier: identifier)
                return
            }
            guard let fileURL = reader.resourceURL(for: canonicalPath) else {
                fail(task, identifier: identifier, code: .fileDoesNotExist)
                return
            }
            stream(fileURL, requestURL: url, task: task, identifier: identifier)
        case .styleSheet(let initials, let generationIdentifier, let key):
            guard let reader = EpubReader(
                initials: initials,
                generationIdentifier: generationIdentifier
            ) else {
                fail(task, identifier: identifier, code: .fileDoesNotExist)
                return
            }
            send(
                reader.styleSheetData(forKey: key),
                mimeType: "text/css",
                requestURL: url,
                task: task,
                identifier: identifier
            )
        case .fontStyleSheet(let moduleInitials):
            guard let fonts = admittedFonts(moduleInitials: moduleInitials),
                  let data = Self.fontStyleSheetData(fonts: fonts) else {
                fail(task, identifier: identifier, code: .fileDoesNotExist)
                return
            }
            send(
                data,
                mimeType: "text/css",
                requestURL: url,
                task: task,
                identifier: identifier
            )
        case .fontResource(let moduleInitials, let relativePath):
            guard let resource = openAuthorizedFontResource(
                moduleInitials: moduleInitials,
                relativePath: relativePath
            ) else {
                fail(task, identifier: identifier, code: .fileDoesNotExist)
                return
            }
            stream(resource, requestURL: url, task: task, identifier: identifier)
        }
    }

    /**
     Resolves one Java-exact, unambiguous installed font owner through the live shared projection.

     - Parameter moduleInitials: Exact percent-decoded initials from the custom resource route.
     - Returns: Winning readable font providers owned by the exact module, or nil.
     - Side effects: Production creates a fresh `SwordManager` and reads installed metadata/filesystem
       state; deterministic tests may invoke the injected resolver instead.
     - Failure modes: Manager creation failure, replacement, ambiguity, rejection, or no readable
       fonts returns nil before any resource is opened.
     */
    private func admittedFonts(moduleInitials: String) -> [SwordAdmittedFont]? {
        let providers: [SwordAdmittedFont]
        if let fontProviderResolver {
            guard let resolved = fontProviderResolver(moduleInitials) else { return nil }
            providers = resolved
        } else {
            guard let manager = SwordManager(modulePath: modulePath) else { return nil }
            providers = manager.admittedFonts()
        }
        let matches = providers.filter {
            SwordJavaStringIdentity.equals($0.moduleName, moduleInitials)
        }
        return matches.isEmpty ? nil : matches
    }

    /**
     Opens one exact font file and then replays live authorization against the opened inode.

     - Parameters:
       - moduleInitials: Exact route owner identity.
       - relativePath: Exact admitted provider path within that owner.
     - Returns: An ownership-pinned open descriptor, or nil when either authorization snapshot,
       path identity, regular-file check, or open operation fails.
     - Side effects: Builds two fresh manager projections, reads file metadata, and opens one file.
     - Failure modes: Any replacement/uninstall between the first projection and post-open replay
       closes the descriptor and returns nil before font bytes are read.
     */
    func openAuthorizedFontResource(
        moduleInitials: String,
        relativePath: String
    ) -> EpubAuthorizedFontResource? {
        guard let firstFonts = admittedFonts(moduleInitials: moduleInitials),
              let firstFont = firstFonts.first(where: {
                  SwordJavaStringIdentity.equals($0.relativePath, relativePath)
              }),
              let handle = try? FileHandle(forReadingFrom: firstFont.fileURL) else {
            return nil
        }
        var retainsHandle = false
        defer {
            if !retainsHandle {
                try? handle.close()
            }
        }
        guard let currentFonts = admittedFonts(moduleInitials: moduleInitials),
              let currentFont = currentFonts.first(where: {
                  SwordJavaStringIdentity.equals($0.relativePath, relativePath)
              }),
              currentFont.fileURL.standardizedFileURL == firstFont.fileURL.standardizedFileURL,
              let current = try? currentFont.fileURL.resourceValues(forKeys: [.isRegularFileKey]),
              current.isRegularFile == true,
              let descriptorIdentity = Self.fileSystemIdentity(for: handle),
              let liveIdentity = Self.fileSystemIdentity(at: currentFont.fileURL),
              descriptorIdentity == liveIdentity,
              let descriptorSize = try? handle.seekToEnd() else {
            return nil
        }
        do {
            try handle.seek(toOffset: 0)
        } catch {
            return nil
        }
        retainsHandle = true
        return EpubAuthorizedFontResource(
            fileURL: firstFont.fileURL,
            fileSize: Int(exactly: descriptorSize) ?? -1,
            handle: handle
        )
    }

    /**
     Reads native device/inode identity from one open descriptor.

     - Parameter handle: File descriptor already opened after shared-projection authorization.
     - Returns: Stable descriptor identity, or nil when `fstat` fails.
     - Side effects: Executes `fstat`; it does not move the descriptor cursor or read contents.
     - Failure modes: Invalid/closed descriptors return nil.
     */
    private static func fileSystemIdentity(for handle: FileHandle) -> EpubFileSystemIdentity? {
        var metadata = Darwin.stat()
        guard Darwin.fstat(handle.fileDescriptor, &metadata) == 0 else { return nil }
        return EpubFileSystemIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    /**
     Reads native device/inode identity for the file currently published at one URL.

     - Parameter url: Reauthorized live font path.
     - Returns: Current path identity, or nil when the path cannot be represented or stated.
     - Side effects: Executes `stat`; it does not open or read file contents.
     - Failure modes: Missing, replaced-during-stat, or unrepresentable paths return nil.
     */
    private static func fileSystemIdentity(at url: URL) -> EpubFileSystemIdentity? {
        var metadata = Darwin.stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &metadata)
        }
        guard result == 0 else { return nil }
        return EpubFileSystemIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    /**
     Builds Android's per-module `fonts.css` from already-authorized provider rows.

     - Parameter fonts: Winning readable font providers for one exact admitted add-on owner.
     - Returns: UTF-8 CSS with one `@font-face` rule per provider, or nil when none exist.
     - Side effects: None; file contents are not read.
     - Failure modes: Unsafe path components that cannot be percent-encoded omit the complete
       stylesheet rather than emitting a partial or cross-file claim.
     */
    private static func fontStyleSheetData(
        fonts: [SwordAdmittedFont]
    ) -> Data? {
        guard !fonts.isEmpty else { return nil }
        var rules: [String] = []
        for font in fonts {
            guard let encodedPath = encodedFontResourcePath(font.relativePath) else { return nil }
            let family = cssSingleQuotedString(font.name)
            rules.append(
                "@font-face {\nfont-family: '\(family)';\nsrc: url('\(encodedPath)') format('truetype');\n}"
            )
        }
        return Data((rules.joined(separator: "\n") + "\n").utf8)
    }

    /**
     Percent-encodes one validated relative font path component by component.

     - Parameter relativePath: Slash-separated provider path already admitted by SwordKit.
     - Returns: A relative CSS URL path, or nil for an empty component/encoding failure.
     - Side effects: None.
     - Failure modes: Returns nil instead of emitting a partial or absolute path.
     */
    private static func encodedFontResourcePath(_ relativePath: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty else { return nil }
        var encoded: [String] = []
        for component in components {
            guard !component.isEmpty,
                  let value = String(component).addingPercentEncoding(
                      withAllowedCharacters: allowed
                  ) else {
                return nil
            }
            encoded.append(value)
        }
        return encoded.joined(separator: "/")
    }

    /**
     Escapes one validated font-family name for a single-quoted CSS literal.

     - Parameter value: Control-free admitted provider name.
     - Returns: CSS-safe text with backslashes and single quotes escaped.
     - Side effects: None.
     - Failure modes: None; control characters were rejected during shared admission.
     */
    private static func cssSingleQuotedString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    /**
     Streams one contained EPUB file in bounded chunks.

     - Parameters:
       - fileURL: Already-contained EPUB package member.
       - requestURL: Custom-scheme response URL.
       - task: WebKit callback channel.
       - identifier: Cancellation identity for the request.
     - Side effects: Opens and reads the file, emits WebKit callbacks, and clears cancellation state.
     - Failure modes: Open/read/metadata errors fail the task unless WebKit already cancelled it.
     */
    private func stream(
        _ fileURL: URL,
        requestURL: URL,
        task: WKURLSchemeTask,
        identifier: ObjectIdentifier
    ) {
        defer { clearCancellation(identifier) }
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard !isCancelled(identifier) else { return }
            task.didReceive(URLResponse(
                url: requestURL,
                mimeType: Self.mimeType(for: fileURL),
                expectedContentLength: values.fileSize ?? -1,
                textEncodingName: nil
            ))
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            while !isCancelled(identifier) {
                guard let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty else { break }
                task.didReceive(data)
            }
            guard !isCancelled(identifier) else { return }
            task.didFinish()
        } catch {
            guard !isCancelled(identifier) else { return }
            task.didFailWithError(error)
        }
    }

    /**
     Streams one already-open ownership-pinned font descriptor in bounded chunks.

     - Parameters:
       - resource: Descriptor returned by post-open live authorization.
       - requestURL: Custom-scheme response URL.
       - task: WebKit callback channel.
       - identifier: Cancellation identity for the request.
     - Side effects: Reads and closes the descriptor, emits WebKit callbacks, and clears
       cancellation state.
     - Failure modes: Descriptor read errors fail the task unless WebKit already cancelled it.
     */
    private func stream(
        _ resource: EpubAuthorizedFontResource,
        requestURL: URL,
        task: WKURLSchemeTask,
        identifier: ObjectIdentifier
    ) {
        defer { clearCancellation(identifier) }
        defer { try? resource.handle.close() }
        guard !isCancelled(identifier) else { return }
        task.didReceive(URLResponse(
            url: requestURL,
            mimeType: Self.mimeType(for: resource.fileURL),
            expectedContentLength: resource.fileSize,
            textEncodingName: nil
        ))
        do {
            while !isCancelled(identifier) {
                guard let data = try resource.handle.read(upToCount: 64 * 1024),
                      !data.isEmpty else {
                    break
                }
                task.didReceive(data)
            }
            guard !isCancelled(identifier) else { return }
            task.didFinish()
        } catch {
            guard !isCancelled(identifier) else { return }
            task.didFailWithError(error)
        }
    }

    /// Sends an in-memory stylesheet response.
    private func send(
        _ data: Data,
        mimeType: String,
        requestURL: URL,
        task: WKURLSchemeTask,
        identifier: ObjectIdentifier
    ) {
        defer { clearCancellation(identifier) }
        guard !isCancelled(identifier) else { return }
        task.didReceive(URLResponse(
            url: requestURL,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        ))
        task.didReceive(data)
        task.didFinish()
    }

    /// Fails a malformed or missing custom-scheme request.
    private func fail(_ task: WKURLSchemeTask, identifier: ObjectIdentifier, code: URLError.Code) {
        defer { clearCancellation(identifier) }
        guard !isCancelled(identifier) else { return }
        task.didFailWithError(URLError(code))
    }

    /// Reads cancellation state under the lock.
    private func isCancelled(_ identifier: ObjectIdentifier) -> Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelledTasks.contains(identifier)
    }

    /// Drops completed cancellation bookkeeping.
    private func clearCancellation(_ identifier: ObjectIdentifier) {
        cancellationLock.lock()
        cancelledTasks.remove(identifier)
        cancellationLock.unlock()
    }

    /// Maps common EPUB resource extensions to browser MIME types.
    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "css": return "text/css"
        case "html", "htm", "xhtml": return "application/xhtml+xml"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
