import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One scale for Mail's text, spacing, and motion, close to the launcher's own, so Mail reads as
/// part of the same app.
enum MailStyle {
    static let sender: CGFloat = 14
    static let subject: CGFloat = 13
    static let preview: CGFloat = 12
    static let meta: CGFloat = 11.5
    static let body: CGFloat = 14.5
    static let title: CGFloat = 17
    /// Text lines longer than this are hard to read, so a plain message stops here.
    static let readingWidth: CGFloat = 760

    /// Short and quiet. Nothing moves when Reduce Motion is on.
    static var motion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18)
    }

    /// "PDF document · 2 KB" in place of a MIME type.
    static func kind(mimeType: String, filename: String) -> String {
        let fromName = (filename as NSString).pathExtension
        if let type = UTType(mimeType: mimeType) ?? UTType(filenameExtension: fromName), let name = type.localizedDescription, !name.isEmpty {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return fromName.isEmpty ? "File" : fromName.uppercased() + " file"
    }

    /// One or two letters for a sender with no picture: "Sam Lee" gives "SL".
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }

    /// Marks each place the search words occur, so a result shows why it matched.
    static func highlighted(_ text: String, words: String) -> AttributedString {
        var result = AttributedString(text)
        for word in words.split(whereSeparator: \.isWhitespace) where word.count >= 2 {
            var from = result.startIndex
            while from < result.endIndex, let range = result[from...].range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive]) {
                result[range].backgroundColor = Color.yellow.opacity(0.32)
                result[range].foregroundColor = .primary
                from = range.upperBound
            }
        }
        return result
    }
}

/// A sender's initials on a steady color, where a picture would be.
struct MailAvatar: View {
    let name: String
    let address: String
    var size: CGFloat = 34
    var body: some View {
        Text(MailStyle.initials(name.isEmpty ? address : name))
            .font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(MailAccountMark.color(for: address.lowercased()).gradient))
            .accessibilityHidden(true)
    }
}

/// An icon button in Mail's toolbars: it lights up under the pointer, so it reads as a button.
struct MailIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Lit(configuration: configuration) }
    private struct Lit: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .padding(.horizontal, 5).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering && enabled ? 0.08 : 0)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Where a list or a pane has nothing to show: a symbol, what is true, and what to do next.
struct MailEmptyState: View {
    let symbol: String
    let title: String
    var detail: String?
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center) }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Grey rows where messages will be, while the first page loads.
struct MailLoadingRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.09)).frame(width: 120 + CGFloat(index % 3) * 30, height: 11)
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 200 + CGFloat(index % 2) * 40, height: 10)
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05)).frame(maxWidth: .infinity).frame(height: 9)
                }
                .padding(.horizontal, 22).padding(.vertical, 10)
                Divider().padding(.leading, 22)
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Loading messages")
    }
}
