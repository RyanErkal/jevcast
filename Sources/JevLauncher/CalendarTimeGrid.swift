import LauncherCore
import SwiftUI

struct CalendarTimeGrid: View {
    @ObservedObject var page: CalendarPage
    private let rail: CGFloat = 62
    private let hourHeight: CGFloat = 60
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("TIME").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).frame(width: rail)
                ForEach(page.days, id: \.self) { day in
                    Button { page.showDay(day) } label: {
                        VStack(spacing: 3) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.system(size: 10, weight: .medium))
                            Text(day.formatted(.dateTime.day())).font(.system(size: 21, weight: .medium))
                                .frame(width: 34, height: 34).background(Circle().fill(Calendar.current.isDateInToday(day) ? Color.accentColor.opacity(0.18) : .clear))
                        }.frame(maxWidth: .infinity).foregroundStyle(Calendar.current.isDateInToday(day) ? Color.accentColor : .primary)
                    }.buttonStyle(.plain).help("Show this day")
                }
            }.padding(.vertical, 7)
            Divider()
            allDay
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(0..<24) { hour in Color.clear.frame(height: hourHeight).id(hour) }
                        }
                        GeometryReader { geometry in
                            let dayWidth = max(1, (geometry.size.width - rail) / CGFloat(max(1, page.days.count)))
                            lines(width: geometry.size.width, dayWidth: dayWidth)
                            ForEach(0..<24) { hour in
                                Text(String(format: "%02d:00", hour)).font(.system(size: 10)).foregroundStyle(.secondary)
                                    .frame(width: rail - 12, alignment: .trailing).offset(y: CGFloat(hour) * hourHeight + 2)
                            }
                            ForEach(Array(page.days.enumerated()), id: \.element) { index, day in
                                eventColumn(day: day, width: dayWidth, index: index)
                            }
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                if let index = page.days.firstIndex(where: { Calendar.current.isDate($0, inSameDayAs: context.date) }) {
                                    let minute = CalendarTimeLayout.minute(context.date, on: page.days[index], calendar: .current)
                                    HStack(spacing: 0) {
                                        Circle().fill(Color.red).frame(width: 6, height: 6)
                                        Rectangle().fill(Color.red).frame(height: 1)
                                    }.frame(width: dayWidth).offset(x: rail + CGFloat(index) * dayWidth - 3, y: CGFloat(minute) / 60 * hourHeight - 3)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }.frame(height: hourHeight * 24 + 25)
                }.onAppear { proxy.scrollTo(8, anchor: .top) }
            }
        }
    }

    private var allDay: some View {
        let count = min(3, page.days.map { page.events(on: $0).filter(\.allDay).count }.max() ?? 0)
        return HStack(alignment: .top, spacing: 0) {
            Text("All day").font(.system(size: 10)).foregroundStyle(.secondary).padding(.trailing, 8).frame(width: rail, alignment: .trailing)
            ForEach(page.days, id: \.self) { day in
                let events = page.events(on: day).filter(\.allDay)
                VStack(spacing: 2) {
                    ForEach(events.prefix(3)) { event in CalendarEventButton(event: event) { page.select(event) }.frame(height: 22) }
                    if events.count > 3 { Button("+\(events.count - 3) more") { page.showDay(day); page.setMode(.list) }.buttonStyle(.plain).font(.caption) }
                }.padding(.horizontal, 2).frame(maxWidth: .infinity, minHeight: CGFloat(max(1, count)) * 24, alignment: .top)
            }
        }.padding(.vertical, 5)
    }

    private func lines(width: CGFloat, dayWidth: CGFloat) -> some View {
        Path { path in
            for hour in 0...24 {
                let y = CGFloat(hour) * hourHeight
                path.move(to: CGPoint(x: rail, y: y)); path.addLine(to: CGPoint(x: width, y: y))
            }
            for day in 0...page.days.count {
                let x = rail + CGFloat(day) * dayWidth
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: hourHeight * 24))
            }
        }.stroke(Color.secondary.opacity(0.19), lineWidth: 0.5).allowsHitTesting(false)
    }

    @ViewBuilder private func eventColumn(day: Date, width: CGFloat, index: Int) -> some View {
        let events = page.events(on: day).filter { !$0.allDay }
        let placements = CalendarTimeLayout.placements(events.map { .init(id: $0.id, start: $0.start, end: $0.end) }, on: day)
        ForEach(placements, id: \.id) { placement in
            if let event = events.first(where: { $0.id == placement.id }) {
                let columnWidth = width / CGFloat(placement.columns)
                CalendarEventButton(event: event, showsTime: placement.endMinute - placement.startMinute >= 40, fillsHeight: true) { page.select(event) }
                    .frame(width: max(10, columnWidth - 5), height: max(20, CGFloat(placement.endMinute - placement.startMinute) / 60 * hourHeight - 2))
                    .offset(x: rail + CGFloat(index) * width + CGFloat(placement.column) * columnWidth + 2,
                            y: CGFloat(placement.startMinute) / 60 * hourHeight + 1)
            }
        }
    }
}
