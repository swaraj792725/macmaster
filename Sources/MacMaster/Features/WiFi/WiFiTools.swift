import Foundation
import CoreWLAN

enum WiFiJoinResult: Sendable {
    case joined
    case needsPassword
    case failed(String)
}

enum WiFiScanResult: Sendable {
    case networks([WiFiNetwork])
    case needsLocation
    case failed(String)
}

/// On-demand network tools. Every function blocks: call from a detached task, never the main thread.
enum WiFiTools {
    // MARK: Ping

    /// Average round trip over 3 packets via /sbin/ping.
    static func ping(_ host: String) -> WiFiPing {
        let r = Shell.run("/sbin/ping", ["-c", "3", "-t", "3", "-q", host], timeout: 8)
        var result = WiFiPing(host: host, avgMs: nil, lossPercent: nil)
        for line in r.stdout.split(separator: "\n") {
            if line.contains("packet loss"),
               let tok = line.split(separator: " ").first(where: { $0.hasSuffix("%") }) {
                result.lossPercent = Double(tok.dropLast())
            } else if line.contains("min/avg/max"), let eq = line.split(separator: "=").last {
                let nums = eq.trimmingCharacters(in: .whitespaces).split(separator: " ").first?.split(separator: "/")
                if let nums, nums.count >= 2 { result.avgMs = Double(nums[1]) }
            }
        }
        return result
    }

    /// One quick packet, for the menu bar latency readout. nil on loss or error.
    static func pingOnce(_ host: String) -> Double? {
        let r = Shell.run("/sbin/ping", ["-c", "1", "-t", "2", "-q", host], timeout: 4)
        for line in r.stdout.split(separator: "\n") where line.contains("min/avg/max") {
            if let eq = line.split(separator: "=").last,
               let nums = eq.trimmingCharacters(in: .whitespaces).split(separator: " ").first?.split(separator: "/"),
               nums.count >= 2 { return Double(nums[1]) }
        }
        return nil
    }

    // MARK: Connections

    /// Established TCP connections of this user's processes, via libproc (no subprocess;
    /// netstat prints nothing when launched from an app on recent macOS).
    static func establishedConnections() -> Int {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return 0 }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return 0 }
        var seen = Set<UInt64>()
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 8)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
            guard got > 0 else { continue }
            for fd in fds.prefix(Int(got) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
                guard r == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == Int32(SOCKINFO_TCP),
                      info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_ESTABLISHED else { continue }
                seen.insert(info.psi.soi_so)   // a socket shared by several processes counts once
            }
        }
        return seen.count
    }

    // MARK: Public IP

    static func publicIP() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 8
        cfg.httpCookieStorage = nil
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 45,
              text.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) else { return nil }
        return text
    }

    // MARK: Scan / join / power

    static func scan() -> WiFiScanResult {
        guard let i = CWWiFiClient.shared().interface() else { return .failed("No Wi-Fi interface") }
        guard i.powerOn() else { return .failed("Wi-Fi is off") }
        let found: Set<CWNetwork>
        do { found = try i.scanForNetworks(withName: nil) } catch {
            return .failed(error.localizedDescription)
        }
        let currentSSID = i.ssid(), currentBSSID = i.bssid()
        var best: [String: WiFiNetwork] = [:]
        for n in found {
            guard let ssid = n.ssid, !ssid.isEmpty else { continue }
            let (label, raw) = security(of: n)
            var net = WiFiNetwork(
                cw: n, ssid: ssid, bssid: n.bssid, rssi: n.rssiValue,
                channel: n.wlanChannel?.channelNumber,
                band: WiFiReader.band(n.wlanChannel?.channelBand.rawValue ?? 0),
                security: label, isOpen: raw == 0 || raw == 14 || raw == 15,
                isEnterprise: [7, 8, 9, 10, 12].contains(raw),
                isCurrent: ssid == currentSSID || (currentBSSID != nil && n.bssid == currentBSSID))
            net.hotspot = hotspotHint(for: n, ssid: ssid)
            if let old = best[ssid], old.rssi >= net.rssi, !(net.isCurrent && !old.isCurrent) { continue }
            best[ssid] = net
        }
        if best.isEmpty, !found.isEmpty { return .needsLocation }
        let sorted = best.values.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return $0.rssi > $1.rssi
        }
        return .networks(sorted)
    }

    /// Personal Hotspots: CoreWLAN's own flag when this macOS exposes it, else a name guess.
    static func hotspotHint(for n: CWNetwork, ssid: String) -> WiFiHotspotHint {
        if n.responds(to: NSSelectorFromString("isPersonalHotspot")),
           (n.value(forKey: "isPersonalHotspot") as? Bool) == true { return .flagged }
        let l = ssid.lowercased()
        if ["iphone", "ipad", "androidap", "galaxy", "pixel"].contains(where: { l.contains($0) }) { return .guessed }
        return .none
    }

    /// Strongest security mode the network advertises, as (label, CWSecurity raw value).
    private static func security(of n: CWNetwork) -> (String, Int) {
        let order: [(Int, String)] = [
            (13, "WPA2/WPA3 Personal"), (11, "WPA3 Personal"), (12, "WPA3 Enterprise"),
            (9, "WPA2 Enterprise"), (10, "WPA2 Enterprise"), (8, "WPA/WPA2 Enterprise"), (7, "WPA Enterprise"),
            (4, "WPA2 Personal"), (5, "WPA2 Personal"), (3, "WPA/WPA2 Personal"), (2, "WPA Personal"),
            (1, "WEP"), (14, "Enhanced Open"), (15, "Enhanced Open"), (0, "Open"),
        ]
        for (raw, label) in order {
            if let s = CWSecurity(rawValue: raw), n.supportsSecurity(s) { return (label, raw) }
        }
        return ("Secured", -1)
    }

    /// Joins `network`. With a nil password, secured networks may still succeed through the keychain.
    /// The password is passed straight to CoreWLAN and never stored by MacMaster.
    static func join(_ network: WiFiNetwork, password: String?) -> WiFiJoinResult {
        guard let i = CWWiFiClient.shared().interface() else { return .failed("No Wi-Fi interface") }
        do {
            try i.associate(to: network.cw, password: password)
            return .joined
        } catch {
            if password == nil, !network.isOpen { return .needsPassword }
            let ns = error as NSError
            return .failed(password == nil ? ns.localizedDescription : "Couldn't join. Check the password and try again.")
        }
    }

    static func setPower(_ on: Bool) -> String? {
        guard let i = CWWiFiClient.shared().interface() else { return "No Wi-Fi interface" }
        do { try i.setPower(on); return nil } catch { return error.localizedDescription }
    }
}
