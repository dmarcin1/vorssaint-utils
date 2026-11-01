import AppKit
import IOKit

// Read-only IORegistry access; independent of privileged charging control.
enum EnergyReader {
    static func read() -> EnergySample? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let value = properties?.takeRetainedValue() as? [String: Any],
              let current = value["Amperage"] as? NSNumber,
              let voltage = value["Voltage"] as? NSNumber,
              let level = value["CurrentCapacity"] as? NSNumber,
              let updated = value["UpdateTime"] as? NSNumber,
              let connected = value["ExternalConnected"] as? NSNumber else { return nil }
        let sample = EnergySample(time: Date().timeIntervalSince1970, uptime: ProcessInfo.processInfo.systemUptime,
            sensorTime: updated.doubleValue, level: level.intValue, milliamps: current.int64Value,
            millivolts: voltage.doubleValue, connected: connected.boolValue)
        return sample.valid ? sample : nil
    }
}
private actor EnergyRecorder {
    private var database: EnergyDatabase?
    private var accumulator = EnergyAccumulator()
    func read(_ sample: EnergySample?) throws -> [EnergyMinute] {
        if database == nil { database = try EnergyDatabase(url: EnergyDatabase.defaultURL) }
        if let sample {
            let rows = accumulator.ingest(sample)
            try database?.save(rows, now: sample.time)
        } else { accumulator.reset() }
        return try database?.read(since: Date().timeIntervalSince1970 - 7 * 86400) ?? []
    }
    func reset() { accumulator.reset() }
}
@MainActor
final class EnergyMonitor: ObservableObject {
    static let shared = EnergyMonitor()
    @Published private(set) var sample: EnergySample?
    @Published private(set) var minutes: [EnergyMinute] = []
    @Published private(set) var error = ""
    private let recorder = EnergyRecorder()
    private var samplingTask: Task<Void, Never>?
    private var started = false
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []
    func start() {
        guard !started else { return }; started = true
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = true; self?.sample = nil
                await self?.recorder.reset()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.recorder.reset(); self?.sleeping = false
            }
        })
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.sleeping {
                    let fresh = EnergyReader.read()
                    self.sample = fresh
                    do { self.minutes = try await self.recorder.read(fresh); self.error = "" }
                    catch { self.error = "历史记录未保存：\(error.localizedDescription)" }
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }
    func stop() {
        samplingTask?.cancel(); samplingTask = nil; started = false; sample = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        Task { await recorder.reset() }
    }
    func syncWithPreferences() {
        if AppFeature.batteryHistory.isAvailable { start() } else { stop() }
    }
    var powerText: String {
        guard let sample, sample.valid, Date().timeIntervalSince1970 - sample.sensorTime <= 90 else { return "电池功率 —" }
        if sample.watts > 0 { return String(format: "放电 %.1f W", sample.watts) }
        if sample.watts < 0 { return String(format: "充电 %.1f W", -sample.watts) }
        return "电池 0.0 W"
    }
    var lastMinute: EnergyMinute? {
        let start = floor(Date().timeIntervalSince1970 / 60) * 60 - 60
        return minutes.last { $0.start == start }
    }
    var minuteText: String {
        guard let row = lastMinute, row.seconds >= 45 else { return "上分钟 · 数据不足" }
        return String(format: "上分钟 %.3f Wh", row.dischargeWh)
    }
}
