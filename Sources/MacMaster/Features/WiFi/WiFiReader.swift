import Foundation
import CoreWLAN
import SystemConfiguration

/// Synchronous reads of Wi-Fi state. Call off the main thread.
enum WiFiReader {
    /// Current association (cheap: a handful of CoreWLAN property reads).
    static func readLink() -> WiFiLink {
        var l = WiFiLink()
        guard let i = CWWiFiClient.shared().interface() else { return l }
        l.hasInterface = true
        l.interfaceName = i.interfaceName
        l.powerOn = i.powerOn()
        l.mac = i.hardwareAddress()
        guard l.powerOn else { return l }
        l.rssi = i.rssiValue()
        l.noise = i.noiseMeasurement()
        l.ssid = clean(i.ssid())
        l.bssid = clean(i.bssid())
        l.country = i.countryCode()
        if let ch = i.wlanChannel() {
            l.channel = ch.channelNumber
            l.band = band(ch.channelBand.rawValue)
            l.widthMHz = width(ch.channelWidth.rawValue)
        }
        if l.rssi != 0 || l.channel != nil {
            l.txRate = i.transmitRate()
            l.phy = phyName(i.activePHYMode().rawValue)
            l.security = securityName(i.security().rawValue)
        }
        return l
    }

    /// Idle menu bar refresh: only power and signal (two XPC calls instead of ~14). Everything else
    /// (SSID, channel, security...) is kept from the last full read, which link events trigger.
    static func readSignal(base: WiFiLink) -> WiFiLink {
        guard let i = CWWiFiClient.shared().interface() else { return WiFiLink() }
        var l = base
        l.powerOn = i.powerOn()
        l.rssi = l.powerOn ? i.rssiValue() : 0
        return l
    }

    /// macOS returns nil (or a placeholder) for SSID/BSSID without Location access.
    private static func clean(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s != "<redacted>", s != "<hidden>" else { return nil }
        return s
    }

    static func band(_ raw: Int) -> WiFiBand? {
        switch raw {
        case 1: .ghz2
        case 2: .ghz5
        case 3: .ghz6
        default: nil
        }
    }

    static func width(_ raw: Int) -> Int? {
        switch raw {
        case 1: 20
        case 2: 40
        case 3: 80
        case 4: 160
        default: nil
        }
    }

    static func phyName(_ raw: Int) -> String? {
        switch raw {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "802.11n (Wi-Fi 4)"
        case 5: "802.11ac (Wi-Fi 5)"
        case 6: "802.11ax (Wi-Fi 6)"
        case 7: "802.11be (Wi-Fi 7)"
        default: nil
        }
    }

    static func securityName(_ raw: Int) -> String {
        switch raw {
        case 0: "Open"
        case 1: "WEP"
        case 2: "WPA Personal"
        case 3: "WPA/WPA2 Personal"
        case 4, 5: "WPA2 Personal"
        case 6: "Dynamic WEP"
        case 7: "WPA Enterprise"
        case 8: "WPA/WPA2 Enterprise"
        case 9, 10: "WPA2 Enterprise"
        case 11: "WPA3 Personal"
        case 12: "WPA3 Enterprise"
        case 13: "WPA2/WPA3 Personal"
        case 14: "Enhanced Open (OWE)"
        case 15: "Enhanced Open (transition)"
        default: "Unknown"
        }
    }

    // MARK: IP info

    /// Addresses of `interface` via getifaddrs, router + DNS via SystemConfiguration (no subprocess).
    static func readIPInfo(interface: String?) -> WiFiIPInfo {
        let name = interface ?? "en0"
        var info = WiFiIPInfo()
        var global6: [String] = [], local6: [String] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let ifa = p.pointee
                guard String(cString: ifa.ifa_name) == name, let addr = ifa.ifa_addr else { continue }
                let family = Int32(addr.pointee.sa_family)
                guard family == AF_INET || family == AF_INET6 else { continue }
                let text = numeric(addr)
                if family == AF_INET {
                    info.ipv4.append(text)
                    if let mask = ifa.ifa_netmask { info.subnetMask = numeric(mask) }
                } else if text.lowercased().hasPrefix("fe80") {
                    local6.append(text)
                } else {
                    global6.append(text)
                }
            }
            freeifaddrs(ifaddr)
        }
        info.ipv6 = global6.isEmpty ? local6 : global6

        if let store = SCDynamicStoreCreate(nil, "MacMaster.WiFi" as CFString, nil, nil) {
            let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []
            for key in keys {
                guard let d = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                      d["InterfaceName"] as? String == name else { continue }
                info.router = d["Router"] as? String
                if let mask = (d["SubnetMasks"] as? [String])?.first { info.subnetMask = mask }
                let dnsKey = key.replacingOccurrences(of: "/IPv4", with: "/DNS")
                if let dns = SCDynamicStoreCopyValue(store, dnsKey as CFString) as? [String: Any] {
                    info.dns = dns["ServerAddresses"] as? [String] ?? []
                }
                break
            }
            if info.dns.isEmpty,
               let g = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
                info.dns = g["ServerAddresses"] as? [String] ?? []
            }
        }
        return info
    }

    private static func numeric(_ addr: UnsafePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        let s = String(cString: host)
        return s.split(separator: "%").first.map(String.init) ?? s
    }
}
