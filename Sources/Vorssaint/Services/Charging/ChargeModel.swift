import SwiftUI
import ServiceManagement
import ChargeShared

@MainActor
final class ChargeModel: ObservableObject {
    static let shared = ChargeModel()
    @Published var status: ChargeStatus?
    @Published var observedBattery: BatteryStatus?
    @Published var error = ""
    @Published var busy = false
    @Published var serviceState = "尚未启用"
    @Published var selectedLimit = 0
    let daemon = SMAppService.daemon(plistName: "com.vorssaint.utils.charge.plist")
    private var refreshTask: Task<Void, Never>?
    func syncWithPreferences() {
        refreshTask?.cancel(); refreshTask = nil
        guard AppFeature.chargingControl.isAvailable, Self.isSupported else {
            if daemon.status == .enabled || daemon.status == .requiresApproval {
                Task {
                    await disable()
                    if daemon.status == .enabled || daemon.status == .requiresApproval {
                        FeatureRuntime.shared.setAvailable([.chargingControl], true, enablingFirstInstalls: false)
                    }
                }
            }
            return
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
    nonisolated static var isSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            && PowerSampler.hasInternalBattery
    }
    var canControl: Bool { status != nil && error.isEmpty && status?.verification != "failed" }
    var percentage: String { (status?.battery ?? observedBattery)?.level.map { "\($0)%" } ?? "—" }
    var policyText: String {
        guard let status else { return "由 macOS 管理" }
        if status.intent == 1 { return "手动暂停 · 低电量时自动恢复" }
        if status.intent == 3 { return "使用电池 · \(status.batteryFloor)% 时自动结束" }
        if status.intent == 2 { return status.topUpComplete ? "已充满 · 拔线后恢复原策略" : "本次充到 100%" }
        return status.baseLimit == 0 ? "由 macOS 管理" : "充电上限 \(status.baseLimit)%"
    }
    var feedback: String {
        guard let status else { return "首次使用请在设置中启用后台控制。" }
        if !status.error.isEmpty { return status.error }
        switch status.verification {
        case "applying": return "正在应用，电池状态可能需要约一分钟更新。"
        case "unknown": return "策略已提交，但电池状态尚无法确认。"
        case "failed": return "控制已停止，请恢复系统管理。"
        default: return status.notice
        }
    }
    func updateServiceState() {
        switch daemon.status {
        case .enabled: serviceState = "已启用"
        case .requiresApproval: serviceState = "等待系统批准"
        case .notRegistered: serviceState = "尚未启用"
        case .notFound: serviceState = "服务文件未找到"
        @unknown default: serviceState = "状态未知"
        }
    }
    func refresh() async {
        guard !busy else { return }
        updateServiceState()
        observedBattery = BatteryStatus.readPublicStatus()
        guard daemon.status == .enabled else { status = nil; error = ""; return }
        do {
            let value = try await ServiceClient.request(.status)
            let previousBase = status?.baseLimit
            status = value; error = ""
            if previousBase != value.baseLimit { selectedLimit = value.baseLimit }
        } catch { self.error = error.localizedDescription; status = nil }
    }
    func run(_ command: BDCommand, limit: Int = 0) async -> Bool {
        guard Self.isSupported, (AppFeature.chargingControl.isAvailable || command == .restore), !busy else { return false }; busy = true; defer { busy = false }
        do {
            let value = try await ServiceClient.request(command, limit: limit)
            status = value; error = ""
            if command == .setLimit || command == .restore { selectedLimit = value.baseLimit }
            return value.verification != "failed" && value.error.isEmpty
        } catch { self.error = error.localizedDescription; return false }
    }
    func enable() async {
        guard Self.isSupported, AppFeature.chargingControl.isAvailable else { return }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        check.arguments = ["print", "system/com.bodian.charge"]
        check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
        do { try check.run(); await Task.detached { check.waitUntilExit() }.value }
        catch { self.error = error.localizedDescription; return }
        guard check.terminationStatus != 0 else {
            error = "请先在Vorssaint中恢复系统管理并停用后台，避免两个控制器同时写充电策略。"; return
        }
        guard Bundle.main.bundlePath == ServiceClient.installedApp else {
            error = "请先将签名应用安装到 /Applications/Vorssaint.app。"; return
        }
        busy = true
        do {
            if !ServiceClient.authorizationIsCurrent {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "do shell script \"/usr/sbin/chown -R root:wheel /Applications/Vorssaint.app && /bin/chmod -R go-w /Applications/Vorssaint.app && /Applications/Vorssaint.app/Contents/MacOS/VorssaintChargeHelper --prepare-trust\" with administrator privileges"]
            let pipe = Pipe(); task.standardError = pipe
            try task.run()
            await Task.detached { task.waitUntilExit() }.value
            guard task.terminationStatus == 0 else { throw ClientError.message("授权未完成，请重试。") }
            }
            if daemon.status != .enabled { try daemon.register() }
            if daemon.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            error = ""
        } catch {
            if daemon.status == .requiresApproval {
                self.error = "请在系统后台项目中允许Vorssaint，然后返回此窗口。"
                SMAppService.openSystemSettingsLoginItems()
            } else { self.error = error.localizedDescription }
        }
        busy = false; updateServiceState()
    }
    func disable() async {
        if daemon.status == .enabled { guard await run(.restore) else { return } }
        do { try await daemon.unregister(); status = nil; updateServiceState() }
        catch { self.error = "设置已恢复，但后台注销失败：\(error.localizedDescription)" }
    }
}
