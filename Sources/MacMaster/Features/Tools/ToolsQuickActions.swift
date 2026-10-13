import SwiftUI
import AppKit
import Observation

struct ToolsActionResult: Sendable {
    var ok: Bool
    var message: String
}

struct ToolsQuickAction: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let colors: [Color]
    var confirm: String? = nil          // shown in an alert when the action is disruptive
    var confirmButton: String = "Run"
    var admin = false
    var stateProbe: (@Sendable () -> Bool)? = nil
    var sheet = false                   // opens a dedicated sheet instead of running
    var run: @Sendable () async -> ToolsActionResult = { ToolsActionResult(ok: true, message: "Done") }
}

private enum ToolsQA {
    static func cmd(_ exe: String, _ args: [String]) async -> Shell.Result { await Shell.runAsync(exe, args, timeout: 60) }

    static func defaultsWrite(_ domain: String, _ key: String, _ type: String, _ value: String) async -> Bool {
        await cmd("/usr/bin/defaults", ["write", domain, key, "-\(type)", value]).ok
    }

    static func kill(_ name: String) async -> Bool { await cmd("/usr/bin/killall", [name]).ok }

    /// Flips a boolean pref, then restarts the process that reads it.
    static func toggleBool(domain: String, key: String, restart: String, on: String, off: String) async -> ToolsActionResult {
        let new = !toolsReadBool(key, domain: domain)
        guard await defaultsWrite(domain, key, "bool", new ? "true" : "false") else {
            return ToolsActionResult(ok: false, message: "Could not change the setting")
        }
        _ = await kill(restart)
        return ToolsActionResult(ok: true, message: new ? on : off)
    }

    static func external() -> [(url: URL, name: String)] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeNameKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return vols.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsInternal != true,
                  v.volumeIsEjectable == true || v.volumeIsRemovable == true, u.path != "/" else { return nil }
            return (u, v.volumeName ?? u.lastPathComponent)
        }
    }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
}

@Observable
@MainActor
final class ToolsQuickActionsModel {
    private(set) var states: [String: Bool] = [:]
    private(set) var running: Set<String> = []

    let actions: [ToolsQuickAction] = [
        ToolsQuickAction(id: "flushDNS", title: "Flush DNS cache", detail: "Fix stale hostnames and website lookups.",
                         symbol: "network", colors: [Color(hex: 0x34D399), Color(hex: 0x059669)], admin: true, run: {
            let r = await ToolsAdmin.runScript(["/usr/bin/dscacheutil -flushcache", "/usr/bin/killall -HUP mDNSResponder"],
                                               prompt: "MacMaster needs administrator access to flush the DNS cache.")
            return r.status == 0 ? ToolsActionResult(ok: true, message: "DNS cache flushed")
                                 : ToolsActionResult(ok: false, message: ToolsAdmin.isCancelled(r) ? "Cancelled" : "Could not flush DNS: \(r.stderr)")
        }),
        ToolsQuickAction(id: "dock", title: "Restart Dock", detail: "Relaunch the Dock and Mission Control.",
                         symbol: "dock.rectangle", colors: [Color(hex: 0x60A5FA), Color(hex: 0x2563EB)], run: {
            await ToolsQA.kill("Dock") ? ToolsActionResult(ok: true, message: "Dock restarted") : ToolsActionResult(ok: false, message: "Dock was not running")
        }),
        ToolsQuickAction(id: "finder", title: "Restart Finder", detail: "Relaunch Finder; open windows will close.",
                         symbol: "folder", colors: [Color(hex: 0x38BDF8), Color(hex: 0x0369A1)], run: {
            await ToolsQA.kill("Finder") ? ToolsActionResult(ok: true, message: "Finder restarted") : ToolsActionResult(ok: false, message: "Finder was not running")
        }),
        ToolsQuickAction(id: "menubar", title: "Restart Menu Bar", detail: "Relaunch SystemUIServer and Control Center.",
                         symbol: "menubar.rectangle", colors: [Color(hex: 0xA78BFA), Color(hex: 0x7C3AED)], run: {
            let a = await ToolsQA.kill("SystemUIServer"), b = await ToolsQA.kill("ControlCenter")
            return ToolsActionResult(ok: a || b, message: a || b ? "Menu bar restarted" : "Could not restart the menu bar")
        }),
        ToolsQuickAction(id: "hidden", title: "Show hidden files", detail: "Toggle dotfiles and hidden folders in Finder.",
                         symbol: "eye", colors: [Color(hex: 0xF472B6), Color(hex: 0xDB2777)],
                         stateProbe: { toolsReadBool("AppleShowAllFiles", domain: "com.apple.finder") }, run: {
            await ToolsQA.toggleBool(domain: "com.apple.finder", key: "AppleShowAllFiles", restart: "Finder",
                                     on: "Hidden files are now visible", off: "Hidden files are hidden")
        }),
        ToolsQuickAction(id: "pathbar", title: "Finder path bar", detail: "Show the current folder path at the bottom of Finder windows.",
                         symbol: "chevron.right.square", colors: [Color(hex: 0x2DD4BF), Color(hex: 0x0F766E)],
                         stateProbe: { toolsReadBool("ShowPathbar", domain: "com.apple.finder") }, run: {
            await ToolsQA.toggleBool(domain: "com.apple.finder", key: "ShowPathbar", restart: "Finder",
                                     on: "Path bar shown", off: "Path bar hidden")
        }),
        ToolsQuickAction(id: "statusbar", title: "Finder status bar", detail: "Show item counts and free space in Finder windows.",
                         symbol: "rectangle.bottomthird.inset.filled", colors: [Color(hex: 0x2DD4BF), Color(hex: 0x0F766E)],
                         stateProbe: { toolsReadBool("ShowStatusBar", domain: "com.apple.finder") }, run: {
            await ToolsQA.toggleBool(domain: "com.apple.finder", key: "ShowStatusBar", restart: "Finder",
                                     on: "Status bar shown", off: "Status bar hidden")
        }),
        ToolsQuickAction(id: "autohide", title: "Dock auto-hide", detail: "Hide the Dock until you move the pointer to its edge.",
                         symbol: "dock.arrow.down.rectangle", colors: [Color(hex: 0x60A5FA), Color(hex: 0x4F46E5)],
                         stateProbe: { toolsReadBool("autohide", domain: "com.apple.dock") }, run: {
            await ToolsQA.toggleBool(domain: "com.apple.dock", key: "autohide", restart: "Dock",
                                     on: "Dock auto-hide on", off: "Dock auto-hide off")
        }),
        ToolsQuickAction(id: "dockspeed", title: "Speed up Dock", detail: "Remove the auto-hide delay and shorten the animation.",
                         symbol: "hare", colors: [Color(hex: 0xFBBF24), Color(hex: 0xF97316)],
                         stateProbe: {
                             (toolsReadPref("autohide-delay", domain: "com.apple.dock") as? NSNumber)?.doubleValue == 0
                         }, run: {
            let fast = (toolsReadPref("autohide-delay", domain: "com.apple.dock") as? NSNumber)?.doubleValue == 0
            if fast {
                _ = await ToolsQA.cmd("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"])
                _ = await ToolsQA.cmd("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-time-modifier"])
            } else {
                let a = await ToolsQA.defaultsWrite("com.apple.dock", "autohide-delay", "float", "0")
                _ = await ToolsQA.defaultsWrite("com.apple.dock", "autohide-time-modifier", "float", "0.3")
                if !a { return ToolsActionResult(ok: false, message: "Could not change the setting") }
            }
            _ = await ToolsQA.kill("Dock")
            return ToolsActionResult(ok: true, message: fast ? "Dock speed restored to default" : "Dock auto-hide is now instant")
        }),
        ToolsQuickAction(id: "screenshot", title: "Screenshot settings", detail: "Choose the format, save location and window shadow.",
                         symbol: "camera.viewfinder", colors: [Color(hex: 0xF87171), Color(hex: 0xDC2626)], sheet: true),
        ToolsQuickAction(id: "spotlight", title: "Rebuild Spotlight index", detail: "Re-index the startup disk. Search is slow while it runs.",
                         symbol: "magnifyingglass", colors: [Color(hex: 0x818CF8), Color(hex: 0x4F46E5)],
                         confirm: "This erases the Spotlight index for your startup disk and rebuilds it. Search results may be incomplete and your Mac may run warm for a while.",
                         confirmButton: "Rebuild", admin: true, run: {
            let r = await ToolsAdmin.run("/usr/bin/mdutil", ["-E", "/"], prompt: "MacMaster needs administrator access to rebuild the Spotlight index.")
            return r.status == 0 ? ToolsActionResult(ok: true, message: "Spotlight is re-indexing")
                                 : ToolsActionResult(ok: false, message: ToolsAdmin.isCancelled(r) ? "Cancelled" : "Spotlight rebuild failed: \(r.stderr)")
        }),
        ToolsQuickAction(id: "ram", title: "Free up RAM", detail: "Purge inactive memory and disk caches.",
                         symbol: "memorychip", colors: [Color(hex: 0x60A5FA), Color(hex: 0x6366F1)], admin: true, run: {
            let r = await ToolsAdmin.run("/usr/sbin/purge", [], prompt: "MacMaster needs administrator access to free up memory.")
            return r.status == 0 ? ToolsActionResult(ok: true, message: "Memory purged")
                                 : ToolsActionResult(ok: false, message: ToolsAdmin.isCancelled(r) ? "Cancelled" : "Purge failed: \(r.stderr)")
        }),
        ToolsQuickAction(id: "launchpad", title: "Reset Launchpad", detail: "Restore the default app layout and restart the Dock.",
                         symbol: "square.grid.3x3", colors: [Color(hex: 0xC084FC), Color(hex: 0x9333EA)],
                         confirm: "Your custom Launchpad folders and ordering will be reset.", confirmButton: "Reset", run: {
            guard await ToolsQA.defaultsWrite("com.apple.dock", "ResetLaunchPad", "bool", "true") else {
                return ToolsActionResult(ok: false, message: "Could not reset Launchpad")
            }
            _ = await ToolsQA.kill("Dock")
            return ToolsActionResult(ok: true, message: "Launchpad reset")
        }),
        ToolsQuickAction(id: "lsregister", title: "Rebuild Launch Services", detail: "Fix duplicate entries in Open With and wrong default apps.",
                         symbol: "arrow.triangle.2.circlepath", colors: [Color(hex: 0xFB923C), Color(hex: 0xEA580C)],
                         confirm: "This rebuilds the database that maps documents to apps. It can take a minute, and Finder restarts afterwards.",
                         confirmButton: "Rebuild", run: {
            guard FileManager.default.isExecutableFile(atPath: ToolsQA.lsregister) else {
                return ToolsActionResult(ok: false, message: "lsregister was not found on this macOS version")
            }
            var r = await Shell.runAsync(ToolsQA.lsregister, ["-kill", "-r", "-domain", "local", "-domain", "user"], timeout: 300)
            if !r.ok { r = await Shell.runAsync(ToolsQA.lsregister, ["-r", "-f", "-domain", "local", "-domain", "user"], timeout: 300) }
            _ = await ToolsQA.kill("Finder")
            return r.ok ? ToolsActionResult(ok: true, message: "Launch Services rebuilt")
                        : ToolsActionResult(ok: false, message: "Rebuild failed: \(r.stderr.prefix(120))")
        }),
        ToolsQuickAction(id: "fonts", title: "Clear font caches", detail: "Fix garbled or missing fonts.",
                         symbol: "textformat", colors: [Color(hex: 0x94A3B8), Color(hex: 0x475569)],
                         confirm: "Font caches are removed and rebuilt. Restart your Mac afterwards for a clean result.",
                         confirmButton: "Clear", admin: true, run: {
            let r = await ToolsAdmin.run("/usr/bin/atsutil", ["databases", "-remove"], prompt: "MacMaster needs administrator access to clear font caches.")
            return r.status == 0 ? ToolsActionResult(ok: true, message: "Font caches cleared — restart recommended")
                                 : ToolsActionResult(ok: false, message: ToolsAdmin.isCancelled(r) ? "Cancelled" : "Could not clear font caches: \(r.stderr)")
        }),
        ToolsQuickAction(id: "eject", title: "Eject all external disks", detail: "Safely unmount every external and removable volume.",
                         symbol: "eject", colors: [Color(hex: 0x34D399), Color(hex: 0x0F766E)],
                         confirm: "All external disks and disk images will be ejected. Save open files first.", confirmButton: "Eject", run: {
            let vols = ToolsQA.external()
            if vols.isEmpty { return ToolsActionResult(ok: true, message: "No external disks to eject") }
            var failed: [String] = []
            for v in vols {
                do { try await ToolsQA.unmount(v.url) } catch { failed.append(v.name) }
            }
            return failed.isEmpty ? ToolsActionResult(ok: true, message: "Ejected \(vols.count) disk\(vols.count == 1 ? "" : "s")")
                                  : ToolsActionResult(ok: false, message: "Could not eject: " + failed.joined(separator: ", "))
        }),
    ]

    func refreshStates() {
        let probes = actions.compactMap { a in a.stateProbe.map { (a.id, $0) } }
        Task {
            let result = await Task.detached { Dictionary(uniqueKeysWithValues: probes.map { ($0.0, $0.1()) }) }.value
            states = result
        }
    }

    func perform(_ action: ToolsQuickAction) {
        guard !running.contains(action.id) else { return }
        running.insert(action.id)
        Task {
            let r = await action.run()
            running.remove(action.id)
            ToolsToastCenter.shared.show(r.message, error: !r.ok)
            refreshStates()
        }
    }
}

extension ToolsQA {
    static func unmount(_ url: URL) async throws {
        try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }.value
    }
}

// MARK: - View

struct ToolsQuickActionsView: View {
    @State private var model = ToolsQuickActionsModel()
    @State private var pending: ToolsQuickAction?
    @State private var showScreenshot = false

    var body: some View {
        Page {
            Text("Everyday fixes and tweaks. Disruptive actions ask first; actions that need administrator access prompt once.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: Theme.spacing)], spacing: Theme.spacing) {
                ForEach(model.actions) { a in
                    ToolsActionCard(action: a, state: model.states[a.id], busy: model.running.contains(a.id)) { tap(a) }
                }
            }
        }
        .onAppear { model.refreshStates() }
        .alert(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { a in
            Button(a.confirmButton, role: .destructive) { model.perform(a); pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { a in Text(a.confirm ?? "") }
        .sheet(isPresented: $showScreenshot) { ToolsScreenshotSheet(onDone: { showScreenshot = false; model.refreshStates() }) }
    }

    private func tap(_ a: ToolsQuickAction) {
        if a.sheet { showScreenshot = true } else if a.confirm != nil { pending = a } else { model.perform(a) }
    }
}

private struct ToolsActionCard: View {
    let action: ToolsQuickAction
    let state: Bool?
    let busy: Bool
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: action.symbol, colors: action.colors, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(action.title).font(.headline)
                        if action.admin { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Needs administrator access") }
                    }
                    Text(action.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if busy { ProgressView().controlSize(.small) }
                else if let state { StatusPill(text: state ? "On" : "Off", color: state ? .green : .gray) }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .card()
            .scaleEffect(hover ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { h in withAnimation(.smooth(duration: 0.15)) { hover = h } }
    }
}

// MARK: - Screenshot settings

private struct ToolsScreenshotSheet: View {
    var onDone: () -> Void
    @State private var format = "png"
    @State private var location = ""
    @State private var shadow = true
    @State private var saving = false
    private let formats = ["png", "jpg", "heic", "tiff", "pdf", "gif"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "camera.viewfinder", colors: [Color(hex: 0xF87171), Color(hex: 0xDC2626)], size: 40)
                Text("Screenshot settings").font(.title2.weight(.bold))
            }
            Picker("Format", selection: $format) { ForEach(formats, id: \.self) { Text($0.uppercased()).tag($0) } }
                .pickerStyle(.segmented)
            HStack {
                Text("Save to").foregroundStyle(.secondary)
                Text(location.isEmpty ? "Desktop" : (location as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    if let u = ToolsPicker.chooseFolder(start: location.isEmpty ? nil : URL(fileURLWithPath: location), message: "Where should screenshots be saved?") {
                        location = u.path
                    }
                }
            }
            Toggle("Include window shadow", isOn: $shadow)
            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(22).frame(width: 440)
        .onAppear {
            format = (toolsReadPref("type", domain: "com.apple.screencapture") as? String) ?? "png"
            if !formats.contains(format) { format = "png" }
            location = (toolsReadPref("location", domain: "com.apple.screencapture") as? String).map { ($0 as NSString).expandingTildeInPath } ?? ""
            shadow = !toolsReadBool("disable-shadow", domain: "com.apple.screencapture")
        }
    }

    private func apply() {
        saving = true
        let fmt = format, loc = location, sh = shadow
        Task {
            var ok = await ToolsQA.defaultsWrite("com.apple.screencapture", "type", "string", fmt)
            if !loc.isEmpty { ok = await ToolsQA.defaultsWrite("com.apple.screencapture", "location", "string", loc) && ok }
            ok = await ToolsQA.defaultsWrite("com.apple.screencapture", "disable-shadow", "bool", sh ? "false" : "true") && ok
            _ = await ToolsQA.kill("SystemUIServer")
            ToolsToastCenter.shared.show(ok ? "Screenshot settings applied" : "Could not apply all settings", error: !ok)
            saving = false
            onDone()
        }
    }
}
