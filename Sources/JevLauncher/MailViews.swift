import SwiftUI
import LauncherCore

struct MailSetupView: View {
    @ObservedObject var model: MailModel
    let needsAccess: Bool
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: needsAccess ? "lock.shield" : "envelope").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(needsAccess ? "Allow Jevcast to read Mail" : NativeMailCenter.isActive ? "Add a mail account" : "Set up Apple Mail first").font(.title2.weight(.semibold))
            if needsAccess {
                Text("macOS protects Apple Mail's messages. Full Disk Access does not list apps by itself, so add Jevcast once:")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Click Open Full Disk Access.")
                    Text("2. Click + below the list, choose Jevcast in Applications, and click Open. Or drag Jevcast from the Finder window into the list.")
                    Text("3. Make sure the Jevcast switch is on.")
                    Text("4. Click Restart Jevcast. macOS applies the access only to a new start.")
                }
                .font(.callout).frame(maxWidth: 460, alignment: .leading)
                Text("HTML mail loads its web images, fonts, and style sheets. Turn this off with Load Images from the Web in the ⋯ menu. A message is sent to the writing model only when you use AI on it.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                HStack {
                    Button("Open Full Disk Access") { Permissions.open("Privacy_AllFiles") }
                    Button("Show Jevcast in Finder") { Frontmost.reveal([Bundle.main.bundleURL]) }
                    Button("Restart Jevcast") { Relaunch.now() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text(NativeMailCenter.isActive ? "Jevcast syncs the accounts you add in Settings › Mail. Add one there, then check again."
                     : "Jevcast shows the accounts you add to Apple Mail. Add an account in Mail, then check again.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
                Button("Check Again") { model.refreshStatus() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum MailRow {
    static func date(_ date: Date) -> String { MailDates.short(date) }
}

/// The notes at the bottom of the mail views. While a sent message waits, it counts down and
/// offers Undo; while it goes to Mail, it says so. A draft that did not go stays here with Show
/// until you take it back. Other notes go away after a few seconds or on a click. The Undo note of
/// an archive, delete, or move shows below them for its whole time, so no other note hides it.
struct MailBanner: View {
    @ObservedObject var model: MailModel
    /// True while a text box has the keys, such as the composer: ⌘Z is the text's own undo there.
    var typing = false

    /// True when the note for `note` shows ⌘Z: the key undoes that note's change, and no text box
    /// has the keys. The note's Undo button stays either way.
    static func showsUndoKey(_ target: MailModel.UndoKeyTarget, on note: MailModel.UndoKeyTarget, typing: Bool) -> Bool {
        !typing && target == note
    }

    /// Clears the "Draft saved." note after its time. Leaving Mail cancels the wait, and the
    /// note stays, so it shows again for its whole time when Mail opens again.
    @MainActor static func expireDraftNote(_ note: String, _ model: MailModel, after nanoseconds: UInt64 = 6_000_000_000) async {
        do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
        if model.draftNote == note { model.draftNote = nil }
    }

    var body: some View {
        VStack(spacing: 6) {
            status
            if let change = model.lastChange {
                let key = Self.showsUndoKey(model.undoKeyTarget, on: .change, typing: typing)
                HStack(spacing: 8) {
                    Text(change.title)
                    Text("·").foregroundStyle(.secondary)
                    // ⌘Z goes to the waiting send first, so only that note shows the key then.
                    Button("Undo") { model.undoLastChange() }.buttonStyle(.link)
                        .help(key ? "Undo (⌘Z)" : "Undo")
                    if key { KeyChip("⌘Z") }
                }
                .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                // The time stops while the pointer is on the note.
                .onHover { model.hoverUndo($0) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder private var status: some View {
        if model.pendingSend != nil {
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Text("Sends in \(secondsLeft(at: context.date)) s").monospacedDigit()
                }
                Text("·").foregroundStyle(.secondary)
                let key = Self.showsUndoKey(model.undoKeyTarget, on: .send, typing: typing)
                Button("Undo") { model.undoSend() }.buttonStyle(.link).help(key ? "Undo (⌘Z)" : "Undo")
                if key { KeyChip("⌘Z") }
            }
            .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        } else if let banner = model.banner {
            Text(banner).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .onTapGesture { model.banner = nil }
                .task(id: banner) { try? await Task.sleep(nanoseconds: 4_000_000_000); if model.banner == banner { model.banner = nil } }
        } else if let note = model.draftNote {
            HStack(spacing: 8) {
                Text(note)
                Button("Open") { model.reopenDraft() }.buttonStyle(.link).help("Open the draft again")
            }
            .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .task(id: note) { await Self.expireDraftNote(note, model) }
        } else if model.sending {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Sending…")
            }
            .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        } else if let first = model.notSent.first {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(model.notSent.count == 1 ? first.reason : "\(model.notSent.count) messages were not sent.")
                Button("Show") { model.showUnsent() }.buttonStyle(.link).help("Open the message again")
            }
            .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        }
    }

    private func secondsLeft(at date: Date) -> Int {
        max(1, Int((model.sendsAt?.timeIntervalSince(date) ?? 0).rounded(.up)))
    }
}
