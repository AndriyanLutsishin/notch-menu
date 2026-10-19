import AppKit
import Darwin
import IOKit.ps
import NotchCore

/// Температура, навантаження, пам'ять і батарея. Без дозволів і без root.
/// Температуру Apple Silicon читаємо тим самим способом, що й програми Stats / iStat
/// (системна служба HID-датчиків); якщо на цьому Mac її немає — просто показуємо «—».
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var temps = SensorSummary.Temps()
    @Published private(set) var cpuLoad: Double?
    @Published private(set) var memoryUsed: UInt64 = 0
    @Published private(set) var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var charging = false
    @Published private(set) var onAC = false
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var topMemory: [MemoryTop.Entry] = []
    /// Список «Найбільше пам'яті» рахуємо лише коли відкрито екран «Система».
    var wantsTopMemory = false

    private var timer: Timer?
    private var backgroundTimer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private let sensors = HIDTemperatureSensors()

    func start(interval: TimeInterval) {
        update()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Рідкісна перевірка у фоні (раз на 30 с), щоб вчасно показати попередження біля чубчика.
    func startBackground() {
        update()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.timer == nil else { return }
                self.update()
            }
        }
    }

    var warning: SystemWarning? {
        SystemWarning.evaluate(cpu: temps.cpu,
                               thermalSerious: thermalState == .serious || thermalState == .critical,
                               battery: batteryPercent, charging: charging || onAC)
    }

    func update() {
        let sensors = self.sensors
        Task.detached(priority: .utility) {
            let t = SensorSummary.summarize(sensors.read())
            await MainActor.run { self.temps = t }
        }
        if let ticks = Self.cpuTicks() {
            if let prev = lastTicks { cpuLoad = SensorSummary.cpuLoad(previous: prev, current: ticks) }
            lastTicks = ticks
        }
        memoryUsed = Self.memoryInUse()
        if wantsTopMemory {
            Task.detached(priority: .utility) {
                let top = MemoryTop.top()
                await MainActor.run { if top != self.topMemory { self.topMemory = top } }
            }
        }
        readBattery()
        thermalState = ProcessInfo.processInfo.thermalState
    }

    var thermalText: String {
        switch thermalState {
        case .nominal: return "Норма"
        case .fair: return "Трохи тепло"
        case .serious: return "Гаряче — Mac сповільнюється"
        case .critical: return "Критично гаряче"
        @unknown default: return "—"
        }
    }

    // MARK: Процесор і пам'ять (стандартні функції macOS)

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total)
    }

    private static func memoryInUse() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        // Як «Пам'ять у використанні» в Моніторі активності: програми + системна + стиснена.
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    // MARK: Батарея

    private func readBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                batteryPercent = Int((Double(cur) / Double(max) * 100).rounded())
            }
            charging = d[kIOPSIsChargingKey] as? Bool ?? false
            onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
    }
}

/// Датчики температури через системну службу HID (функції шукаємо під час роботи —
/// якщо їх немає, програма не впаде, а просто не покаже температуру).
final class HIDTemperatureSensors: @unchecked Sendable {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyPropertyFn = @convention(c) (UnsafeRawPointer, CFString) -> UnsafeMutableRawPointer?
    private typealias CopyEventFn = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private let lock = NSLock()
    private var client: UnsafeMutableRawPointer?
    private var copyServices: CopyServicesFn?
    private var copyProperty: CopyPropertyFn?
    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = dlsym(h, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let services = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let property = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let event = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let float = dlsym(h, "IOHIDEventGetFloatValue") else { return }
        let createFn = unsafeBitCast(create, to: CreateFn.self)
        guard let c = createFn(kCFAllocatorDefault) else { return }
        // Сторінка 0xff00, використання 5 — датчики температури.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = unsafeBitCast(setMatching, to: SetMatchingFn.self)(c, matching)
        client = c
        copyServices = unsafeBitCast(services, to: CopyServicesFn.self)
        copyProperty = unsafeBitCast(property, to: CopyPropertyFn.self)
        copyEvent = unsafeBitCast(event, to: CopyEventFn.self)
        getFloat = unsafeBitCast(float, to: GetFloatFn.self)
    }

    func read() -> [(name: String, celsius: Double)] {
        lock.lock(); defer { lock.unlock() }
        guard let client, let copyServices, let copyProperty, let copyEvent, let getFloat,
              let raw = copyServices(client) else { return [] }
        let services = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        let kTemperature: Int64 = 15
        let field = Int32(15 << 16)
        var out: [(String, Double)] = []
        for i in 0..<CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, i) else { continue }
            guard let namePtr = copyProperty(service, "Product" as CFString) else { continue }
            let name = Unmanaged<CFTypeRef>.fromOpaque(namePtr).takeRetainedValue() as? String ?? ""
            guard let ev = copyEvent(service, kTemperature, 0, 0) else { continue }
            let value = getFloat(ev, field)
            Unmanaged<CFTypeRef>.fromOpaque(ev).release()
            out.append((name, value))
        }
        return out
    }
}
