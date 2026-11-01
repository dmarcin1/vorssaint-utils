import Foundation
import CSQLite

public final class EnergyDatabase {
    private var handle: OpaquePointer?
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vorssaint", isDirectory: true).appendingPathComponent("energy.sqlite")
    }
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(handle); handle = nil; throw error
        }
        sqlite3_busy_timeout(handle, 1500)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try execute("PRAGMA journal_mode=WAL; PRAGMA journal_size_limit=1048576;")
            try execute("""
                CREATE TABLE IF NOT EXISTS minutes (
                    start REAL PRIMARY KEY, seconds REAL NOT NULL, discharge REAL NOT NULL,
                    charge REAL NOT NULL, first_level REAL NOT NULL, last_level REAL NOT NULL,
                    mode TEXT NOT NULL, sensor_updates INTEGER NOT NULL);
                """)
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }
    private func failure() -> NSError {
        NSError(domain: "com.bodian.energy", code: Int(sqlite3_errcode(handle)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    public func save(_ rows: [EnergyMinute], now: Double) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            let sql = """
                INSERT INTO minutes VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(start) DO UPDATE SET
                seconds=minutes.seconds+excluded.seconds, discharge=minutes.discharge+excluded.discharge,
                charge=minutes.charge+excluded.charge, last_level=excluded.last_level,
                mode=CASE WHEN minutes.mode=excluded.mode THEN minutes.mode ELSE 'mixed' END,
                sensor_updates=minutes.sensor_updates+excluded.sensor_updates
                """
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
            defer { sqlite3_finalize(statement) }
            for row in rows {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                for (index, value) in [row.start, row.seconds, row.dischargeWh, row.chargeWh, row.firstLevel, row.lastLevel].enumerated() {
                    sqlite3_bind_double(statement, Int32(index + 1), value)
                }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 7, row.mode.rawValue, -1, transient)
                sqlite3_bind_int(statement, 8, Int32(row.sensorUpdates))
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            }
            var prune: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM minutes WHERE start < ?", -1, &prune, nil) == SQLITE_OK else { throw failure() }
            defer { sqlite3_finalize(prune) }
            sqlite3_bind_double(prune, 1, floor(now / 60) * 60 - 7 * 86400)
            guard sqlite3_step(prune) == SQLITE_DONE else { throw failure() }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func read(since: Double) throws -> [EnergyMinute] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT * FROM minutes WHERE start >= ? ORDER BY start", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since)
        var rows: [EnergyMinute] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append(EnergyMinute(start: sqlite3_column_double(statement, 0), seconds: sqlite3_column_double(statement, 1),
                dischargeWh: sqlite3_column_double(statement, 2), chargeWh: sqlite3_column_double(statement, 3),
                firstLevel: sqlite3_column_double(statement, 4), lastLevel: sqlite3_column_double(statement, 5),
                mode: EnergyMode(rawValue: String(cString: sqlite3_column_text(statement, 6))) ?? .mixed,
                sensorUpdates: Int(sqlite3_column_int(statement, 7))))
        }
    }
    public static func csv(_ rows: [EnergyMinute]) -> String {
        let formatter = ISO8601DateFormatter()
        var result = "time,coverage_seconds,discharge_Wh,charge_Wh,average_discharge_W,start_percent,end_percent,mode,sensor_updates\n"
        for row in rows {
            result += "\(formatter.string(from: Date(timeIntervalSince1970: row.start))),\(row.seconds),\(row.dischargeWh),\(row.chargeWh),\(row.averageDischargeWatts),\(row.firstLevel),\(row.lastLevel),\(row.mode.rawValue),\(row.sensorUpdates)\n"
        }
        return result
    }
}
