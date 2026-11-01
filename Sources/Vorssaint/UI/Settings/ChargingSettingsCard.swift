// SPDX-License-Identifier: GPL-3.0-or-later
// Ported from BoDian by permission of its local project owner.
import SwiftUI
import ChargeShared
import ServiceManagement

struct ChargingSettingsCard: View {
    @ObservedObject private var model = ChargeModel.shared
    var body: some View {
        SettingsCard {
            Text(PortStrings.text("charging")).font(.headline)
            if !ChargeModel.isSupported {
                Text("macOS 27+ · MacBook")
            } else {
                LabeledContent("电量", value: model.percentage)
                LabeledContent("当前策略", value: model.policyText)
                LabeledContent("后台", value: model.serviceState)
                if model.daemon.status != .enabled || !ServiceClient.authorizationIsCurrent {
                    Button("授权并启用充电控制") { Task { await model.enable(); await model.refresh() } }
                }
                HStack {
                    Button(model.status?.intent == 1 ? "恢复充电" : "暂停充电") {
                        Task { _ = await model.run(model.status?.intent == 1 ? .resume : .pause) }
                    }
                    Button(model.status?.intent == 2 ? "取消充满" : "本次充满") {
                        Task { _ = await model.run(model.status?.intent == 2 ? .resume : .topUp) }
                    }
                }.disabled(!model.canControl)
                HStack {
                    Picker("充电上限", selection: $model.selectedLimit) {
                        Text("选择上限").tag(0)
                        ForEach(Array(stride(from: 50, through: 100, by: 5)), id: \.self) { Text("\($0)%").tag($0) }
                    }
                    Button("应用") { Task { _ = await model.run(.setLimit, limit: model.selectedLimit) } }
                        .disabled(model.selectedLimit == 0)
                }.disabled(!model.canControl)
                Toggle("接线时使用电池", isOn: Binding(get: { model.status?.intent == 3 }, set: { on in
                    Task { _ = await model.run(on ? .useBattery : .resume) }
                })).disabled(!model.canControl)
                Picker("使用电池自动结束电量", selection: Binding(get: { model.status?.batteryFloor ?? 20 }, set: { value in
                    Task { _ = await model.run(.setBatteryFloor, limit: value) }
                })) {
                    ForEach(Array(stride(from: 5, through: 30, by: 5)), id: \.self) { Text("\($0)%").tag($0) }
                }.disabled(!model.canControl)
                Button("恢复系统管理并停用后台") { Task { await model.disable() } }
                    .disabled(model.status == nil)
                Text(model.feedback).font(.caption).foregroundStyle(.secondary)
                Text("暂停充电不会主动放电，低至 20% 自动恢复。退出界面会保留后台策略；停用控制请使用上方按钮。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.error.isEmpty { Text(model.error).foregroundStyle(.orange).textSelection(.enabled) }
        }.disabled(model.busy)
         .task { await model.refresh() }
    }
}

struct BatteryHistoryCard: View {
    @ObservedObject private var monitor = EnergyMonitor.shared
    var body: some View {
        SettingsCard {
            Text(PortStrings.text("history")).font(.headline)
            LabeledContent("当前电池功率", value: monitor.powerText)
            Text(monitor.minuteText).monospacedDigit()
            Button("查看历史与导出 CSV") { EnergyHistoryWindow.shared.show() }
            Text("每 15 秒记录，保留 7 天；关闭窗口继续采集，退出应用或卸载此功能停止采集。")
                .font(.caption).foregroundStyle(.secondary)
            if !monitor.error.isEmpty { Text(monitor.error).foregroundStyle(.orange) }
        }
    }
}
