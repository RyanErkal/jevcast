import AppKit
import LauncherCore

extension Diagnostics {
    /// `--diagnose-jev "request" …`: runs each request through the launcher as if typed,
    /// with the stored TypeSafe key, and prints Jev's pick, the top row, and the tokens used.
    /// Prints titles only, never paths. Each request that reaches Jev is billed and counted in Settings › Usage.
    static func jev(_ requests: [String]) {
        let preferences = Preferences()
        let catalogue = AppCatalogue()
        catalogue.refresh(extra: preferences.appFolders)
        let usage = JevUsageLog.shared
        let model = LauncherModel(preferences: preferences, catalogue: catalogue, jev: JevService(usage: usage), usage: usage)
        Task { @MainActor in
            for _ in 0..<100 where catalogue.entries.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
            print("Apps: \(catalogue.entries.count). Jev on: \(preferences.jevEnabled). Key: \(keyState(await JevKeyCache.shared.load()))")
            for request in requests {
                model.begin()
                let before = usage.summary(days: nil)
                model.updateQuery(request, typed: true)
                let done: Set<String> = ["Jev matched", "No clear AI match", "Kept exact match", "Remembered"]
                for _ in 0..<120 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if done.contains(model.aiStatus) || model.aiError != nil { break }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                let after = usage.summary(days: nil)
                let top = model.results.first(where: \.isCurrent)
                print("""
                ---
                Request: \(request)
                Status: \(model.aiStatus.isEmpty ? "Jev not asked" : model.aiStatus)\(model.aiError.map { " (\($0))" } ?? "")
                Query now: \(model.query)
                Top: \(top?.title ?? "none") [\(top?.detail ?? "")]
                Candidates sent: \(after.requests > before.requests ? String(model.jevCandidates().candidates.count) : "0")
                Tokens: \(after.inputTokens - before.inputTokens) in, \(after.outputTokens - before.outputTokens) out, \(JevPricing.format(after.cost - before.cost))
                """)
                model.end()
            }
            fflush(stdout)
            exit(0)
        }
        RunLoop.main.run()
    }

    /// Never prints the key itself.
    private static func keyState(_ state: JevKeyCache.State) -> String {
        switch state {
        case .present: return "stored"
        case .missing: return "missing"
        case .unknown: return "unknown"
        case .failed(let message): return "failed: " + message
        }
    }
}
