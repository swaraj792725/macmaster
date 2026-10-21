import Foundation

/// One listening socket group: the same process + protocol + port, with every address it is bound to.
struct PortEntry: Identifiable, Hashable, Sendable {
    var pid: Int32
    var command: String
    var user: String
    var uid: UInt32
    var proto: String            // "TCP" or "UDP"
    var port: Int
    var addresses: [String]      // as lsof prints them: "*", "127.0.0.1", "[::1]"…

    var id: String { "\(pid)|\(proto)|\(port)" }

    /// Reachable from other machines: bound to every interface or to a non-loopback address.
    var isExposed: Bool { addresses.contains { !PortsParser.isLoopback($0) } }

    var addressSummary: String {
        if addresses.contains(where: { $0 == "*" || $0 == "[::]" || $0 == "0.0.0.0" }) { return "All interfaces" }
        if !isExposed { return "localhost" }
        return addresses.filter { !PortsParser.isLoopback($0) }.joined(separator: ", ")
    }
}

enum PortsParser {
    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "[::1]" || h == "::1" || h.hasPrefix("127.")
    }

    /// Splits an lsof name like `*:3000`, `127.0.0.1:5432`, `[::1]:8080` or `1.2.3.4:53->5.6.7.8:99`.
    /// Returns nil when there is no numeric port (for example UDP `*:*`).
    static func splitName(_ raw: String) -> (host: String, port: Int)? {
        var name = raw
        if let arrow = name.range(of: "->") { name = String(name[..<arrow.lowerBound]) }
        if let space = name.firstIndex(of: " ") { name = String(name[..<space]) }
        guard let colon = name.lastIndex(of: ":") else { return nil }
        let host = String(name[..<colon])
        guard let port = Int(name[name.index(after: colon)...]), port > 0, port < 65_536, !host.isEmpty else { return nil }
        return (host, port)
    }

    /// Parses `lsof -F` field output (`p` pid, `c` command, `u` uid, `L` login, `f` fd, `P` protocol, `n` name, `T` info).
    /// Lenient: unknown fields and malformed lines are skipped. TCP rows are only kept when their state is LISTEN
    /// (or unknown); UDP rows are kept when they have a bound port.
    static func parse(_ output: String, defaultProto: String = "TCP") -> [PortEntry] {
        var pid: Int32?
        var command = ""
        var uid: UInt32 = 0
        var user = ""
        var proto = defaultProto
        var pendingName: String?
        var state: String?
        var merged: [String: PortEntry] = [:]
        var order: [String] = []

        func flush() {
            defer { pendingName = nil; state = nil }
            guard let pid, let name = pendingName, !name.contains("->"),
                  let (host, port) = splitName(name) else { return }
            if proto == "TCP", let s = state, s != "LISTEN" { return }
            let key = "\(pid)|\(proto)|\(port)"
            if var e = merged[key] {
                if !e.addresses.contains(host) { e.addresses.append(host) }
                merged[key] = e
            } else {
                merged[key] = PortEntry(pid: pid, command: command, user: user, uid: uid, proto: proto, port: port, addresses: [host])
                order.append(key)
            }
        }

        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                flush()
                pid = Int32(value)
                command = ""; user = ""; uid = 0; proto = defaultProto
            case "c": command = value
            case "u": uid = UInt32(value) ?? 0
            case "L": user = value
            case "f":
                flush()
                proto = defaultProto
            case "P": proto = value.uppercased()
            case "n": pendingName = value
            case "T":
                if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        flush()
        return order.compactMap { merged[$0] }
    }

    /// Well-known development ports.
    static func label(forPort port: Int) -> String? {
        switch port {
        case 3000: "React / Node"
        case 3001: "Dev server"
        case 3306: "MySQL"
        case 4000: "Phoenix / Jekyll"
        case 4200: "Angular"
        case 4321: "Astro"
        case 5000: "Flask / AirPlay"
        case 5173, 5174: "Vite"
        case 5432: "PostgreSQL"
        case 5500: "Live Server"
        case 5672: "RabbitMQ"
        case 6006: "Storybook"
        case 6379: "Redis"
        case 7000: "AirPlay"
        case 8000: "Django / Python"
        case 8080: "HTTP alt"
        case 8081: "Metro"
        case 8443: "HTTPS alt"
        case 8888: "Jupyter"
        case 9000: "PHP-FPM / Dev"
        case 9200: "Elasticsearch"
        case 9229: "Node inspector"
        case 11211: "Memcached"
        case 27017: "MongoDB"
        case 19000, 19006: "Expo"
        default: nil
        }
    }

    /// Ports that most likely speak HTTP, for the "Open in browser" action.
    static func likelyHTTP(_ e: PortEntry) -> Bool {
        guard e.proto == "TCP" else { return false }
        let nonHTTP: Set<Int> = [22, 25, 53, 3306, 5432, 5672, 6379, 11211, 27017, 9229]
        return !nonHTTP.contains(e.port)
    }
}
