import SwiftUI
import CoreWLAN
import Observation

// MARK: - Wi-Fi

struct StatsWiFiInfo: Equatable, Sendable {
    var interface: String
    var ssid: String?
    var rssi: Int
    var noise: Int
    var txRate: Double
    var channel: Int?
    var band: String?
    var security: String
    var poweredOn: Bool

    var snr: Int { rssi - noise }
    /// 0…1 signal quality from RSSI (-90 … -30 dBm).
    var quality: Double { min(1, max(0, (Double(rssi) + 90) / 60)) }
}

enum StatsWiFiReader {
    static func read() -> StatsWiFiInfo? {
        guard let i = CWWiFiClient.shared().interface() else { return nil }
        guard i.powerOn() else {
            return StatsWiFiInfo(interface: i.interfaceName ?? "Wi-Fi", ssid: nil, rssi: 0, noise: 0, txRate: 0,
                                 channel: nil, band: nil, security: "—", poweredOn: false)
        }
        let band: String? = {
            switch i.wlanChannel()?.channelBand {
            case .band2GHz?: return "2.4 GHz"
            case .band5GHz?: return "5 GHz"
            case .band6GHz?: return "6 GHz"
            default: return nil
            }
        }()
        return StatsWiFiInfo(interface: i.interfaceName ?? "Wi-Fi", ssid: i.ssid(), rssi: i.rssiValue(),
                             noise: i.noiseMeasurement(), txRate: i.transmitRate(),
                             channel: i.wlanChannel()?.channelNumber, band: band,
                             security: securityName(i.security()), poweredOn: true)
    }

    private static func securityName(_ s: CWSecurity) -> String {
        switch s {
        case .none: return "Open"
        case .WEP, .dynamicWEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA Personal"
        case .wpa2Personal, .personal: return "WPA2 Personal"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Transition: return "WPA3 Transition"
        case .wpaEnterprise, .wpaEnterpriseMixed: return "WPA Enterprise"
        case .wpa2Enterprise, .enterprise: return "WPA2 Enterprise"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .OWE, .oweTransition: return "Enhanced Open"
        default: return "Unknown"
        }
    }
}

// MARK: - Public IP (on demand only)

@Observable
@MainActor
final class StatsPublicIPModel {
    enum State: Equatable { case idle, loading, value(String), failed(String) }
    private(set) var state: State = .idle

    func fetch() {
        guard state != .loading else { return }
        state = .loading
        Task {
            do {
                var req = URLRequest(url: URL(string: "https://api.ipify.org")!)
                req.timeoutInterval = 8
                let (data, _) = try await URLSession.shared.data(for: req)
                let ip = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                state = ip.isEmpty ? .failed("Empty response") : .value(ip)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Volumes

struct StatsVolume: Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    let total: Int64
    let available: Int64
    let isInternal: Bool
    var id: String { path }
    var used: Int64 { max(0, total - available) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum StatsVolumeLoader {
    static func load() -> [StatsVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
                                      .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let avail = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return StatsVolume(path: url.path, name: v.volumeName ?? url.lastPathComponent,
                               total: Int64(total), available: avail, isInternal: v.volumeIsInternal ?? false)
        }
    }
}
