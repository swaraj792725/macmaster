import AppKit
import SwiftUI

/// Dev aid: `MM_SNAPSHOT_DIR=/path open MacMaster.app` (or run the binary with the env var)
/// walks every section and writes PNGs of the main window — no Screen Recording permission needed.
@MainActor
enum DebugSnapshot {
    static func runIfRequested() {
        if ProcessInfo.processInfo.environment["MM_HUNTER_DUMP"] != nil { dumpHunter(); return }
        if let ids = ProcessInfo.processInfo.environment["MM_THUMB_TEST"], let dir = ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] {
            Task { @MainActor in
                for id in ids.split(separator: ",").compactMap({ UInt32($0) }) {
                    guard let img = await WindowPreviewThumbnailer.shared.capture(id: id, box: CGSize(width: 520, height: 330), maxAge: 0) else { continue }
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("thumb-\(id).png"))
                }
                NSApp.terminate(nil)
            }
            return
        }
        guard let dir = ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] else { return }
        let only = ProcessInfo.processInfo.environment["MM_SNAPSHOT_SECTIONS"]?.split(separator: ",").map(String.init)
        let sections = AppSection.allCases.filter { only?.contains($0.rawValue) ?? true }
        Task { @MainActor in
            let wait = Double(ProcessInfo.processInfo.environment["MM_SNAPSHOT_WAIT"] ?? "") ?? 3
            try? await Task.sleep(for: .seconds(wait))
            // MM_SNAPSHOT_HEIGHT=2600: render each page alone in a tall borderless window (whole page in one PNG).
            if let h = Double(ProcessInfo.processInfo.environment["MM_SNAPSHOT_HEIGHT"] ?? "") {
                let dark = ProcessInfo.processInfo.environment["MM_SNAPSHOT_LIGHT"] == nil
                for s in sections {
                    await captureTall(s, height: h, dark: dark,
                                      to: URL(fileURLWithPath: dir).appendingPathComponent("\(s.rawValue)-tall.png"))
                }
                if ProcessInfo.processInfo.environment["MM_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
                return
            }
            // MM_PERF=seconds: measure CPU time per page over that window (written to perf.txt).
            let perf = Double(ProcessInfo.processInfo.environment["MM_PERF"] ?? "")
            var report = ""
            for s in sections {
                NotificationCenter.default.post(name: .openSection, object: s.rawValue)
                try? await Task.sleep(for: .seconds(2.5))
                capture(to: URL(fileURLWithPath: dir).appendingPathComponent("\(s.rawValue).png"))
                if let perf {
                    try? await Task.sleep(for: .seconds(2))
                    let c0 = cpuSeconds()
                    try? await Task.sleep(for: .seconds(perf))
                    let pct = (cpuSeconds() - c0) / perf * 100
                    report += String(format: "%-12@ %5.1f%%  footprint %.0f MB\n", s.rawValue as NSString, pct, footprintMB())
                }
            }
            if perf != nil { try? report.write(toFile: dir + "/perf.txt", atomically: true, encoding: .utf8) }
            await captureMenuBar(to: URL(fileURLWithPath: dir).appendingPathComponent("popover.png"))
            await capturePopover(StatsPopoverView(module: .battery), width: 340,
                                 to: URL(fileURLWithPath: dir).appendingPathComponent("popover-battery.png"))
            if ProcessInfo.processInfo.environment["MM_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
        }
    }

    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func sec(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return sec(u.ru_utime) + sec(u.ru_stime)
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func captureTall(_ section: AppSection, height: CGFloat, dark: Bool, to url: URL) async {
        let size = NSSize(width: 940, height: height)
        let root = section.view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.backgroundColor = .windowBackgroundColor
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(3))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
        window.contentView = nil
    }

    /// Renders the menu bar popover offscreen.
    static func captureMenuBar(to url: URL) async {
        await capturePopover(MenuBarControlCenter(), width: 352, to: url)
    }

    /// Renders a popover-sized view offscreen in dark mode, sized to fit its content.
    static func capturePopover<V: View>(_ view: V, width: CGFloat, to url: URL) async {
        let dark = ProcessInfo.processInfo.environment["MM_SNAPSHOT_LIGHT"] == nil
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))   // cacheDisplay skips the window background
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.backgroundColor = .windowBackgroundColor
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(2))      // let the popover measure itself
        let fit = host.fittingSize
        if fit.width > 0, fit.height > 0 { window.setContentSize(fit) }
        try? await Task.sleep(for: .seconds(1))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
        window.contentView = nil
    }

    /// `MM_HUNTER_DUMP=1` prints Leftover Hunter results to stdout and quits (no UI, nothing removed).
    static func dumpHunter() {
        Task.detached {
            let apps = UninstallerAppCatalog.discover()
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
            let r = await UninstallerHunter.scan(apps: apps, runningIDs: running, includeSystem: true) { _ in }
            print("installed=\(r.installedAppCount) scanned=\(r.scannedEntries) groups=\(r.groups.count) broken=\(r.brokenItems.count)")
            for g in r.groups.sorted(by: { $0.totalSize > $1.totalSize }) {
                print("== \(g.name) [\(Fmt.bytes(g.totalSize))]\(g.isDeveloper ? " (dev)" : "")")
                for i in g.items { print("   \(i.confidence) \(Fmt.bytes(i.size))  \(i.url.path)  — \(i.reason)") }
            }
            for b in r.brokenItems { print("BROKEN \(b.confidence) \(b.url.path) — \(b.reason)") }
            fflush(stdout)
            await MainActor.run { NSApp.terminate(nil) }
        }
    }
}
