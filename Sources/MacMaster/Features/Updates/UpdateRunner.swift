import Foundation

struct CheckOptions: Sendable {
    var includeBeta: Bool
    var osVersion: String
}

struct CheckOutcome: Sendable {
    var apps: [InstalledApp] = []
    var direct: [AppUpdate] = []
    var brew: [AppUpdate] = []
    var failures: [CheckFailure] = []
    var formulae: [String] = []
    var brewAvailable = false
    var brewError: String?
    /// Every network request failed with a connectivity error.
    var offline = false
}

/// Does one full check: scan, then Sparkle + App Store + Homebrew concurrently (bounded). Off-main.
enum UpdateRunner {
    static let maxConcurrent = 6

    private enum Unit: Sendable {
        case sparkle(InstalledApp)
        case appStore([InstalledApp])
    }

    private struct UnitResult: Sendable {
        var updates: [AppUpdate] = []
        var failures: [CheckFailure] = []
        var succeeded = 0
        var connectivityFailures = 0
        var size = 1
    }

    static func run(options: CheckOptions,
                    onScan: @escaping @Sendable ([InstalledApp]) -> Void,
                    progress: @escaping @Sendable (Int, Int) -> Void) async -> CheckOutcome {
        var outcome = CheckOutcome()
        var apps = await Task.detached(priority: .utility) { AppScanner.scan() }.value
        outcome.apps = apps
        onScan(apps)

        // Homebrew runs alongside the network checks.
        let hasBrew = HomebrewChecker.brewPath != nil
        outcome.brewAvailable = hasBrew
        let snapshot = apps
        let brewTask: Task<HomebrewChecker.Result, Never>? = hasBrew
            ? Task { await HomebrewChecker.check(apps: snapshot) } : nil

        var units: [Unit] = []
        var masApps: [InstalledApp] = []
        for a in apps {
            if a.hasReceipt { masApps.append(a) }
            else if a.feedURL != nil { units.append(.sparkle(a)) }
        }
        var start = 0
        while start < masApps.count {
            units.append(.appStore(Array(masApps[start..<min(start + AppStoreChecker.batchSize, masApps.count)])))
            start += AppStoreChecker.batchSize
        }
        let total = units.reduce(0) { n, u in
            switch u { case .sparkle: n + 1; case .appStore(let b): n + b.count }
        } + (hasBrew ? 1 : 0)
        progress(0, total)

        var done = 0
        var attempted = 0, succeeded = 0, connectivity = 0
        await withTaskGroup(of: UnitResult.self) { group in
            var iterator = units.makeIterator()
            func addNext() {
                guard let u = iterator.next() else { return }
                group.addTask { await process(u, options: options) }
            }
            for _ in 0..<maxConcurrent { addNext() }
            while let r = await group.next() {
                outcome.direct.append(contentsOf: r.updates)
                outcome.failures.append(contentsOf: r.failures)
                attempted += r.size
                succeeded += r.succeeded
                connectivity += r.connectivityFailures
                done += r.size
                progress(done, total)
                addNext()
            }
        }
        outcome.offline = attempted > 0 && succeeded == 0 && connectivity > 0

        if let brewTask {
            let b = await brewTask.value
            outcome.brew = b.updates
            outcome.formulae = b.formulae
            outcome.brewError = b.error
            done += 1
            progress(done, total)
            apps = assignTracking(apps, brewTracked: b.tracked)
        } else {
            apps = assignTracking(apps, brewTracked: [:])
        }
        outcome.apps = apps
        outcome.direct.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return outcome
    }

    private static func process(_ unit: Unit, options: CheckOptions) async -> UnitResult {
        switch unit {
        case .sparkle(let app):
            var r = UnitResult()
            do {
                let sparkleOptions = SparkleChecker.Options(includeBeta: options.includeBeta, osVersion: options.osVersion)
                let update = try await withTimeout(25) { try await SparkleChecker.check(app, options: sparkleOptions) }
                r.succeeded = 1
                if let update { r.updates.append(update) }
            } catch {
                r.failures.append(CheckFailure(appKey: app.key, name: app.name, source: .sparkle, message: describe(error)))
                if UpdateNet.isOffline(error) { r.connectivityFailures = 1 }
            }
            return r
        case .appStore(let batch):
            var r = UnitResult()
            r.size = batch.count
            do {
                let ids = batch.map(\.bundleID)
                let found = try await withTimeout(25) { try await AppStoreChecker.lookup(bundleIDs: ids) }
                r.succeeded = batch.count
                for app in batch {
                    if let entry = found[app.bundleID.lowercased()],
                       let u = AppStoreChecker.update(for: app, entry: entry, osVersion: options.osVersion) {
                        r.updates.append(u)
                    }
                }
            } catch {
                for app in batch {
                    r.failures.append(CheckFailure(appKey: app.key, name: app.name, source: .appStore, message: describe(error)))
                }
                if UpdateNet.isOffline(error) { r.connectivityFailures = batch.count }
            }
            return r
        }
    }

    /// App Store receipt beats Sparkle feed beats Homebrew cask.
    static func assignTracking(_ apps: [InstalledApp], brewTracked: [String: String]) -> [InstalledApp] {
        apps.map { a in
            var a = a
            a.caskToken = brewTracked[a.path]
            if a.hasReceipt { a.tracking = .appStore }
            else if a.feedURL != nil { a.tracking = .sparkle }
            else if a.caskToken != nil { a.tracking = .homebrew }
            else { a.tracking = nil }
            return a
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .timedOut: return "Timed out"
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "No internet connection"
            case .cannotFindHost, .dnsLookupFailed: return "Server not found"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .appTransportSecurityRequiresSecureConnection: return "Secure connection failed"
            default: return e.localizedDescription
            }
        }
        if error is CancellationError { return "Timed out" }
        return error.localizedDescription
    }

    /// Hard cap so one stuck request can't hold a slot.
    private static func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }
}
