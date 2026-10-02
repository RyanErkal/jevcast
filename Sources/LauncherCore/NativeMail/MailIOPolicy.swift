import Foundation

/// An explicit offline gate for fixture tests and demo renders. Fake transports do not use it.
public enum MailIOPolicy {
    public static var isOffline: Bool { ProcessInfo.processInfo.environment["JEVCAST_MAIL_OFFLINE"] == "1" }

    public static func requireOnline() throws {
        if isOffline { throw MailError.notFound("Mail connections and Apple Mail actions are disabled for this offline run.") }
    }
}

final class OfflineMailTransport: MailTransport, @unchecked Sendable {
    func write(_ data: Data) async throws { try MailIOPolicy.requireOnline() }
    func read(timeout: TimeInterval) async throws -> Data {
        throw MailError.notFound("Mail connections are disabled for this offline run.")
    }
    func startTLS() async throws { try MailIOPolicy.requireOnline() }
    func close() {}
}
