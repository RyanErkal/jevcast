import Foundation
@testable import LauncherCore

/// Fake programs for staged-run tests. Nothing here starts a real CLI or reaches the network.
/// The fake `codex` logs each call to `$HOME/calls.jsonl`. For a fetch worker it acts as the tool server
/// would: it runs the spec's command and writes the result and child records. Behaviour is set by files in `$HOME`.
struct StagedFixture {
    let dir: URL
    var home: URL { dir }
    var calls: URL { dir.appendingPathComponent("calls.jsonl") }

    init(dir: URL) throws {
        self.dir = dir
        try TestCodexSignIn.install(home: dir)
    }

    func write(_ name: String, _ text: String, executable: Bool = false) throws -> String {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { chmod(url.path, 0o755) }
        return url.path
    }

    func mode(_ name: String, _ value: String = "1") throws { _ = try write("mode-" + name, value) }

    /// Each logged codex call: arguments and working folder.
    func codexCalls() -> [(args: [String], cwd: String)] {
        guard let text = try? String(contentsOf: calls, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return (o["args"] as? [String] ?? [], o["cwd"] as? String ?? "")
        }
    }

    func codex() throws -> String {
        try write("codex", #"""
        #!/usr/bin/python3
        import json, os, sys, subprocess
        home = os.environ["HOME"]
        args = sys.argv[1:]
        prompt = sys.stdin.read()
        with open(os.path.join(home, "calls.jsonl"), "a") as f:
            f.write(json.dumps({"args": args, "cwd": os.getcwd()}) + "\n")
        def mode(name):
            return os.path.exists(os.path.join(home, "mode-" + name))
        def say(o):
            print(json.dumps(o)); sys.stdout.flush()
        say({"type": "thread.started", "thread_id": "0199a213-81c0-7800-8aa1-bbab2a035a53"})
        tool = [a for a in args if a.startswith("mcp_servers.jevfetch.args=")]
        if tool:
            spec_path = json.loads(tool[0].split("=", 1)[1])[1]
            spec = json.load(open(spec_path))
            if mode("fetch-leave-group"):
                # A group whose leader exits while a member runs on: its identity cannot be confirmed.
                g = subprocess.Popen(["/bin/sh", "-c", "sleep 30 & exit 0"], start_new_session=True)
                g.wait()
                with open(spec["childFile"], "w") as f:
                    json.dump({"pgid": g.pid, "start": 0}, f)
                with open(os.path.join(home, "left-group"), "w") as f:
                    f.write(str(g.pid))
            elif not mode("fetch-no-call"):
                p = subprocess.Popen([spec["executable"]] + spec["arguments"], cwd=spec["workingDirectory"],
                                     env=spec["environment"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                with open(spec["childFile"], "w") as f:
                    json.dump({"pgid": p.pid}, f)
                out, err = p.communicate()
                with open(spec["resultFile"], "w") as f:
                    json.dump({"state": "finished", "periodKey": spec["periodKey"], "argv": [spec["executable"]] + spec["arguments"],
                               "exitCode": p.returncode, "reason": "exited", "stdout": out.decode(), "stderr": err.decode(),
                               "started": 0, "finished": 0}, f)
                say({"type": "item.completed", "item": {"type": "mcp_tool_call", "server": "jevfetch", "tool": "fetch_report_bundle"}})
            if mode("fetch-turn-fail"):
                say({"type": "turn.failed", "error": {"message": "model stream ended early"}})
                sys.exit(1)
            if mode("fetch-ran-shell"):
                say({"type": "item.completed", "item": {"type": "command_execution", "command": "ls", "exit_code": 0, "aggregated_output": ""}})
            reply = {"summary": "Fetched", "report_markdown": "manifest", "pdf_html": ""}
        else:
            if mode("analyst-fail"):
                sys.stderr.write("analyst could not finish\n"); sys.exit(3)
            with open(os.path.join(home, "analyst-prompt.txt"), "w") as f:
                f.write(prompt)
            reply = {"summary": "Report written", "report_markdown": "# Report\nReport period: 2026-09-21 to 2026-09-27", "pdf_html": ""}
        say({"type": "item.completed", "item": {"type": "agent_message", "text": json.dumps(reply)}})
        say({"type": "turn.completed", "usage": {"input_tokens": 3, "cached_input_tokens": 0, "output_tokens": 2}})
        """#, executable: true)
    }

    /// Prints `$HOME/handoff.json`; exits with `$HOME/preflight-exit` when present; sleeps when `mode-preflight-sleep` exists.
    func preflight() throws -> String {
        try write("preflight", #"""
        #!/bin/sh
        echo "$@" > "$HOME/preflight-args.txt"
        [ -f "$HOME/mode-preflight-sleep" ] && sleep 30
        echo "collector warning: lifecycle source slow" >&2
        [ -f "$HOME/block-output" ] && mkdir "$(cat "$HOME/block-output")/output.md"
        echo "planning..."
        cat "$HOME/handoff.json"
        echo
        [ -f "$HOME/preflight-exit" ] && exit "$(cat "$HOME/preflight-exit")"
        exit 0
        """#, executable: true)
    }

    /// Logs its arguments and prints a validated finish result for the item.
    func finish() throws -> String {
        try write("finish", #"""
        #!/usr/bin/python3
        import json, os, sys
        home = os.environ["HOME"]
        args = sys.argv[1:]
        with open(os.path.join(home, "finish-calls.jsonl"), "a") as f:
            f.write(json.dumps(args) + "\n")
        item = args[args.index("--item") + 1]
        period = args[args.index("--period-key") + 1]
        if "--agent-output" in args:
            json.load(open(args[args.index("--agent-output") + 1]))
        if os.path.exists(os.path.join(home, "mode-finish-blocked")):
            print(json.dumps({"schema": "jevcast.finish.v1", "status": "blocked", "summary": "Validation failed", "markdown": "Missing SMS draft."}))
            sys.exit(1)
        print(json.dumps({"schema": "jevcast.finish.v1", "status": "validated", "summary": "Saved", "markdown": "Full report and drafts",
                          "publication": {"job": item.rsplit(":", 1)[0], "period_key": period, "title": "Weekly " + period,
                                          "artifact_hashes": {"/reports/" + period + ".md": "a" * 64}}}))
        """#, executable: true)
    }

    /// Records every pending item in the proof.
    func publish() throws -> String {
        try write("publish", #"""
        #!/usr/bin/python3
        import json, os, sys
        home = os.environ["HOME"]
        args = sys.argv[1:]
        with open(os.path.join(home, "publish-calls.jsonl"), "a") as f:
            f.write(json.dumps(args) + "\n")
        if os.path.exists(os.path.join(home, "mode-publish-fail")):
            sys.stderr.write("Report state is locked\n"); sys.exit(1)
        proof = json.load(open(args[args.index("--proof") + 1]))
        print(json.dumps({"schema": "jevcast.publish.v1",
                          "recorded": [{"job": i["job"], "period_key": i["period_key"], "reason": ""} for i in proof["items"]], "refused": []}))
        """#, executable: true)
    }

    /// The fetch command: prints a manifest, or fails when `mode-command-fail` exists.
    func fetchCommand() throws -> String {
        try write("fetch-command", #"""
        #!/bin/sh
        echo "$@" > "$HOME/fetch-command-args.txt"
        [ -f "$HOME/mode-command-fail" ] && { echo "Meta API error 190" >&2; exit 2; }
        echo '{"status":"READY_FOR_ANALYSIS","bundle_path":"/reports/'"$3"'.json"}'
        """#, executable: true)
    }

    static func handoff(_ outcome: String, items: [[String: Any]] = [], summary: String = "Check finished.", markdown: String = "Sources checked.") -> String {
        let object: [String: Any] = ["schema": StagedHandoff.schema, "outcome": outcome, "summary": summary, "markdown": markdown, "items": items]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func item(_ action: String, period: String = "2026-09-26", fetch: Bool = false, hashes: [String: String] = [:]) -> [String: Any] {
        ["id": "other-client:weekly:" + period, "job": "other-client:weekly", "period_key": period, "action": action, "fetch": fetch,
         "title": "Other Client weekly " + period, "brief": "Bundle path: /reports/\(period).json", "display": "Saved report text",
         "artifact_hashes": hashes]
    }
}
