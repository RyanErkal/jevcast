import AppKit
import SwiftUI

/// Demo-only views. CalendarPage never reads EventKit, accounts, tokens, or preferences here.
@MainActor
enum CalendarSnapshots {
    static func writeAll(to directory: String) {
        let rig = LauncherSnapshotRig(catalogue: AppCatalogue(loadCache: false, roots: DemoData.appRoots, persistsCache: false), demo: true)
        let names = ["calendar-week", "calendar-day", "calendar-month", "calendar-details", "calendar-week-compact", "calendar-google-sign-in"]
        func render(_ index: Int) {
            guard index < names.count else { rig.removePreferences(); NSApp.terminate(nil); return }
            let list = SourcePage(.calendar, source: nil, model: rig.model, hasDetail: true, emptyText: "")
            let page = CalendarPage(list: list, readsEvents: false)
            page.opened()
            if index == 1 { page.setMode(.day) }
            if index == 2 { page.setMode(.month) }
            if index == 3, let event = page.displayedEvents.first(where: { $0.id == "demo0" }) { page.select(event) }
            let size = index == 4 ? NSSize(width: 860, height: 580) : index == 5 ? NSSize(width: 540, height: 420) : NSSize(width: 1140, height: 700)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
            if index == 5 {
                let defaults = UserDefaults(suiteName: LauncherSnapshotRig.suite)!
                let account = GoogleCalendarAccount(defaults: defaults, readToken: { nil }, saveToken: { _ in }, deleteToken: {}, readSecret: { nil })
                window.contentView = NSHostingView(rootView: CalendarGoogleSignIn(account: account, connected: {}))
            } else { window.contentView = NSHostingView(rootView: page.content()) }
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let content = window.contentView {
                    UISnapshots.write(content, name: names[index], to: directory)
                    print("[Jev snapshot] \(names[index]) content=\(Int(content.bounds.width))x\(Int(content.bounds.height))")
                    fflush(stdout)
                }
                window.orderOut(nil); page.closed(handingOff: false); render(index + 1)
            }
        }
        render(0)
    }
}
