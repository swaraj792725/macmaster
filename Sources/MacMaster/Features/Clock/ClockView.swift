import SwiftUI

/// Settings page for the Clock replacement.
struct ClockView: View {
    @State private var settings = ClockSettings.shared
    @State private var pickingSecond = false
    @State private var addingWorld = false
    @State private var calendarAccess = Permissions.calendarsGranted
    private let presetColumns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)]

    var body: some View {
        Page {
            PageHeader(title: "Clock",
                       subtitle: "Your own menu bar clock: format, second time zone, calendar and world clocks.",
                       symbol: "clock.fill", colors: Theme.Palette.orange)
            menuBarCard
            formatSection
            secondZoneSection
            worldSection
            calendarSection
            appleSection
        }
    }

    // MARK: Menu bar

    private var menuBarCard: some View {
        HStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(ClockFormatter.shared.string(for: ctx.date, settings: settings))
                    .font(.system(.callout, design: .default).monospacedDigit().weight(.medium))
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Show in menu bar").font(.headline)
                Text(settings.showInMenuBar ? "Click the time to open the calendar, world clocks and time controls."
                                            : "Off by default so you don't get a second clock until you want one.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $settings.showInMenuBar).toggleStyle(.switch).labelsHidden().controlSize(.large)
        }
        .card(kind: .glass, radius: Theme.Radius.hero)
    }

    // MARK: Format

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupedSection("Presets", symbol: "textformat", footer: "Presets set the options below. Fine-tune them or write your own pattern.") {
                LazyVGrid(columns: presetColumns, spacing: 8) {
                    ForEach(ClockPreset.allCases) { p in
                        let on = settings.currentPreset == p
                        Button { settings.apply(p) } label: {
                            Text(p.title).font(.callout.monospacedDigit())
                                .padding(.vertical, 8).frame(maxWidth: .infinity)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            GroupedSection("Format", symbol: "slider.horizontal.3") {
                toggleRow("24-hour time", "clock.badge", $settings.use24h)
                if !settings.use24h { toggleRow("Show AM/PM", "sun.and.horizon", $settings.showAMPM) }
                toggleRow("Show seconds", "timer", $settings.showSeconds)
                toggleRow("Show date", "calendar", $settings.showDate)
                toggleRow("Show weekday", "calendar.day.timeline.left", $settings.showWeekday)
                toggleRow("Week numbers in calendar", "number", $settings.showWeekNumbers)
            }
            .disabled(settings.useCustomPattern)
            .opacity(settings.useCustomPattern ? 0.5 : 1)
            GroupedSection("Custom pattern", symbol: "chevron.left.forwardslash.chevron.right",
                           footer: "Uses Unicode date patterns, for example EEE d MMM HH:mm:ss. Put literal text in single quotes.") {
                toggleRow("Use a custom pattern", "wand.and.stars", $settings.useCustomPattern)
                if settings.useCustomPattern {
                    SettingsRow(title: "Pattern") {
                        TextField("EEE d MMM HH:mm", text: $settings.customPattern)
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(width: 220)
                    }
                }
            }
        }
    }

    private func toggleRow(_ title: String, _ symbol: String, _ binding: Binding<Bool>) -> some View {
        SettingsRow(title: title, symbol: symbol, colors: Theme.Palette.orange) {
            Toggle("", isOn: binding).toggleStyle(.switch).labelsHidden()
        }
    }

    // MARK: Second zone

    private var secondZoneSection: some View {
        GroupedSection("Second time zone", symbol: "globe",
                       footer: "Appears after the main time, for example \u{201C}9:41 \u{00B7} NY 00:11\u{201D}. Leave the label empty to use the zone's abbreviation.") {
            toggleRow("Show a second time zone", "globe.americas.fill", $settings.showSecondZone)
            if settings.showSecondZone {
                SettingsRow(title: "Zone", subtitle: settings.secondZoneID) {
                    Button("Choose\u{2026}") { pickingSecond.toggle() }.buttonStyle(.mmSecondary)
                        .popover(isPresented: $pickingSecond, arrowEdge: .bottom) {
                            ClockZoneSearchList(selected: settings.secondZoneID) { id in
                                settings.secondZoneID = id
                                if settings.secondZoneLabel.isEmpty { /* keep abbreviation */ }
                                pickingSecond = false
                            }
                            .padding(12).frame(width: 300)
                        }
                }
                SettingsRow(title: "Label") {
                    TextField(ClockZones.shortLabel(settings.secondZoneID), text: $settings.secondZoneLabel)
                        .textFieldStyle(.roundedBorder).frame(width: 120)
                }
            }
        }
    }

    // MARK: World clocks

    private var worldSection: some View {
        GroupedSection("World clocks", symbol: "globe.europe.africa.fill", footer: "Shown in the World tab of the popover, with a live day and night map.") {
            toggleRow("Show world map", "map.fill", $settings.showWorldMap)
            if settings.showWorldMap {
                ClockWorldMapView(zones: settings.worldClocks).frame(maxWidth: .infinity)
            }
            if settings.worldClocks.isEmpty {
                Text("No world clocks yet.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(settings.worldClocks, id: \.self) { id in
                SettingsRow(title: ClockZones.city(id), subtitle: id) {
                    Button { settings.removeWorldClock(id) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
                }
            }
            HStack {
                Button { addingWorld.toggle() } label: { Label("Add city", systemImage: "plus") }
                    .buttonStyle(.mmSecondary)
                    .popover(isPresented: $addingWorld, arrowEdge: .bottom) {
                        ClockZoneSearchList { id in settings.addWorldClock(id); addingWorld = false }
                            .padding(12).frame(width: 300)
                    }
                Spacer()
            }
        }
    }

    // MARK: Calendar

    private var calendarSection: some View {
        GroupedSection("Calendar events", symbol: "calendar.badge.clock",
                       footer: "Events show under the month grid in the popover, with join links for Zoom, Meet and Teams. MacMaster only reads them, on demand, and only when the popover opens or Calendar changes.") {
            toggleRow("Show next event in the menu bar", "bell.badge", $settings.showNextEvent)
            SettingsRow(title: "Calendar access", subtitle: calendarAccess ? "Allowed" : "Not allowed yet",
                        symbol: "calendar", colors: Theme.Palette.orange) {
                if !calendarAccess {
                    Button(Permissions.calendarsCanPrompt ? "Grant" : "Open Settings") { Permissions.request(.calendars) }
                        .buttonStyle(.mmSecondary)
                }
            }
        }
        .onAppear { calendarAccess = Permissions.calendarsGranted }
        .onReceive(NotificationCenter.default.publisher(for: .calendarAuthorizationChanged)) { _ in
            calendarAccess = Permissions.calendarsGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calendarAccess = Permissions.calendarsGranted
        }
    }

    // MARK: Apple's clock

    private var appleSection: some View {
        GroupedSection("Apple's menu bar clock", symbol: "info.circle",
                       footer: "MacMaster never edits Control Center preferences. This only opens System Settings.") {
            VStack(alignment: .leading, spacing: 8) {
                Text("macOS doesn't let apps remove its own clock. To make it small, open Control Center settings, choose Clock Options, and pick Analog. The two clocks then sit side by side.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Control Center settings") { ClockSystem.openControlCenterSettings() }.buttonStyle(.mmSecondary)
                    Button("Date & Time settings") { ClockSystem.openDateTimeSettings() }.buttonStyle(.mmGhost)
                    Spacer()
                }
            }
        }
    }
}
