import LauncherCore
import SwiftUI

/// The event editor beside the calendar: a new event or a change. ⌘↩ saves; Escape cancels.
struct CalendarEventEditor: View {
    @ObservedObject var page: CalendarPage
    @FocusState private var titleFocused: Bool

    var body: some View {
        if let editing = page.editing {
            let draft = Binding(get: { page.editing?.draft ?? editing.draft }, set: { page.editing?.draft = $0 })
            VStack(spacing: 0) {
                HStack {
                    Text(editing.isNew ? "New event" : "Edit event").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Cancel") { page.cancelEdit() }.buttonStyle(.borderless).help("Cancel (esc)")
                }
                .padding(.horizontal, 16).frame(height: 40)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Title", text: draft.title).textFieldStyle(.roundedBorder).font(.system(size: 14))
                            .focused($titleFocused).onSubmit { page.saveEdit() }
                        Toggle("All day", isOn: draft.allDay).toggleStyle(.switch).controlSize(.small)
                        VStack(alignment: .leading, spacing: 6) {
                            row("Starts") {
                                DatePicker("Starts", selection: Binding(get: { draft.wrappedValue.start }, set: { new in
                                    // Moving the start keeps the length, as in Calendar.
                                    let length = draft.wrappedValue.end.timeIntervalSince(draft.wrappedValue.start)
                                    draft.wrappedValue.start = new; draft.wrappedValue.end = new.addingTimeInterval(max(0, length))
                                }), displayedComponents: draft.wrappedValue.allDay ? [.date] : [.date, .hourAndMinute]).labelsHidden()
                            }
                            row("Ends") {
                                DatePicker("Ends", selection: draft.end, displayedComponents: draft.wrappedValue.allDay ? [.date] : [.date, .hourAndMinute]).labelsHidden()
                            }
                        }
                        if !page.writableCalendars.isEmpty {
                            row("Calendar") {
                                Picker("Calendar", selection: draft.calendarID) {
                                    ForEach(page.writableCalendars) { calendar in
                                        Text(calendar.title + " · " + calendar.account).tag(Optional(calendar.id))
                                    }
                                }.labelsHidden().controlSize(.small)
                            }
                        }
                        TextField("Location or call link", text: draft.location).textFieldStyle(.roundedBorder)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            TextEditor(text: draft.notes).font(.system(size: 12)).frame(minHeight: 90)
                                .scrollContentBackground(.hidden).padding(5)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                        }
                        if editing.recurring {
                            Picker("Change", selection: Binding(get: { page.editing?.future ?? false }, set: { page.editing?.future = $0 })) {
                                Text("This event").tag(false)
                                Text("This and future events").tag(true)
                            }.pickerStyle(.radioGroup).font(.system(size: 12))
                        }
                        if let problem = page.editProblem {
                            Text(problem).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 16).padding(.bottom, 12)
                }
                Divider()
                HStack {
                    Spacer()
                    Button(editing.isNew ? "Add Event" : "Save") { page.saveEdit() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.wrappedValue.trimmedTitle.isEmpty)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .onAppear { DispatchQueue.main.async { titleFocused = true } }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}
