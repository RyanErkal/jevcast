import SwiftUI
import LauncherCore

/// A small spinner that shows only when loading takes longer than a moment, so a quick load
/// does not blink.
struct MailDelayedSpinner: View {
    /// Seconds before the spinner shows.
    static let delay: Double = 0.15
    @State private var shows = false
    var body: some View {
        ProgressView().controlSize(.small)
            .opacity(shows ? 1 : 0)
            .accessibilityHidden(!shows)
            .task {
                try? await Task.sleep(nanoseconds: UInt64(Self.delay * 1_000_000_000))
                if !Task.isCancelled { shows = true }
            }
    }
}

/// Quiet grey lines where the message text will be, while its body loads.
struct MailBodyPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array([0.35, 0.92, 0.85, 0.9, 0.6].enumerated()), id: \.offset) { _, fraction in
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07))
                        .frame(width: min(geo.size.width, MailStyle.readingWidth) * fraction)
                }
                .frame(height: 10)
            }
            MailDelayedSpinner().frame(maxWidth: .infinity).padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading message")
    }
}

/// The message's body is not on this Mac yet: what is true, and two ways on.
struct MailBodyMissing: View {
    @ObservedObject var model: MailModel
    var body: some View {
        VStack(spacing: 12) {
            Text("Mail has not downloaded this message yet.").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Retry Download") { model.retrySelectedBody() }
                if !NativeMailCenter.isActive { Button("Open in Mail") { model.openInMail() } }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
