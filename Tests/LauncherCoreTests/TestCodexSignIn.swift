import Foundation

/// A fake ChatGPT sign-in for tests that run fake `codex` scripts, so the subscription check passes.
/// The tokens are placeholders; nothing reads them but `CodexAuth`.
enum TestCodexSignIn {
    static func install(home: URL) throws {
        let folder = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"OPENAI_API_KEY":null,"tokens":{"access_token":"test-access","refresh_token":"test-refresh"}}"#.utf8)
            .write(to: folder.appendingPathComponent("auth.json"))
    }
}
