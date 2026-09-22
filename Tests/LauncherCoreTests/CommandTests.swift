import XCTest
@testable import LauncherCore

final class CommandTests: XCTestCase {
    func testPortQueries() {
        XCTAssertEqual(PortQuery.parse("port 3000"), PortQuery(port: 3000))
        XCTAssertEqual(PortQuery.parse("kill port 5173"), PortQuery(port: 5173))
        XCTAssertEqual(PortQuery.parse("kill 8080"), PortQuery(port: 8080))
        XCTAssertEqual(PortQuery.parse("stop :4000"), PortQuery(port: 4000))
        XCTAssertEqual(PortQuery.parse(":3000"), PortQuery(port: 3000))
        XCTAssertEqual(PortQuery.parse("ports"), PortQuery(port: nil))
        XCTAssertEqual(PortQuery.parse("kill ports"), PortQuery(port: nil))
    }

    func testPlainLanguagePortQueries() {
        XCTAssertEqual(PortQuery.parse("stop whatever is running on 3000"), PortQuery(port: 3000))
        XCTAssertEqual(PortQuery.parse("what's listening on 5173"), PortQuery(port: 5173))
        XCTAssertEqual(PortQuery.parse("kill the server on localhost:8080"), PortQuery(port: 8080))
        XCTAssertNil(PortQuery.parse("running shoes size 10"))
        XCTAssertNil(PortQuery.parse("running on empty 10 miles"), "A number that does not follow on, port, or at is not a port.")
    }

    func testNonPortQueriesAreIgnored() {
        XCTAssertNil(PortQuery.parse("kill"))
        XCTAssertNil(PortQuery.parse("kill finder"))
        XCTAssertNil(PortQuery.parse("port 70000"))
        XCTAssertNil(PortQuery.parse("portal"))
        XCTAssertNil(PortQuery.parse("port 3000 now"))
        XCTAssertNil(PortQuery.parse("12 * 3"))
    }

    func testFirstPortInFreeText() {
        XCTAssertEqual(PortQuery.firstPort(in: "stop whatever is running on 3000 please"), 3000)
        XCTAssertNil(PortQuery.firstPort(in: "what is on my ports"))
        XCTAssertNil(PortQuery.firstPort(in: "port 99999"))
    }

    func testLsofOutputParses() {
        let output = """
        p812
        cnode
        n*:3000
        n[::1]:3000
        p90
        cpostgres
        n127.0.0.1:5432
        p812
        cnode
        n*:9229
        """
        XCTAssertEqual(ListeningPorts.parse(output), [
            ListeningPort(pid: 812, command: "node", port: 3000, exposed: true),
            ListeningPort(pid: 90, command: "postgres", port: 5432),
            ListeningPort(pid: 812, command: "node", port: 9229, exposed: true)
        ])
        XCTAssertEqual(ListeningPorts.parse(""), [])
    }

    func testExposureIsMergedPerProcessAndPort() {
        let output = "p812\ncnode\nn127.0.0.1:5173\nn[::1]:5173\np90\ncpostgres\nn*:5432\n"
        let ports = ListeningPorts.parse(output)
        XCTAssertEqual(ports.map(\.port), [5173, 5432])
        XCTAssertFalse(ports[0].exposed, "Loopback only.")
        XCTAssertTrue(ports[1].exposed, "Listens on every interface.")
    }

    func testProcessSnapshotsJoinPsAndLsof() {
        let snapshots = ProcessSnapshots.parse(
            stats: "  812   501  12.5  86016   02:05:09\n   90     0   0,3  20480 3-04:00:00\n",
            executables: "  812 /opt/homebrew/bin/node\n   90 /usr/libexec/rapportd\n",
            commandLines: "  812 node /Users/me/site/node_modules/.bin/vite --port 5173\n   90 /usr/libexec/rapportd\n",
            folders: "p812\nfcwd\nn/Users/me/site\np90\nfcwd\nn/\n")
        let node = try! XCTUnwrap(snapshots[812])
        XCTAssertEqual(node.cpu, 12.5)
        XCTAssertEqual(node.memoryText, "84 MB")
        XCTAssertEqual(node.uptime, 2 * 3600 + 5 * 60 + 9)
        XCTAssertEqual(node.uptimeText, "up 2 h")
        XCTAssertEqual(node.folder, "/Users/me/site")
        XCTAssertEqual(node.role, "vite")
        XCTAssertEqual(node.owner(currentUID: 501), .yours)
        let service = try! XCTUnwrap(snapshots[90])
        XCTAssertEqual(service.cpu, 0.3, "A comma decimal separator still reads.")
        XCTAssertNil(service.folder, "The root folder says nothing.")
        XCTAssertEqual(service.uptimeText, "up 3 d")
        XCTAssertEqual(service.owner(currentUID: 501), .otherUser)
        var system = service; system.uid = 501
        XCTAssertEqual(system.owner(currentUID: 501), .system)
    }

    func testProcessRoles() {
        func role(_ args: String) -> String { var p = ProcessSnapshot(pid: 1); p.arguments = args; return p.role }
        XCTAssertEqual(role("python3 -m http.server 8000"), "http.server")
        XCTAssertEqual(role("node /Users/me/app/node_modules/next/dist/bin/next dev -p 3000"), "next dev")
        XCTAssertEqual(role("node server.js"), "server.js")
        XCTAssertEqual(role("/opt/homebrew/opt/postgresql/bin/postgres -D /usr/local/var"), "postgres")
        XCTAssertEqual(role("bun run dev"), "dev")
        var python = ProcessSnapshot(pid: 1)
        python.executable = "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
        python.arguments = python.executable + " -m http.server 8765"
        XCTAssertEqual(python.role, "http.server", "Capitalised interpreter names count.")
        var app = ProcessSnapshot(pid: 2)
        app.executable = "/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)"
        app.arguments = app.executable + " --type=utility"
        XCTAssertEqual(app.role, "T3 Code (Nightly)", "A path with spaces stays whole.")
    }

    func testBuiltInCommandsAreFixedAndUnique() {
        let ids = SystemCommands.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for command in SystemCommands.all {
            XCTAssertFalse(command.steps.isEmpty, command.id)
            for step in command.steps {
                XCTAssertTrue(step.first?.hasPrefix("/") == true, "\(command.id) must name an absolute executable")
                XCTAssertFalse(["/bin/sh", "/bin/zsh", "/bin/bash"].contains(step.first!), "\(command.id) must not use a shell")
            }
        }
        XCTAssertTrue(SystemCommands.command(id: "empty-trash")!.confirm)
    }
}
