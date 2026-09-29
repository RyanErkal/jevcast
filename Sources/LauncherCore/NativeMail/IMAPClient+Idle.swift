import Foundation

extension IMAPClient {
    public enum IdleOutcome: Sendable, Equatable {
        /// The server reported new, removed, or changed messages.
        case changed
        /// The time ran out with no news.
        case quiet
    }

    /// Waits in IDLE (RFC 2177) on `mailbox` until the server reports a change or `duration` passes.
    /// Use a connection of its own: this one is busy while it waits. Cancelling the task closes
    /// the connection, which ends the wait at once.
    public func idle(in mailbox: String, for duration: TimeInterval) async throws -> IdleOutcome {
        try await exclusive {
            try await ensureSelected(mailbox, validity: nil)
            guard has("IDLE") else { throw MailError.idleUnsupported }
            guard let transport else { throw MailTransportError.closed }
            let done = DoneOnce(transport: transport)
            return try await withTaskCancellationHandler {
                try await idleLoop(transport: transport, done: done, duration: duration)
            } onCancel: {
                transport.close()
            }
        }
    }

    private func idleLoop(transport: MailTransport, done: DoneOnce, duration: TimeInterval) async throws -> IdleOutcome {
        let tag = "IDLE\(UInt32.random(in: 1...UInt32.max))"
        try await transport.write(Data("\(tag) IDLE\r\n".utf8))
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(max(1, duration) * 1_000_000_000))
            await done.send()
        }
        defer { timer.cancel() }
        var changed = false
        do {
            while true {
                // The timer ends IDLE before this read can time out.
                switch try await next(timeout: duration + 120) {
                case .continuation: continue
                case .untagged(let data):
                    switch data {
                    case .exists, .expunge, .fetch, .vanished, .recent:
                        if case .exists(let count) = data { selected?.exists = count }
                        changed = true
                        await done.send()
                    default: continue
                    }
                case .tagged(let replyTag, let status):
                    guard replyTag == tag else { continue }
                    guard status.status == .ok else { throw MailError.commandFailed(command: "IDLE", status: status.status, text: status.text) }
                    return changed ? .changed : .quiet
                }
            }
        } catch {
            disconnect()
            throw error
        }
    }
}

/// Writes DONE once, whether the timer or a server event asks first. A second DONE would be read
/// as a bad command.
actor DoneOnce {
    private let transport: MailTransport
    private var sent = false
    init(transport: MailTransport) { self.transport = transport }
    func send() async {
        guard !sent else { return }
        sent = true
        try? await transport.write(Data("DONE\r\n".utf8))
    }
}
