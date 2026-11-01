import SwiftUI
import Charts
import UniformTypeIdentifiers

extension EnergyMode {
    var title: String {
        switch self { case .discharge: return "放电"; case .charging: return "充电"
        case .holding: return "保持"; case .mixed: return "切换" }
    }
    var tint: Color {
        switch self { case .discharge: return Color(nsColor: .systemGreen)
        case .charging: return .blue; case .holding: return .secondary; case .mixed: return .orange }
    }
}
private struct EnergyBin: Identifiable {
    var id: Double { start }
    var start: Double
    var energy = 0.0
    var coverage = 0.0
}
private struct LevelPoint: Identifiable {
    var id: Double { time }
    var time: Double
    var level: Double
    var segment: Int
    var mode: EnergyMode
}
struct EnergyHistoryView: View {
    @ObservedObject var monitor = EnergyMonitor.shared
    @State private var hours = 1
    @State private var selectedDate: Date?
    @State private var exportError = ""
    private var now: Double { Date().timeIntervalSince1970 }
    private var rows: [EnergyMinute] { monitor.minutes.filter { $0.start >= now - Double(hours) * 3600 } }
    private var binSeconds: Double { hours == 1 ? 60 : hours == 24 ? 900 : 3600 }
    private var bins: [EnergyBin] {
        var values: [Double: EnergyBin] = [:]
        for row in rows {
            let start = floor(row.start / binSeconds) * binSeconds
            var bin = values[start] ?? EnergyBin(start: start)
            bin.energy += row.dischargeWh; bin.coverage += row.seconds
            values[start] = bin
        }
        return values.values.sorted { $0.start < $1.start }
    }
    private var levelPoints: [LevelPoint] {
        var segment = 0
        var previous: EnergyMinute?
        return rows.map { row in
            if let previous, row.start - previous.start > 60 || row.mode != previous.mode { segment += 1 }
            previous = row
            return LevelPoint(time: row.start, level: row.lastLevel, segment: segment, mode: row.mode)
        }
    }
    private var selectedBin: EnergyBin? {
        guard let selectedDate else { return nil }
        let target = selectedDate.timeIntervalSince1970
        return bins.first { target >= $0.start && target < $0.start + binSeconds }
    }
    private var coverage: Double { rows.reduce(0) { $0 + $1.seconds } }
    private var energy: Double { rows.reduce(0) { $0 + $1.dischargeWh } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("电池用量").font(.system(size: 21, weight: .semibold))
                    Text("分钟记录 · 本机保留 7 天").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { exportCSV() } label: { Label("导出 CSV", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(rows.isEmpty)
            }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 14)
            Picker("时间范围", selection: $hours) {
                Text("1 小时").tag(1); Text("24 小时").tag(24); Text("7 天").tag(168)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 250).padding(.bottom, 18)
                .onChange(of: hours) { _, _ in selectedDate = nil }
            HStack(alignment: .top, spacing: 0) {
                statistic("当前电池功率", value: monitor.powerText.replacingOccurrences(of: "电池功率 ", with: ""))
                statistic("记录内放出能量", value: String(format: "%.3f Wh", energy))
                statistic("有效监测时长", value: String(format: "%.1f 分钟", coverage / 60))
            }.padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if rows.isEmpty {
                        ContentUnavailableView("等待第一段记录", systemImage: "chart.xyaxis.line",
                            description: Text("打开Vorssaint后自动采集，约 15 秒产生第一段数据。"))
                            .frame(height: 220)
                    } else {
                        energyChart
                        levelChart
                        recentMinutes
                    }
                    if !monitor.error.isEmpty { Text(monitor.error).foregroundStyle(.orange) }
                    if !exportError.isEmpty { Text(exportError).foregroundStyle(.orange) }
                    Text("Wh 为电池端能量估算，非整机输入功率。睡眠、退出应用及无效数据留空；浅色柱表示该时段覆盖不足。关闭窗口继续记录，退出Vorssaint暂停。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(24)
            }
        }
        .frame(minWidth: 600, minHeight: 510).background(.background)
    }
    private func statistic(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 19, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var energyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("电池放出能量").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(hours == 1 ? "每分钟 · mWh" : hours == 24 ? "每 15 分钟 · mWh" : "每小时 · mWh")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(bins) { bin in
                    RectangleMark(xStart: .value("开始", Date(timeIntervalSince1970: bin.start + binSeconds * 0.06)),
                            xEnd: .value("结束", Date(timeIntervalSince1970: bin.start + binSeconds * 0.94)),
                            yStart: .value("零基线", 0.0), yEnd: .value("放出能量 mWh", bin.energy * 1000))
                        .foregroundStyle(Color(nsColor: .systemGreen).opacity(bin.coverage >= binSeconds * 0.75 ? 0.85 : 0.35))
                }
                if let selectedDate {
                    RuleMark(x: .value("选择时间", selectedDate)).foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .chartXScale(domain: Date(timeIntervalSince1970: now - Double(hours) * 3600)...Date(timeIntervalSince1970: now))
            .chartYScale(domain: 0...max(1, (bins.map { $0.energy * 1000 }.max() ?? 0) * 1.1))
            .chartXSelection(value: $selectedDate)
            .chartYAxisLabel("mWh")
            .frame(height: 150)
            Group {
                if let selectedBin {
                    Text("\(Date(timeIntervalSince1970: selectedBin.start).formatted(date: .omitted, time: .shortened)) · \(selectedBin.energy, specifier: "%.3f") Wh · 有效 \(selectedBin.coverage, specifier: "%.0f") 秒")
                } else { Text("点选图表查看能量及有效覆盖时长") }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private var levelChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("电量变化").font(.system(size: 12, weight: .semibold))
            Chart(levelPoints) { point in
                LineMark(x: .value("时间", Date(timeIntervalSince1970: point.time)), y: .value("电量", point.level),
                         series: .value("连续记录", point.segment))
                    .foregroundStyle(point.mode.tint).lineStyle(StrokeStyle(lineWidth: 1.5))
                PointMark(x: .value("时间", Date(timeIntervalSince1970: point.time)), y: .value("电量", point.level))
                    .foregroundStyle(point.mode.tint).symbolSize(5)
            }
            .chartXScale(domain: Date(timeIntervalSince1970: now - Double(hours) * 3600)...Date(timeIntervalSince1970: now))
            .chartYScale(domain: 0...100).chartYAxisLabel("%")
            .frame(height: 95)
            HStack(spacing: 12) {
                ForEach([EnergyMode.discharge, .charging, .holding, .mixed], id: \.self) { mode in
                    Label { Text(mode.title) } icon: { Circle().fill(mode.tint).frame(width: 5, height: 5) }
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private var recentMinutes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近分钟").font(.system(size: 12, weight: .semibold))
            Grid(horizontalSpacing: 22, verticalSpacing: 7) {
                GridRow { Text("时间"); Text("状态"); Text("放出能量"); Text("电量下降"); Text("覆盖") }
                    .foregroundStyle(.secondary)
                ForEach(Array(rows.suffix(8).reversed())) { row in
                    GridRow {
                        Text(Date(timeIntervalSince1970: row.start), format: .dateTime.hour().minute())
                        Text(row.mode.title).foregroundStyle(row.mode.tint)
                        Text(String(format: "%.3f Wh", row.dischargeWh))
                        Text(String(format: "%+.1f 个百分点", row.dropPoints))
                        Text(String(format: "%.0f / 60 秒", row.seconds))
                    }.monospacedDigit()
                }
            }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Vorssaint-电池用量.csv"
        let content = EnergyDatabase.csv(rows)
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do { try content.write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = "导出失败：\(error.localizedDescription)" }
        }
    }
}
@MainActor
final class EnergyHistoryWindow: NSWindowController {
    static let shared = EnergyHistoryWindow()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Vorssaint · 电池用量"
        window.identifier = NSUserInterfaceItemIdentifier("energy-history")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EnergyHistoryView())
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func show() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate() }
}
