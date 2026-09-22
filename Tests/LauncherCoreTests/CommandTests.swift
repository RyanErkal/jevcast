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
            ListeningPort(pid: 812, command: "node", port: 3000),
            ListeningPort(pid: 90, command: "postgres", port: 5432),
            ListeningPort(pid: 812, command: "node", port: 9229)
        ])
        XCTAssertEqual(ListeningPorts.parse(""), [])
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
