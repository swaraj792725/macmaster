import AppKit

/// Dev aid: `MM_MENUBAR_DIAG=/path/file.txt` dumps control-item frames and the AX inventory,
/// then collapses, dumps again, and expands. Lets us see how the bar behaves on a given macOS.
@MainActor
enum MenuBarManagerDiagnostics {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["MM_MENUBAR_DIAG"] else { return }
        Task { @MainActor in
            var log = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) axTrusted=\(AXIsProcessTrusted()) screens=\(NSScreen.screens.map { "\($0.frame) safeTop=\($0.safeAreaInsets.top)" })\n"
            let dir = (path as NSString).deletingLastPathComponent
            let m = MenuBarManager.shared
            try? await Task.sleep(for: .seconds(4))
            if m.runningMode == .dropdown {
                // Dropdown mode moves nothing: dump the inventory with inferred visibility, then open the list.
                await m.refreshDropdownInventory(force: true)
                log += dump("initial", m); shot(dir, "initial")
                m.openDropdown()
                try? await Task.sleep(for: .seconds(2))
                log += "dropdown visible=\(m.dropdown.isVisible) frame=\(m.dropdown.frame.map { "\($0)" } ?? "nil") \(m.dropdown.sizeDebug)\n"
                if let f = m.dropdown.frame, let h = NSScreen.screens.first?.frame.height {
                    shot(dir, "dropdown", rect: "\(Int(f.minX)),\(Int(h - f.maxY)),\(Int(f.width)),\(Int(f.height))")
                }
                m.dropdown.hide()
            } else {
                m.clearHidingUnsupported()
                log += dump("initial", m); shot(dir, "initial")
                m.collapse()
                try? await Task.sleep(for: .seconds(1.5))
                log += dump("after collapse", m); shot(dir, "collapsed")
                m.expand()
                try? await Task.sleep(for: .seconds(1.5))
                log += dump("after expand", m); shot(dir, "expanded")
                for len in [600.0, 1500.0] {
                    m.dividerItem?.length = len
                    try? await Task.sleep(for: .seconds(1.5))
                    log += dump("divider len \(len)", m); shot(dir, "len\(Int(len))")
                }
                m.dividerItem?.length = MenuBarManager.dividerLength
                log += "unsupported=\(m.hidingUnsupported)\n"
                m.toggleFromUser(optionDown: false)
                try? await Task.sleep(for: .seconds(1.5))
                log += "panel visible=\(m.panel.isVisible) frame=\(m.panel.frame.map { "\($0)" } ?? "nil")\n"
                m.panel.hide()
            }
            try? log.write(toFile: path, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["MM_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
        }
    }

    private static func shot(_ dir: String, _ name: String, rect: String? = nil) {
        let w = Int(NSScreen.screens.first?.frame.width ?? 1512)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R\(rect ?? "0,0,\(w),40")", "\(dir)/bar-\(name).png"]
        try? p.run(); p.waitUntilExit()
    }

    private static func dump(_ label: String, _ m: MenuBarManager) -> String {
        var s = "== \(label): state=\(m.state) running=\(m.isRunning) blocked=\(m.blockedReason ?? "-")\n"
        for (n, it) in [("toggle", m.toggleItem), ("divider", m.dividerItem), ("alwaysHidden", m.alwaysHiddenItem)] {
            guard let it else { s += "  \(n): nil\n"; continue }
            let w = it.button?.window
            s += "  \(n): len=\(it.length) visible=\(it.isVisible) win#=\(w?.windowNumber ?? -1) appkit=\(w?.frame ?? .zero) "
            s += "cg=\(m.frame(of: it).map { "\($0)" } ?? "nil") screen=\(w?.screen?.localizedName ?? "nil")\n"
        }
        let raw = MenuBarManagerScanner.axStatusItems(apps: m.runningAppRefs(), own: MenuBarManagerScanner.ownStatusItems())
        s += "  AX items: \(raw.count)\n"
        for r in raw.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            s += "    \(r.ownerName) [\(r.identifier)] '\(r.title)' \(r.frame)\n"
        }
        if m.runningMode == .dropdown {
            s += "  dropdown inventory: \(m.dropdownEntries.count) notShowing=\(m.dropdownNotShowingCount)\n"
            for e in m.dropdownEntries { s += "    \(e.displayName) \(e.visibility.rawValue) id=\(e.id) \(e.frame)\n" }
            return s
        }
        s += "  inventory: \(m.items.count) hidden=\(m.hiddenCount)\n"
        for it in m.items { s += "    \(it.displayName) \(it.section) \(it.frame)\n" }
        return s
    }
}
