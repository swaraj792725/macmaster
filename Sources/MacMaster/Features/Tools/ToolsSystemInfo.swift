import SwiftUI
import AppKit

struct ToolsHardwareProfile: Sendable {
    var modelName = ""
    var modelNumber = ""
    var chip = ""
    var gpuCores = ""
    var cores = ""
    var memory = ""
    var firmware = ""
}

enum ToolsSystemProfiler {
    /// `system_profiler` is slow (~1s), so it runs once in the background. Serial numbers are intentionally never read.
    static func load() async -> ToolsHardwareProfile {
        var p = ToolsHardwareProfile()
        let hw = await Shell.runAsync("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"], timeout: 25)
        if let d = hw.stdout.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let arr = root["SPHardwareDataType"] as? [[String: Any]], let h = arr.first {
            p.modelName = h["machine_name"] as? String ?? ""
            p.modelNumber = h["model_number"] as? String ?? ""
            p.chip = h["chip_type"] as? String ?? (h["cpu_type"] as? String ?? "")
            p.cores = h["number_processors"] as? String ?? ""
            p.memory = h["physical_memory"] as? String ?? ""
            p.firmware = h["boot_rom_version"] as? String ?? ""
        }
        let gpu = await Shell.runAsync("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"], timeout: 25)
        if let d = gpu.stdout.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let arr = root["SPDisplaysDataType"] as? [[String: Any]], let g = arr.first {
            p.gpuCores = g["sppci_cores"] as? String ?? ""
        }
        return p
    }
}

struct ToolsSystemInfoView: View {
    private let monitor = SystemMonitor.shared
    private let battery = BatteryMonitor.shared
    @State private var profile: ToolsHardwareProfile?
    @State private var copied = false

    var body: some View {
        let info = SystemInfo.current
        Page {
            hero(info)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Theme.spacing, alignment: .top)], spacing: Theme.spacing) {
                processorCard(info)
                memoryCard(info)
                storageCard
                systemCard(info)
                displaysCard
                if battery.reading.isPresent { batteryCard }
            }
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report(info), forType: .string)
                    copied = true
                    ToolsToastCenter.shared.show("System report copied")
                } label: { Label(copied ? "Copied" : "Copy report", systemImage: "doc.on.doc") }
            }
        }
        .task { if profile == nil { profile = await ToolsSystemProfiler.load() } }
    }

    private func mem(_ v: UInt64) -> String { Fmt.bytes(Int64(clamping: v), style: .memory) }

    // MARK: Cards

    private func hero(_ info: SystemInfo) -> some View {
        HStack(spacing: 20) {
            IconTile(symbol: "laptopcomputer", colors: ToolsTool.systemInfo.colors, size: 70)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile?.modelName.isEmpty == false ? profile!.modelName : info.modelIdentifier)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(info.chip).font(.title3).foregroundStyle(.secondary)
                Text("\(info.hostName) · \(info.osVersion)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Uptime").font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(Fmt.duration(SystemInfo.uptime)).font(.system(size: 22, weight: .semibold, design: .rounded))
                }
            }
        }
        .card()
    }

    private func processorCard(_ info: SystemInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "Processor & graphics", symbol: "cpu")
            InfoRow(label: "Chip", value: info.chip)
            InfoRow(label: "Performance cores", value: info.performanceCores > 0 ? "\(info.performanceCores)" : "—")
            InfoRow(label: "Efficiency cores", value: info.efficiencyCores > 0 ? "\(info.efficiencyCores)" : "—")
            InfoRow(label: "Logical cores", value: "\(info.logicalCores)")
            InfoRow(label: "GPU cores", value: profile?.gpuCores.isEmpty == false ? profile!.gpuCores : "—")
            InfoRow(label: "CPU load", value: Fmt.percent(monitor.cpu.total))
            InfoRow(label: "Thermal state", value: "\(monitor.thermal.state)".capitalized)
        }
        .card()
    }

    private func memoryCard(_ info: SystemInfo) -> some View {
        let m = monitor.memory
        return VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "Memory", symbol: "memorychip")
            InfoRow(label: "Installed", value: mem(info.memory))
            InfoRow(label: "In use", value: mem(m.used))
            InfoRow(label: "Wired / compressed", value: "\(mem(m.wired)) / \(mem(m.compressed))")
            InfoRow(label: "Swap used", value: mem(m.swapUsed))
            CapsuleBar(fraction: m.usedFraction, color: Theme.Palette.memory).padding(.top, 4)
        }
        .card()
    }

    private var storageCard: some View {
        let d = monitor.disk
        let vals = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey, .volumeLocalizedFormatDescriptionKey])
        return VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "Storage", symbol: "internaldrive")
            InfoRow(label: "Volume", value: vals?.volumeName ?? "Macintosh HD")
            InfoRow(label: "Format", value: vals?.volumeLocalizedFormatDescription ?? "—")
            InfoRow(label: "Capacity", value: Fmt.bytes(d.total))
            InfoRow(label: "Available", value: Fmt.bytes(d.available))
            CapsuleBar(fraction: d.usedFraction).padding(.top, 4)
        }
        .card()
    }

    private func systemCard(_ info: SystemInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "System", symbol: "macwindow")
            InfoRow(label: "Model identifier", value: info.modelIdentifier)
            if let n = profile?.modelNumber, !n.isEmpty { InfoRow(label: "Model number", value: n) }
            InfoRow(label: "macOS", value: info.osVersion)
            InfoRow(label: "Build", value: Sysctl.string("kern.osversion") ?? "—")
            InfoRow(label: "Kernel", value: Sysctl.string("kern.osrelease").map { "Darwin \($0)" } ?? "—")
            if let f = profile?.firmware, !f.isEmpty { InfoRow(label: "Firmware", value: f) }
            InfoRow(label: "Booted", value: Date(timeIntervalSinceNow: -SystemInfo.uptime).formatted(date: .abbreviated, time: .shortened))
        }
        .card()
    }

    private var displaysCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Displays", symbol: "display")
            ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.localizedName).font(.callout.weight(.semibold))
                    Text(displayDetail(s)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if NSScreen.screens.isEmpty { Text("No displays found").foregroundStyle(.secondary) }
        }
        .card()
    }

    private func displayDetail(_ s: NSScreen) -> String {
        let px = CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
        var parts = ["\(Int(s.frame.width))×\(Int(s.frame.height)) pt", "\(Int(px.width))×\(Int(px.height)) px",
                     "\(Int(s.backingScaleFactor))x", "\(s.maximumFramesPerSecond) Hz"]
        if let cs = s.colorSpace?.localizedName { parts.append(cs) }
        if s.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.5 { parts.append("HDR") }
        return parts.joined(separator: " · ")
    }

    private var batteryCard: some View {
        let b = battery.reading
        return VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "Battery", symbol: "battery.100")
            InfoRow(label: "Charge", value: "\(Int(b.percent))%\(b.isCharging ? " · charging" : "")")
            InfoRow(label: "Cycle count", value: "\(b.cycleCount)")
            InfoRow(label: "Health", value: Fmt.percent(b.health))
            InfoRow(label: "Condition", value: b.condition ?? "—")
        }
        .card()
    }

    private func report(_ info: SystemInfo) -> String {
        let d = monitor.disk
        var lines = [
            "Model: \(profile?.modelName ?? info.modelIdentifier) (\(info.modelIdentifier))",
            "Chip: \(info.chip) — \(info.performanceCores)P + \(info.efficiencyCores)E cores",
            "Memory: \(mem(info.memory))",
            "macOS: \(info.osVersion)",
            "Disk: \(Fmt.bytes(d.total)) total, \(Fmt.bytes(d.available)) available",
            "Uptime: \(Fmt.duration(SystemInfo.uptime))",
        ]
        for s in NSScreen.screens { lines.append("Display: \(s.localizedName) \(displayDetail(s))") }
        if battery.reading.isPresent { lines.append("Battery cycles: \(battery.reading.cycleCount)") }
        return lines.joined(separator: "\n")
    }
}
