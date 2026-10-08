import Foundation
import AppKit
import Darwin
import IOKit

struct ProcessSnapshot: Identifiable {
    let id: pid_t
    let name: String
    let cpu: Double
    let memoryMB: Double
    let icon: NSImage
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var usedMemoryGB: Double = 0
    @Published var totalMemoryGB: Double = 0
    @Published var freeStorageGB: Double = 0
    @Published var storageUsage: Double = 0
    @Published var gpuUsage: Double = 0
    @Published var gpuUsageText: String = "N/A"
    @Published var processes: [ProcessSnapshot] = []

    private var timer: Timer?
    private var lastProcessCPU: [pid_t: UInt64] = [:]
    private var lastTotalCPU: UInt64 = 0

    func start() {
        guard timer == nil else { return }
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    func refreshNow() {
        cpuUsage = readTotalCPU()
        readMemory()
        readStorage()
        readGPU()
        readProcesses()
    }

    func quit(_ process: ProcessSnapshot) {
        guard let app = NSRunningApplication(processIdentifier: process.id) else { return }
        if !app.terminate() {
            // Do not force-kill automatically; apps get a chance to save data.
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshNow()
        }
    }

    private func readTotalCPU() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(HOST_CPU_LOAD_INFO_COUNT)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return cpuUsage }

        let user = UInt64(load.cpu_ticks.0)
        let system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2)
        let nice = UInt64(load.cpu_ticks.3)
        let total = user + system + idle + nice
        let previousBusy = lastTotalCPU
        lastTotalCPU = total
        if previousBusy == 0 { return 0 }
        let deltaTotal = total - previousBusy
        let deltaIdle = idle - (previousBusy > 0 ? previousIdle : 0)
        lastIdle = idle
        guard deltaTotal > 0 else { return cpuUsage }
        return min(100, max(0, Double(deltaTotal - deltaIdle) / Double(deltaTotal) * 100))
    }

    private var lastIdle: UInt64 = 0

    private func readMemory() {
        var size = UInt64(0)
        var sizeLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &sizeLen, nil, 0)
        totalMemoryGB = Double(size) / 1_073_741_824

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let page = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count)
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        let used = (active + wired + compressed) * page
        usedMemoryGB = Double(used) / 1_073_741_824
    }

    private func readStorage() {
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            if let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage {
                let totalGB = Double(total) / 1_073_741_824
                freeStorageGB = Double(free) / 1_073_741_824
                storageUsage = totalGB > 0 ? 1 - freeStorageGB / totalGB : 0
            }
        } catch { }
    }

    private func readGPU() {
        // macOS does not expose a stable public GPU-utilization API. IOKit
        // PerformanceStatistics is used here when the driver provides it.
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            gpuUsageText = "N/A"
            return
        }
        defer { IOObjectRelease(iterator) }

        var found: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let dict = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            for key in ["Device Utilization %", "GPU Utilization", "GPU Utilization %"] {
                if let n = dict[key] as? NSNumber {
                    found = n.doubleValue
                    break
                }
            }
            if found != nil { break }
        }
        if let value = found {
            gpuUsage = min(max(value / 100, 0), 1)
            gpuUsageText = "\(Int(value))%"
        } else {
            gpuUsage = 0
            gpuUsageText = "N/A"
        }
    }

    private func readProcesses() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        var current: [pid_t: UInt64] = [:]
        var snapshots: [ProcessSnapshot] = []

        for app in apps {
            let pid = app.processIdentifier
            guard let usage = processCPUTime(pid: pid) else { continue }
            current[pid] = usage
            let previous = lastProcessCPU[pid] ?? usage
            let cpu = previous == usage ? 0 : min(100.0, Double(usage - previous) / 1_000_000.0 / 1.5 * 100.0)
            let memory = processMemoryMB(pid: pid)
            let icon = app.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
            snapshots.append(ProcessSnapshot(id: pid, name: app.localizedName ?? "Unknown", cpu: cpu, memoryMB: memory, icon: icon))
        }

        lastProcessCPU = current
        processes = snapshots.sorted { $0.cpu == $1.cpu ? $0.memoryMB > $1.memoryMB : $0.cpu > $1.cpu }
    }

    private func processCPUTime(pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let size = MemoryLayout<rusage_info_v4>.size
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: UInt8.self, capacity: size) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_user_time + info.ri_system_time
    }

    private func processMemoryMB(pid: pid_t) -> Double {
        var info = rusage_info_v4()
        let size = MemoryLayout<rusage_info_v4>.size
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: UInt8.self, capacity: size) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return 0 }
        return Double(info.ri_resident_size) / 1_048_576
    }
}
