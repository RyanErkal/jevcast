import Foundation
import os

/// Opt-in timings contain only stage names and elapsed time, never query text or paths.
enum PerformanceTrace {
    private static let log = OSLog(subsystem: "ai.typesafe.JevLauncher", category: .pointsOfInterest)
    static func start(_ name: StaticString) -> (OSSignpostID, TimeInterval) {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return (id, ProcessInfo.processInfo.systemUptime)
    }
    static func end(_ name: StaticString, _ start: (OSSignpostID, TimeInterval)) {
        os_signpost(.end, log: log, name: name, signpostID: start.0)
        if CommandLine.arguments.contains("--trace-latency") {
            let ms = (ProcessInfo.processInfo.systemUptime - start.1) * 1000
            print(String(format: "[Jev timing] %@ %.2f ms", String(describing: name), ms))
            fflush(stdout)
        }
    }
}
