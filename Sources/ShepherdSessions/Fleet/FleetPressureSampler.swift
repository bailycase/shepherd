import Darwin
import Foundation
import IOKit.ps
import ShepherdCore

/// The CPU's tick counters (`host_statistics`, HOST_CPU_LOAD_INFO), summed over every core.
struct FleetCPUTicks: Equatable, Sendable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64

    var total: UInt64 { user + system + idle + nice }
}

/// The VM page counts a sample needs (`host_statistics64`, HOST_VM_INFO64).
struct FleetMemoryPages: Equatable, Sendable {
    var free: UInt64
    var inactive: UInt64
    var speculative: UInt64
    var pageSize: UInt64
}

/// Where a sampler reads each fact. The defaults are the system's; tests give counters.
struct FleetPressureSources: Sendable {
    var cpuTicks: @Sendable () -> FleetCPUTicks?
    var memory: @Sendable () -> FleetMemoryPages?
    var totalMemoryBytes: @Sendable () -> UInt64
    var cpuCount: @Sendable () -> Int
    var thermal: @Sendable () -> FleetThermal
    /// On battery, and its charge.
    var power: @Sendable () -> (onBattery: Bool, percent: Int?)
    /// Waits between the two CPU readings.
    var pause: @Sendable (Duration) async -> Void
    /// The kernel's memory pressure level.
    var memoryPressure: @Sendable () -> FleetMemoryPressure = { .normal }

    static let system = FleetPressureSources(
        cpuTicks: FleetPressureSampler.systemCPUTicks,
        memory: FleetPressureSampler.systemMemory,
        totalMemoryBytes: { ProcessInfo.processInfo.physicalMemory },
        cpuCount: { ProcessInfo.processInfo.activeProcessorCount },
        thermal: {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: .nominal
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            @unknown default: .nominal
            }
        },
        power: FleetPressureSampler.systemPower,
        pause: { try? await Task.sleep(for: $0) },
        memoryPressure: FleetPressureSampler.systemMemoryPressure)
}

/// Takes `FleetPressureSample`s in process, with no subprocess: CPU from two tick readings 200 ms
/// apart, memory from the VM counters with t3's darwin formula (free + inactive + speculative
/// pages) and the kernel's pressure level, the thermal state and the power source. Agent counts come from the caller.
/// The 60 s CPU average is the host's (`FleetPressure`): a sampler keeps nothing between samples.
struct FleetPressureSampler: Sendable {
    /// The wait between the two CPU readings.
    static let window: Duration = .milliseconds(200)

    var sources: FleetPressureSources = .system

    func sample(activeAgents: Int, commandAgents: Int? = nil, reserved: Int = 0) async -> FleetPressureSample {
        let first = sources.cpuTicks()
        await sources.pause(Self.window)
        let second = sources.cpuTicks()
        let power = sources.power()
        let total = sources.totalMemoryBytes()
        return FleetPressureSample(
            cpuUtilization: first.flatMap { a in second.map { Self.cpuUtilization(from: a, to: $0) } } ?? 0,
            cpuCount: max(1, sources.cpuCount()),
            totalMemoryBytes: total,
            availableMemoryBytes: min(total, sources.memory().map(Self.availableBytes) ?? 0),
            thermal: sources.thermal(),
            onBattery: power.onBattery,
            batteryPercent: power.percent,
            activeAgents: max(0, activeAgents),
            reserved: max(0, reserved),
            commandAgents: commandAgents.map { min(max(0, activeAgents), max(0, $0)) },
            memoryPressure: sources.memoryPressure())
    }

    /// The share of ticks between two readings spent busy (user, system and nice), 0...1; 0 when
    /// no time passed or a counter went backwards.
    static func cpuUtilization(from a: FleetCPUTicks, to b: FleetCPUTicks) -> Double {
        guard b.total > a.total, b.idle >= a.idle, b.user >= a.user, b.system >= a.system, b.nice >= a.nice else { return 0 }
        let total = Double(b.total - a.total)
        let idle = Double(b.idle - a.idle)
        return min(1, max(0, (total - idle) / total))
    }

    /// Free, inactive and speculative pages in bytes.
    static func availableBytes(_ pages: FleetMemoryPages) -> UInt64 {
        (pages.free + pages.inactive + pages.speculative) * pages.pageSize
    }

    // MARK: The system's counters

    static func systemCPUTicks() -> FleetCPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        // The four counters are in the order CPU_STATE_USER, SYSTEM, IDLE, NICE.
        return FleetCPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                             idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    static func systemMemory() -> FleetMemoryPages? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        return FleetMemoryPages(free: UInt64(stats.free_count), inactive: UInt64(stats.inactive_count),
                                speculative: UInt64(stats.speculative_count), pageSize: UInt64(pageSize))
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical. A Mac that won't say is normal.
    static func systemMemoryPressure() -> FleetMemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return FleetMemoryPressure(kernelLevel: Int(level))
    }

    static func systemPower() -> (onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (false, nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var percent: Int?
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            percent = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
        }
        return (providing == kIOPSBatteryPowerValue, percent)
    }
}
