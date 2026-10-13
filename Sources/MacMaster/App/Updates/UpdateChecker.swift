import AppKit
import Observation

/// Checks GitHub Releases for a newer MacMaster. No auto-install: the user is pointed at the release page/DMG.
@Observable
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let repo = "swaraj792725/macmaster"

    struct Release: Equatable {
        var version: String
        var name: String
        var notes: String
        var pageURL: URL
        var dmgURL: URL?
        var published: Date?
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), failed(String)
    }

    private enum Keys {
        static let auto = "mm.updates.autoCheck"
        static let last = "mm.updates.lastCheck"
        static let notified = "mm.updates.notifiedVersion"
        static let skipped = "mm.updates.skippedVersion"
    }

    private(set) var state: State = .idle
    var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Keys.auto); schedule() }
    }
    var lastCheck: Date? { UserDefaults.standard.object(forKey: Keys.last) as? Date }

    var available: Release? {
        if case .available(let r) = state { return r }
        return nil
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private var timer: Timer?

    private init() {
        let d = UserDefaults.standard
        autoCheck = d.object(forKey: Keys.auto) as? Bool ?? true
    }

    func start() {
        schedule()
        // First look shortly after launch, off the critical path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard autoCheck else { return }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateChecker.shared.checkIfDue() }
        }
        t.tolerance = 1800
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkIfDue() {
        guard autoCheck else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 23 * 3600 { return }
        Task { await check(userInitiated: false) }
    }

    /// `userInitiated` checks ignore "skip this version" and always report the result.
    func check(userInitiated: Bool) async {
        if state == .checking { return }
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Keys.last)
            if Self.compare(release.version, Self.currentVersion) == .orderedDescending {
                let skipped = UserDefaults.standard.string(forKey: Keys.skipped) == release.version
                state = (skipped && !userInitiated) ? .upToDate : .available(release)
                if !userInitiated, !skipped, UserDefaults.standard.string(forKey: Keys.notified) != release.version {
                    UserDefaults.standard.set(release.version, forKey: Keys.notified)
                    Notifier.post(title: "MacMaster \(release.version) is available",
                                  body: "Open MacMaster › Settings › Updates to download it.", id: "mm.update")
                }
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func skip(_ r: Release) {
        UserDefaults.standard.set(r.version, forKey: Keys.skipped)
        state = .upToDate
    }

    func download(_ r: Release) {
        NSWorkspace.shared.open(r.dmgURL ?? r.pageURL)
    }

    // MARK: GitHub

    private struct APIRelease: Decodable {
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
        var tag_name: String
        var name: String?
        var body: String?
        var html_url: URL
        var draft: Bool?
        var prerelease: Bool?
        var published_at: Date?
        var assets: [Asset]
    }

    private enum CheckError: LocalizedError {
        case noReleases, http(Int)
        var errorDescription: String? {
            switch self {
            case .noReleases: return "No releases have been published yet."
            case .http(let c): return "GitHub answered with HTTP \(c)."
            }
        }
    }

    private static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacMaster/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw CheckError.noReleases }
        guard code == 200 else { throw CheckError.http(code) }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(APIRelease.self, from: data)
        let version = r.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let dmg = r.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browser_download_url
        return Release(version: version, name: r.name ?? "MacMaster \(version)", notes: r.body ?? "",
                       pageURL: r.html_url, dmgURL: dmg, published: r.published_at)
    }

    /// Numeric dotted-version compare ("0.10.0" > "0.9.3"); anything after "-" is ignored.
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
