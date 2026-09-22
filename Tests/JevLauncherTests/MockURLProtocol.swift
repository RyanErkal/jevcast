import Foundation

/// Serves canned responses per URL, so parallel tests never share a handler.
final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [URL: Handler] = [:]

    static func setHandler(_ handler: @escaping Handler, for url: URL) { lock.withLock { handlers[url] = handler } }
    static func removeHandler(for url: URL) { _ = lock.withLock { handlers.removeValue(forKey: url) } }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = request.url.flatMap { url in Self.lock.withLock { Self.handlers[url] } }
        guard let requestHandler = handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
