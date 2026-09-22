import AppKit
import SwiftUI

/// One key cap, such as "⌘K" or "↩".
struct KeyChip: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(.system(size: LauncherMetrics.chipFontSize, weight: .medium))
            .padding(.horizontal, LauncherMetrics.chipPaddingX).padding(.vertical, LauncherMetrics.chipPaddingY)
            .background(RoundedRectangle(cornerRadius: LauncherMetrics.chipRadius).fill(.quaternary))
    }
}

/// What a key does, followed by its key chip, such as "Open Application ↩".
struct KeyHint: View {
    let label: String; let keys: String
    init(_ label: String, _ keys: String) { self.label = label; self.keys = keys }
    var body: some View {
        HStack(spacing: 6) {
            Text(label).lineLimit(1)
            KeyChip(keys)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
