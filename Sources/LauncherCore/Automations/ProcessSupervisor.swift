import Darwin
import Foundation

/// How a supervised process ended.
public struct ProcessOutcome: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case exited
        case timedOut
        case cancelled
        /// Killed by a signal the supervisor did not send.
        case signaled
        case spawnFailed(String)
    }
    public var reason: Reason
    public var exitCode: Int32?
    public var signal: Int32?
    /// The last bytes of stdout and stderr, within the caps.
    public var stdoutTail: Data
    public var stderrTail: Data
    public var stdoutBytes: Int
    public var succeeded: Bool { reason == .exited && exitCode == 0 }
}

/// Runs one process in its own process group, with no shell. Output is drained on two threads,
/// stdout lines go to a callback, and timeout or cancel stops the whole group (TERM, then KILL after a grace).
///
/// Thread safety: `run` blocks its caller; `cancel` may be called from any thread.
public final class ProcessSupervisor: @unchecked Sendable {
    public var stdoutTailBytes = 64 * 1024
    public var stderrTailBytes = 64 * 1024
    public var maxLineBytes = RunnerEvents.maxLineBytes
    public var killGrace: TimeInterval = 10

    private let lock = NSLock()
    private var cancelled = false
    private let wake = DispatchSemaphore(value: 0)

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        wake.signal()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func run(_ launch: ProcessLaunch, timeout: TimeInterval, onLine: @escaping (Data) -> Void = { _ in }) -> ProcessOutcome {
        runRecording(launch, timeout: timeout, onStart: { _ in }, onLine: onLine)
    }

    /// As `run`, and calls `onStart` on the caller's thread with the child's PID (also its process group ID)
    /// right after it starts, before any wait, so the caller can record it.
    public func runRecording(_ launch: ProcessLaunch, timeout: TimeInterval, onStart: (pid_t) -> Void,
                             onLine: @escaping (Data) -> Void) -> ProcessOutcome {
        if isCancelled {
            return ProcessOutcome(reason: .cancelled, exitCode: nil, signal: nil,
                                  stdoutTail: Data(), stderrTail: Data(), stdoutBytes: 0)
        }
        signal(SIGPIPE, SIG_IGN)
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0 else { return failed("Cannot create pipes.") }
        guard pipe(&outPipe) == 0 else { closeAll(inPipe); return failed("Cannot create pipes.") }
        guard pipe(&errPipe) == 0 else { closeAll(inPipe + outPipe); return failed("Cannot create pipes.") }
        for fd in [inPipe[1], outPipe[0], errPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if !launch.workingDirectory.isEmpty { posix_spawn_file_actions_addchdir_np(&actions, launch.workingDirectory) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own group before exec; close every other descriptor (such as the runner lock); default signal handlers.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(); sigfillset(&all); posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t(); sigemptyset(&none); posix_spawnattr_setsigmask(&attr, &none)

        let argv = [launch.executable] + launch.arguments
        let envp = launch.environment.map { "\($0.key)=\($0.value)" }.sorted()
        var pid: pid_t = 0
        let spawnError = withCStrings(argv) { a in withCStrings(envp) { e in posix_spawn(&pid, launch.executable, &actions, &attr, a, e) } }
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard spawnError == 0 else {
            closeAll([inPipe[1], outPipe[0], errPipe[0]])
            return failed("Cannot start \(URL(fileURLWithPath: launch.executable).lastPathComponent): \(String(cString: strerror(spawnError)))")
        }

        onStart(pid)
        let group = DispatchGroup()
        let io = PipeControl()
        for fd in [inPipe[1], outPipe[0], errPipe[0]] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        let stdinData = launch.stdin, inFD = inPipe[1]
        DispatchQueue.global().async(group: group) { Self.writeAll(stdinData, to: inFD, control: io); close(inFD) }
        let out = LineDrain(fd: outPipe[0], tailCap: stdoutTailBytes, lineCap: maxLineBytes, onLine: onLine, control: io)
        let err = LineDrain(fd: errPipe[0], tailCap: stderrTailBytes, lineCap: 0, onLine: nil, control: io)
        DispatchQueue.global().async(group: group) { out.drain() }
        DispatchQueue.global().async(group: group) { err.drain() }

        let reaper = Reaper(pid: pid)
        let wake = self.wake
        Thread.detachNewThread { reaper.wait(); wake.signal() }

        var reason: ProcessOutcome.Reason = .exited
        let deadline = Date().addingTimeInterval(max(timeout, 1))
        while !reaper.done {
            if isCancelled { reason = .cancelled; break }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { reason = .timedOut; break }
            _ = wake.wait(timeout: .now() + min(left, 1))
        }
        if !reaper.done { stopGroup(pid, reaper: reaper) }
        // The leader is gone; stop anything it left in its group so the pipes close.
        if kill(-pid, 0) == 0 { stopGroup(pid, reaper: nil) }
        if group.wait(timeout: .now() + 5) == .timedOut {
            io.stop()
            group.wait()
        }

        let status = reaper.status
        let exited = status & 0x7f == 0
        var outcome = ProcessOutcome(reason: reason, exitCode: exited ? (status >> 8) & 0xff : nil, signal: exited ? nil : status & 0x7f,
                                     stdoutTail: out.tail, stderrTail: err.tail, stdoutBytes: out.total)
        if reason == .exited, !exited { outcome.reason = .signaled }
        return outcome
    }

    /// SIGTERM to the group, then SIGKILL after the grace period, then reap.
    private func stopGroup(_ pid: pid_t, reaper: Reaper?) {
        kill(-pid, SIGTERM)
        let end = Date().addingTimeInterval(killGrace)
        while Date() < end {
            if let reaper, reaper.done, kill(-pid, 0) != 0 { return }
            if reaper == nil, kill(-pid, 0) != 0 { return }
            _ = wake.wait(timeout: .now() + 0.1)
        }
        kill(-pid, SIGKILL)
        if let reaper { while !reaper.done { _ = wake.wait(timeout: .now() + 0.05) } }
    }

    private func failed(_ why: String) -> ProcessOutcome {
        ProcessOutcome(reason: .spawnFailed(why), exitCode: nil, signal: nil, stdoutTail: Data(), stderrTail: Data(), stdoutBytes: 0)
    }

    private func closeAll(_ fds: [Int32]) { fds.forEach { close($0) } }

    private static func writeAll(_ data: Data, to fd: Int32, control: PipeControl) {
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var done = 0
            while done < buf.count, !control.stopped {
                let n = write(fd, base + done, buf.count - done)
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN {
                    control.wait(fd, events: Int16(POLLOUT)); continue
                }
                if n <= 0 { return }
                done += n
            }
        }
    }

    private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

/// Waits for one child on its own thread.
private final class Reaper: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var _done = false
    private var _status: Int32 = 0
    init(pid: pid_t) { self.pid = pid }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }
    var status: Int32 { lock.lock(); defer { lock.unlock() }; return _status }
    func wait() {
        var st: Int32 = 0
        while waitpid(pid, &st, 0) < 0, errno == EINTR {}
        lock.lock(); _status = st; _done = true; lock.unlock()
    }
}

/// Reads a pipe to the end. Keeps the last `tailCap` bytes and splits lines for the callback.
private final class LineDrain: @unchecked Sendable {
    let fd: Int32, tailCap: Int, lineCap: Int
    let onLine: ((Data) -> Void)?
    let control: PipeControl
    private(set) var tail = Data()
    private(set) var total = 0
    private var line = Data()
    private var skipping = false

    init(fd: Int32, tailCap: Int, lineCap: Int, onLine: ((Data) -> Void)?, control: PipeControl) {
        self.fd = fd; self.tailCap = tailCap; self.lineCap = lineCap; self.onLine = onLine; self.control = control
    }

    func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !control.stopped {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN {
                control.wait(fd, events: Int16(POLLIN)); continue
            }
            if n <= 0 { break }
            let chunk = Data(buffer[0..<n])
            total += n
            tail.append(chunk)
            if tail.count > tailCap * 2 { tail = tail.suffix(tailCap) }
            if onLine != nil { split(chunk) }
        }
        close(fd)
        if tail.count > tailCap { tail = tail.suffix(tailCap) }
        if let onLine, !line.isEmpty, !skipping { onLine(line) }
    }

    private func split(_ chunk: Data) {
        var start = chunk.startIndex
        while let nl = chunk[start...].firstIndex(of: 10) {
            if !skipping { line.append(chunk[start..<nl]); if line.count <= lineCap { onLine?(line) } }
            line.removeAll(keepingCapacity: true); skipping = false
            start = chunk.index(after: nl)
        }
        guard !skipping else { return }
        line.append(chunk[start...])
        // A line over the cap is dropped whole.
        if line.count > lineCap { line.removeAll(); skipping = true }
    }
}

/// Stops pipe workers even when a descendant escaped the process group and kept a pipe open.
private final class PipeControl: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func stop() { lock.lock(); value = true; lock.unlock() }
    func wait(_ fd: Int32, events: Int16) {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        _ = poll(&descriptor, 1, 100)
    }
}
