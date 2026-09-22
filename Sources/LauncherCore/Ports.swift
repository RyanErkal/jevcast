import Foundation

/// A process that listens on a local TCP port.
public struct ListeningPort: Identifiable, Sendable, Equatable, Hashable {
    public let pid: Int32
    public let command: String
    public let port: Int
    public var id: String { "port:\(port):\(pid)" }
    public init(pid: Int32, command: String, port: Int) {
        self.pid = pid; self.command = command; self.port = port
    }
}

/// Reads port queries such as "port 3000", "kill port 3000", "kill 3000", ":3000", and "ports".
public struct PortQuery: Equatable, Sendable {
    /// The port to find, or nil to list every listening port.
    public let port: Int?
    public init(port: Int?) { self.port = port }

    public static func parse(_ text: String) -> PortQuery? {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return nil }
        if words.count == 1, first.hasPrefix(":"), let port = number(String(first.dropFirst())) { return PortQuery(port: port) }
        if ["port", "ports"].contains(first) {
            if words.count == 1 { return PortQuery(port: nil) }
            if words.count == 2, let port = number(words[1]) { return PortQuery(port: port) }
            return nil
        }
        if ["kill", "stop", "free"].contains(first), words.count >= 2 {
            if ["port", "ports"].contains(words[1]) {
                if words.count == 2 { return PortQuery(port: nil) }
                if words.count == 3, let port = number(words[2]) { return PortQuery(port: port) }
                return nil
            }
            if words.count == 2, let port = number(words[1].hasPrefix(":") ? String(words[1].dropFirst()) : words[1]) {
                return PortQuery(port: port)
            }
        }
        // "stop whatever is running on 3000", "what's on port 5173", "kill the server on localhost:8080".
        let portWords: Set<String> = ["port", "running", "listening", "server", "localhost", "dev"]
        if words.contains(where: { portWords.contains($0) || $0.hasPrefix("localhost:") }) {
            // The number must read as a port: "on 3000", "port 3000", "at 3000", ":3000", or "localhost:3000".
            for (index, word) in words.enumerated() {
                let tail = word.split(separator: ":").last.map(String.init) ?? word
                guard let port = number(tail) else { continue }
                if word.contains(":") || (index > 0 && ["on", "port", "at"].contains(words[index - 1])) { return PortQuery(port: port) }
            }
        }
        return nil
    }

    /// The first valid port number anywhere in free text, for a request Jev matched to ports.
    public static func firstPort(in text: String) -> Int? {
        text.split(whereSeparator: { !$0.isNumber }).lazy.compactMap { number(String($0)) }.first
    }

    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let value = Int(text), (1...65_535).contains(value) else { return nil }
        return value
    }
}

public enum ListeningPorts {
    /// Fixed arguments for `/usr/sbin/lsof`: numeric output, TCP listeners only, machine-readable fields.
    public static let lsofArguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]

    /// Parses `lsof -Fpcn` output. One entry per process and port, sorted by port.
    public static func parse(_ output: String) -> [ListeningPort] {
        var result = Set<ListeningPort>()
        var pid: Int32?
        var command = ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); command = ""
            case "c": command = value
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                result.insert(ListeningPort(pid: pid, command: command, port: port))
            default: continue
            }
        }
        return result.sorted { $0.port != $1.port ? $0.port < $1.port : $0.pid < $1.pid }
    }
}
