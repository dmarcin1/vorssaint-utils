// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import FinderSync

struct FinderMenuSettings: View {
    @ObservedObject private var service = FinderMenuService.shared
    @State private var selectedApp: String?
    @State private var arguments = ""
    @State private var environment = ""
    @State private var editingApplication = false
    var body: some View {
        Section(PortStrings.text("finder")) {
            Button("在系统设置中启用 Finder 扩展") { FIFinderSyncController.showExtensionManagementInterface() }
            Text("需先启用 Vorssaint Finder 扩展。iCloud 等 File Provider 目录可能不显示第三方菜单，这是 FinderSync 的系统限制。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("收起为 Vorssaint 子菜单", isOn: $service.configuration.collapsed)
                .onChange(of: service.configuration.collapsed) { _, _ in service.save() }
            ForEach(Array(service.configuration.actions.enumerated()), id: \.element.id) { index, action in
                HStack {
                    Toggle(PortStrings.text(action.id), isOn: Binding(get: { service.configuration.actions[index].enabled }, set: { value in
                        service.configuration.actions[index].enabled = value; service.save()
                    }))
                    Spacer()
                    Button { service.configuration.actions.swapAt(index, index - 1); service.save() } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                    Button { service.configuration.actions.swapAt(index, index + 1); service.save() } label: { Image(systemName: "arrow.down") }.disabled(index == service.configuration.actions.count - 1)
                }
            }
            Text("剪切、粘贴、移动到使用已有的 Finder 剪切粘贴功能；图片转换使用已有媒体工具。请在功能页保留相应功能。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(PortStrings.text("open-with")) {
            ForEach(service.configuration.applications) { item in
                HStack {
                    Text(item.name); Spacer()
                    Button("参数与环境变量") {
                        selectedApp = item.id
                        arguments = item.arguments.joined(separator: "\n")
                        environment = item.environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "\n")
                        editingApplication = true
                    }
                    Button(role: .destructive) { service.configuration.applications.removeAll { $0.id == item.id }; service.save() } label: { Image(systemName: "minus.circle") }
                }
            }
            Button("添加应用…") { chooseApplication() }
        }
        Section(PortStrings.text("new-file")) {
            ForEach($service.configuration.templates) { $item in
                HStack {
                    TextField("名称", text: $item.name).onSubmit { service.save() }
                    Text(item.path).foregroundStyle(.secondary)
                    Button(role: .destructive) { service.configuration.templates.removeAll { $0.id == item.id }; service.save() } label: { Image(systemName: "minus.circle") }
                }
            }
            HStack {
                Button("从文件添加模板…") { chooseTemplate() }
                Button("恢复默认模板") {
                    service.configuration.templates = FinderMenuContract.FinderTemplatePresets.defaultTemplates()
                    service.save()
                }
            }
            Text("模板保存文件内容副本；新建时自动编号，保留原模板和已有文件。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(PortStrings.text("directories")) {
            ForEach($service.configuration.directories) { $item in
                HStack {
                    TextField("名称", text: $item.name).onSubmit { service.save() }
                    Text(item.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button(role: .destructive) { service.configuration.directories.removeAll { $0.id == item.id }; service.save() } label: { Image(systemName: "minus.circle") }
                }
            }
            Button("添加目录…") { chooseDirectory() }
        }
        Section {
            HStack {
                Button("导出菜单设置…") { exportConfiguration() }
                Button("导入菜单设置…") { importConfiguration() }
                Button("恢复菜单默认设置") { service.configuration = .init(); service.save() }
            }
            if !service.error.isEmpty { Text(service.error).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .onDisappear { service.save() }
        .sheet(isPresented: $editingApplication) {
            VStack(alignment: .leading, spacing: 12) {
                Text("启动参数（每行一个）").font(.headline)
                TextEditor(text: $arguments).frame(height: 100)
                Text("环境变量（每行 NAME=value）").font(.headline)
                TextEditor(text: $environment).frame(height: 100)
                HStack {
                    Button("取消") { editingApplication = false }
                    Spacer()
                    Button("保存") {
                        guard let index = service.configuration.applications.firstIndex(where: { $0.id == selectedApp }) else { return }
                        service.configuration.applications[index].arguments = arguments.split(separator: "\n").map(String.init)
                        var variables: [String: String] = [:]
                        for line in environment.split(separator: "\n") {
                            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                            guard parts.count == 2, !parts[0].isEmpty else { service.error = "环境变量格式应为 NAME=value"; return }
                            variables[String(parts[0])] = String(parts[1])
                        }
                        service.configuration.applications[index].environment = variables
                        service.save(); editingApplication = false
                    }
                }
            }.padding(20).frame(width: 450)
        }
    }
    private func chooseApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        service.configuration.applications.append(.init(name: url.deletingPathExtension().lastPathComponent, path: url.path)); service.save()
    }
    private func chooseTemplate() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 10 * 1024 * 1024 else { service.error = "请选择不超过 10 MB 的模板"; return }
            let data = try Data(contentsOf: url)
            service.configuration.templates.append(.init(name: url.deletingPathExtension().lastPathComponent, path: url.pathExtension, content: data)); service.save()
        } catch { service.error = error.localizedDescription }
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        service.configuration.directories.append(.init(name: url.lastPathComponent, path: url.path)); service.save()
    }
    private func exportConfiguration() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Vorssaint-Finder.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONEncoder().encode(service.configuration).write(to: url, options: .atomic) }
        catch { service.error = error.localizedDescription }
    }
    private func importConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { service.configuration = try JSONDecoder().decode(FinderMenuContract.Configuration.self, from: Data(contentsOf: url)); service.save() }
        catch { service.error = error.localizedDescription }
    }
}
