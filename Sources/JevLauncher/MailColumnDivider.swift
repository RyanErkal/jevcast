import AppKit
import SwiftUI

/// The line between two of Mail's columns. Drag it to make the column on its left wider or
/// narrower; double-click it to go back to the width that follows the panel. The line is one
/// point wide; the area that takes the pointer is wider, with the resize pointer over it.
struct MailColumnDivider: View {
    /// The column's width when a drag starts.
    let width: CGFloat
    /// What the column holds, for VoiceOver: "mailboxes" or "message list".
    let title: String
    /// The width the pointer asks for. The page clamps it.
    let resize: (CGFloat) -> Void
    let end: () -> Void
    let reset: () -> Void
    @State private var start: CGFloat?
    @State private var hovering = false

    static let hitWidth: CGFloat = 9

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: Self.hitWidth)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != hovering else { return }
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let base = start ?? width
                            if start == nil { start = width }
                            resize(base + value.translation.width)
                        }
                        .onEnded { _ in start = nil; end() })
                    .onTapGesture(count: 2, perform: reset)
            }
            // Above the columns on both sides, so the wider area takes the pointer.
            .zIndex(1)
            .onDisappear { if hovering { hovering = false; NSCursor.pop() } }
            .help("Drag to resize the \(title). Double-click to reset.")
            .accessibilityElement()
            .accessibilityLabel("Width of the \(title)")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: resize(width + 20); end()
                case .decrement: resize(width - 20); end()
                @unknown default: break
                }
            }
    }
}
