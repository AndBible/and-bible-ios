import Foundation
import SwordKit

/**
 Forwards the synthetic Downloads repository to the wrapper-owned loopback fixture service.

 The protocol is installed only for an explicit, validated UI-test endpoint and intercepts only
 `uitest-download.invalid`. It streams each loopback response chunk into the repository's outer
 download task, so `ModuleRepository` still owns byte progress, cancellation, ZIP validation,
 extraction, and staged publication.
 */
final class UITestDownloadFixtureURLProtocol: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    static let endpointEnvironmentKey = "UITEST_DOWNLOAD_FIXTURE_ENDPOINT"
    static let repositoryHost = "uitest-download.invalid"

    private let stateLock = NSLock()
    private var relaySession: URLSession?
    private var relayTask: URLSessionDataTask?
    private var sourceURL: URL?
    private var didFinish = false

    override class func canInit(with request: URLRequest) -> Bool {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.lowercased() == repositoryHost else {
            return false
        }
        return validatedEndpoint(
            ProcessInfo.processInfo.environment[endpointEnvironmentKey]
        ) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let sourceURL = request.url,
              let endpoint = Self.validatedEndpoint(
                  ProcessInfo.processInfo.environment[Self.endpointEnvironmentKey]
              ),
              let relayURL = Self.relayURL(sourceURL: sourceURL, endpoint: endpoint) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        var relayRequest = request
        relayRequest.url = relayURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 600
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
        let task = session.dataTask(with: relayRequest)
        stateLock.lock()
        guard !didFinish else {
            stateLock.unlock()
            session.invalidateAndCancel()
            return
        }
        self.sourceURL = sourceURL
        relaySession = session
        relayTask = task
        task.resume()
        stateLock.unlock()
    }

    override func stopLoading() {
        stateLock.lock()
        didFinish = true
        let task = relayTask
        let session = relaySession
        relayTask = nil
        relaySession = nil
        sourceURL = nil
        stateLock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            finish(with: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        stateLock.lock()
        guard !didFinish, let sourceURL else {
            stateLock.unlock()
            completionHandler(.cancel)
            return
        }
        stateLock.unlock()
        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }
        guard let forwardedResponse = HTTPURLResponse(
            url: sourceURL,
            statusCode: httpResponse.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            finish(with: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        client?.urlProtocol(self, didReceive: forwardedResponse, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateLock.lock()
        let shouldForward = !didFinish
        stateLock.unlock()
        if shouldForward, !data.isEmpty {
            client?.urlProtocol(self, didLoad: data)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        finish(with: error)
    }

    private func finish(with error: Error?) {
        stateLock.lock()
        guard !didFinish else {
            stateLock.unlock()
            return
        }
        didFinish = true
        let session = relaySession
        relayTask = nil
        relaySession = nil
        sourceURL = nil
        stateLock.unlock()

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
        session?.finishTasksAndInvalidate()
    }

    static func validatedEndpoint(_ rawValue: String?) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "http",
              url.host == "127.0.0.1",
              url.port != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              !url.path.isEmpty,
              url.path != "/" else {
            return nil
        }
        return url
    }

    static func relayURL(sourceURL: URL, endpoint: URL) -> URL? {
        guard sourceURL.host?.lowercased() == repositoryHost,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = endpoint.path + sourceURL.path
        components.query = sourceURL.query
        return components.url
    }
}

/** Creates the ordinary repository with the fixture URLSession only for the explicit UI run. */
enum UITestDownloadFixtureTransport {
    static func repositoryIfConfigured() -> ModuleRepository? {
        guard UITestDownloadFixtureURLProtocol.validatedEndpoint(
            ProcessInfo.processInfo.environment[
                UITestDownloadFixtureURLProtocol.endpointEnvironmentKey
            ]
        ) != nil else {
            return nil
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.protocolClasses = [UITestDownloadFixtureURLProtocol.self]
        return ModuleRepository(session: URLSession(configuration: configuration))
    }
}
