import AppKit
import SwiftUI
import XCTest
@testable import JevLauncher

/// Renders the demo window offscreen. Set AUTOMATION_SNAPSHOT_DIR to also write PNGs for review.
final class AutomationsWindowTests: XCTestCase {
    @MainActor private func render<V: View>(_ view: V, size: NSSize, name: String) -> NSView {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.setContentSize(size)
        // Tables and materials draw only in a window on screen.
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        defer { window.orderOut(nil) }
        if let dir = ProcessInfo.processInfo.environment["AUTOMATION_SNAPSHOT_DIR"] {
            UISnapshots.write(hosting, name: name, to: dir)
        }
        return hosting
    }

    @MainActor func testDemoViewsRender() {
        let size = NSSize(width: 1100, height: 720)
        for section in AutomationsViewModel.Section.allCases {
            let view = render(AutomationsWindow.snapshotView(demo: true, section: section), size: size, name: "section-" + section.rawValue)
            XCTAssertGreaterThan(view.fittingSize.width, 0, section.rawValue)
            XCTAssertGreaterThan(view.fittingSize.height, 0, section.rawValue)
        }
        _ = render(AutomationsWindow.snapshotView(demo: false, section: .all), size: size, name: "empty-all")
        for template in [AutomationTemplate.desktopTidy, .metricsRefresh] {
            let editor = render(AutomationsWindow.snapshotEditor(template), size: NSSize(width: 700, height: 760), name: "editor-" + template.rawValue)
            XCTAssertGreaterThan(editor.fittingSize.height, 0)
        }
    }
}

/// Parts rendered outside scroll views, because cacheDisplay leaves List, ScrollView, and Form blank.
final class AutomationPartsSnapshotTests: XCTestCase {
    @MainActor func testPartsRender() throws {
        guard let dir = ProcessInfo.processInfo.environment["AUTOMATION_SNAPSHOT_DIR"] else { throw XCTSkip("Review renders only") }
        let model = AutomationsViewModel(center: nil, quill: nil, demo: AutomationsDemoData.make())
        let demo = model.demo!
        let tidy = model.automation("desktop-tidy-demo")!
        let manifest = demo.proposals[AutomationsDemoData.approvalRunID]!
        func save<V: View>(_ v: V, _ name: String, width: CGFloat = 560) {
            let r = ImageRenderer(content: v.frame(width: width).padding(16).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("part-" + name + ".png"))
            }
        }
        save(VStack(spacing: 8) { ForEach(model.filteredAutomations) { AutomationRow(model: model, automation: $0) } }, "rows", width: 360)
        save(VStack(spacing: 8) { ForEach(model.allRuns) { RunRow(model: model, run: $0, showsName: true) } }, "runrows", width: 360)
        save(AutomationDetailView(model: model, automation: tidy).frame(height: 120), "header", width: 600)
        save(VStack(alignment: .leading, spacing: 10) {
            ForEach(manifest.proposal.items) { item in
                ProposalRow(item: item, checked: manifest.checked.first { $0.id == item.id }, refusal: manifest.refused[item.id], isOn: .constant(true), preview: {})
            }
        }, "proposal", width: 600)
        save(HStack(alignment: .top) { ForEach(demo.clients) { ClientCard(model: model, entry: $0) } }, "clients", width: 760)
        save(VStack { ForEach(demo.codex) { CodexCard(model: model, item: $0) } }, "codex", width: 700)
        save(VStack { ForEach(demo.quillTasks) { QuillTaskRow(model: model, task: $0) } }, "quill", width: 700)
        save(RunnerStatusPopover(model: model, status: .needsApproval), "popover", width: 300)
        save(QuillExplainerSheet(model: model), "explainer", width: 480)
    }
}
