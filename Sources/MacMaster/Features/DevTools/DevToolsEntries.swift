import Foundation

extension AppSearchIndex {
    /// Disk and dev extras that live outside the Toolbox: Cleaner projects and Uninstaller unused apps.
    static let devToolsEntries: [SearchEntry] = [
        SearchEntry(.cleaner, crumb: "Developer projects", "Clean project junk", "projects node_modules build target pods derived data venv cache developer clean old", anchor: "cleaner.projects", tab: "Projects"),
        SearchEntry(.cleaner, crumb: "Developer projects", "Xcode simulators", "xcode simulator unavailable runtimes devices simctl delete", anchor: "cleaner.simulators", tab: "Projects"),
        SearchEntry(.cleaner, crumb: "Developer projects", "Docker disk usage", "docker images containers volumes prune space", anchor: "cleaner.docker", tab: "Projects"),
        SearchEntry(.uninstaller, crumb: "Unused apps", "Find unused apps", "unused apps not opened days old reclaim space remove bulk", tab: "unused"),
    ]
}
