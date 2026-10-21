import Foundation

extension AppSearchIndex {
    /// Port Manager pages, added to the global search.
    static let portsEntries: [SearchEntry] = [
        SearchEntry(.tools, crumb: "Port Manager", "Kill process on a port", "port kill process stop listening localhost address in use force quit", tab: "ports"),
        SearchEntry(.tools, crumb: "Port Manager", "Ports exposed to network", "ports exposed network listening all interfaces firewall udp", tab: "ports"),
    ]
}
