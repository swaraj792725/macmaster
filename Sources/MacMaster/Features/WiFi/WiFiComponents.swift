import SwiftUI

// MARK: - Small pieces

/// Label + monospaced value with a copy button. Used inside `GroupedSection`.
struct WiFiValueRow: View {
    let title: String
    var value: String?
    var placeholder = "—"
    var copyable = true
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value ?? placeholder)
                .monospacedDigit()
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if copyable, let value {
                Button {
                    WiFiModel.copy(value)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
        }
        .font(.callout)
    }
}

struct WiFiStat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Hero

struct WiFiHeroCard: View {
    private let model = WiFiModel.shared

    var body: some View {
        let l = model.link
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(l.qualityColor.opacity(0.16))
                    WiFiArcsView(bars: l.bars, ink: l.qualityColor, slashed: !l.isConnected, height: 24)
                }
                .frame(width: 60, height: 60)
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(l.qualityColor.opacity(0.25), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title(l)).font(.system(size: 20, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    HStack(spacing: 6) {
                        StatusPill(text: l.quality, color: l.qualityColor)
                        if l.isConnected, let b = l.band { chip(b.rawValue) }
                        if l.isConnected, let phy = l.phy {
                            chip(phy.components(separatedBy: "(").last?.trimmingCharacters(in: CharacterSet(charactersIn: "() ")) ?? phy)
                        }
                        if l.isConnected, l.lockState == 1 { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                }
                Spacer(minLength: 8)
                if l.hasInterface {
                    Toggle(isOn: Binding(get: { model.link.powerOn }, set: { model.setPower($0) })) { EmptyView() }
                        .toggleStyle(.mmSwitch).accessibilityLabel("Wi-Fi")
                }
            }
            if model.needsLocationForName { locationRow }
            if let e = model.actionError { Text(e).font(.caption).foregroundStyle(.red) }
            if l.isConnected {
                HStack(spacing: 8) {
                    WiFiStat(label: "Signal", value: WiFiFmt.dbm(l.rssi))
                    WiFiStat(label: "Noise", value: WiFiFmt.dbm(l.noise))
                    WiFiStat(label: "SNR", value: l.snr.map { "\($0) dB" } ?? "—")
                    WiFiStat(label: "Tx rate", value: l.txRate > 0 ? "\(Int(l.txRate)) Mbps" : "—")
                }
                if !l.channelText.isEmpty {
                    Label(l.channelText, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .card()
        .background(
            LinearGradient(colors: [l.qualityColor.opacity(l.isConnected ? 0.14 : 0.04), .clear],
                           startPoint: .topLeading, endPoint: .center)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .allowsHitTesting(false)
        )
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.07), in: Capsule())
    }

    private func title(_ l: WiFiLink) -> String {
        if !l.hasInterface { return "No Wi-Fi hardware" }
        if !l.powerOn { return "Wi-Fi is off" }
        if !l.isConnected { return "Not connected" }
        return l.ssid ?? "Wi-Fi network"
    }

    private var locationRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.fill").foregroundStyle(Theme.Palette.teal.last ?? .teal)
            Text("Allow Location to see network name").font(.callout)
            Spacer(minLength: 8)
            Button(Permissions.locationCanPrompt ? "Allow" : "Open Settings") { Permissions.request(.location) }
                .buttonStyle(.mmSecondary)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Details

struct WiFiDetailsCard: View {
    private let model = WiFiModel.shared
    var showsLink = true

    var body: some View {
        let l = model.link, ip = model.ip
        VStack(alignment: .leading, spacing: 14) {
            if showsLink, l.isConnected {
                GroupedSection("Connection", symbol: "wifi") {
                    WiFiValueRow(title: "Network", value: l.ssid, placeholder: "Hidden (needs Location)")
                    WiFiValueRow(title: "Standard", value: l.phy, copyable: false)
                    WiFiValueRow(title: "Security", value: l.security, copyable: false)
                    WiFiValueRow(title: "Router BSSID", value: l.bssid, placeholder: "Hidden (needs Location)")
                    WiFiValueRow(title: "Interface", value: l.interfaceName)
                    if let c = l.country { WiFiValueRow(title: "Country", value: c, copyable: false) }
                }
            }
            if l.isConnected {
                GroupedSection("Addresses", symbol: "number") {
                    WiFiValueRow(title: "IPv4", value: ip.ipv4.first)
                    WiFiValueRow(title: "IPv6", value: ip.ipv6.first)
                    WiFiValueRow(title: "Router", value: ip.router)
                    WiFiValueRow(title: "DNS", value: ip.dns.isEmpty ? nil : ip.dns.joined(separator: ", "))
                    WiFiValueRow(title: "MAC", value: l.mac)
                    WiFiPublicIPRow()
                }
            }
        }
    }
}

struct WiFiPublicIPRow: View {
    private let model = WiFiModel.shared

    var body: some View {
        switch model.publicIP {
        case .value(let v): WiFiValueRow(title: "Public IP", value: v)
        case .loading:
            HStack {
                Text("Public IP").foregroundStyle(.secondary).font(.callout)
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .failed(let m): WiFiValueRow(title: "Public IP", value: m, copyable: false)
        case .idle:
            WiFiValueRow(title: "Public IP", value: WiFiSettings.publicIPEnabled ? nil : "Off in settings", copyable: false)
        }
    }
}

// MARK: - Throughput

struct WiFiThroughputCard: View {
    private let monitor = SystemMonitor.shared
    private let model = WiFiModel.shared

    var body: some View {
        let hist = monitor.history.suffix(45)
        let down = hist.map(\.netDown), up = hist.map(\.netUp)
        let peak = max(down.max() ?? 0, up.max() ?? 0, 10_000)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                lane("Download", "arrow.down", Fmt.rate(monitor.network.downRate), down, peak, Color(hex: 0x30D158))
                lane("Upload", "arrow.up", Fmt.rate(monitor.network.upRate), up, peak, Color(hex: 0x0A84FF))
            }
            HStack {
                Label(model.connections.map { "\($0) active connections" } ?? "Counting connections…", systemImage: "arrow.left.arrow.right")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("All interfaces").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .card()
    }

    private func lane(_ title: String, _ symbol: String, _ value: String, _ values: [Double], _ peak: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(color)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Sparkline(values: values, color: color, maxValue: peak).frame(height: 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Speed test

struct WiFiSpeedTestCard: View {
    private let test = WiFiSpeedTest.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Speed test", systemImage: "gauge.with.dots.needle.67percent").font(.system(size: 14, weight: .semibold))
                Spacer()
                if test.isRunning {
                    Button("Cancel") { test.cancel() }.buttonStyle(.mmSecondary)
                } else {
                    Button(test.last == nil ? "Start" : "Run again") { test.start() }.buttonStyle(.mmPrimary)
                }
            }
            switch test.state {
            case .running(let since):
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    let t = ctx.date.timeIntervalSince(since)
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: min(0.97, t / 24))
                        Text("Measuring download, upload and responsiveness… \(Int(t))s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .failed(let m):
                Text(m).font(.caption).foregroundStyle(.red)
                if let r = test.last { results(r) }
            case .done(let r): results(r)
            case .idle:
                if let r = test.last { results(r) } else {
                    Text("Uses Apple's networkQuality for about 20 seconds and moves real data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    private func results(_ r: WiFiSpeedResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WiFiStat(label: "Download", value: "\(WiFiFmt.mbps(r.downBps)) Mbps")
                WiFiStat(label: "Upload", value: "\(WiFiFmt.mbps(r.upBps)) Mbps")
                WiFiStat(label: "Responsiveness", value: r.rpm.map { "\(Int($0)) RPM" } ?? "—")
            }
            HStack(spacing: 6) {
                if let w = r.responsivenessWord { Text(w).font(.caption.weight(.medium)) }
                if let b = r.baseRTT { Text("· base latency \(WiFiFmt.ms(b))").font(.caption) }
                Spacer()
                Text(r.date, style: .time).font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Latency

struct WiFiLatencyCard: View {
    private let model = WiFiModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Latency", systemImage: "waveform.path.ecg").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.pinging { ProgressView().controlSize(.small) }
                Button("Ping") { model.runPings() }.buttonStyle(.mmSecondary).disabled(model.pinging || !model.link.isConnected)
            }
            HStack(spacing: 8) {
                tile("Router", model.gatewayPing, model.ip.router)
                tile("Internet", model.internetPing, "1.1.1.1")
            }
        }
        .card()
    }

    private func tile(_ title: String, _ p: WiFiPing?, _ host: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(p.map { WiFiFmt.ms($0.avgMs) } ?? "—")
                .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color(p))
            Text(sub(p, host)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sub(_ p: WiFiPing?, _ host: String?) -> String {
        guard let p else { return host ?? "" }
        let loss = p.lossPercent.map { $0 > 0 ? " · \(Int($0))% loss" : "" } ?? ""
        return (host ?? p.host) + loss
    }

    private func color(_ p: WiFiPing?) -> Color {
        guard let ms = p?.avgMs else { return .primary }
        return ms < 30 ? Color(hex: 0x30D158) : (ms < 80 ? Color(hex: 0xFF9F0A) : Color(hex: 0xFF453A))
    }
}

// MARK: - Actions

struct WiFiActionsCard: View {
    var body: some View {
        HStack(spacing: 8) {
            Button { WiFiModel.openWiFiSettings() } label: {
                Label("Wi-Fi Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
            }
            Button { WiFiModel.openDiagnostics() } label: {
                Label("Diagnostics", systemImage: "stethoscope").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.mmSecondary)
    }
}
