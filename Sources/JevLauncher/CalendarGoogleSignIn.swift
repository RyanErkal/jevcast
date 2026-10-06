import LauncherCore
import AppKit
import SwiftUI

struct CalendarGoogleSignIn: View {
    @ObservedObject var account: GoogleCalendarAccount
    let connected: () -> Void
    var cancel: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var secret = ""
    @State private var problem: String?
    @State private var work: Task<Void, Never>?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect Google Calendar", systemImage: "calendar").font(.title2.weight(.semibold))
            Text("Sign in through your browser. Jevcast can read your calendars, event details, and meeting links. It cannot change or delete Google events.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Google Desktop app client ID", text: $clientID)
            SecureField("Desktop client secret", text: $secret)
            Text("You can use the Google client already set up for Mail. Calendar has its own sign-in and token.").font(.caption).foregroundStyle(.secondary)
            Text("Use a Desktop app OAuth client. Enable the Google Calendar API and add Calendar read-only access to the consent screen. Add your address as a test user while the app is in Testing. Leave the secret empty to keep the saved secret for this client.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Link("Google app setup", destination: MailOAuthProvider.google.setupURL)
                Link("Enable Calendar API", destination: URL(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")!)
            }.font(.caption)
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if working { HStack { ProgressView().controlSize(.small); Text("Finish sign-in in your browser…").foregroundStyle(.secondary) } }
            HStack {
                Button("Cancel") { work?.cancel(); if let cancel { cancel() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Sign in with Google") { signIn() }.keyboardShortcut(.defaultAction)
                    .disabled(working || (try? MailOAuthClient(provider: .google, clientID: clientID)) == nil)
            }
        }.padding(22).frame(width: 480)
            .onAppear { clientID = account.clientID }
            .onDisappear { work?.cancel() }
    }

    private func signIn() {
        working = true; problem = nil
        work = Task { @MainActor in
            defer { working = false }
            do { try await account.signIn(clientID: clientID, secret: secret); connected(); dismiss() }
            catch is CancellationError {}
            catch let error as MailOAuthError {
                problem = error == .invalidToken || error == .signInRequired
                    ? "Google did not grant Calendar access. Check your OAuth client and sign in again." : error.localizedDescription
            } catch { problem = error.localizedDescription }
        }
    }
}

/// A browser switch closes the launcher. This window owns the sign-in independently.
@MainActor
final class CalendarGoogleSignInWindow: NSObject, NSWindowDelegate {
    static let shared = CalendarGoogleSignInWindow()
    private var window: NSWindow?

    func show(account: GoogleCalendarAccount) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connect Google Calendar"; window.isReleasedWhenClosed = false; window.delegate = self
        let host = NSHostingView(rootView: CalendarGoogleSignIn(account: account, connected: { [weak self] in self?.close() }, cancel: { [weak self] in self?.close() }))
        host.sizingOptions = [.intrinsicContentSize]
        window.contentView = host
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func close() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        // Removing the view cancels a pending browser callback through onDisappear.
        window?.contentView = nil; window = nil
    }
}
