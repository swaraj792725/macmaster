import SwiftUI

/// Month grid with navigation, today highlight, optional week numbers, a selectable day and event dots.
struct ClockCalendarGrid: View {
    let showWeekNumbers: Bool
    var selectedDay: Date? = nil
    /// Start-of-day dates that get an event dot.
    var eventDays: Set<Date> = []
    var onSelect: (Date) -> Void = { _ in }
    var onMonthChange: (Date) -> Void = { _ in }
    @State private var month: Date = Calendar.autoupdatingCurrent.date(
        from: Calendar.autoupdatingCurrent.dateComponents([.year, .month], from: Date())) ?? Date()

    private var cal: Calendar { .autoupdatingCurrent }

    var body: some View {
        VStack(spacing: 8) {
            header
            let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: showWeekNumbers ? 8 : 7)
            LazyVGrid(columns: cols, spacing: 2) {
                if showWeekNumbers { Text("").frame(height: 16) }
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(height: 16)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, week in
                    if showWeekNumbers {
                        Text(weekNumber(week)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    ForEach(Array(week.enumerated()), id: \.offset) { _, d in dayCell(d) }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
            Spacer()
            navButton("chevron.left") { shift(-1) }
            Button("Today") {
                month = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
                onMonthChange(month)
            }
            .buttonStyle(.mmGhost)
            navButton("chevron.right") { shift(1) }
        }
    }

    private func navButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }

    private func shift(_ n: Int) {
        if let d = cal.date(byAdding: .month, value: n, to: month) { month = d; onMonthChange(d) }
    }

    private var weekdaySymbols: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let f = cal.firstWeekday - 1
        return Array(s[f...] + s[..<f])
    }

    /// Weeks of the month; leading and trailing blanks are nil.
    private var rows: [[Date?]] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: lead)
        for d in range { days.append(cal.date(byAdding: .day, value: d - 1, to: month)) }
        while days.count % 7 != 0 { days.append(nil) }
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<$0 + 7]) }
    }

    private func weekNumber(_ week: [Date?]) -> String {
        guard let d = week.compactMap({ $0 }).first else { return "" }
        return String(cal.component(.weekOfYear, from: d))
    }

    @ViewBuilder
    private func dayCell(_ d: Date?) -> some View {
        if let d {
            let today = cal.isDateInToday(d)
            let weekend = cal.isDateInWeekend(d)
            let selected = selectedDay.map { cal.isDate($0, inSameDayAs: d) } ?? false
            let hasEvents = eventDays.contains(cal.startOfDay(for: d))
            VStack(spacing: 1) {
                Text(String(cal.component(.day, from: d)))
                    .font(.callout.monospacedDigit().weight(today ? .bold : .regular))
                    .foregroundStyle(today ? Color.white : (weekend ? Color.secondary : Color.primary))
                    .frame(width: 28, height: 26)
                    .background(Circle().fill(today ? Color.accentColor : .clear))
                    .overlay(Circle().strokeBorder(selected && !today ? Color.accentColor : .clear, lineWidth: 1.5))
                Circle().fill(hasEvents ? Color.accentColor.opacity(0.8) : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 33)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(d) }
        } else {
            Color.clear.frame(height: 33)
        }
    }
}
