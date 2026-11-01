// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Security

@MainActor
final class FinderMenuService: ObservableObject {
    static let shared = FinderMenuService()
    @Published var configuration: FinderMenuContract.Configuration
    @Published var error = ""
    private var seenRequests: [UUID: Double] = [:]
    private var defaultsObserver: NSObjectProtocol?
    private let media = MediaService(replacesExistingOutputs: false)
    private var mediaWindow: NSWindow?
    private init() {
        var config = UserDefaults.standard.data(forKey: FinderMenuContract.settingsKey)
            .flatMap { try? JSONDecoder().decode(FinderMenuContract.Configuration.self, from: $0) } ?? .init()
        let hasOfficeTemplates = ["docx", "xlsx", "pptx", "pdf"].allSatisfy { ext in
            config.templates.contains(where: { $0.path == ext })
        }
        if !hasOfficeTemplates {
            let existingPaths = Set(config.templates.map(\.path))
            for preset in FinderMenuContract.FinderTemplatePresets.defaultTemplates() {
                if !existingPaths.contains(preset.path) {
                    config.templates.append(preset)
                }
            }
            configuration = config
            save()
        } else {
            configuration = config
        }
    }
    func save() {
        do {
            let data = try JSONEncoder().encode(configuration)
            UserDefaults.standard.set(data, forKey: FinderMenuContract.settingsKey)
            try publish()
            error = ""
        } catch { self.error = error.localizedDescription }
    }
    func syncWithPreferences() {
        do { try publish(); error = "" } catch { self.error = error.localizedDescription }
        if AppFeature.finderMenu.isAvailable, defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in try? self?.publish() }
            }
        } else if !AppFeature.finderMenu.isAvailable, let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer); defaultsObserver = nil
        }
    }
    private func publish() throws {
        if FinderMenuContract.readKey() == nil {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
            guard FinderMenuContract.writeKey(Data(bytes)) else { throw CocoaError(.fileWriteUnknown) }
        }
        var snapshot = configuration
        snapshot.enabled = AppFeature.finderMenu.isAvailable
        snapshot.canCutPaste = AppFeature.finderCutPaste.isAvailable
        snapshot.canConvert = AppFeature.mediaTools.isAvailable
        for key in configuration.actions.map(\.id) + ["open-with", "new-file", "directories"] {
            snapshot.labels[key] = PortStrings.text(key)
        }
        let data = try JSONEncoder().encode(snapshot)
        guard FinderMenuContract.writeConfigurationData(data) else { throw CocoaError(.fileWriteUnknown) }
    }
    func handle(_ url: URL) -> Bool {
        guard url.scheme == FinderMenuContract.scheme else { return false }
        let payload = String(url.path.dropFirst())
        return handlePayload(payload)
    }
    @discardableResult
    func handlePayload(_ rawPayload: String) -> Bool {
        guard AppFeature.finderMenu.isAvailable, let key = FinderMenuContract.readKey() else { return true }
        var base64 = rawPayload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let now = Date().timeIntervalSince1970
        guard let data = Data(base64Encoded: base64), data.count < 196608,
              let envelope = try? JSONDecoder().decode(FinderMenuContract.Envelope.self, from: data),
              let request = envelope.verified(key: key, now: now) else { return false }
        seenRequests = seenRequests.filter { now - $0.value < 30 }
        guard seenRequests[request.id] == nil else { return true }
        seenRequests[request.id] = now
        Task { await perform(request) }
        return true
    }
    private func perform(_ request: FinderMenuContract.Request) async {
        var urls = request.paths.map { URL(fileURLWithPath: $0) }
        let effectiveDirURL: URL
        if !request.directory.isEmpty {
            effectiveDirURL = URL(fileURLWithPath: request.directory)
        } else if let firstURL = urls.first {
            let isDir = (try? firstURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            effectiveDirURL = isDir ? firstURL : firstURL.deletingLastPathComponent()
        } else {
            effectiveDirURL = FileManager.default.homeDirectoryForCurrentUser
        }
        let directory = effectiveDirURL
        let action = request.action
        let enabled = Set(configuration.actions.filter(\.enabled).map(\.id))
        do {
            if action.hasPrefix("app:"), let app = configuration.applications.first(where: { "app:" + $0.id == action }) {
                let options = NSWorkspace.OpenConfiguration(); options.arguments = app.arguments; options.environment = app.environment
                _ = try await NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: app.path), configuration: options)
            } else if action.hasPrefix("directory:"), let item = configuration.directories.first(where: { "directory:" + $0.id == action }) {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            } else if action.hasPrefix("template:"),
                      let item = configuration.templates.first(where: { "template:" + $0.id == action }),
                      let content = item.content {
                let name = item.name + (item.path.isEmpty ? "" : "." + item.path)
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw CocoaError(.fileWriteInvalidFileName) }
                let target = FinderFileCopy.uniqueDestinationURL(for: directory.appendingPathComponent(name), in: directory)
                // No existing file is ever replaced, including a concurrent creator.
                try content.write(to: target, options: .withoutOverwriting)
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } else if action.hasPrefix("convert:"), enabled.contains("convert-images"), AppFeature.mediaTools.isAvailable,
                      let format = MediaImageFormat(rawValue: String(action.dropFirst(8))), [.jpeg, .png, .webp].contains(format) {
                if case .running = media.state { return }
                media.processImages(inputURLs: urls, outputDirectory: directory,
                    options: MediaImageOptions(quality: 0.9, maxDimension: 1600, format: format, stripMetadata: false, resizeMode: MediaImageResizeMode.none))
                showMediaProgress()
            } else if enabled.contains(action) {
                if ["cut-files", "copy-to", "move-to", "delete-direct", "hide", "unhide"].contains(action) {
                    if request.container && ["hide", "unhide"].contains(action) {
                        urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        if action == "unhide" { urls.append(directory) }
                    }
                    guard !urls.contains(where: FinderFileCopy.isProtected) else { throw CocoaError(.fileWriteNoPermission) }
                }
                switch action {
                case "copy-path":
                    let pathsToCopy = request.paths.isEmpty ? [directory.path] : request.paths
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pathsToCopy.joined(separator: "\n"), forType: .string)
                case "hide", "unhide":
                    for url in urls { var values = URLResourceValues(); values.isHidden = action == "hide"; var file = url; try file.setResourceValues(values) }
                case "delete-direct":
                    guard !request.container else { return }
                    let alert = NSAlert(); alert.messageText = PortStrings.text("delete-direct")
                    alert.informativeText = urls.map(\.lastPathComponent).joined(separator: "\n")
                    alert.alertStyle = .warning; alert.addButton(withTitle: PortStrings.text("delete-direct")); alert.addButton(withTitle: "Cancel")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { for url in urls { try FileManager.default.removeItem(at: url) } }
                case "airdrop": NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
                case "cut-files" where AppFeature.finderCutPaste.isAvailable: FinderCutPaste.shared.cutFromMenu(urls)
                case "paste-files" where AppFeature.finderCutPaste.isAvailable: FinderCutPaste.shared.pasteFromMenu(into: directory)
                case "copy-to", "move-to":
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    NSApp.activate(ignoringOtherApps: true)
                    guard panel.runModal() == .OK, let destination = panel.url else { return }
                    if action == "move-to", AppFeature.finderCutPaste.isAvailable {
                        FinderCutPaste.shared.cutFromMenu(urls); FinderCutPaste.shared.pasteFromMenu(into: destination)
                    } else if action == "copy-to" {
                        let result = await Task.detached { FinderFileCopy.copy(urls, to: destination) }.value
                        if let first = result.first { throw first }
                    }
                default: break
                }
            }
        } catch {
            self.error = error.localizedDescription
            let alert = NSAlert(); alert.messageText = "Vorssaint Finder"; alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
    private func showMediaProgress() {
        if mediaWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Vorssaint · " + PortStrings.text("convert-images")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: FinderMenuMediaProgress(media: media))
            window.center(); mediaWindow = window
        }
        mediaWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
import SwiftUI
private struct FinderMenuMediaProgress: View {
    @ObservedObject var media: MediaService
    var body: some View {
        VStack(spacing: 12) {
            Text(PortStrings.text("convert-images")).font(.headline)
            switch media.state {
            case .running(let progress, _):
                ProgressView(value: progress)
                Button("Cancel") { media.cancel() }
            case .completed(let result):
                Text("\(result.processedCount) ✓ · \(result.failedCount) ✕")
                ForEach(result.outputURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            case .failed: Text("转换失败，请检查所选文件格式与目标文件夹权限。")
            case .cancelled: Text("已取消")
            default: EmptyView()
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
