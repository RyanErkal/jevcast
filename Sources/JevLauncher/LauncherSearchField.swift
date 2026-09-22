import AppKit
import SwiftUI

/// Use AppKit's real first responder, rather than a SwiftUI focus flag that
/// can remain true while a hidden panel loses keyboard focus.
struct LauncherSearchField: NSViewRepresentable {
    @ObservedObject var model: LauncherModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: model.query)
        field.placeholderString = "Search"
        field.font = .systemFont(ofSize: LauncherMetrics.searchFontSize)
        field.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("launcher-query")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        model.focusSearch = { [weak field] in
            guard let field, let window = field.window else { return }
            if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != model.query { field.stringValue = model.query }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: LauncherModel
        init(model: LauncherModel) { self.model = model }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.updateQuery(field.stringValue, typed: true)
            if CommandLine.arguments.contains("--trace-interaction") {
                print("[Jev interaction] typed queryLength=\(field.stringValue.count)"); fflush(stdout)
            }
        }
    }
}
