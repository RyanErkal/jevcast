import Foundation

/// HTTP/1.1 over a plain TCP connection, for tailnet checks. App Transport Security blocks cleartext
/// URL loads to Tailscale addresses, and it covers only URL loading.
public enum PlainHTTP {
    public struct Response: Equatable, Sendable {
        public let status: Int
        public let body: Data
        /// True when the whole body has arrived, by Content-Length or the last chunk.
        public let complete: Bool
    }

    /// A GET that asks the server to close the connection after its answer. `host` is the name the
    /// server knows itself by, such as its MagicDNS name for a Tailscale Serve share.
    public static func request(host: String, port: Int, path: String, agent: String, secure: Bool = false) -> Data {
        let hostHeader = (host.contains(":") ? "[\(host)]" : host) + (port == (secure ? 443 : 80) ? "" : ":\(port)")
        return Data("GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nUser-Agent: \(agent)\r\nAccept: */*\r\nConnection: close\r\n\r\n".utf8)
    }

    /// The response in `data` so far. Nil until the head has arrived, or when the bytes are not HTTP.
    public static func parse(_ data: Data) -> Response? {
        let bytes = Data(data)
        guard let headEnd = bytes.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: bytes[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]) else { return nil }
        var length: Int?
        var chunked = false
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "content-length": length = Int(parts[1])
            case "transfer-encoding": chunked = parts[1].lowercased().contains("chunked")
            default: break
            }
        }
        let raw = Data(bytes[headEnd.upperBound...])
        if chunked {
            let (body, done) = dechunk(raw)
            return Response(status: status, body: body, complete: done)
        }
        if let length { return Response(status: status, body: raw.prefix(length), complete: raw.count >= length) }
        // Without a length the body ends when the server closes the connection.
        return Response(status: status, body: raw, complete: false)
    }

    /// The body of a chunked answer, and whether the last chunk has arrived.
    static func dechunk(_ data: Data) -> (Data, Bool) {
        let bytes = [UInt8](data)
        var body = Data()
        var index = 0
        while let lineEnd = lineEnd(in: bytes, from: index) {
            let sizeText = String(decoding: bytes[index..<lineEnd], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return (body, false) }
            if size == 0 { return (body, true) }
            let start = lineEnd + 2
            guard bytes.count - start >= size else {
                body.append(contentsOf: bytes[min(start, bytes.count)...])
                return (body, false)
            }
            body.append(contentsOf: bytes[start..<start + size])
            index = start + size + 2
        }
        return (body, false)
    }

    private static func lineEnd(in bytes: [UInt8], from index: Int) -> Int? {
        guard index < bytes.count - 1 else { return nil }
        return (index..<bytes.count - 1).first { bytes[$0] == 13 && bytes[$0 + 1] == 10 }
    }
}
