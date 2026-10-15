import SwiftUI
import AppKit
import Observation

struct ToolsStartupItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case loginItem, userAgent, systemAgent, systemDaemon
        var title: String {
            switch self {
            case .loginItem: "Login item"
            case .userAgent: "User agent"
            case .systemAgent: "System agent"
            case .systemDaemon: "System daemon"
            }
        }
        var symbol: String {
            switch self {
            case .loginItem: "person.crop.circle.badge.checkmark"
            case .userAgent: "person"
            case .systemAgent: "person.2"
            case .systemDaemon: "gearshape.2"
            }
        }
    }

    var id: String
    var name: String
    var label: String
    var kind: Kind
    var plistURL: URL?
    var appURL: URL?
    var programPath: String?
    var programExists = true
    var isLoaded = false
    var isDisabled = false
    var runAtLoad = false
    /// Login item read from AppleScript (removable by name) vs. Background Task Management (managed in Settings).
    var removableLoginItem = false
    var enabledInBTM = true

    var isApple: Bool { label.hasPrefix("com.apple.") || (programPath?.hasPrefix("/System/") ?? false) }
    var isThirdParty: Bool { !isApple }
    var isBroken: Bool { plistURL != nil && !programExists }
    var needsAdmin: Bool { kind == .systemDaemon || kind == .systemAgent }
    var isActive: Bool { kind == .loginItem ? enabledInBTM : (!isDisabled) }
}

enum ToolsStartupLoader {
    private static let uid = getuid()

    static func load() async -> [ToolsStartupItem] {
        await Task.detached(priority: .userInitiated) { loadSync() }.value
    }

    private static func loadSync() -> [ToolsStartupItem] {
        let fm = FileManager.default
        let home = AppPaths.home
        let userDisabled = disabledLabels(domain: "gui/\(uid)")
        let systemDisabled = disabledLabels(domain: "system")
        let loadedUser = loadedUserLabels()

        var items: [ToolsStartupItem] = []
        let dirs: [(URL, ToolsStartupItem.Kind)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon),
        ]
        for (dir, kind) in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: f),
                      let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
                else { continue }
                let label = (dict["Label"] as? String) ?? f.deletingPathExtension().lastPathComponent
                let args = dict["ProgramArguments"] as? [String]
                let program = (dict["Program"] as? String) ?? args?.first
                var exists = true
                if let p = program, p.hasPrefix("/") { exists = fm.fileExists(atPath: p) }
                if program == nil && dict["BundleProgram"] == nil && dict["MachServices"] == nil { exists = false }
                let loaded: Bool
                switch kind {
                case .systemDaemon: loaded = Shell.run("/bin/launchctl", ["print", "system/\(label)"], timeout: 8).ok
                default: loaded = loadedUser.contains(label)
                }
                let disabledSet = kind == .systemDaemon ? systemDisabled : userDisabled
                items.append(ToolsStartupItem(
                    id: f.path, name: prettyName(label: label, program: program), label: label, kind: kind, plistURL: f,
                    programPath: program, programExists: exists, isLoaded: loaded,
                    isDisabled: disabledSet.contains(label), runAtLoad: (dict["RunAtLoad"] as? Bool) ?? false))
            }
        }

        // Login items: BTM dump (needs privileges on recent macOS), else System Events.
        var login = parseBTM(Shell.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 20).stdout)
        if login.isEmpty { login = appleScriptLoginItems() }
        items += login
        return items.sorted {
            ($0.isThirdParty ? 0 : 1, $0.kind.rawValue, $0.name.lowercased()) < ($1.isThirdParty ? 0 : 1, $1.kind.rawValue, $1.name.lowercased())
        }
    }

    static func prettyName(label: String, program: String?) -> String {
        if let p = program, p.contains(".app/") {
            let comp = p.components(separatedBy: "/").first { $0.hasSuffix(".app") } ?? ""
            if !comp.isEmpty { return String(comp.dropLast(4)) }
        }
        return label
    }

    /// `launchctl print-disabled <domain>` lines look like `"com.foo.bar" => disabled`.
    static func disabledLabels(domain: String) -> Set<String> {
        let r = Shell.run("/bin/launchctl", ["print-disabled", domain], timeout: 10)
        var out = Set<String>()
        for line in r.stdout.split(whereSeparator: \.isNewline) {
            guard let q1 = line.firstIndex(of: "\""), let q2 = line[line.index(after: q1)...].firstIndex(of: "\"") else { continue }
            let label = String(line[line.index(after: q1)..<q2])
            let tail = line[q2...].lowercased()
            if tail.contains("=> disabled") || tail.contains("=> true") { out.insert(label) }
        }
        return out
    }

    static func loadedUserLabels() -> Set<String> {
        let r = Shell.run("/bin/launchctl", ["list"], timeout: 10)
        var out = Set<String>()
        for line in r.stdout.split(whereSeparator: \.isNewline).dropFirst() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.count >= 3 { out.insert(String(parts[2])) }
        }
        return out
    }

    /// Parses `sfltool dumpbtm`. Only app / login-item records that are currently enabled are returned;
    /// launchd agents and daemons are covered by the plist scan.
    static func parseBTM(_ text: String) -> [ToolsStartupItem] {
        guard !text.isEmpty else { return [] }
        var out: [ToolsStartupItem] = []
        var seen = Set<String>()
        var blocks: [[String]] = []
        var skipSection = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Records for UID") {
                // Our records (and the shared -2 bucket); other users' / root records are ignored.
                let uid = t.split(separator: " ").dropFirst(3).first.map(String.init) ?? ""
                skipSection = !(uid == "\(getuid())" || uid == "-2")
                continue
            }
            if skipSection { continue }
            if t.range(of: #"^#\d+:"#, options: .regularExpression) != nil, !line.hasPrefix("    ") { blocks.append([]) }
            if !blocks.isEmpty { blocks[blocks.count - 1].append(line) }
        }
        for b in blocks {
            var f: [String: String] = [:]
            for l in b {
                guard !l.hasPrefix("    #"), let c = l.firstIndex(of: ":") else { continue }
                let k = l[..<c].trimmingCharacters(in: .whitespaces)
                let v = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
                if !k.isEmpty, f[k] == nil { f[k] = v }
            }
            let type = (f["Type"] ?? "").lowercased()
            guard type.hasPrefix("app") || type.hasPrefix("login item") else { continue }
            guard (f["Disposition"] ?? "").lowercased().contains("enabled") else { continue }
            guard let name = f["Name"], !name.isEmpty, name != "(null)" else { continue }
            var appURL: URL?
            if let u = f["URL"], u != "(null)" {
                appURL = u.hasPrefix("file://") ? URL(string: u) : URL(fileURLWithPath: u)
            }
            let rawID = f["Identifier"] ?? name
            let label = rawID.replacingOccurrences(of: #"^\d+\."#, with: "", options: .regularExpression)
            guard seen.insert(rawID).inserted else { continue }
            var item = ToolsStartupItem(id: "btm:" + rawID, name: name, label: label, kind: .loginItem,
                                        appURL: appURL, programPath: appURL?.path)
            item.programExists = appURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
            item.isLoaded = true
            out.append(item)
        }
        return out
    }

    static func appleScriptLoginItems() -> [ToolsStartupItem] {
        let r = Shell.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get the name of every login item"], timeout: 15)
        guard r.ok else { return [] }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ", ")
            .filter { !$0.isEmpty }
            .map { name in
                var i = ToolsStartupItem(id: "login:" + name, name: name, label: name, kind: .loginItem)
                i.removableLoginItem = true
                i.isLoaded = true
                let guess = URL(fileURLWithPath: "/Applications/\(name).app")
                if FileManager.default.fileExists(atPath: guess.path) { i.appURL = guess }
                return i
            }
    }
}

@Observable
@MainActor
final class ToolsStartupModel {
    private(set) var items: [ToolsStartupItem] = []
    private(set) var isLoading = false
    private(set) var busy: Set<String> = []
    var search = ""
    var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", thirdParty = "Third-party", broken = "Broken", apple = "Apple"
        var id: String { rawValue }
    }

    var filtered: [ToolsStartupItem] {
        items.filter { i in
            switch filter {
            case .all: true
            case .thirdParty: i.isThirdParty
            case .broken: i.isBroken
            case .apple: i.isApple
            }
        }
        .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.label.localizedCaseInsensitiveContains(search) }
    }

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            items = await ToolsStartupLoader.load()
            isLoading = false
        }
    }

    func readLoginItemsAsAdmin() {
        Task {
            let r = await ToolsAdmin.run("/usr/bin/sfltool", ["dumpbtm"], prompt: "MacMaster needs administrator access to read all login items.")
            guard r.status == 0 else {
                ToolsToastCenter.shared.show(ToolsAdmin.isCancelled(r) ? "Cancelled" : "Could not read login items", error: true)
                return
            }
            let parsed = ToolsStartupLoader.parseBTM(r.stdout)
            items.removeAll { $0.kind == .loginItem }
            items += parsed
            ToolsToastCenter.shared.show("Found \(parsed.count) login item\(parsed.count == 1 ? "" : "s")")
        }
    }

    private func domain(for item: ToolsStartupItem) -> String { item.kind == .systemDaemon ? "system" : "gui/\(getuid())" }

    func setEnabled(_ item: ToolsStartupItem, enabled: Bool) {
        guard let plist = item.plistURL, !busy.contains(item.id) else { return }
        busy.insert(item.id)
        let dom = domain(for: item)
        let target = "\(dom)/\(item.label)"
        let first = enabled ? ["enable", target] : ["disable", target]
        let second = enabled ? ["bootstrap", dom, plist.path] : ["bootout", target]
        let admin = item.needsAdmin
        Task {
            var ok = true
            var err = ""
            if admin {
                // bootout/bootstrap report errors when the service is already in that state; only enable/disable must succeed.
                let line1 = (["/bin/launchctl"] + first).map(Shell.quote).joined(separator: " ")
                let line2 = (["/bin/launchctl"] + second).map(Shell.quote).joined(separator: " ") + " || true"
                let r = await ToolsAdmin.runScript([line1, line2], prompt: "MacMaster needs administrator access to change \(item.name).")
                ok = r.status == 0; err = ToolsAdmin.isCancelled(r) ? "Cancelled" : r.stderr
            } else {
                let r1 = await Shell.runAsync("/bin/launchctl", first)
                ok = r1.ok; err = r1.stderr
                if ok { _ = await Shell.runAsync("/bin/launchctl", second) }
            }
            busy.remove(item.id)
            if ok {
                ToolsToastCenter.shared.show(enabled ? "\(item.name) enabled" : "\(item.name) disabled")
                try? await Task.sleep(nanoseconds: 600_000_000)
                refreshOne()
            } else {
                ToolsToastCenter.shared.show("Could not change \(item.name): \(err.prefix(100))", error: true)
            }
        }
    }

    private func refreshOne() {
        isLoading = false
        reload()
    }

    func remove(_ item: ToolsStartupItem) {
        busy.insert(item.id)
        Task {
            var ok = false
            var err = ""
            switch item.kind {
            case .userAgent:
                if let plist = item.plistURL {
                    _ = await Shell.runAsync("/bin/launchctl", ["bootout", "gui/\(getuid())/\(item.label)"])
                    if let e = AppPaths.trash(plist) { err = e } else { ok = true }
                }
            case .systemAgent, .systemDaemon:
                if let plist = item.plistURL {
                    let dom = domain(for: item)
                    let trash = AppPaths.home.appendingPathComponent(".Trash").path
                    // Unique name so an existing Trash entry can't turn the move into a silent no-op.
                    let stem = plist.deletingPathExtension().lastPathComponent
                    let dest = "\(trash)/\(stem)-\(UUID().uuidString.prefix(8)).\(plist.pathExtension)"
                    let r = await ToolsAdmin.runScript([
                        "/bin/launchctl bootout \(Shell.quote(dom + "/" + item.label)) || true",
                        "/bin/mv -n \(Shell.quote(plist.path)) \(Shell.quote(dest))",
                        "/usr/sbin/chown \(getuid()) \(Shell.quote(dest)) || true",
                        // Last command decides the status: succeed only if the plist is really gone.
                        "test ! -e \(Shell.quote(plist.path))",
                    ], prompt: "MacMaster needs administrator access to remove \(item.name).")
                    ok = r.status == 0 && !FileManager.default.fileExists(atPath: plist.path)
                    err = ToolsAdmin.isCancelled(r) ? "Cancelled" : (r.stderr.isEmpty ? "The file is still in place" : r.stderr)
                }
            case .loginItem:
                if item.removableLoginItem {
                    let safe = item.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let r = await Shell.runAsync("/usr/bin/osascript", ["-e", "tell application \"System Events\" to delete login item \"\(safe)\""])
                    ok = r.ok; err = r.stderr
                } else {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    busy.remove(item.id)
                    ToolsToastCenter.shared.show("Turn it off in System Settings › Login Items")
                    return
                }
            }
            busy.remove(item.id)
            if ok {
                items.removeAll { $0.id == item.id }
                ToolsToastCenter.shared.show("\(item.name) removed")
            } else {
                ToolsToastCenter.shared.show("Could not remove \(item.name): \(err.prefix(100))", error: true)
            }
        }
    }

    func reveal(_ item: ToolsStartupItem) {
        if let u = item.plistURL ?? item.appURL { toolsReveal([u]) }
        else if let p = item.programPath { toolsReveal([URL(fileURLWithPath: p)]) }
    }
}

struct ToolsStartupView: View {
    @State private var model = ToolsStartupModel()
    @State private var pendingToggle: (ToolsStartupItem, Bool)?
    @State private var pendingRemove: ToolsStartupItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $model.filter) {
                    ForEach(ToolsStartupModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $model.search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 220)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Menu {
                    Button("Read all login items (admin)") { model.readLoginItemsAsAdmin() }
                    Button("Open Login Items settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 30)
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
            }
            .padding(.horizontal, Theme.pagePadding).padding(.vertical, 12)
            Divider()

            if model.items.isEmpty && model.isLoading {
                VStack { Spacer(); ProgressView("Reading startup items…"); Spacer() }
            } else if model.filtered.isEmpty {
                ToolsEmptyHint(symbol: "power.circle", text: "Nothing to show.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.filtered) { item in
                            ToolsStartupRow(item: item, busy: model.busy.contains(item.id),
                                            onToggle: { on in request(item, on) },
                                            onReveal: { model.reveal(item) },
                                            onRemove: { pendingRemove = item })
                        }
                    }
                    .padding(Theme.pagePadding)
                }
            }
        }
        .onAppear { if model.items.isEmpty { model.reload() } }
        .alert("Change system item?", isPresented: Binding(get: { pendingToggle != nil }, set: { if !$0 { pendingToggle = nil } }),
               presenting: pendingToggle) { pair in
            Button(pair.1 ? "Enable" : "Disable", role: pair.1 ? nil : .destructive) { model.setEnabled(pair.0, enabled: pair.1); pendingToggle = nil }
            Button("Cancel", role: .cancel) { pendingToggle = nil }
        } message: { pair in
            Text("\(pair.0.name) is a \(pair.0.kind.title.lowercased()) shared by all users. This needs your administrator password.")
        }
        .alert("Remove \(pendingRemove?.name ?? "item")?", isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
               presenting: pendingRemove) { item in
            Button("Remove", role: .destructive) { model.remove(item); pendingRemove = nil }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: { item in
            Text(item.kind == .loginItem && !item.removableLoginItem
                 ? "This login item is managed in System Settings. We will open it for you."
                 : "The launch configuration moves to the Trash and the item stops running. The app itself is not removed.")
        }
    }

    private func request(_ item: ToolsStartupItem, _ on: Bool) {
        if item.needsAdmin { pendingToggle = (item, on) } else { model.setEnabled(item, enabled: on) }
    }
}

private struct ToolsStartupRow: View {
    let item: ToolsStartupItem
    let busy: Bool
    let onToggle: (Bool) -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let app = item.appURL ?? appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 34, height: 34)
                } else {
                    IconTile(symbol: item.kind.symbol, colors: item.isBroken ? [.orange, .red] : ToolsTool.startup.colors, size: 34)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.headline).lineLimit(1)
                    if item.isBroken { StatusPill(text: "Broken", color: .red) }
                    else if item.isThirdParty { StatusPill(text: "Third-party", color: .blue) }
                    else { StatusPill(text: "Apple", color: .gray) }
                }
                Text(item.programPath ?? item.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(item.kind.title)
                    if item.kind != .loginItem {
                        Text(item.isLoaded ? "Loaded" : "Not loaded").foregroundStyle(item.isLoaded ? .green : .secondary)
                        if item.runAtLoad { Text("Runs at login") }
                        if !item.programExists { Text("Program missing").foregroundStyle(.red) }
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            Button(action: onReveal) { Image(systemName: "magnifyingglass.circle") }.buttonStyle(.plain).help("Reveal in Finder")
            Button(action: onRemove) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(item.isApple && item.kind != .loginItem).help("Remove")
            if item.plistURL != nil {
                Toggle("", isOn: Binding(get: { item.isActive }, set: { onToggle($0) }))
                    .toggleStyle(.switch).labelsHidden().disabled(busy || item.isApple)
            } else {
                StatusPill(text: item.enabledInBTM ? "On" : "Off", color: item.enabledInBTM ? .green : .gray)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
    }

    private var appURL: URL? {
        guard let p = item.programPath, let r = p.range(of: ".app") else { return nil }
        return URL(fileURLWithPath: String(p[..<r.upperBound]))
    }
}
