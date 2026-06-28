import AVFoundation
import CLibSword
import Foundation
import SwiftData
@testable import BibleCore

/**
 Test double for `SpeakService` package tests.

 The fake records utterances and transport controls without invoking the platform speech engine,
 allowing `SpeakService` state transitions to run deterministically in the BibleCore package lane.
 */
final class FakeSpeechSynthesizer: SpeechSynthesizing {
    weak var delegate: AVSpeechSynthesizerDelegate?

    private(set) var spokenUtterances: [AVSpeechUtterance] = []
    private(set) var stopBoundaries: [AVSpeechBoundary] = []
    private(set) var pauseBoundaries: [AVSpeechBoundary] = []
    private(set) var continueCount = 0

    /**
     Records one utterance requested by the service.

     - Parameter utterance: Speech utterance supplied by `SpeakService`.
     - Side effects: Appends the utterance to `spokenUtterances`.
     - Failure modes: This fake cannot fail.
     */
    func speak(_ utterance: AVSpeechUtterance) {
        spokenUtterances.append(utterance)
    }

    /**
     Records a stop request.

     - Parameter boundary: Boundary passed through from `SpeakService.stop()`.
     - Returns: Always `true`, matching a successful platform stop request.
     - Side effects: Appends the boundary to `stopBoundaries`.
     - Failure modes: This fake cannot fail.
     */
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopBoundaries.append(boundary)
        return true
    }

    /**
     Records a pause request.

     - Parameter boundary: Boundary passed through from `SpeakService.pause()`.
     - Returns: Always `true`, matching a successful platform pause request.
     - Side effects: Appends the boundary to `pauseBoundaries`.
     - Failure modes: This fake cannot fail.
     */
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        pauseBoundaries.append(boundary)
        return true
    }

    /**
     Records a resume request.

     - Returns: Always `true`, matching a successful platform continue request.
     - Side effects: Increments `continueCount`.
     - Failure modes: This fake cannot fail.
     */
    func continueSpeaking() -> Bool {
        continueCount += 1
        return true
    }
}

/**
 Creates an in-memory settings store for BibleCore package tests.

 - Returns: A `SettingsStore` backed by an in-memory SwiftData container containing only `Setting`.
 - Side effects: Allocates a transient model container for the test process.
 - Failure modes: Throws if SwiftData cannot create the in-memory container.
 */
func makeInMemorySettingsStore() throws -> SettingsStore {
    SettingsStore(modelContext: ModelContext(try makeInMemorySettingsContainer()))
}

/**
 Creates an in-memory SwiftData settings container.

 - Returns: A transient `ModelContainer` with the `Setting` schema.
 - Side effects: Allocates in-process SwiftData storage.
 - Failure modes: Throws if SwiftData cannot initialize the model container.
 */
func makeInMemorySettingsContainer() throws -> ModelContainer {
    let schema = Schema([Setting.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

/**
 Decompresses gzip bytes produced by remote-sync archive services for fixture inspection.

 - Parameter data: Gzip-compressed archive bytes.
 - Returns: Decompressed archive payload.
 - Side effects: Allocates and frees one CLibSword gzip output buffer.
 - Failure modes: Throws `RemoteSyncArchiveStagingError.decompressionFailed` when decompression
   fails or the input buffer is empty.
 */
func gunzipTestData(_ data: Data) throws -> Data {
    try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
        guard let baseAddress = ptr.baseAddress else {
            throw RemoteSyncArchiveStagingError.decompressionFailed
        }

        var outputLength: UInt = 0
        guard let output = gunzip_data(
            baseAddress.assumingMemoryBound(to: UInt8.self),
            UInt(data.count),
            &outputLength
        ) else {
            throw RemoteSyncArchiveStagingError.decompressionFailed
        }

        defer { gunzip_free(output) }
        return Data(bytes: output, count: Int(outputLength))
    }
}

/**
 Creates a URL session whose requests are handled by `MockURLProtocol`.

 Remote-sync package tests use this helper to validate WebDAV request construction without opening
 network sockets. Each test is responsible for assigning and clearing `MockURLProtocol.requestHandler`.

 - Returns: Ephemeral `URLSession` configured with the mock protocol class.
 - Side effects: Allocates a session object with in-process request interception.
 - Failure modes: The helper itself cannot fail; requests fail if the test did not install a
   handler.
 */
func makeMockedURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

/**
 Reads request body bytes from either `httpBody` or `httpBodyStream`.

 WebDAV tests need to assert XML and marker-upload payloads after URL loading has wrapped the
 request. The helper mirrors production-safe stream handling by opening, draining, and closing the
 stream before returning collected bytes.

 - Parameter request: Request captured by `MockURLProtocol`.
 - Returns: Body data when present, otherwise `nil`.
 - Side effects: Opens and closes `request.httpBodyStream` when the request uses a stream.
 - Failure modes: Returns `nil` when stream reading reports an error.
 */
func requestBodyData(for request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read < 0 {
            return nil
        }
        if read == 0 {
            break
        }
        data.append(buffer, count: read)
    }
    return data
}

/**
 Stable WebDAV multistatus fixture used by transport parser tests.

 The XML contains one collection and one gzip patch file, matching the shape Android/Nextcloud
 remote sync expects from a PROPFIND or SEARCH listing.
 */
let sampleWebDAVMultiStatusXML = """
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/remote.php/dav/files/alice/sync/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>sync</d:displayname>
        <d:resourcetype><d:collection /></d:resourcetype>
        <d:getlastmodified>Wed, 26 Feb 2026 12:00:00 GMT</d:getlastmodified>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/sync/1.1.sqlite3.gz</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>1.1.sqlite3.gz</d:displayname>
        <d:getcontentlength>12345</d:getcontentlength>
        <d:getcontenttype>application/gzip</d:getcontenttype>
        <d:getlastmodified>Wed, 26 Feb 2026 12:01:00 GMT</d:getlastmodified>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
"""

/**
 Builds a WebDAV multistatus listing for a folder and one gzip file.

 - Parameters:
   - folderPath: Remote folder href, with or without a trailing slash.
   - fileName: Child file name included in the listing.
 - Returns: XML string containing a folder response and one file response.
 - Side effects: none.
 - Failure modes: none; inputs are embedded verbatim except for trailing-slash normalization.
 */
func webDAVMultiStatusXML(folderPath: String, fileName: String) -> String {
    let normalizedFolderPath = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
    let folderDisplayName = normalizedFolderPath
        .split(separator: "/")
        .last
        .map(String.init) ?? ""
    return [
        #"<?xml version="1.0" encoding="utf-8"?>"#,
        #"<d:multistatus xmlns:d="DAV:">"#,
        #"  <d:response>"#,
        "    <d:href>\(normalizedFolderPath)</d:href>",
        #"    <d:propstat>"#,
        #"      <d:prop>"#,
        "        <d:displayname>\(folderDisplayName)</d:displayname>",
        #"        <d:resourcetype><d:collection /></d:resourcetype>"#,
        #"        <d:getlastmodified>Wed, 26 Feb 2026 12:00:00 GMT</d:getlastmodified>"#,
        #"      </d:prop>"#,
        #"      <d:status>HTTP/1.1 200 OK</d:status>"#,
        #"    </d:propstat>"#,
        #"  </d:response>"#,
        #"  <d:response>"#,
        "    <d:href>\(normalizedFolderPath)\(fileName)</d:href>",
        #"    <d:propstat>"#,
        #"      <d:prop>"#,
        "        <d:displayname>\(fileName)</d:displayname>",
        #"        <d:getcontentlength>12345</d:getcontentlength>"#,
        #"        <d:getcontenttype>application/gzip</d:getcontenttype>"#,
        #"        <d:getlastmodified>Wed, 26 Feb 2026 12:01:00 GMT</d:getlastmodified>"#,
        #"      </d:prop>"#,
        #"      <d:status>HTTP/1.1 200 OK</d:status>"#,
        #"    </d:propstat>"#,
        #"  </d:response>"#,
        #"</d:multistatus>"#,
    ].joined(separator: "\n")
}

/**
 URL loading protocol test double for package-level transport tests.

 The static handler lets each test synchronously inspect an outgoing request and return a deterministic
 HTTP response body. Tests must clear `requestHandler` in teardown to avoid cross-test coupling.
 Missing handlers fail the intercepted load through the URL protocol client so the awaiting test sees
 an ordinary request error instead of crashing the whole test process.
 */
final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "BibleCoreTests.MockURLProtocol",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "MockURLProtocol.requestHandler must be set before use"
                    ]
                )
            )
            return
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

/**
 Thread-safe request log for async URL protocol callbacks.

 Tests append HTTP method/path pairs from URL loading callbacks and assert the final ordered request
 sequence after the transport call completes.
 */
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RequestLogEntry] = []

    /**
     Appends one request record.

     - Parameters:
       - method: HTTP method captured from the request.
       - path: URL path captured from the request.
     - Side effects: Mutates the protected in-memory log.
     - Failure modes: none.
     */
    func append(method: String, path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(RequestLogEntry(method: method, path: path))
    }

    /**
     Returns a snapshot of recorded requests.

     - Returns: Ordered request entries captured so far.
     - Side effects: Reads the protected log.
     - Failure modes: none.
     */
    func snapshot() -> [RequestLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

/// HTTP method/path pair recorded by `RequestLog`.
struct RequestLogEntry: Equatable {
    let method: String
    let path: String
}
