// EpubResourceSchemeHandler.swift -- contained EPUB resources for the shared reader

import BibleCore
import Foundation
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
        guard components.count >= 2,
              let initials = components.first,
              !initials.isEmpty,
              initials != ".",
              initials != "..",
              !initials.contains("\0"),
              components.dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")
              }),
              isSafeGenerationIdentifier(components[1]) else {
            return nil
        }
        let generationIdentifier = components[1]
        switch host {
        case "epub":
            guard components.count >= 3 else { return nil }
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
 Serves installed EPUB package resources to `WKWebView` through a contained custom scheme.

 Resource requests resolve the addressed EPUB by stable initials, validate the canonical path in
 `EpubReader`, and stream bytes in bounded chunks. Stylesheet requests return the adapter's
 Android-compatible sanitized CSS bundle. WebKit cancellation stops later callbacks.
 */
final class EpubResourceSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    /// Serial state lock protecting cancellation ids shared with the worker queue.
    private let cancellationLock = NSLock()

    /// Request identities cancelled by WebKit before streaming completed.
    private var cancelledTasks = Set<ObjectIdentifier>()

    /// Background queue used so large media files never block the main actor.
    private let workerQueue = DispatchQueue(label: "org.andbible.epub-resources", qos: .userInitiated)

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
        }
    }

    /// Streams a contained file in bounded chunks and closes it on every path.
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
