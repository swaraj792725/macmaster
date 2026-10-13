import SwiftUI
import ApplicationServices

/// "Personal Hotspot" section: iPhones and iPads Instant Hotspot can see (even with the hotspot off), plus hotspots
/// that already show up in the Wi-Fi scan. Discovery only runs while this card is on screen.
struct WiFiHotspotCard: View {
    private let wifi = WiFiModel.shared
    @State private var hs = WiFiHotspotModel.shared
    @State private var password = ""
    @FocusState private var focused: Bool

    /// Scan results that look like a hotspot and aren't already listed as a discovered device.
    private var scanned: [WiFiNetwork] {
        let known = Set(hs.devices.map(\.nameKey))
        return wifi.networks.filter { $0.hotspot != .none && !known.contains(WiFiHotspot.normalized($0.ssid)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(hs.devices) { deviceRow($0) }
            ForEach(scanned) { scannedRow($0) }
            status
            if let e = hs.error {
                Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if showsInfoRow { infoRow }
        }
        .card()
        .onAppear {
            hs.sectionAppeared()
            if wifi.scanState == .idle, wifi.link.powerOn { wifi.scan() }
        }
        .onDisappear { hs.sectionDisappeared() }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "personalhotspot").foregroundStyle(Color.green)
            Text("Personal Hotspot").font(.headline)
            Spacer()
            if hs.discovery == .searching { ProgressView().controlSize(.small) }
            Button { hs.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.mmGhost).help("Look again")
                .disabled(hs.connectingID != nil)
        }
    }

    @ViewBuilder private var status: some View {
        switch hs.discovery {
        case .searching where hs.devices.isEmpty && scanned.isEmpty:
            Text("Looking for your iPhone…").font(.callout).foregroundStyle(.secondary)
        case .empty where scanned.isEmpty:
            Text("No iPhone or iPad found nearby. It needs Bluetooth and Wi-Fi on, and the same Apple ID as this Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .unavailable(let why):
            Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        default:
            if !hs.devices.isEmpty {
                Text("Connect asks the phone to turn Personal Hotspot on, then joins it. Same as Apple's Wi-Fi menu.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The honest fallback: only when discovery can't help.
    private var showsInfoRow: Bool {
        if case .unavailable = hs.discovery { return true }
        return hs.devices.isEmpty && hs.discovery != .searching
    }

    private var infoRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("To wake a hotspot that's off, open Apple's Wi-Fi menu.").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("Open") { WiFiHotspot.openAppleWiFiMenu() }.buttonStyle(.mmSecondary)
                .help(AXIsProcessTrusted() ? "Opens Apple's Wi-Fi menu" : "Opens Wi-Fi settings (grant Accessibility to open the menu itself)")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Rows

    private func deviceRow(_ d: WiFiHotspotDevice) -> some View {
        let connected = hs.isConnected(d)
        let busy = hs.connectingID == d.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.green.opacity(0.16))
                    Image(systemName: d.symbol).font(.system(size: 17)).foregroundStyle(.green)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.name).font(.callout.weight(.medium)).lineLimit(1)
                    HStack(spacing: 8) {
                        if let b = d.battery { Label("\(b)%", systemImage: batterySymbol(b)) }
                        if let s = d.signalBars { cellularBars(s) }
                        if let n = d.network { Text(n).font(.caption2.weight(.semibold)) }
                    }
                    .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 6)
                if busy {
                    ProgressView().controlSize(.small)
                } else if connected {
                    Label("Connected", systemImage: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.green)
                } else {
                    Button("Connect") { hs.connect(d) }
                        .buttonStyle(.mmPrimary).disabled(hs.connectingID != nil || !wifi.link.powerOn)
                }
            }
            if busy, let step = hs.step {
                Text(step).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func scannedRow(_ n: WiFiNetwork) -> some View {
        let joining = wifi.joiningID == n.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.green.opacity(0.16))
                    Image(systemName: "personalhotspot").font(.system(size: 16)).foregroundStyle(.green)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.displayName).font(.callout.weight(.medium)).lineLimit(1)
                    Text(n.hotspot == .flagged ? "Personal Hotspot on, in range" : "Looks like a hotspot (guessed from its name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if joining {
                    ProgressView().controlSize(.small)
                } else if n.isCurrent {
                    Label("Connected", systemImage: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.green)
                } else {
                    Button("Join") { password = ""; wifi.join(n, password: nil) }
                        .buttonStyle(.mmPrimary).disabled(wifi.joiningID != nil)
                }
            }
            if wifi.passwordTargetID == n.id {
                HStack(spacing: 6) {
                    SecureField("Hotspot password", text: $password).textFieldStyle(.roundedBorder)
                        .focused($focused).onSubmit { submit(n) }
                    Button("Join") { submit(n) }.buttonStyle(.mmPrimary).disabled(password.isEmpty)
                    Button("Cancel") { password = ""; wifi.passwordTargetID = nil }.buttonStyle(.mmGhost)
                }
                .onAppear { focused = true }
            }
        }
    }

    private func submit(_ n: WiFiNetwork) {
        guard !password.isEmpty else { return }
        let pw = password
        password = ""
        wifi.join(n, password: pw)
    }

    // MARK: Glyphs

    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func cellularBars(_ n: Int) -> some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < n ? Color.primary.opacity(0.75) : Color.primary.opacity(0.2))
                    .frame(width: 3, height: CGFloat(4) + CGFloat(i) * 2.5)
            }
        }
        .frame(height: 12)
    }
}
