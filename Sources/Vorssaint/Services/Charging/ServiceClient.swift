import Foundation
import ChargeShared
import Darwin
import Security

struct BatteryStatus: Decodable {
    let level: Int?
    let charging: Bool?
    let connected: Bool?
    let current: Int64?
    let updated: Double?
    let source: String?
    enum CodingKeys: String, CodingKey {
        case level = "CurrentCapacity", charging = "IsCharging", connected = "ExternalConnected"
        case current = "Amperage", updated = "UpdateTime", source
    }
}
struct ChargeStatus: Decodable {
    let version: Int
    let battery: BatteryStatus
    let baseLimit: Int
    let batteryFloor: Int
    let intent: Int
    let topUpComplete: Bool
    let activeTarget: Int
    let registered: Bool
    let verification: String
    let error: String
    let notice: String
}
enum ClientError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}
// Completion is exchanged only while holding the lock, including timeout/error races.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Result<Data, Error>) -> Void)?
    init(_ completion: @escaping (Result<Data, Error>) -> Void) { self.completion = completion }
    func finish(_ result: Result<Data, Error>) {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?(result)
    }
}
enum ServiceClient {
    static let serviceName = "com.vorssaint.utils.charge"
    static let installedApp = "/Applications/Vorssaint.app"
    private static func helperHash() throws -> String {
        let paths = ["/Library", "/Library/Application Support", "/Library/Application Support/Vorssaint", "/Library/Application Support/Vorssaint/Charging"]
        for path in paths {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else {
                throw ClientError.message("后台授权目录不安全，请重新授权此版本。")
            }
        }
        let path = paths.last! + "/trust.plist"
        guard FileManager.default.fileExists(atPath: path) else {
            throw ClientError.message("后台尚未授权，请打开设置并启用控制。")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0,
              (attributes[.size] as? NSNumber)?.intValue ?? 99999 < 4096,
              let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: Any],
              (value["ownerUID"] as? NSNumber)?.uint32Value == getuid(),
              let hash = value["helperHash"] as? String,
              hash.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw ClientError.message("此版本尚未获得后台授权。")
        }
        return hash
    }
    static var authorizationIsCurrent: Bool {
        guard (try? helperHash()) != nil,
              let data = try? Data(contentsOf: URL(fileURLWithPath: "/Library/Application Support/Vorssaint/Charging/trust.plist")),
              let trust = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code, SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return false }
        return trust["appHash"] as? String == hash.map { String(format: "%02x", $0) }.joined()
    }
    static func request(_ command: BDCommand, limit: Int = 0) async throws -> ChargeStatus {
        let hash = try helperHash()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: BDChargeService.self)
            connection.setCodeSigningRequirement("identifier \"com.vorssaint.utils.charge-helper\" and cdhash H\"\(hash)\"")
            let box = ReplyBox { result in connection.invalidate(); continuation.resume(with: result) }
            connection.invalidationHandler = { box.finish(.failure(ClientError.message("后台服务未连接，请在设置中启用。"))) }
            connection.resume()
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in
                box.finish(.failure(ClientError.message("后台连接失败：\(error.localizedDescription)")))
            }) as? BDChargeService else {
                box.finish(.failure(ClientError.message("后台协议不可用。"))); return
            }
            remote.perform(command, limit: limit) { data, error in
                if let error { box.finish(.failure(ClientError.message(error))) }
                else if let data { box.finish(.success(data)) }
                else { box.finish(.failure(ClientError.message("后台返回空结果。"))) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 50) {
                box.finish(.failure(ClientError.message("操作等待超时，请重新连接检查状态。")))
            }
        }
        let status = try JSONDecoder().decode(ChargeStatus.self, from: data)
        guard status.version == 3 else { throw ClientError.message("应用与后台版本不同，请重新安装此版本。") }
        return status
    }
}
