import AppKit
import CoreServices
import Foundation

/// Discovers installed apps and reads bundle metadata. All functions are synchronous and
/// must be called off the main thread.
enum UninstallerAppCatalog {
    static func roots() -> [(URL, String)] {
        [
            (URL(fileURLWithPath: "/Applications"), "Applications"),
            (URL(fileURLWithPath: "/Applications/Utilities"), "Utilities"),
            (UninstallerPaths.home.appendingPathComponent("Applications"), "~/Applications"),
            (URL(fileURLWithPath: "/Applications/Setapp"), "Setapp"),
        ]
    }

    /// Apple apps that come from the App Store / developer downloads and may be deleted normally.
    private static let removableApple: [String] = [
        "com.apple.dt.xcode", "com.apple.iwork.", "com.apple.garageband", "com.apple.imovieapp", "com.apple.logic",
        "com.apple.finalcutpro", "com.apple.motionapp", "com.apple.compressor", "com.apple.mainstage",
        "com.apple.configurator", "com.apple.dt.", "com.apple.remotedesktop", "com.apple.instruments",
    ]

    static func discover() -> [UninstallerApp] {
        var out: [UninstallerApp] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for (root, source) in roots() {
            guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                if Task.isCancelled { return out }
                if child.pathExtension.lowercased() == "app" {
                    if seen.insert(child.path).inserted, let app = makeApp(at: child, source: source) { out.append(app) }
                } else if UninstallerPaths.isDirectory(child) {
                    // One extra level: vendor folders such as /Applications/Adobe Photoshop 2025/
                    for sub in UninstallerPaths.children(child) where sub.pathExtension.lowercased() == "app" {
                        if seen.insert(sub.path).inserted, let app = makeApp(at: sub, source: source) { out.append(app) }
                    }
                }
            }
        }
        return out
    }

    static func infoPlist(of appURL: URL) -> [String: Any]? {
        let candidates = [
            appURL.appendingPathComponent("Contents/Info.plist"),
            appURL.appendingPathComponent("Info.plist"),
            appURL.appendingPathComponent("WrappedBundle/Info.plist"),
        ]
        for c in candidates { if let p = UninstallerPaths.readPlist(c) { return p } }
        // iPhone/iPad apps on Apple silicon: Wrapper/<Name>.app/Info.plist
        for sub in UninstallerPaths.children(appURL.appendingPathComponent("Wrapper")) where sub.pathExtension == "app" {
            if let p = UninstallerPaths.readPlist(sub.appendingPathComponent("Info.plist")) { return p }
        }
        return nil
    }

    static func makeApp(at url: URL, source: String) -> UninstallerApp? {
        guard let info = infoPlist(of: url) else { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        let bundleID = (info["CFBundleIdentifier"] as? String) ?? "unknown.\(UninstallerText.normalize(fileName))"
        let display = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fileName
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? ""
        let exec = (info["CFBundleExecutable"] as? String) ?? fileName
        var aliases = [display, fileName, exec]
        if let n = info["CFBundleName"] as? String { aliases.append(n) }
        var seen = Set<String>()
        aliases = aliases.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }

        let lowerID = bundleID.lowercased()
        let hasMASReceipt = UninstallerPaths.fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path)
        let path = url.path
        var isSystem = path.hasPrefix("/System/")
        if lowerID.hasPrefix("com.apple.") && !isSystem {
            let removable = hasMASReceipt || removableApple.contains { lowerID.hasPrefix($0) }
            isSystem = !removable
        }
        return UninstallerApp(url: url, name: display, bundleID: bundleID, version: version, executable: exec,
                              aliases: aliases, isSystem: isSystem, source: source,
                              size: nil, lastUsed: lastUsed(of: url))
    }

    static func lastUsed(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func bundleID(of bundleURL: URL) -> String? {
        let candidates = [bundleURL.appendingPathComponent("Contents/Info.plist"), bundleURL.appendingPathComponent("Info.plist")]
        for c in candidates { if let id = UninstallerPaths.readPlist(c)?["CFBundleIdentifier"] as? String { return id } }
        return nil
    }

    /// Team ID from the code signature (`TeamIdentifier=`).
    static func teamID(of appURL: URL) -> String? {
        let r = Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", appURL.path], timeout: 20)
        for line in (r.stderr + "\n" + r.stdout).split(whereSeparator: \.isNewline) where line.hasPrefix("TeamIdentifier=") {
            let v = String(line.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespaces)
            return (v.isEmpty || v == "not set") ? nil : v
        }
        return nil
    }

    /// Bundle ids of helpers/extensions/XPC services/login items embedded in the app (lowercased).
    static func embeddedIDs(of appURL: URL) -> Set<String> {
        var out = Set<String>()
        let contents = appURL.appendingPathComponent("Contents")
        let dirs = ["Library/LoginItems", "PlugIns", "Helpers", "XPCServices", "Library/LaunchServices",
                    "Library/LaunchDaemons", "Library/LaunchAgents", "Frameworks", "Library/SystemExtensions"]
        let bundleExts: Set<String> = ["app", "appex", "xpc", "systemextension"]
        for d in dirs {
            for child in UninstallerPaths.children(contents.appendingPathComponent(d)) {
                let ext = child.pathExtension.lowercased()
                if bundleExts.contains(ext) {
                    if d == "Frameworks" && ext != "app" { continue }
                    if let id = bundleID(of: child) { out.insert(id.lowercased()) }
                } else if d.hasPrefix("Library/Launch") || d == "Library/LaunchServices" {
                    let base = (ext == "plist" ? child.deletingPathExtension().lastPathComponent : child.lastPathComponent).lowercased()
                    if UninstallerText.looksLikeBundleID(base) { out.insert(base) }
                }
            }
        }
        return out
    }

    /// Bundle ids and names of every app Spotlight knows about (anywhere on disk, incl. external folders).
    static func spotlightApps() -> [(id: String, aliases: [String])] {
        let r = Shell.run("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"], timeout: 30)
        guard r.ok else { return [] }
        var out: [(String, [String])] = []
        var count = 0
        for line in r.stdout.split(separator: "\n") {
            if Task.isCancelled { break }
            let path = String(line)
            if path.contains("/Contents/") || path.contains("/CoreSimulator/") || path.hasPrefix("/System/")
                || path.contains("/.Trash/") || path.contains("/Wrapper/") { continue }
            let url = URL(fileURLWithPath: path)
            guard let info = UninstallerPaths.readPlist(url.appendingPathComponent("Contents/Info.plist")),
                  let id = info["CFBundleIdentifier"] as? String else { continue }
            var aliases = [url.deletingPathExtension().lastPathComponent]
            for k in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                if let v = info[k] as? String { aliases.append(v) }
            }
            out.append((id, aliases))
            count += 1
            if count > 4000 { break }
        }
        return out
    }
}
