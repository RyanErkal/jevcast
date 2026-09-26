import XCTest
@testable import LauncherCore

final class RunnerEventsTests: XCTestCase {
    func testCodexStream() {
        var e = RunnerEvents(runner: .codex)
        for line in [
            #"{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"bash -lc 'ls -la'","status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"bash -lc 'ls -la'","exit_code":0}}"#,
            #"{"type":"some.future.event","x":1}"#,
            "not json at all",
            #"{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"{\"summary\":\"ok\",\"report_markdown\":\"R\"}"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7,"reasoning_output_tokens":3}}"#,
        ] { e.consume(line) }
        XCTAssertEqual(e.sessionID, "0199a213-81c0-7800-8aa1-bbab2a035a53")
        XCTAssertEqual(e.usage, TokenUsage(input: 100, cachedInput: 40, output: 7))
        XCTAssertEqual(e.activity, ["Ran: bash -lc 'ls -la'"])
        XCTAssertNil(e.error)
        let obj = try? JSONSerialization.jsonObject(with: e.structured ?? Data()) as? [String: String]
        XCTAssertEqual(obj?["summary"], "ok")
    }

    func testCodexErrors() {
        var e = RunnerEvents(runner: .codex)
        e.consume(#"{"type":"error","message":"stream disconnected before completion"}"#)
        XCTAssertEqual(e.error, "stream disconnected before completion")
        e.consume(#"{"type":"turn.failed","error":{"message":"Usage limit reached"}}"#)
        XCTAssertEqual(e.error, "Usage limit reached")
    }

    func testClaudeStream() {
        var e = RunnerEvents(runner: .claude)
        e.consume(#"{"type":"system","subtype":"init","session_id":"5f0c1c43-7d1a-4c1e-9d6e-1b2f3a4b5c6d","tools":["Read"]}"#)
        e.consume(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}},{"type":"text","text":"hi"}]}}"#)
        e.consume(#"{"type":"result","subtype":"success","is_error":false,"result":"done","structured_output":{"summary":"s","report_markdown":"m"},"session_id":"5f0c1c43-7d1a-4c1e-9d6e-1b2f3a4b5c6d","usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":5,"output_tokens":3}}"#)
        XCTAssertEqual(e.sessionID, "5f0c1c43-7d1a-4c1e-9d6e-1b2f3a4b5c6d")
        XCTAssertEqual(e.activity, ["Read file"])
        XCTAssertEqual(e.finalText, "done")
        XCTAssertEqual(e.usage, TokenUsage(input: 35, cachedInput: 20, output: 3))
        XCTAssertNil(e.error)
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: e.structured!) as? [String: String])?["report_markdown"], "m")
    }

    func testClaudeError() {
        var e = RunnerEvents(runner: .claude)
        e.consume(#"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"s"}"#)
        XCTAssertEqual(e.error, "error_max_turns")
    }

    func testOversizedLineSkipped() {
        var e = RunnerEvents(runner: .codex)
        e.consume(Data(count: RunnerEvents.maxLineBytes + 1))
        XCTAssertEqual(e.skippedLines, 1)
    }
}
