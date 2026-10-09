import XCTest
import LauncherCore
@testable import JevLauncher

/// What a failed send through Apple Mail means. Only a failure during or after Mail's `send`, or one
/// at a point Jevcast cannot know, may have sent the message. Nothing here talks to Mail.
final class MailSendFailureTests: XCTestCase {
    private func failure(_ text: String) -> Error { CommandRunner.Failure(text: text) }

    func testOnlyFailuresDuringOrAfterSendMayHaveSent() {
        let maybe = [
            "0:1402: execution error: Mail stopped while it sent the message. (1005)",
            "0:1402: execution error: Mail got an error: AppleEvent timed out. (-1712)",
            "osascript took too long and was stopped."
        ]
        for text in maybe { XCTAssertTrue(MailActions.sendFailure(failure(text)) is MailMaybeSentError, text) }
        XCTAssertTrue(MailActions.sendFailure(CancellationError()) is MailMaybeSentError, "A cancel stops the script at an unknown point")

        let notSent = [
            "0:1402: execution error: Mail got an error: AppleEvent timed out. (1004)",
            "0:1402: execution error: Mail did not take the text, so nothing was sent. (1003)",
            "0:1402: execution error: Mail did not send the message. (1002)",
            "0:1402: execution error: Mail got an error: Can’t get account id \"A\". (-1728)",
            "osascript failed with code 1.",
            "osascript could not start."
        ]
        for text in notSent {
            let error = MailActions.sendFailure(failure(text))
            XCTAssertFalse(error is MailMaybeSentError, text)
            XCTAssertEqual(error.localizedDescription, text, "The error stays as it was")
        }
        XCTAssertFalse(MailActions.sendFailure(LauncherError("Apple Mail is not installed.")) is MailMaybeSentError)
        XCTAssertEqual(MailMaybeSentError().localizedDescription, "Mail may have sent this message. Check Sent before you send it again.")
    }

    func testErrorNumberIsTheLastNumberInParentheses() {
        XCTAssertEqual(MailActions.errorNumber("0:12: execution error: Mail stopped (really) while it sent the message. (1005)"), 1005)
        XCTAssertEqual(MailActions.errorNumber("0:12: execution error: Mail got an error: AppleEvent timed out. (-1712)"), -1712)
        XCTAssertNil(MailActions.errorNumber("osascript took too long and was stopped."))
        XCTAssertNil(MailActions.errorNumber("Mail got an error (see Console)"))
    }

    /// `CommandRunner` writes the time-limit text; a real stopped process shows that both agree.
    @MainActor
    func testTheTimeLimitOfARealProcessMayHaveSent() async {
        let finished = expectation(description: "The timed process reports its result")
        let work = Task { @MainActor in
            defer { finished.fulfill() }
            do {
                _ = try await CommandRunner.capture(["/bin/sleep", "5"], timeout: 0.2)
                XCTFail("The time limit stops the process")
            } catch {
                XCTAssertTrue(MailActions.sendFailure(error) is MailMaybeSentError, error.localizedDescription)
            }
        }
        // Match the app-actor context of the other CommandRunner checks. Keep this test
        // bounded even if the subprocess bridge stops returning its continuation.
        await fulfillment(of: [finished], timeout: 10)
        work.cancel()
    }
}
