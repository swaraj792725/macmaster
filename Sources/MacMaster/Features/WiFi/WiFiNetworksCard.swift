import SwiftUI

/// Nearby networks: scanned on demand, click to join. Passwords are typed here, handed to CoreWLAN and never stored.
struct WiFiNetworksCard: View {
    private let model = WiFiModel.shared
    var limit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Nearby networks", systemImage: "wifi.router").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.scanState == .scanning { ProgressView().controlSize(.small) }
                Button(model.scanState == .idle ? "Scan" : "Rescan") { model.scan() }
                    .buttonStyle(.mmSecondary)
                    .disabled(model.scanState == .scanning || !model.link.powerOn)
            }
            content
            if let e = model.joinError { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .card()
    }

    @ViewBuilder private var content: some View {
        switch model.scanState {
        case .idle:
            Text(model.link.powerOn ? "Scan to list networks around you." : "Turn Wi-Fi on to scan.")
                .font(.caption).foregroundStyle(.secondary)
        case .scanning where model.networks.isEmpty:
            Text("Scanning…").font(.caption).foregroundStyle(.secondary)
        case .needsLocation:
            HStack {
                Text("Allow Location to see network names.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Allow") { Permissions.request(.location) }.buttonStyle(.mmSecondary)
            }
        case .failed(let m):
            Text(m).font(.caption).foregroundStyle(.secondary)
        default:
            if model.networks.isEmpty {
                Text("No networks found.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.networks.prefix(limit)) { n in
                        WiFiNetworkRow(network: n)
                    }
                }
            }
        }
    }
}

private struct WiFiNetworkRow: View {
    let network: WiFiNetwork
    private let model = WiFiModel.shared
    @State private var password = ""
    @State private var hover = false
    @FocusState private var focused: Bool

    private var joining: Bool { model.joiningID == network.id }
    private var askingPassword: Bool { model.passwordTargetID == network.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard !network.isCurrent, model.joiningID == nil else { return }
                password = ""
                model.join(network, password: nil)
            } label: {
                HStack(spacing: 10) {
                    WiFiBarsView(bars: network.bars, ink: .primary, height: 13).frame(width: 22, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(network.displayName).font(.callout).lineLimit(1)
                        Text([network.band?.rawValue, network.channel.map { "Ch \($0)" }, network.security]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if joining {
                        ProgressView().controlSize(.small)
                    } else if network.isCurrent {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.blue)
                    } else if !network.isOpen {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("\(network.rssi)").font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(hover && !network.isCurrent ? Color.primary.opacity(0.06) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(network.isCurrent ? "Connected" : "Join \(network.displayName)")

            if askingPassword {
                HStack(spacing: 6) {
                    SecureField("Password for \(network.displayName)", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(submit)
                    Button("Join", action: submit).buttonStyle(.mmPrimary).disabled(password.isEmpty || joining)
                    Button("Cancel") { password = ""; model.passwordTargetID = nil }.buttonStyle(.mmGhost)
                }
                .padding(.horizontal, 8)
                .onAppear { focused = true }
            }
        }
        .onChange(of: model.passwordTargetID) { _, id in if id != network.id { password = "" } }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let pw = password
        password = ""
        model.join(network, password: pw)
    }
}
