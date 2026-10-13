import Foundation

/// Sun position from UTC (NOAA-style low-precision formulas, good to about a tenth of a degree).
struct ClockSun {
    /// Latitude of the point directly under the sun, degrees (the solar declination).
    let lat: Double
    /// Longitude of the point directly under the sun, degrees (-180...180). Includes the equation of time.
    let lon: Double
    private let sinDec: Double, cosDec: Double

    init(date: Date) {
        let rad = Double.pi / 180
        let n = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0   // days since J2000
        let g = (357.529 + 0.98560028 * n) * rad                                  // mean anomaly
        let q = 280.459 + 0.98564736 * n                                          // mean longitude
        let l = (q + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad                   // ecliptic longitude
        let e = (23.439 - 0.00000036 * n) * rad                                   // obliquity
        let ra = atan2(cos(e) * sin(l), cos(l)) / rad
        let dec = asin(sin(e) * sin(l))
        let gmst = 280.46061837 + 360.98564736629 * n
        var lon = (ra - gmst).truncatingRemainder(dividingBy: 360)
        if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        self.lat = dec / rad
        self.lon = lon
        sinDec = sin(dec); cosDec = cos(dec)
    }

    /// Sine of the sun's altitude at a place (negative below the horizon).
    func sinAltitude(lat: Double, lon: Double) -> Double {
        let rad = Double.pi / 180
        let phi = lat * rad
        return sin(phi) * sinDec + cos(phi) * cosDec * cos((lon - self.lon) * rad)
    }

    /// Altitude in degrees.
    func altitude(lat: Double, lon: Double) -> Double {
        asin(max(-1, min(1, sinAltitude(lat: lat, lon: lon)))) * 180 / .pi
    }

    enum Phase: String {
        case day = "Day", twilight = "Twilight", night = "Night"
    }

    func phase(lat: Double, lon: Double) -> Phase {
        let a = altitude(lat: lat, lon: lon)
        return a > 0 ? .day : a > -6 ? .twilight : .night
    }
}

/// Where a time zone lives on the map. Uses the system's `zone.tab` (one principal city per zone),
/// with a small built-in fallback and, as a last resort, the longitude implied by the UTC offset.
enum ClockGeo {
    struct Point: Sendable {
        let lat: Double
        let lon: Double
        /// True when guessed from the UTC offset rather than a known city.
        var approximate = false
    }

    static func coordinate(for id: String, at date: Date = Date()) -> Point {
        let key = aliases[id] ?? id
        if let p = table[key] { return p }
        let secs = TimeZone(identifier: id)?.secondsFromGMT(for: date) ?? 0
        return Point(lat: 25, lon: max(-180, min(180, Double(secs) / 3600 * 15)), approximate: true)
    }

    private static let table: [String: Point] = {
        var out = fallback.mapValues { Point(lat: $0.0, lon: $0.1) }
        guard let text = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else { return out }
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3, let p = parseISO6709(String(cols[1])) else { continue }
            out[String(cols[2])] = p
        }
        return out
    }()

    /// "+513030-0000731" or "+2232+08822" -> latitude, longitude.
    static func parseISO6709(_ s: String) -> Point? {
        let chars = Array(s)
        guard chars.count > 6, let split = chars.indices.dropFirst().first(where: { chars[$0] == "+" || chars[$0] == "-" }) else { return nil }
        func part(_ c: ArraySlice<Character>, degrees: Int) -> Double? {
            guard let sign = c.first, sign == "+" || sign == "-" else { return nil }
            let d = Array(c.dropFirst())
            guard d.count >= degrees + 2, d.allSatisfy(\.isNumber),
                  let deg = Double(String(d[0..<degrees])), let min = Double(String(d[degrees..<degrees + 2])) else { return nil }
            let sec = d.count >= degrees + 4 ? Double(String(d[(degrees + 2)..<(degrees + 4)])) ?? 0 : 0
            return (sign == "-" ? -1 : 1) * (deg + min / 60 + sec / 3600)
        }
        guard let lat = part(chars[0..<split], degrees: 2), let lon = part(chars[split...], degrees: 3) else { return nil }
        return Point(lat: lat, lon: lon)
    }

    /// Link names that `zone.tab` does not list.
    private static let aliases: [String: String] = [
        "Asia/Calcutta": "Asia/Kolkata", "Asia/Saigon": "Asia/Ho_Chi_Minh", "Asia/Katmandu": "Asia/Kathmandu",
        "Asia/Rangoon": "Asia/Yangon", "Asia/Dacca": "Asia/Dhaka", "Europe/Kiev": "Europe/Kyiv",
        "America/Buenos_Aires": "America/Argentina/Buenos_Aires", "America/Indianapolis": "America/Indiana/Indianapolis",
        "US/Eastern": "America/New_York", "US/Central": "America/Chicago", "US/Mountain": "America/Denver",
        "US/Pacific": "America/Los_Angeles", "US/Alaska": "America/Anchorage", "US/Hawaii": "Pacific/Honolulu",
        "Australia/ACT": "Australia/Sydney", "Australia/NSW": "Australia/Sydney", "Australia/Victoria": "Australia/Melbourne",
        "GB": "Europe/London", "Japan": "Asia/Tokyo", "PRC": "Asia/Shanghai", "Singapore": "Asia/Singapore",
        "Hongkong": "Asia/Hong_Kong", "Israel": "Asia/Jerusalem", "Turkey": "Europe/Istanbul", "Egypt": "Africa/Cairo",
    ]

    /// Used only if `zone.tab` is unreadable.
    private static let fallback: [String: (Double, Double)] = [
        "America/New_York": (40.71, -74.01), "America/Chicago": (41.88, -87.63), "America/Denver": (39.74, -104.99),
        "America/Los_Angeles": (34.05, -118.24), "America/Toronto": (43.65, -79.38), "America/Mexico_City": (19.43, -99.13),
        "America/Sao_Paulo": (-23.55, -46.63), "Europe/London": (51.51, -0.13), "Europe/Paris": (48.86, 2.35),
        "Europe/Berlin": (52.52, 13.40), "Europe/Moscow": (55.76, 37.62), "Africa/Cairo": (30.04, 31.24),
        "Africa/Johannesburg": (-26.20, 28.05), "Asia/Dubai": (25.20, 55.27), "Asia/Kolkata": (22.57, 88.36),
        "Asia/Singapore": (1.35, 103.82), "Asia/Hong_Kong": (22.32, 114.17), "Asia/Shanghai": (31.23, 121.47),
        "Asia/Tokyo": (35.68, 139.69), "Australia/Sydney": (-33.87, 151.21), "Pacific/Auckland": (-36.85, 174.76),
        "Pacific/Honolulu": (21.31, -157.86),
    ]
}
