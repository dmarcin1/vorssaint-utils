import Foundation

public enum EnergyMode: String, Codable, Sendable {
    case discharge, charging, holding, mixed
}
public struct EnergySample: Codable, Sendable {
    public var time: Double
    public var uptime: Double
    public var sensorTime: Double
    public var level: Int
    public var milliamps: Int64
    public var millivolts: Double
    public var connected: Bool
    public init(time: Double, uptime: Double, sensorTime: Double, level: Int,
                milliamps: Int64, millivolts: Double, connected: Bool) {
        self.time = time; self.uptime = uptime; self.sensorTime = sensorTime; self.level = level
        self.milliamps = milliamps; self.millivolts = millivolts; self.connected = connected
    }
    // Positive = battery supplies energy. Adapter connection does not determine the sign.
    public var watts: Double { -Double(milliamps) * millivolts / 1_000_000 }
    public var mode: EnergyMode { milliamps < 0 ? .discharge : milliamps > 0 ? .charging : .holding }
    public var valid: Bool {
        time.isFinite && uptime.isFinite && sensorTime.isFinite && (0...100).contains(level) &&
        millivolts.isFinite && (5_000...30_000).contains(millivolts) &&
        (-30_000...30_000).contains(milliamps) && time - sensorTime >= -5 && time - sensorTime <= 90
    }
}
public struct EnergyMinute: Codable, Identifiable, Sendable, Equatable {
    public var id: Double { start }
    public var start: Double
    public var seconds: Double
    public var dischargeWh: Double
    public var chargeWh: Double
    public var firstLevel: Double
    public var lastLevel: Double
    public var mode: EnergyMode
    public var sensorUpdates: Int
    public var averageDischargeWatts: Double { seconds > 0 ? dischargeWh * 3600 / seconds : 0 }
    public var dropPoints: Double { firstLevel - lastLevel }
    public init(start: Double, seconds: Double, dischargeWh: Double, chargeWh: Double,
                firstLevel: Double, lastLevel: Double, mode: EnergyMode, sensorUpdates: Int) {
        self.start = start; self.seconds = seconds; self.dischargeWh = dischargeWh; self.chargeWh = chargeWh
        self.firstLevel = firstLevel; self.lastLevel = lastLevel; self.mode = mode; self.sensorUpdates = sensorUpdates
    }
}

public struct EnergyAccumulator: Sendable {
    private var previous: EnergySample?
    public init() {}
    public mutating func reset() { previous = nil }
    public mutating func ingest(_ sample: EnergySample) -> [EnergyMinute] {
        guard sample.valid else { reset(); return [] }
        defer { previous = sample }
        guard let old = previous else { return [] }
        let duration = sample.time - old.time
        guard duration > 0, duration <= 45,
              abs(duration - (sample.uptime - old.uptime)) < 2,
              sample.sensorTime >= old.sensorTime else { return [] }
        // Do not interpolate through plugging/unplugging or a charge-flow reversal.
        guard old.connected == sample.connected, old.mode == sample.mode else { return [] }
        var position = old.time
        var changed: [EnergyMinute] = []
        while position < sample.time {
            let start = floor(position / 60) * 60
            let end = min(start + 60, sample.time)
            let left = (position - old.time) / duration
            let right = (end - old.time) / duration
            let wattsLeft = old.watts + (sample.watts - old.watts) * left
            let wattsRight = old.watts + (sample.watts - old.watts) * right
            let wh = (wattsLeft + wattsRight) / 2 * (end - position) / 3600
            let levelLeft = Double(old.level) + Double(sample.level - old.level) * left
            let levelRight = Double(old.level) + Double(sample.level - old.level) * right
            let row = EnergyMinute(start: start, seconds: end - position,
                dischargeWh: max(0, wh), chargeWh: max(0, -wh), firstLevel: levelLeft,
                lastLevel: levelRight, mode: sample.mode,
                sensorUpdates: sample.sensorTime != old.sensorTime ? 1 : 0)
            changed.append(row)
            position = end
        }
        return changed
    }
}
