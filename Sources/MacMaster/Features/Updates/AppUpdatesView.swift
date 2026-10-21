import SwiftUI
import AppKit

struct AppUpdatesView: View {
    private let engine = AppUpdatesEngine.shared
    @AppStorage(AppUpdatesEngine.Keys.autoCheck) private var autoCheck = true
    @AppStorage(AppUpdatesEngine.Keys.notify) private var notify = true
    @AppStorage(AppUpdatesEngine.Keys.beta) private var includeBeta = false
    @AppStorage(AppUpdatesEngine.Keys.showUntracked) private var showUntracked = false
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var showFailures = false
    @State private var showIgnored = false

    private var shown: [AppUpdate] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = engine.visibleUpdates
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Page {
            PageHeader(title: AppSection.updates.title, subtitle: AppSection.updates.blurb,
                       symbol: AppSection.updates.symbol, colors: AppSection.updates.colors) {
                headerAccessory
            }
            summaryCard.searchAnchor("updates.summary")
            if !engine.visibleUpdates.isEmpty || engine.isChecking && engine.lastChecked == nil { listSection }
            else if engine.lastChecked != nil { upToDate }
            if showUntracked { untrackedSection }
            if !engine.failures.isEmpty { failuresFooter }
            settingsSection
            ignoredSection.searchAnchor("updates.ignored")
        }
        .task {
            // Snapshot and first-run: nothing cached yet, so look right away.
            if engine.lastChecked == nil && !engine.isChecking { engine.check() }
        }
    }

    // MARK: Header

    private var headerAccessory: some View {
        HStack(spacing: 12) {
            if engine.isChecking {
                ProgressView().controlSize(.small)
                Text(engine.progress.total > 0 ? "Checking \(engine.progress.done) of \(engine.progress.total)" : "Scanning apps")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            } else if let last = engine.lastChecked {
                AgoText(prefix: "Checked", date: last).font(.callout).foregroundStyle(.secondary)
            }
            Button {
                engine.check()
            } label: {
                Label("Check Now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.mmPrimary(tint: Theme.Palette.blue[1]))
            .disabled(engine.isChecking)
        }
    }

    // MARK: Summary

    private var summaryCard: some View {
        let visible = engine.visibleUpdates
        let n = visible.count
        let counts = UpdateSource.allCases.map { s in (s, visible.filter { $0.source == s }.count) }.filter { $0.1 > 0 }
        let tracked = engine.apps.filter { $0.tracking != nil }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconTile(symbol: n > 0 ? "arrow.down.circle.fill" : "checkmark.circle.fill",
                         colors: n > 0 ? Theme.Palette.blue : Theme.Palette.green, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(summaryTitle(n)).font(.title3.weight(.semibold))
                    if n > 0 {
                        HStack(spacing: 6) {
                            ForEach(counts, id: \.0) { s, c in SourceBadge(source: s, count: c) }
                        }
                    } else if engine.lastChecked != nil {
                        Text("\(tracked) apps checked across Sparkle, the App Store and Homebrew")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Looking at the apps in /Applications").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                homebrewButtons
            }
            if engine.isChecking && engine.progress.total > 0 {
                CapsuleBar(fraction: Double(engine.progress.done) / Double(max(1, engine.progress.total)),
                           color: Theme.Palette.blue[1], height: 5)
            }
            if engine.offline {
                notice("wifi.slash", "You appear to be offline. Showing the last results.", .orange)
            }
            if let toast = engine.toast { notice("checkmark.circle.fill", toast, .green) }
            if let err = engine.brewRefreshError { notice("exclamationmark.triangle.fill", "brew update failed: \(err)", .red) }
            if !engine.outdatedFormulae.isEmpty { formulaeNote }
        }
        .card()
    }

    private func summaryTitle(_ n: Int) -> String {
        if n == 0 { return engine.lastChecked == nil ? "Checking for updates" : "Everything is up to date" }
        return n == 1 ? "1 update available" : "\(n) updates available"
    }

    @ViewBuilder private var homebrewButtons: some View {
        if engine.brewAvailable {
            HStack(spacing: 8) {
                Button {
                    engine.refreshHomebrew()
                } label: {
                    if engine.isRefreshingBrew {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Refreshing…") }
                    } else {
                        Label("Refresh Homebrew", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.mmSecondary)
                .disabled(engine.isRefreshingBrew)
                .help("Runs brew update, then checks again")
                let casks = engine.brewCaskUpdates
                if casks.count >= 1 {
                    let busy = casks.contains { engine.brewJobs[$0.id] == .running }
                    Button {
                        engine.upgradeAllCasks()
                    } label: {
                        Text(busy ? "Updating…" : "Update All (Homebrew)")
                    }
                    .buttonStyle(.mmPrimary(tint: Color(hex: 0xFF9F0A)))
                    .disabled(busy)
                }
            }
        }
    }

    private var formulaeNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            let n = engine.outdatedFormulae.count
            Text("\(n) Homebrew \(n == 1 ? "formula is" : "formulae are") outdated. Run brew upgrade in Terminal.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Copy command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew upgrade", forType: .string)
            }
            .buttonStyle(.mmGhost)
            .help(engine.outdatedFormulae.joined(separator: ", "))
        }
    }

    private func notice(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    // MARK: List

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SectionTitle(text: "Available updates", symbol: "arrow.down.app")
                Spacer()
                searchField
            }
            if shown.isEmpty && !engine.visibleUpdates.isEmpty {
                Text("No updates match “\(query)”.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(24).card(padding: 0)
            } else if engine.visibleUpdates.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Scanning your apps…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(28).card(padding: 0)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, u in
                        UpdateRow(update: u, isExpanded: expanded.contains(u.id)) {
                            withAnimation(.smooth(duration: 0.2)) {
                                if expanded.contains(u.id) { expanded.remove(u.id) } else { expanded.insert(u.id) }
                            }
                        }
                        if i < shown.count - 1 { HairlineDivider(leadingInset: 68) }
                    }
                }
                .card(padding: 0)
            }
        }
        .searchAnchor("updates.list")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Filter", text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(width: 200)
        .background(Theme.cardFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    private var upToDate: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: Theme.Palette.green, startPoint: .top, endPoint: .bottom))
                    .frame(width: 72, height: 72)
                    .shadow(color: Theme.Palette.green[1].opacity(0.35), radius: 12, y: 5)
                Image(systemName: "checkmark").font(.system(size: 32, weight: .bold)).foregroundStyle(.white)
            }
            Text("Everything is up to date").font(.title3.weight(.semibold))
            Text("Your apps are on their latest versions. MacMaster checks again every day.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .card(padding: 0)
    }

    // MARK: Untracked

    private var untrackedSection: some View {
        let list = engine.untrackedApps
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Not tracked (\(list.count))", symbol: "questionmark.app")
            if list.isEmpty {
                Text("Every app has an update source.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(20).card(padding: 0)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                        HStack(spacing: 12) {
                            AppIconView(path: a.path, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name).font(.body)
                                Text(a.version.isEmpty ? "No version" : "Version \(a.version)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("No update source").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)])
                            }
                        }
                        if i < list.count - 1 { HairlineDivider(leadingInset: 54) }
                    }
                }
                .card(padding: 0)
            }
        }
    }

    // MARK: Failures

    private var failuresFooter: some View {
        let list = engine.failures
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { showFailures.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Couldn't check \(list.count) \(list.count == 1 ? "app" : "apps")")
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(showFailures ? 90 : 0))
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if showFailures {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(list) { f in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(f.name).font(.caption.weight(.medium))
                            Text(f.source.label).font(.caption2).foregroundStyle(.tertiary)
                            Text(f.message).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Settings

    private var settingsSection: some View {
        GroupedSection("Settings", symbol: "gearshape", footer: "Homebrew is never updated in the background. Use Refresh Homebrew to fetch new package data.") {
            SettingsRow(title: "Check for updates daily", subtitle: "Runs quietly in the background", symbol: "clock.arrow.circlepath",
                        colors: Theme.Palette.blue) {
                Toggle("", isOn: $autoCheck).labelsHidden().toggleStyle(.switch)
            }.searchAnchor("updates.auto")
            SettingsRow(title: "Notify when updates appear", subtitle: "Once per new version", symbol: "bell.badge.fill",
                        colors: Theme.Palette.red) {
                Toggle("", isOn: $notify).labelsHidden().toggleStyle(.switch)
            }.searchAnchor("updates.notify")
            SettingsRow(title: "Include beta updates", subtitle: "Sparkle apps that publish a separate beta channel", symbol: "flask.fill",
                        colors: Theme.Palette.purple) {
                Toggle("", isOn: $includeBeta).labelsHidden().toggleStyle(.switch)
            }.searchAnchor("updates.beta")
            SettingsRow(title: "Show apps that can't be tracked", subtitle: "Apps with no Sparkle feed, App Store receipt or Homebrew cask",
                        symbol: "questionmark.app.fill", colors: Theme.Palette.gray) {
                Toggle("", isOn: $showUntracked).labelsHidden().toggleStyle(.switch)
            }.searchAnchor("updates.untracked")
        }
    }

    // MARK: Ignored

    private var ignoredSection: some View {
        let rules = engine.ignoreRules
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { showIgnored.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(showIgnored ? 90 : 0))
                    Text("Ignored (\(rules.count))")
                }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            if showIgnored {
                if rules.isEmpty {
                    Text("Updates you ignore show up here, so you can bring them back.")
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rules.enumerated()), id: \.element.id) { i, r in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.name)
                                    Text(r.version.map { "Version \($0)" } ?? "All updates")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Unignore") { engine.removeRule(r) }.buttonStyle(.mmGhost)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            if i < rules.count - 1 { HairlineDivider(leadingInset: 14) }
                        }
                    }
                    .card(padding: 0)
                }
            }
        }
    }
}

// MARK: - Row

private struct UpdateRow: View {
    let update: AppUpdate
    let isExpanded: Bool
    let toggle: () -> Void
    private let engine = AppUpdatesEngine.shared

    private var hasDetails: Bool {
        update.notes != nil || update.notesURL != nil || update.pageURL != nil && update.source == .homebrew
    }
    private var job: AppUpdatesEngine.BrewJob? { engine.brewJobs[update.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if update.path != nil {
                    AppIconView(path: update.path, size: 40)
                } else {
                    IconTile(symbol: "shippingbox.fill", colors: Theme.Palette.orange, size: 40)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(update.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        SourceBadge(source: update.source)
                        if update.isCritical { StatusPill(text: "Critical", color: .red) }
                    }
                    HStack(spacing: 8) {
                        VersionPill(from: update.installedVersion, to: update.newVersion)
                        if hasDetails {
                            Button(action: toggle) {
                                HStack(spacing: 3) {
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                    Text("Release notes")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 8)
                actions
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if isExpanded { details }
            if case .failed(let output) = job { failure(output) }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Ignore this version") { engine.ignoreVersion(update) }
            Button("Ignore app") { engine.ignoreApp(update) }
            if update.path != nil {
                Divider()
                Button("Reveal in Finder") { engine.reveal(update) }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch update.source {
        case .appStore:
            Button("Update") { engine.openAppStore(update) }
                .buttonStyle(RowButtonStyle(tint: Theme.Palette.blue[1], prominent: true))
                .help("Opens the App Store page")
        case .sparkle:
            HStack(spacing: 6) {
                if update.downloadURL != nil {
                    Button("Download") { engine.openURL(update.downloadURL) }
                        .buttonStyle(RowButtonStyle(tint: .primary, prominent: false))
                        .help("Downloads the new version in your browser")
                }
                Button("Update") { engine.openApp(update) }
                    .buttonStyle(RowButtonStyle(tint: Color(hex: 0x5856D6), prominent: true))
                    .disabled(update.path == nil)
                    .help("Opens the app. Most apps then offer the update.")
            }
        case .homebrew:
            if job == .running {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Updating…").font(.caption).foregroundStyle(.secondary) }
            } else {
                Button(job == nil ? "Update" : "Retry") { engine.upgradeCask(update) }
                    .buttonStyle(RowButtonStyle(tint: Color(hex: 0xFF9F0A), prominent: true))
                    .disabled(update.caskToken == nil)
                    .help("Runs brew upgrade --cask \(update.caskToken ?? "")")
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notes = update.notes {
                Text(notes).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if update.notesURL == nil {
                Text("No release notes were published.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let n = update.notesURL { Button("Open release notes") { engine.openURL(n) }.buttonStyle(.mmGhost) }
                if update.source == .homebrew, let p = update.pageURL { Button("Homepage") { engine.openURL(p) }.buttonStyle(.mmGhost) }
            }
        }
        .padding(.leading, 66).padding(.trailing, 14).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private func failure(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Update failed. The app may be running, or the installer needs a password.").font(.callout)
                Spacer()
                Button("Dismiss") { engine.dismissJob(update.id) }.buttonStyle(.mmGhost)
            }
            ScrollView {
                Text(output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(maxHeight: 130)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.leading, 66).padding(.trailing, 14).padding(.bottom, 12)
    }
}

// MARK: - Small pieces

private struct RowButtonStyle: ButtonStyle {
    var tint: Color
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(Capsule().fill(prominent
                ? AnyShapeStyle(LinearGradient(colors: [tint.lighter(0.12), tint], startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(tint.opacity(configuration.isPressed ? 0.14 : 0.07))))
            .overlay(Capsule().strokeBorder(prominent ? Color.white.opacity(0.2) : Theme.hairline, lineWidth: 0.5))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
    }
}

private struct VersionPill: View {
    let from: String
    let to: String
    var body: some View {
        HStack(spacing: 5) {
            Text(from.isEmpty ? "?" : from).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            Text(to).foregroundStyle(Theme.Palette.green[1]).fontWeight(.semibold)
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

private struct SourceBadge: View {
    let source: UpdateSource
    var count: Int? = nil

    private var color: Color {
        switch source {
        case .sparkle: Color(hex: 0x5856D6)
        case .appStore: Color(hex: 0x0A7AFF)
        case .homebrew: Color(hex: 0xE08A00)
        }
    }
    private var symbol: String {
        switch source {
        case .sparkle: "sparkles"
        case .appStore: "bag.fill"
        case .homebrew: "mug.fill"
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: SymbolKit.resolve(symbol)).font(.system(size: 9, weight: .bold))
            Text(count.map { "\($0) \(source.label)" } ?? source.label).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

/// App icon from the bundle, cached.
private struct AppIconView: View {
    let path: String?
    var size: CGFloat

    private static let cache = NSCache<NSString, NSImage>()

    private var image: NSImage? {
        guard let path else { return nil }
        if let hit = Self.cache.object(forKey: path as NSString) { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        Self.cache.setObject(img, forKey: path as NSString)
        return img
    }

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            IconTile(symbol: "app.fill", colors: Theme.Palette.gray, size: size)
        }
    }
}
