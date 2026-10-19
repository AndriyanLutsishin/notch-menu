import Foundation

/// Зведення датчиків температури Apple Silicon у кілька зрозумілих чисел.
public enum SensorSummary {
    public struct Temps: Equatable, Sendable {
        public var cpu: Double?
        public var battery: Double?
        public var ssd: Double?
        public init(cpu: Double? = nil, battery: Double? = nil, ssd: Double? = nil) {
            self.cpu = cpu; self.battery = battery; self.ssd = ssd
        }
    }

    /// Назви датчиків: «PMU tdie3», «pACC MTR Temp Sensor2», «gas gauge battery», «NAND CH0 temp»…
    public static func summarize(_ readings: [(name: String, celsius: Double)]) -> Temps {
        let valid = readings.filter { $0.celsius > 0 && $0.celsius < 130 }
        func pick(_ match: (String) -> Bool) -> [Double] {
            valid.filter { match($0.name.lowercased()) }.map(\.celsius)
        }
        let cpu = pick { $0.contains("tdie") || $0.contains("pacc") || $0.contains("eacc") || $0.contains("cpu") }
        let battery = pick { $0.contains("battery") }
        let ssd = pick { $0.contains("nand") || $0.contains("ssd") }
        return Temps(cpu: cpu.max(), battery: battery.max(), ssd: ssd.max())
    }

    /// Простими словами: наскільки гарячий процесор.
    public static func feel(_ celsius: Double) -> String {
        switch celsius {
        case ..<50: return "прохолодно"
        case ..<70: return "нормально"
        case ..<85: return "тепло"
        case ..<95: return "гаряче"
        default: return "дуже гаряче"
        }
    }

    /// Відсоток навантаження процесора між двома замірами тактів (busy, total).
    public static func cpuLoad(previous: (busy: UInt64, total: UInt64), current: (busy: UInt64, total: UInt64)) -> Double? {
        guard current.total > previous.total, current.busy >= previous.busy else { return nil }
        let load = Double(current.busy - previous.busy) / Double(current.total - previous.total)
        return min(max(load, 0), 1)
    }
}
