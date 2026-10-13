import SwiftUI
import CoreWLAN

// MARK: - Settings

/// Menu bar icon looks the user can pick from.
enum WiFiIconStyle: String, CaseIterable, Identifiable {
    case classic, bars, colorful, dotName, speed, wifiSpeed, wifiDbm
    case pill, ring, band, ping, lock, activity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .bars: "Signal bars"
        case .colorful: "Colorful"
        case .dotName: "Dot + name"
        case .speed: "Speed"
        case .wifiSpeed: "Wi-Fi + speed"
        case .wifiDbm: "Wi-Fi + dBm"
        case .pill: "Name pill"
        case .ring: "Signal ring"
        case .band: "Band badge"
        case .ping: "Wi-Fi + ping"
        case .lock: "Secure arcs"
        case .activity: "Activity"
        }
    }

    var blurb: String {
        switch self {
        case .classic: "Wi-Fi arcs that fill with signal strength"
        case .bars: "Four rising bars, like a phone"
        case .colorful: "Arcs tinted green, yellow or red by quality"
        case .dotName: "Quality dot and network name"
        case .speed: "Upload and download rates"
        case .wifiSpeed: "Wi-Fi arcs with live rates"
        case .wifiDbm: "Wi-Fi arcs with signal in dBm"
        case .pill: "Solid pill with bars and network name"
        case .ring: "Ring that fills with signal strength"
        case .band: "Mono arcs with a 2.4G / 5G / 6G badge"
        case .ping: "Arcs with latency, checked every 30 s"
        case .lock: "Arcs with a padlock for secure or open networks"
        case .activity: "Arcs with live upload and download arrows"
        }
    }

    /// Monochrome styles are rendered as template images so macOS tints them for the menu bar.
    var isTemplate: Bool { ![.colorful, .dotName, .pill, .ring].contains(self) }
    /// Styles whose image changes with live throughput.
    var showsSpeed: Bool { self == .speed || self == .wifiSpeed || self == .activity }
    /// Styles that print the network name (so a name change must redraw).
    var showsName: Bool { self == .dotName || self == .pill }
}

enum WiFiSettings {
    static let enabledKey = "wifi.enabled"
    static let styleKey = "wifi.iconStyle"
    static let intervalKey = "wifi.interval"
    static let publicIPKey = "wifi.publicIP"

    static let intervals: [Double] = [2, 3, 5, 10]

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var style: WiFiIconStyle {
        WiFiIconStyle(rawValue: UserDefaults.standard.string(forKey: styleKey) ?? "") ?? .classic
    }
    /// Seconds between link reads while no Wi-Fi UI is on screen.
    static var interval: Double {
        let v = UserDefaults.standard.double(forKey: intervalKey)
        return v >= 2 ? min(v, 30) : 3
    }
    static var publicIPEnabled: Bool { UserDefaults.standard.object(forKey: publicIPKey) as? Bool ?? true }
}

// MARK: - Link

enum WiFiBand: String, Sendable {
    case ghz2 = "2.4 GHz", ghz5 = "5 GHz", ghz6 = "6 GHz"
}

/// Everything CoreWLAN reports about the current association. Cheap to read.
struct WiFiLink: Equatable, Sendable {
    var hasInterface = false
    var interfaceName: String?
    var powerOn = false
    var ssid: String?
    var bssid: String?
    var rssi = 0               // dBm, 0 = not associated
    var noise = 0              // dBm
    var txRate = 0.0           // Mbps
    var channel: Int?
    var band: WiFiBand?
    var widthMHz: Int?
    var phy: String?
    var security: String?
    var mac: String?
    var country: String?

    var isConnected: Bool { powerOn && (rssi != 0 || ssid != nil || channel != nil) }
    var snr: Int? { rssi != 0 && noise != 0 ? rssi - noise : nil }

    /// 0 unknown, 1 secured, 2 open (no password).
    var lockState: Int {
        guard isConnected, let security else { return 0 }
        return security == "Open" ? 2 : 1
    }
    /// Short band label for compact icons.
    var bandBadge: String {
        switch band {
        case .ghz2: "2.4G"
        case .ghz5: "5G"
        case .ghz6: "6G"
        case nil: ""
        }
    }

    /// 0…1 signal fraction (-90 dBm → 0, -40 dBm → 1).
    var signal: Double {
        guard isConnected, rssi != 0 else { return 0 }
        return max(0, min(1, Double(rssi + 90) / 50))
    }
    /// 0…4 bars.
    var bars: Int {
        guard isConnected, rssi != 0 else { return 0 }
        switch rssi {
        case (-55)...: return 4
        case (-65)...: return 3
        case (-75)...: return 2
        default: return 1
        }
    }
    var quality: String {
        guard isConnected, rssi != 0 else { return powerOn ? "Not connected" : "Wi-Fi off" }
        switch rssi {
        case (-50)...: return "Excellent"
        case (-60)...: return "Good"
        case (-70)...: return "Fair"
        default: return "Weak"
        }
    }
    var qualityColor: Color {
        guard isConnected, rssi != 0 else { return .gray }
        switch rssi {
        case (-60)...: return Color(hex: 0x30D158)
        case (-70)...: return Color(hex: 0xFF9F0A)
        default: return Color(hex: 0xFF453A)
        }
    }
    /// "5 GHz · Ch 36 · 80 MHz"
    var channelText: String {
        var parts: [String] = []
        if let band { parts.append(band.rawValue) }
        if let channel { parts.append("Ch \(channel)") }
        if let widthMHz { parts.append("\(widthMHz) MHz") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - IP info

struct WiFiIPInfo: Equatable, Sendable {
    var ipv4: [String] = []
    var ipv6: [String] = []
    var router: String?
    var dns: [String] = []
    var subnetMask: String?
}

enum WiFiRemote<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle, loading, value(Value), failed(String)
    var value: Value? { if case .value(let v) = self { v } else { nil } }
    var isLoading: Bool { if case .loading = self { true } else { false } }
}

struct WiFiPing: Equatable, Sendable {
    var host: String
    var avgMs: Double?
    var lossPercent: Double?
}

// MARK: - Scan results

/// How sure we are that a scanned network is a Personal Hotspot.
enum WiFiHotspotHint: Sendable { case none, flagged, guessed }

struct WiFiNetwork: Identifiable, @unchecked Sendable {
    /// Kept so `associate(to:)` can be called without rescanning.
    let cw: CWNetwork
    let ssid: String
    let bssid: String?
    let rssi: Int
    let channel: Int?
    let band: WiFiBand?
    let security: String
    let isOpen: Bool
    let isEnterprise: Bool
    let isCurrent: Bool
    /// Whether this looks like a phone's Personal Hotspot.
    var hotspot: WiFiHotspotHint = .none
    var id: String { ssid.isEmpty ? (bssid ?? UUID().uuidString) : ssid }
    var displayName: String { ssid.isEmpty ? "Hidden network" : ssid }
    var bars: Int {
        switch rssi {
        case (-55)...: 4
        case (-65)...: 3
        case (-75)...: 2
        default: 1
        }
    }
}

// MARK: - Formatting

enum WiFiFmt {
    /// Compact rate for the menu bar: "1.2M", "340K", "0".
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        switch v {
        case ..<1_000: return "0K"
        case ..<1_000_000: return String(format: "%.0fK", v / 1_000)
        case ..<10_000_000: return String(format: "%.1fM", v / 1_000_000)
        case ..<1_000_000_000: return String(format: "%.0fM", v / 1_000_000)
        default: return String(format: "%.1fG", v / 1_000_000_000)
        }
    }

    static func mbps(_ bitsPerSecond: Double) -> String {
        let m = bitsPerSecond / 1_000_000
        return m >= 100 ? String(format: "%.0f", m) : String(format: "%.1f", m)
    }

    static func ms(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v >= 100 ? String(format: "%.0f ms", v) : String(format: "%.1f ms", v)
    }

    static func dbm(_ v: Int) -> String { v == 0 ? "—" : "\(v) dBm" }
}
