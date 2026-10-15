import AppKit
import Observation

/// One point in the rolling metrics history.
struct MetricPoint: Identifiable {
    let date: Date
    let cpu: Double
    let memory: Double
    let gpu: Double
    let netDown: Double
    let netUp: Double
    let diskRead: Double
    let diskWrite: Double
    let cpuTemp: Double?
    var id: Date { date }
}

/// Shared live system metrics. Single sampler for the whole app — features read
/// from here instead of polling hardware themselves.
@Observable
@MainActor
final class SystemMonitor {
    static let shared = SystemMonitor()

    private(set) var cpu = CPUReading(total: 0, user: 0, system: 0, perCore: [], loadAverage: (0, 0, 0))
    private(set) var memory = MemoryReader.read()
    private(set) var disk = DiskReading(total: 0, available: 0, readRate: 0, writeRate: 0)
    private(set) var network = NetworkReading(downRate: 0, upRate: 0, totalDown: 0, totalUp: 0)
    private(set) var gpu: Double = 0
    private(set) var thermal = ThermalReading(sensors: [], state: .nominal)
    private(set) var processes: [ProcessSample] = []
    private(set) var history: [MetricPoint] = []
    private(set) var lastUpdate = Date()

    /// Seconds between samples.
    var interval: TimeInterval = 2 { didSet { restart() } }
    /// History length in samples (default 5 min at 2s).
    var historyLimit = 150
    /// Process sampling costs more; consumers opt in by incrementing.
    private var processDemand = 0

    @ObservationIgnored private let cpuReader = CPUReader()
    @ObservationIgnored private let diskReader = DiskReader()
    @ObservationIgnored private let netReader = NetworkReader()
    @ObservationIgnored private let procReader = ProcessReader()
    @ObservationIgnored private let queue = DispatchQueue(label: "macmaster.monitor", qos: .utility)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    /// A read still running (slow sensor, stalled sysctl): skip ticks instead of queueing more behind it.
    @ObservationIgnored private var sampling = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        sample()
        restart()
    }

    private func restart() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Call from `onAppear` / services needing per-process data; balance with `releaseProcesses()`.
    /// `background` holders (health, auto-optimize) only need a sample every ~10 s; on-screen views get every tick.
    func requestProcesses(background: Bool = false) {
        if background { backgroundProcessDemand += 1 } else { processDemand += 1 }
    }
    func releaseProcesses(background: Bool = false) {
        if background { backgroundProcessDemand = max(0, backgroundProcessDemand - 1) }
        else { processDemand = max(0, processDemand - 1) }
    }
    private var backgroundProcessDemand = 0

    private func sample() {
        guard !sampling else { return }
        sampling = true
        tick += 1
        let wantProcs = processDemand > 0 || (backgroundProcessDemand > 0 && tick % 5 == 0)
        // Sensors are the most expensive read: every other tick while a window is up, every ~30 s otherwise.
        let wantThermal = tick % (Self.windowVisible ? 2 : 15) == 1
        queue.async { [cpuReader, diskReader, netReader, procReader] in
            let c = cpuReader.read()
            let m = MemoryReader.read()
            let d = diskReader.read()
            let n = netReader.read()
            let g = GPUReader.utilization() ?? 0
            let th = wantThermal ? ThermalReader.shared.read() : nil
            let p = wantProcs ? procReader.read() : nil
            DispatchQueue.main.async {
                self.sampling = false
                self.apply(cpu: c, mem: m, disk: d, net: n, gpu: g, thermal: th, procs: p)
            }
        }
    }

    private func apply(cpu c: CPUReading, mem: MemoryReading, disk d: DiskReading, net n: NetworkReading,
                       gpu g: Double, thermal th: ThermalReading?, procs: [ProcessSample]?) {
        cpu = c; memory = mem; disk = d; network = n; gpu = g
        if let th { thermal = th }
        if let procs { processes = procs }
        lastUpdate = Date()
        history.append(MetricPoint(date: lastUpdate, cpu: c.total, memory: mem.usedFraction, gpu: g,
                                   netDown: n.downRate, netUp: n.upRate, diskRead: d.readRate,
                                   diskWrite: d.writeRate, cpuTemp: thermal.cpu))
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    /// Any sizeable on-screen window of ours (main window, settings). Menu bar items alone don't count.
    static var windowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && $0.frame.width > 400 }
    }

    var topCPU: [ProcessSample] { Array(processes.sorted { $0.cpu > $1.cpu }.prefix(8)) }
    var topMemory: [ProcessSample] { Array(processes.sorted { $0.memory > $1.memory }.prefix(8)) }
}

/// Battery history point, persisted.
struct BatteryPoint: Codable, Identifiable, Sendable {
    let date: Date
    let percent: Double
    let isCharging: Bool
    let watts: Double
    let temperature: Double?
    var id: Date { date }
}

@Observable
@MainActor
final class BatteryMonitor {
    private nonisolated static let saveQueue = DispatchQueue(label: "macmaster.battery.save", qos: .utility)
    static let shared = BatteryMonitor()

    private(set) var reading = BatteryReader.read()
    /// Up to 7 days at 1-minute resolution.
    private(set) var history: [BatteryPoint] = Store.load([BatteryPoint].self, from: "battery-history.json") ?? []
    @ObservationIgnored private var fastTimer: Timer?
    @ObservationIgnored private var historyTimer: Timer?

    private init() {}

    func start() {
        guard fastTimer == nil else { return }
        refresh()
        fastTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // The charge limit explains "plugged in, not charging", so read it up front and keep it current
        // (it can also change in System Settings).
        historyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.record()
                await BatteryChargeLimiter.shared.refresh()
            }
        }
        record()
        Task { await BatteryChargeLimiter.shared.refresh() }
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let r = BatteryReader.read()
            await MainActor.run { self.reading = r }
        }
    }

    private func record() {
        guard reading.isPresent else { return }
        history.append(BatteryPoint(date: Date(), percent: reading.percent, isCharging: reading.isCharging,
                                    watts: reading.batteryPowerWatts, temperature: reading.temperature))
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        history.removeAll { $0.date < cutoff }
        // Encoding a week of points and writing it is file IO: keep it off the main thread (serial, so writes stay in order).
        let snapshot = history
        Self.saveQueue.async { Store.save(snapshot, to: "battery-history.json") }
    }
}
