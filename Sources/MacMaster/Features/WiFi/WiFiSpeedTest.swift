import Foundation
import Observation

struct WiFiSpeedResult: Equatable, Sendable {
    var downBps: Double
    var upBps: Double
    var rpm: Double?
    var baseRTT: Double?
    var date: Date

    /// Apple's responsiveness bands (round trips per minute).
    var responsivenessWord: String? {
        guard let rpm else { return nil }
        switch rpm {
        case 1000...: return "Excellent"
        case 300...: return "Good"
        case 100...: return "Fair"
        default: return "Poor"
        }
    }
}

/// Wraps `/usr/bin/networkQuality -c`. Runs only when the user asks; one run at a time; cancellable.
@Observable
@MainActor
final class WiFiSpeedTest {
    enum State: Equatable {
        case idle
        case running(since: Date)
        case done(WiFiSpeedResult)
        case failed(String)
    }

    static let shared = WiFiSpeedTest()
    private(set) var state: State = .idle
    private(set) var last: WiFiSpeedResult?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var cancelled = false

    var isRunning: Bool { if case .running = state { true } else { false } }

    func start() {
        guard !isRunning else { return }
        let exe = "/usr/bin/networkQuality"
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            state = .failed("networkQuality needs macOS 12 or later.")
            return
        }
        cancelled = false
        state = .running(since: Date())

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-c", "-M", "30"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        process = p

        Task.detached(priority: .utility) { [weak self] in
            do { try p.run() } catch {
                await self?.finish(data: nil, status: -1, message: error.localizedDescription)
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()   // returns when the process exits
            p.waitUntilExit()
            await self?.finish(data: data, status: p.terminationStatus, message: nil)
        }
    }

    func cancel() {
        guard isRunning else { return }
        cancelled = true
        process?.terminate()
    }

    private func finish(data: Data?, status: Int32, message: String?) {
        process = nil
        if cancelled { state = last.map { .done($0) } ?? .idle; return }
        if let result = data.flatMap(Self.parse) {
            last = result
            state = .done(result)
        } else {
            state = .failed(message ?? (status == 0 ? "Couldn't read the speed test result." : "Speed test failed. Check your connection and try again."))
        }
    }

    nonisolated static func parse(_ data: Data) -> WiFiSpeedResult? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let down = (obj["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (obj["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        return WiFiSpeedResult(downBps: down, upBps: up,
                               rpm: (obj["responsiveness"] as? NSNumber)?.doubleValue,
                               baseRTT: (obj["base_rtt"] as? NSNumber)?.doubleValue,
                               date: Date())
    }
}
