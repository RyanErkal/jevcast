import XCTest
import LauncherCore
@testable import JevLauncher

final class MailScriptCompileTests: XCTestCase {
    /// Compile the fixed scripts against the local Mail dictionary. Do not execute them.
    func testScriptsCompileWithoutExecutingMailActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mail-script-compile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scripts = [MailScripts.reply, MailScripts.forward, MailScripts.send, MailScripts.delete, MailScripts.move,
                       MailScripts.setRead, MailScripts.setFlagged, MailScripts.sendingIdentities, MailScripts.outboxCount]
        for (index, script) in scripts.enumerated() {
            let input = directory.appendingPathComponent("\(index).applescript"), output = directory.appendingPathComponent("\(index).scpt")
            try script.write(to: input, atomically: true, encoding: .utf8)
            _ = try await CommandRunner.capture(["/usr/bin/osacompile", "-o", output.path, input.path], timeout: 15)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
    }
}
