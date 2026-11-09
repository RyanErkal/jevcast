import LauncherCore
import SwiftUI

/// Day, 3 Days, and Week: the day headers, all-day events, and a scrolling hourly grid.
struct CalendarTimeGrid: View {
    @ObservedObject var page: CalendarPage
    private let rail: CGFloat = 54
    private let hourHeight: CGFloat = 56
    /// Room above midnight and below the last hour, so their labels are not cut off.
    private let top: CGFloat = 8
    private var calendar: Calendar { .current }
    private var gridHeight: CGFloat { hourHeight * 24 + top * 2 }

    var body: some View {
        VStack(spacing: 0) {
            dayHeaders
            if allDayRows > 0 { allDay }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        // Each hour's row starts `top` above its line, so scrolling to it shows the label.
                        VStack(spacing: 0) {
                            ForEach(0..<24) { hour in Color.clear.frame(height: hourHeight).id(hour) }
                            Color.clear.frame(height: top * 2)
                        }
                        GeometryReader { geometry in
                            let dayWidth = max(1, (geometry.size.width - rail) / CGFloat(max(1, page.days.count)))
                            todayTint(dayWidth: dayWidth, height: gridHeight).offset(x: rail)
                            lines(width: geometry.size.width, dayWidth: dayWidth)
                            // A double-click on an empty time starts a new event there.
                            Color.clear.contentShape(Rectangle())
                                .frame(width: max(0, geometry.size.width - rail), height: hourHeight * 24).offset(x: rail, y: top)
                                .onTapGesture(count: 2) { point in
                                    let index = min(page.days.count - 1, max(0, Int(point.x / dayWidth)))
                                    guard page.days.indices.contains(index) else { return }
                                    page.beginCreate(on: page.days[index], minute: Int(point.y / hourHeight * 60))
                                }
                            // One timer draws both the faint line under the events and the clock over them.
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                ZStack(alignment: .topLeading) {
                                    nowAcross(now: context.date, width: geometry.size.width)
                                    ForEach(Array(page.days.enumerated()), id: \.element) { index, day in
                                        eventColumn(day: day, width: dayWidth, index: index)
                                    }
                                    clock(now: context.date, width: geometry.size.width, dayWidth: dayWidth)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                    .frame(height: gridHeight)
                }
                .onAppear { proxy.scrollTo(firstHour, anchor: .top) }
            }
        }
    }

    /// Opens at 08:00, or earlier when an event on screen starts earlier.
    private var firstHour: Int {
        let starts = page.days.flatMap { day in
            page.events(on: day).filter { !$0.allDay && calendar.isDate($0.start, inSameDayAs: day) }
                .map { calendar.component(.hour, from: $0.start) }
        }
        return min(8, starts.min() ?? 8)
    }

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            Text(TimeZone.current.abbreviation() ?? "").font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(width: rail - 10, alignment: .trailing).padding(.trailing, 10)
                .help(TimeZone.current.identifier.replacingOccurrences(of: "_", with: " "))
            ForEach(page.days, id: \.self) { day in
                Button { if page.mode != .day { page.showDay(day) } } label: { dayLabel(day) }
                    .buttonStyle(.plain).help(page.mode == .day ? "" : "Show this day")
            }
        }
        .frame(height: 40)
    }

    @ViewBuilder private func dayLabel(_ day: Date) -> some View {
        let today = calendar.isDateInToday(day)
        let number = Text(day.formatted(.dateTime.day())).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            .foregroundStyle(today ? Color.white : .primary)
            .frame(minWidth: 22, minHeight: 22).padding(.horizontal, today ? 2 : 0)
            .background(Capsule().fill(today ? Color.accentColor : .clear))
        let weekday = { (style: Date.FormatStyle.Symbol.Weekday) in
            Text(day.formatted(.dateTime.weekday(style))).foregroundStyle(today ? Color.accentColor : .secondary)
        }
        Group {
            if page.days.count <= 3 {
                HStack(spacing: 6) {
                    weekday(.wide).font(.system(size: 13, weight: .medium))
                    number
                    if page.mode == .day { Text(day.formatted(.dateTime.month(.wide))).font(.system(size: 13)).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            } else {
                HStack(spacing: 5) { weekday(.abbreviated).font(.system(size: 12)); number }
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        .background(today && page.days.count > 1 ? Color.accentColor.opacity(0.04) : .clear)
    }

    private var allDayRows: Int { min(3, page.days.map { page.events(on: $0).filter(\.allDay).count }.max() ?? 0) }

    private var allDay: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("All day").font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: rail - 10, alignment: .trailing).padding(.trailing, 10).padding(.top, 9)
            ForEach(page.days, id: \.self) { day in
                let events = page.events(on: day).filter(\.allDay)
                VStack(spacing: 2) {
                    ForEach(events.prefix(3)) { event in
                        CalendarEventButton(event: event, selected: page.selectedEvent?.id == event.id) { page.select(event) }.frame(height: 20)
                    }
                    if events.count > 3 {
                        Button("+\(events.count - 3) more") { page.showDay(day); page.setMode(.list) }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 3).padding(.vertical, 5)
                .frame(maxWidth: .infinity, minHeight: CGFloat(allDayRows) * 22 + 10, alignment: .top)
                .background(calendar.isDateInToday(day) && page.days.count > 1 ? Color.accentColor.opacity(0.04) : .clear)
            }
        }
    }

    @ViewBuilder private func todayTint(dayWidth: CGFloat, height: CGFloat) -> some View {
        if page.days.count > 1, let index = page.days.firstIndex(where: calendar.isDateInToday) {
            Rectangle().fill(Color.accentColor.opacity(0.04)).frame(width: dayWidth, height: height)
                .offset(x: CGFloat(index) * dayWidth).allowsHitTesting(false)
        }
    }

    private func lines(width: CGFloat, dayWidth: CGFloat) -> some View {
        Path { path in
            for hour in 0...24 {
                let y = top + CGFloat(hour) * hourHeight
                path.move(to: CGPoint(x: rail, y: y)); path.addLine(to: CGPoint(x: width, y: y))
            }
            for day in 0...page.days.count {
                let x = rail + CGFloat(day) * dayWidth
                path.move(to: CGPoint(x: x, y: top)); path.addLine(to: CGPoint(x: x, y: top + hourHeight * 24))
            }
        }.stroke(Color.secondary.opacity(0.16), lineWidth: 0.5).allowsHitTesting(false)
    }

    /// Where the current time falls in the grid, when today is on screen.
    private func now(_ date: Date) -> (index: Int, y: CGFloat)? {
        guard let index = page.days.firstIndex(where: { calendar.isDate($0, inSameDayAs: date) }) else { return nil }
        return (index, top + CGFloat(CalendarTimeLayout.minute(date, on: page.days[index], calendar: calendar)) / 60 * hourHeight)
    }

    /// A faint line for the current time across the other days, under their events.
    @ViewBuilder private func nowAcross(now date: Date, width: CGFloat) -> some View {
        if page.days.count > 1, let y = now(date)?.y {
            Rectangle().fill(Color.red.opacity(0.3)).frame(width: max(0, width - rail), height: 1)
                .offset(x: rail, y: y - 0.5).allowsHitTesting(false)
        }
    }

    /// Hour labels and the current time. A label near the current time gives way to it.
    private func clock(now date: Date, width: CGFloat, dayWidth: CGFloat) -> some View {
        let current = now(date)
        let midnight = calendar.startOfDay(for: date)
        return ZStack(alignment: .topLeading) {
            ForEach(0..<25) { hour in
                let y = top + CGFloat(hour) * hourHeight
                if current.map({ abs($0.y - y) >= 11 }) ?? true {
                    Text((calendar.date(byAdding: .hour, value: hour % 24, to: midnight) ?? midnight).formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: rail - 10, alignment: .trailing).offset(y: y - 6)
                }
            }
            if let current {
                HStack(spacing: 0) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Rectangle().fill(Color.red).frame(height: 1.5)
                }
                .frame(width: dayWidth + 3.5).offset(x: rail + CGFloat(current.index) * dayWidth - 3.5, y: current.y - 3.5)
                Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white).padding(.horizontal, 4).frame(height: 15).background(Capsule().fill(Color.red))
                    .fixedSize().frame(width: rail - 6, alignment: .trailing).offset(y: current.y - 7.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func eventColumn(day: Date, width: CGFloat, index: Int) -> some View {
        let events = page.events(on: day).filter { !$0.allDay }
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let placements = CalendarTimeLayout.placements(events.map { .init(id: $0.id, start: $0.start, end: $0.end) }, on: day)
        ForEach(placements, id: \.id) { placement in
            if let event = byID[placement.id] {
                let lane = (width - 6) / CGFloat(placement.columns)
                let height = max(18, CGFloat(placement.endMinute - placement.startMinute) / 60 * hourHeight - 2)
                CalendarGridEvent(page: page, event: event, block: height >= 38, dayWidth: width, hourHeight: hourHeight)
                    .frame(width: max(10, lane - (placement.column + 1 < placement.columns ? 2 : 0)), height: height)
                    .offset(x: rail + CGFloat(index) * width + 3 + CGFloat(placement.column) * lane,
                            y: top + CGFloat(placement.startMinute) / 60 * hourHeight + 1)
            }
        }
    }
}

/// One event in the hourly grid. An event Jevcast can change moves when dragged: up and down by
/// quarter hours, sideways by days. It is saved when dropped.
private struct CalendarGridEvent: View {
    @ObservedObject var page: CalendarPage
    let event: CalendarPage.Event
    let block: Bool
    let dayWidth: CGFloat
    let hourHeight: CGFloat
    @State private var drag = CGSize.zero

    var body: some View {
        let button = CalendarEventButton(event: event, selected: page.selectedEvent?.id == event.id,
                                         style: block ? .block : .line, fillsHeight: true) { page.select(event) }
        if event.editable, page.writer != nil {
            button.offset(snapped).zIndex(drag == .zero ? 0 : 1).opacity(drag == .zero ? 1 : 0.8)
                .simultaneousGesture(DragGesture(minimumDistance: 6)
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        let move = Self.move(value.translation, dayWidth: dayWidth, hourHeight: hourHeight)
                        drag = .zero
                        page.move(event, minutes: move.minutes, days: move.days)
                    })
        } else { button }
    }

    /// The dragged distance as whole days and quarter hours.
    static func move(_ translation: CGSize, dayWidth: CGFloat, hourHeight: CGFloat) -> (minutes: Int, days: Int) {
        (CalendarEventDraft.snappedMinutes(Double(translation.height / hourHeight * 60)), Int((translation.width / max(1, dayWidth)).rounded()))
    }

    private var snapped: CGSize {
        let move = Self.move(drag, dayWidth: dayWidth, hourHeight: hourHeight)
        return CGSize(width: CGFloat(move.days) * dayWidth, height: CGFloat(move.minutes) / 60 * hourHeight)
    }
}
