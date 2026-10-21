import Foundation

extension AppSearchIndex {
    /// Disk Map pages, added to the global search.
    static let diskMapEntries: [SearchEntry] = [
        SearchEntry(.tools, crumb: "Disk Map", "Scan whole disk", "disk map scan whole disk volume treemap full disk access", tab: "diskMap"),
        SearchEntry(.tools, crumb: "Disk Map", "Biggest folders", "disk map biggest largest folders space usage reveal trash", tab: "diskMap"),
    ]
}
