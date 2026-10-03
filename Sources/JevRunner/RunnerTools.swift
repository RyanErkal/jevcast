import Foundation
import LauncherCore

/// The runner's two one-shot modes. Neither takes the runner lock or starts the scheduler.
enum RunnerTools {
    /// Serves one fetch worker over stdin and stdout until the CLI closes them. SIGTERM stops the command.
    static func serveFetchTool(specPath: String) -> Int32 {
        guard let spec = FetchToolServer.loadSpec(specPath) else {
            log("The fetch tool spec could not be read.")
            return 2
        }
        let server = FetchToolServer(spec: spec)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let queue = DispatchQueue(label: "jevcast.fetch-tool.signals")
        let sources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { server.stop() }
            source.resume()
            return source
        }
        withExtendedLifetime(sources) {
            server.serve(input: FileHandle.standardInput, output: FileHandle.standardOutput)
        }
        return 0
    }

    /// Prints a JSON report. Exit 0 when applied (or checked) without problems.
    static func configure(file: String, root: URL, check: Bool) -> Int32 {
        guard !file.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: file)), data.count < 2_000_000 else {
            log("Give the definition file: --configure <file> [--check].")
            return 2
        }
        let spec: AutomationSetup.Spec
        do { spec = try AutomationSetup.decode(data) } catch {
            log("The definition file is not valid: \(error)")
            return 2
        }
        let report = AutomationSetup.apply(spec, store: AutomationStore(root: root), check: check)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if let out = try? encoder.encode(report) { FileHandle.standardOutput.write(out + Data("\n".utf8)) }
        return report.problems.isEmpty ? 0 : 1
    }
}
