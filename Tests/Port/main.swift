// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import ImageIO
import ChargeShared

var checks = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw NSError(domain: "PortTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    checks += 1
}
func reading(_ time: Double, current: Int64 = -1000, sensor: Double? = nil, connected: Bool = true) -> EnergySample {
    EnergySample(time: time, uptime: time, sensorTime: sensor ?? time, level: 85, milliamps: current, millivolts: 12000, connected: connected)
}
do {
    var policy = BDPolicy(baseLimit: 80, batteryFloor: 20, intent: BDIntentPause, topUpComplete: false)
    try expect(bd_policy_target(&policy, 81, false, false) == 20, "pause uses the non-discharge floor")
    try expect(bd_policy_target(&policy, 20, false, false) == 80 && policy.intent == BDIntentNone, "pause ends at 20%")
    policy.intent = BDIntentTopUp
    try expect(bd_policy_target(&policy, 100, true, false) == 100 && policy.topUpComplete, "full charge persists until unplug")
    try expect(bd_policy_target(&policy, 99, false, true) == 80, "unplug returns to base")
    for floor: Int32 in [5, 10, 15, 20, 25, 30] {
        policy.batteryFloor = floor; policy.intent = BDIntentBattery
        try expect(bd_policy_target(&policy, floor + 1, false, false) == floor, "battery mode accepts threshold")
        try expect(bd_policy_target(&policy, floor, false, false) == 80 && policy.intent == BDIntentNone, "battery threshold ends temporary mode")
    }
    for invalid: Int32 in [-1, 1, 20, 49, 101] { try expect(!bd_valid_base_limit(invalid), "invalid limit rejected") }
    var accumulator = EnergyAccumulator()
    try expect(accumulator.ingest(reading(50)).isEmpty, "first sample is a baseline")
    let rows = accumulator.ingest(reading(80))
    try expect(rows.count == 2 && rows[0].seconds == 10 && rows[1].seconds == 20, "minute boundary splits actual elapsed time")
    try expect(abs(rows.reduce(0) { $0 + $1.dischargeWh } - 0.1) < 0.000001, "12 W for 30 seconds equals 0.1 Wh")
    try expect(accumulator.ingest(reading(95, current: 1000)).isEmpty, "direction changes are not interpolated")
    try expect(accumulator.ingest(reading(4000)).isEmpty, "sleep gap invents no energy")
    try expect(accumulator.ingest(reading(4015, sensor: 3900)).isEmpty, "stale reading invents no energy")
    accumulator.reset(); _ = accumulator.ingest(reading(0))
    try expect(accumulator.ingest(reading(15, sensor: 0))[0].sensorUpdates == 0, "repeated sensor timestamp is not a new measurement")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vorssaint-port-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let databaseURL = temporary.appendingPathComponent("energy.sqlite")
    do {
        let database = try EnergyDatabase(url: databaseURL)
        try database.save(rows, now: 80)
        try expect(try database.read(since: 0).count == 2, "SQLite persists minute records")
        try expect(EnergyDatabase.csv(rows).contains("discharge_Wh"), "CSV declares energy unit")
    }
    let reopened = try EnergyDatabase(url: databaseURL)
    try expect(try reopened.read(since: 0).count == 2, "database survives reopening")
    try reopened.save([], now: 8 * 86400)
    try expect(try reopened.read(since: 0).isEmpty, "data older than seven days is pruned")

    let source = temporary.appendingPathComponent("source.txt")
    try Data("original".utf8).write(to: source)
    let destination = temporary.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try expect(FinderFileCopy.copy([source], to: destination).isEmpty, "copy-to completes")
    try expect(FinderFileCopy.copy([source], to: destination).isEmpty, "repeat copy numbers the collision")
    try expect(try String(contentsOf: destination.appendingPathComponent("source-2.txt"), encoding: .utf8) == "original", "numbered copy has correct bytes")
    try expect(try String(contentsOf: source, encoding: .utf8) == "original", "source survives copy")
    try expect(!FinderFileCopy.copy([destination], to: destination).isEmpty, "copying directory into itself is rejected")
    let nested = destination.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try expect(!FinderFileCopy.copy([destination], to: nested).isEmpty, "recursive copy into descendant is rejected")

    let key = Data(repeating: 7, count: 32)
    let request = FinderMenuContract.Request(action: "copy-path", paths: [source.path], directory: temporary.path)
    let envelope = try FinderMenuContract.Envelope(request: request, key: key)
    try expect(envelope.verified(key: key, now: request.timestamp) != nil, "extension request authenticates")
    let emptyDirRequest = FinderMenuContract.Request(action: "copy-path", paths: [source.path], directory: "")
    let emptyDirEnvelope = try FinderMenuContract.Envelope(request: emptyDirRequest, key: key)
    try expect(emptyDirEnvelope.verified(key: key, now: emptyDirRequest.timestamp) != nil, "request with empty directory and valid paths authenticates")
    let invalidEmptyRequest = FinderMenuContract.Request(action: "copy-path", paths: [], directory: "")
    let invalidEmptyEnvelope = try FinderMenuContract.Envelope(request: invalidEmptyRequest, key: key)
    try expect(invalidEmptyEnvelope.verified(key: key, now: invalidEmptyRequest.timestamp) == nil, "request with empty directory and empty paths is rejected")
    try expect(envelope.verified(key: Data(repeating: 8, count: 32), now: request.timestamp) == nil, "wrong key is rejected")
    try expect(envelope.verified(key: key, now: request.timestamp + 31) == nil, "expired request is rejected")
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as! [String: Any]
    object["message"] = Data("tampered".utf8).base64EncodedString()
    let urlPayload = try JSONEncoder().encode(envelope).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let callback = URL(string: "vorssaint-finder://action/" + urlPayload)!
    try expect(callback.host == "action" && String(callback.path.dropFirst()) == urlPayload, "Foundation preserves the signed callback payload")
    let tampered = try JSONDecoder().decode(FinderMenuContract.Envelope.self, from: JSONSerialization.data(withJSONObject: object))
    try expect(tampered.verified(key: key, now: request.timestamp) == nil, "modified request is rejected")
    try expect(FinderMenuContract.FinderTemplatePresets.defaultTemplates().count == 6, "all 6 default templates exist")
    try expect(FinderMenuContract.FinderTemplatePresets.defaultTemplates().allSatisfy { !$0.id.isEmpty }, "all default templates have non-empty IDs")

    let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 0.5)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
    let webpURL = temporary.appendingPathComponent("output.webp")
    try WebPEncoder.write(context.makeImage()!, to: webpURL, quality: 0.9)
    let bytes = try Data(contentsOf: webpURL)
    try expect(String(data: bytes[0..<4], encoding: .ascii) == "RIFF" && String(data: bytes[8..<12], encoding: .ascii) == "WEBP", "output is WebP, not a renamed PNG")
    let decoded = CGImageSourceCreateWithURL(webpURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    try expect(decoded?.width == 8 && decoded?.height == 6, "WebP decodes with original dimensions")
    try expect(decoded?.alphaInfo != CGImageAlphaInfo.none && decoded?.alphaInfo != CGImageAlphaInfo.noneSkipLast, "WebP retains transparency")
    var rgba = [UInt8](repeating: 0, count: 4)
    rgba.withUnsafeMutableBytes { buffer in
        let sample = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        sample.draw(decoded!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    try expect((120...136).contains(Int(rgba[3])), "WebP retains the actual half-transparent alpha value")
    print("PASS: \(checks) charging, energy, file, IPC and WebP checks")
} catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
