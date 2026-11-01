// SPDX-License-Identifier: GPL-3.0-or-later
// Signed diagnostics share the GUI's XPC authentication, as in BoDian.
import AppKit
import ChargeShared

enum LocalPortCommands {
    @MainActor static func runIfRequestedAndExit() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--local-port-status"] {
            if AppFeature.finderMenu.isAvailable {
                FinderMenuService.shared.syncWithPreferences()
            }
            let value: [String: Any] = [
                "chargingSupported": ChargeModel.isSupported,
                "chargingAvailable": AppFeature.chargingControl.isAvailable,
                "historyAvailable": AppFeature.batteryHistory.isAvailable,
                "finderMenuAvailable": AppFeature.finderMenu.isAvailable,
                "finderPreferencesAvailable": FinderMenuContract.isPreferencesAvailable,
                "finderKeyReady": FinderMenuContract.readKey() != nil,
                "finderError": FinderMenuService.shared.error,
                "batteryReadingValid": EnergyReader.read() != nil,
            ]
            output(value); exit(0)
        }
        if args == ["--battery-energy-report"] {
            do {
                let database = try EnergyDatabase(url: EnergyDatabase.defaultURL)
                let rows = try database.read(since: Date().timeIntervalSince1970 - 7 * 86400)
                output(["minutes": rows.count, "coverageSeconds": rows.reduce(0) { $0 + $1.seconds },
                        "dischargeWh": rows.reduce(0) { $0 + $1.dischargeWh }]); exit(0)
            } catch { fail(error) }
        }
        guard args.first == "--charge-command" else { return }
        let commands: [String: BDCommand] = ["status": .status, "pause": .pause, "resume": .resume,
            "limit": .setLimit, "topup": .topUp, "restore": .restore, "battery": .useBattery, "floor": .setBatteryFloor]
        guard args.count >= 2, let command = commands[args[1]],
              args.count == ((command == .setLimit || command == .setBatteryFloor) ? 3 : 2),
              ChargeModel.isSupported else { exit(64) }
        let limit = args.count == 3 ? Int(args[2]) : 0
        guard let limit else { exit(64) }
        Task {
            do {
                let status = try await ServiceClient.request(command, limit: limit)
                output(["baseLimit": status.baseLimit, "batteryFloor": status.batteryFloor,
                    "intent": status.intent, "target": status.activeTarget, "verification": status.verification,
                    "registered": status.registered, "current": status.battery.current ?? 0,
                    "level": status.battery.level ?? -1, "error": status.error])
                exit(status.error.isEmpty ? 0 : 1)
            } catch { fail(error) }
        }
        RunLoop.main.run()
    }
    private static func output(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }
    private static func fail(_ error: Error) -> Never {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
    }
}
