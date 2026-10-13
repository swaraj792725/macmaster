import SwiftUI
import AppKit

/// Parses the bundled CHANGELOG.md (`## [x.y.z] - date`, `### Group`, `- item`).
struct ChangelogEntry: Identifiable {
    struct Group: Identifiable { var title: String; var items: [String]; var id: String { title } }
    var version: String
    var date: String
    var groups: [Group]
    var id: String { version }

    static func load() -> [ChangelogEntry] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [ChangelogEntry] {
        var out: [ChangelogEntry] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                let head = line.dropFirst(3)
                let version = head.split(separator: "]").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[ ")) } ?? String(head)
                let date = head.components(separatedBy: " - ").dropFirst().first ?? ""
                out.append(ChangelogEntry(version: version, date: date, groups: []))
            } else if line.hasPrefix("### "), !out.isEmpty {
                out[out.count - 1].groups.append(Group(title: String(line.dropFirst(4)), items: []))
            } else if line.hasPrefix("- "), !out.isEmpty {
                if out[out.count - 1].groups.isEmpty { out[out.count - 1].groups.append(Group(title: "Changes", items: [])) }
                let g = out[out.count - 1].groups.count - 1
                out[out.count - 1].groups[g].items.append(String(line.dropFirst(2)))
            }
        }
        return out
    }
}

struct WhatsNewView: View {
    var entries = ChangelogEntry.load()
    @State private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New in MacMaster").font(.title2.weight(.semibold))
                    Text("Version \(UpdateChecker.currentVersion) (\(UpdateChecker.currentBuild))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                UpdateStatusControl(compact: true)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if entries.isEmpty {
                        Text("Changelog not found in this build.").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { e in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(e.version).font(.title3.weight(.bold))
                                if e.version == UpdateChecker.currentVersion {
                                    StatusPill(text: "Installed", color: .green)
                                }
                                Spacer()
                                Text(e.date).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(e.groups) { g in
                                Text(g.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(Array(g.items.enumerated()), id: \.offset) { _, item in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Circle().fill(.secondary).frame(width: 4, height: 4).offset(y: -2)
                                            Text(.init(item)).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Link("All releases on GitHub", destination: URL(string: "https://github.com/\(UpdateChecker.repo)/releases")!)
                Spacer()
                Button("Close") { WhatsNewWindow.close() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 600)
    }
}

/// "Check for Updates" button + status line; used in Settings and the What's New window.
struct UpdateStatusControl: View {
    var compact = false
    @State private var updates = UpdateChecker.shared

    var body: some View {
        HStack(spacing: 8) {
            switch updates.state {
            case .checking:
                ProgressView().controlSize(.small)
                if !compact { Text("Checking…").foregroundStyle(.secondary) }
            case .available(let r):
                Text("\(r.version) available").foregroundStyle(.green)
                Button("Download") { updates.download(r) }.buttonStyle(.mmPrimary)
            case .upToDate:
                if !compact { Text("You're up to date").foregroundStyle(.secondary) }
                Button("Check Again") { Task { await updates.check(userInitiated: true) } }
            case .failed(let msg):
                if !compact { Text(msg).foregroundStyle(.secondary).lineLimit(2) }
                Button("Check for Updates") { Task { await updates.check(userInitiated: true) } }
            case .idle:
                Button("Check for Updates") { Task { await updates.check(userInitiated: true) } }
            }
        }
        .font(.callout)
    }
}

@MainActor
enum WhatsNewWindow {
    private static var window: NSWindow?
    private static let seenKey = "mm.app.lastSeenVersion"

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WhatsNewView())
            w.center()
            window = w
        }
        FrontAppTracker.markDeliberate()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(UpdateChecker.currentVersion, forKey: seenKey)
    }

    static func close() { window?.close() }

    /// Once per version after an update (not on a fresh install).
    static func showIfUpdated() {
        let d = UserDefaults.standard
        let current = UpdateChecker.currentVersion
        // No record: a fresh install (skip) or an update from 0.1.0, which didn't record versions (show).
        let seen = d.string(forKey: seenKey) ?? (Onboarding.isNeeded ? current : "0.1.0")
        if UpdateChecker.compare(current, seen) == .orderedDescending {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { show() }
        } else {
            d.set(current, forKey: seenKey)
        }
    }
}
