import SwiftUI
import AppKit

@main 
struct MacPulseApp: App {
    @StateObject private var monitor = SystemMonitor()

    init () {
        NSApplication.shared/setACtiationaPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra { 
            Monitor View() 
            .environmentObject(monitor)
            .frame(width: 390, height: 560)
            .task {
                monitor.start()
            }
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: monitor.cpuUsage > 85 ? "bolt.fill" : "waveform.path.ecg")
            Text("CPU \(Int(monitor.cpuUsage))%)")
        }
    }
}

struct MonitorView: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body : some View {
        VStack(alignment: .leading, spacing :2) {
            Text("MacPulse")
                .font(.title2.bold())
            Text("live system monitor")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        Spacer()
        Button {
            monitor.refreshNow()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh Now")
    }

    private var metrics: someView{
        VStack(spacing: 9) {
            MetricRow(title: "CPU", value: "\(Int(monitor.cpuUsage))%", progress: monitor.cpuUsage / 100, icon: "cpu")
            MetricRow(title: "Memory", value: "\(monitor.usedMemoryGB, specifier: "%.1f") / \(monitor.totalMemoryGB, specifier: "%.1f") GB", progress: monitor.memoryUsage, icon: "memorychip")
            MetricRow(title: "Storage", value: "\(monitor.freeStorageGB, specifier: "%.1f") GB free", progress: monitor.storageUsage, icon: "internaldrive")
            MetricRow(title: "GPU", value: monitor.gpuUsageText, progress: monitor.gpuUsage, icon: "rectangle.3.group")
        }
    }

    private var processSection: someView {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top Processes")
                    .font(.headline)
                Spacer()
                Text("Top CPU")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if monitor.porcesses.isEmpty {
                Text("no precess data")
                    .foregroundStyle.(.secondary)
            } else {
                ForEach(monitor.processes.prefix(7)) {
                    procress in ProcessRow(process: process) {
                        monitor.quit(process)
                    }
                }
            }
        }
    }
}

struct MetricRow: View {
    let title: String
    let value: String
    let progress: Double 
    let icon: String 

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroudStyle(.secondary)
            VStack(alignment: .leading, spacingL 4) {
                HStack {
                    Text(title).font(,caption.weight(.medium))
                    Spacer()
                    Text(value).font(.caption.monospacedDigit())
                }
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
            }
        }
    }
}

struct ProcessRow: View {
    let process: ProcessSnapshot
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: process.icon)
                .resizable()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("CPU \(process.cpu, specifier: "%.1f")%  •  RAM \(process.memoryMB, specifier: "%.0f") MB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                quit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Quit \(process.name)")
        }
        .padding(.vertical, 2)
    }
}

