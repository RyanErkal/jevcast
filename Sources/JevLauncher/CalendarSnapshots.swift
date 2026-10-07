import AppKit
import SwiftUI

/// Demo-only views. CalendarPage never reads EventKit, accounts, tokens, or preferences here.
@MainActor
enum CalendarSnapshots {
    static func writeAll(to directory: String) {
        let rig = LauncherSnapshotRig(catalogue: AppCatalogue(loadCache: false, roots: DemoData.appRoots, persistsCache: false), demo: true)
        let names = ["calendar-3-days", "calendar-3-days-details", "calendar-3-days-light", "calendar-3-days-compact",
                     "calendar-week", "calendar-day", "calendar-month", "calendar-google-sign-in"]
        func render(_ index: Int) {
            guard index < names.count else { rig.removePreferences(); NSApp.terminate(nil); return }
            let name = names[index]
            let list = SourcePage(.calendar, source: nil, model: rig.model, hasDetail: true, emptyText: "")
            let defaults = UserDefaults(suiteName: LauncherSnapshotRig.suite)!
            let account = GoogleCalendarAccount(defaults: defaults, readToken: { nil }, saveToken: { _ in }, deleteToken: {}, readSecret: { nil })
            let page = CalendarPage(list: list, readsEvents: false, google: name == "calendar-3-days-compact" ? account : nil)
            page.opened()
            if name == "calendar-3-days-compact", let month = Calendar.current.dateInterval(of: .month, for: Date()) {
                page.showDay(month.end.addingTimeInterval(-86_400 - 1)); page.setMode(.threeDays)
            }
            if name == "calendar-week" { page.setMode(.week) }
            if name == "calendar-day" { page.setMode(.day) }
            if name == "calendar-month" { page.setMode(.month) }
            if name == "calendar-3-days-details" || name == "calendar-3-days-compact",
               let event = page.displayedEvents.first(where: { $0.id == "demo0" }) { page.select(event) }
            let size = name == "calendar-3-days-compact" ? NSSize(width: 860, height: 580)
                : name == "calendar-google-sign-in" ? NSSize(width: 540, height: 420) : NSSize(width: 1140, height: 700)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
            if name == "calendar-3-days-light" { window.appearance = NSAppearance(named: .aqua) }
            if name == "calendar-google-sign-in" {
                window.contentView = NSHostingView(rootView: CalendarGoogleSignIn(account: account, connected: {}))
            } else { window.contentView = NSHostingView(rootView: page.content()) }
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let content = window.contentView {
                    UISnapshots.write(content, name: name, to: directory)
                    print("[Jev snapshot] \(name) content=\(Int(content.bounds.width))x\(Int(content.bounds.height))")
                    fflush(stdout)
                }
                window.orderOut(nil); page.closed(handingOff: false); render(index + 1)
            }
        }
        render(0)
    }
}
