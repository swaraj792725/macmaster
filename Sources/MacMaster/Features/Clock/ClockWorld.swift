import SwiftUI

/// Searchable list over every known time zone.
struct ClockZoneSearchList: View {
    var selected: String? = nil
    var height: CGFloat = 220
    let onPick: (String) -> Void
    @State private var query = ""

    private var matches: [ClockZones.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = ClockZones.index
        guard !q.isEmpty else { return Array(all.prefix(80)) }
        return Array(all.filter { $0.key.contains(q) }.prefix(80))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search city or region", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            let list = matches
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list) { e in
                        Button { onPick(e.id) } label: {
                            HStack {
                                Text(e.city)
                                Text(e.region).foregroundStyle(.secondary)
                                Spacer()
                                if e.id == selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                            .font(.callout).padding(.horizontal, 8).padding(.vertical, 5)
                            .background(e.id == selected ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if list.isEmpty { Text("No matches").font(.callout).foregroundStyle(.secondary).padding(12) }
                }
            }
            .frame(height: height)
        }
    }
}

/// One world-clock row: city, relative offset, day/night glyph and time.
struct ClockWorldRow: View {
    let id: String
    let date: Date
    var onRemove: (() -> Void)?
    @State private var hover = false

    var body: some View {
        let tz = TimeZone(identifier: id) ?? .current
        HStack(spacing: 10) {
            Image(systemName: ClockZones.isDay(tz, at: date) ? "sun.max.fill" : "moon.stars.fill")
                .foregroundStyle(ClockZones.isDay(tz, at: date) ? Color.orange : Color.indigo)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(ClockZones.city(id)).fontWeight(.medium)
                Text("\(ClockZones.dayLabel(tz, at: date)) \u{00B7} \(ClockZones.relative(tz, at: date))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hover, let onRemove {
                Button(action: onRemove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Remove")
            }
            Text(timeString(tz)).font(.title3.monospacedDigit().weight(.light))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(hover ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hover = $0 }
    }

    private func timeString(_ tz: TimeZone) -> String {
        let s = ClockSettings.shared
        let style = Date.FormatStyle(timeZone: tz)
            .hour(s.use24h ? .twoDigits(amPM: .omitted) : .defaultDigits(amPM: .abbreviated)).minute()
        return date.formatted(style)
    }
}

/// Popover tab: world clocks, add-a-city, and a time-zone converter.
struct ClockWorldTab: View {
    @State private var settings = ClockSettings.shared
    @State private var adding = false
    @State private var showConverter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(spacing: 6) {
                        ClockWorldRow(id: TimeZone.current.identifier, date: ctx.date, onRemove: nil)
                        ForEach(settings.worldClocks, id: \.self) { id in
                            ClockWorldRow(id: id, date: ctx.date) { settings.removeWorldClock(id) }
                        }
                    }
                }
                if adding {
                    ClockZoneSearchList(height: 170) { id in settings.addWorldClock(id); adding = false }
                    Button("Cancel") { adding = false }.buttonStyle(.mmGhost)
                } else {
                    Button { adding = true } label: { Label("Add city", systemImage: "plus") }.buttonStyle(.mmSecondary)
                }
                Divider().padding(.vertical, 2)
                DisclosureGroup(isExpanded: $showConverter) { ClockConverter().padding(.top, 8) } label: {
                    Label("Time zone converter", systemImage: "arrow.left.arrow.right").font(.callout.weight(.semibold))
                }
            }
            .padding(14)
        }
    }
}

/// Pick a date and time in one zone and see it everywhere else.
struct ClockConverter: View {
    @State private var settings = ClockSettings.shared
    @State private var fromID = TimeZone.current.identifier
    @State private var when = Date()

    private var zoneIDs: [String] {
        var ids = [TimeZone.current.identifier]
        for z in settings.worldClocks where !ids.contains(z) { ids.append(z) }
        return ids
    }

    var body: some View {
        let from = TimeZone(identifier: fromID) ?? .current
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("From").foregroundStyle(.secondary)
                Picker("", selection: $fromID) {
                    ForEach(zoneIDs, id: \.self) { Text(ClockZones.city($0)).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 160)
                Spacer()
                Button("Now") { when = Date() }.buttonStyle(.mmGhost)
            }
            DatePicker("", selection: $when, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden().environment(\.timeZone, from)
            if zoneIDs.count == 1 {
                Text("Add a city in the list above to convert between zones.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(zoneIDs.filter { $0 != fromID }, id: \.self) { id in
                let tz = TimeZone(identifier: id) ?? .current
                HStack {
                    Text(ClockZones.city(id))
                    Spacer()
                    Text(when.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
