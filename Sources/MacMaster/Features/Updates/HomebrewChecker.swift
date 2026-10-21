import Foundation

/// Runs a child process with a hard timeout, an explicit environment and no stdin. Blocking: call off main.
enum UpdateProcess {
    struct Output {
        var status: Int32
        var out: String
        var err: String
        var timedOut: Bool
        var ok: Bool { status == 0 && !timedOut }
        /// Output trimmed for display.
        var combined: String {
            let t = [out, err].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
            return t.count > 6000 ? "…" + String(t.suffix(6000)) : t
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var d = Data()
        func set(_ x: Data) { lock.lock(); d = x; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return d }
    }

    static func run(_ path: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return Output(status: -1, out: "", err: error.localizedDescription, timedOut: false) }
        let ob = Box(), eb = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { ob.set(o.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter()
        DispatchQueue.global().async { eb.set(e.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        let deadline = DispatchTime.now() + timeout
        var timedOut = group.wait(timeout: deadline) == .timedOut
        if !timedOut { timedOut = exited.wait(timeout: deadline) == .timedOut }
        if timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            _ = group.wait(timeout: .now() + 1)
        }
        return Output(status: p.isRunning ? -1 : p.terminationStatus,
                      out: String(decoding: ob.get(), as: UTF8.self),
                      err: String(decoding: eb.get(), as: UTF8.self), timedOut: timedOut)
    }

    static func runAsync(_ path: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval) async -> Output {
        await Task.detached(priority: .utility) { run(path, args, env: env, timeout: timeout) }.value
    }
}

enum HomebrewChecker {
    struct Result {
        var updates: [AppUpdate] = []
        /// Scanned app path -> cask token for every installed cask we could map.
        var tracked: [String: String] = [:]
        var formulae: [String] = []
        var error: String?
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Never let brew update itself in the background: only the explicit "Refresh Homebrew" button does.
    static let env: [String: String] = [
        "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_ANALYTICS": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1", "NONINTERACTIVE": "1",
        "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    ]

    struct CaskInfo {
        var token: String
        var names: [String]
        var appFiles: [String]
        var homepage: String?
    }

    static func check(apps: [InstalledApp]) async -> Result {
        guard let brew = brewPath else { return Result(error: "Homebrew isn't installed") }
        async let outdated = UpdateProcess.runAsync(brew, ["outdated", "--cask", "--greedy", "--json=v2"], env: env, timeout: 90)
        async let installed = UpdateProcess.runAsync(brew, ["info", "--cask", "--json=v2", "--installed"], env: env, timeout: 60)
        let (out, inst) = await (outdated, installed)
        guard out.ok else {
            return Result(error: out.timedOut ? "brew timed out" : "brew outdated failed: " + String(out.combined.suffix(300)))
        }
        guard let parsed = parseOutdated(out.out) else { return Result(error: "Couldn't read brew's output") }
        let infos = inst.ok ? parseInstalledInfo(inst.out) : [:]
        return map(outdated: parsed, infos: infos, apps: apps)
    }

    // MARK: Parsing

    struct OutdatedCask { var token: String; var installed: String; var current: String; var pinned: Bool }

    static func parseOutdated(_ json: String) -> (casks: [OutdatedCask], formulae: [String])? {
        // brew can print progress lines before the JSON.
        guard let start = json.firstIndex(of: "{"), let data = String(json[start...]).data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let casks = (root["casks"] as? [[String: Any]] ?? []).compactMap { c -> OutdatedCask? in
            guard let token = c["name"] as? String, let cur = c["current_version"] as? String else { return nil }
            let inst = (c["installed_versions"] as? [String])?.last ?? ""
            return OutdatedCask(token: token, installed: inst, current: cur, pinned: (c["pinned"] as? Bool) ?? false)
        }
        let formulae = (root["formulae"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return (casks, formulae)
    }

    static func parseInstalledInfo(_ json: String) -> [String: CaskInfo] {
        guard let start = json.firstIndex(of: "{"), let data = String(json[start...]).data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [:] }
        var out: [String: CaskInfo] = [:]
        for c in casks {
            guard let token = c["token"] as? String else { continue }
            var files: [String] = []
            for art in c["artifacts"] as? [[String: Any]] ?? [] {
                for item in art["app"] as? [Any] ?? [] {
                    if let s = item as? String { files.append(s) }
                    else if let d = item as? [String: Any], let t = d["target"] as? String { files.append(t) }
                }
                if art["app"] != nil, let t = art["target"] as? String { files.append(t) }
            }
            out[token] = CaskInfo(token: token, names: c["name"] as? [String] ?? [],
                                  appFiles: files.map { ($0 as NSString).lastPathComponent },
                                  homepage: c["homepage"] as? String)
        }
        return out
    }

    // MARK: Mapping

    static func map(outdated: (casks: [OutdatedCask], formulae: [String]), infos: [String: CaskInfo],
                    apps: [InstalledApp]) -> Result {
        var byFile: [String: InstalledApp] = [:]
        for a in apps { byFile[UpdateText.normalized(((a.path as NSString).lastPathComponent as NSString).deletingPathExtension)] = a }

        func app(for info: CaskInfo?, token: String) -> InstalledApp? {
            if let info {
                for f in info.appFiles {
                    if let a = byFile[UpdateText.normalized((f as NSString).deletingPathExtension)] { return a }
                }
                for n in info.names { if let a = byFile[UpdateText.normalized(n)] { return a } }
            }
            return byFile[UpdateText.normalized(token)]
        }

        var result = Result(formulae: outdated.formulae)
        for (token, info) in infos {
            if let a = app(for: info, token: token) { result.tracked[a.path] = token }
        }
        for c in outdated.casks where !c.pinned && c.current != "latest" {
            let info = infos[c.token]
            let matched = app(for: info, token: c.token)
            let newVersion = UpdateText.caskDisplayVersion(c.current)
            let installedShown = matched.map { $0.version.isEmpty ? $0.build : $0.version }
                ?? UpdateText.caskDisplayVersion(c.installed)
            if let m = matched {
                result.tracked[m.path] = c.token
                // The app may have updated itself behind brew's back (auto_updates casks).
                if !m.version.isEmpty, VersionCompare.compare(m.version, newVersion) >= 0 { continue }
                let parts = c.current.split(separator: ",").map(String.init)
                if parts.count > 1, !m.build.isEmpty, VersionCompare.compare(m.build, parts[1]) >= 0,
                   VersionCompare.compare(m.version, parts[0]) >= 0 { continue }
            } else if VersionCompare.compare(UpdateText.caskDisplayVersion(c.installed), newVersion) >= 0 {
                continue
            }
            result.updates.append(AppUpdate(
                id: matched?.id ?? "brew:" + c.token,
                key: matched?.key ?? "cask:" + c.token,
                name: matched?.name ?? info?.names.first ?? c.token,
                bundleID: matched?.bundleID ?? "",
                path: matched?.path,
                installedVersion: installedShown, newVersion: newVersion, source: .homebrew,
                notes: nil, notesURL: nil, downloadURL: nil, pageURL: info?.homepage,
                caskToken: c.token))
        }
        result.updates.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }
}
