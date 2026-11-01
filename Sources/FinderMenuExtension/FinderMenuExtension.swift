// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FinderSync
import os

private let log = Logger(subsystem: "com.vorssaint.utils.finder-menu", category: "menu")

private struct FinderMenuActionContext {
    let action: String
    let paths: [String]
    let directory: String
    let container: Bool
}

@objc(FinderMenuExtension)
final class FinderMenuExtension: FIFinderSync {
    // Finder rebuilds menu items in its own process; only the tag survives the
    // round trip back to `invoke`, so each item's context is kept here by tag.
    private var contexts: [Int: FinderMenuActionContext] = [:]
    private var nextTag = 1
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Volumes")]
    }
    override var toolbarItemName: String { "Vorssaint" }
    override var toolbarItemToolTip: String { "Vorssaint Finder" }
    override var toolbarItemImage: NSImage { NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: nil)! }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard let config = FinderMenuContract.readConfiguration(), config.enabled else { return nil }
        let controller = FIFinderSyncController.default()
        let selectedURLs = controller.selectedItemURLs() ?? []
        var targets = selectedURLs.map(\.path)
        let target = controller.targetedURL()
        var directory = target?.path ?? ""
        let container = menuKind == .contextualMenuForContainer
        if let target, (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            directory = target.deletingLastPathComponent().path
        }
        if directory.isEmpty, let firstSelected = selectedURLs.first {
            let isDir = (try? firstSelected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            directory = (isDir && menuKind == .contextualMenuForItems && selectedURLs.count == 1)
                ? firstSelected.path
                : firstSelected.deletingLastPathComponent().path
        }
        if directory.isEmpty {
            directory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        }
        if container {
            targets = [directory]
        }
        if contexts.count > 2000 { contexts.removeAll() }
        let content = NSMenu()
        func label(_ key: String) -> String { config.labels[key] ?? key }
        func add(_ title: String, _ action: String, to menu: NSMenu = content) {
            let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
            item.target = self
            item.tag = nextTag
            contexts[nextTag] = FinderMenuActionContext(action: action, paths: targets, directory: directory, container: container)
            nextTag += 1
            menu.addItem(item)
        }
        for action in config.actions where action.enabled {
            if container && ["cut-files", "copy-to", "move-to", "delete-direct", "convert-images"].contains(action.id) { continue }
            if !config.canCutPaste && ["cut-files", "paste-files", "move-to"].contains(action.id) { continue }
            if action.id == "convert-images" {
                guard config.canConvert, !targets.isEmpty else { continue }
                let item = NSMenuItem(title: label(action.id), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for format in ["jpeg", "png", "webp"] { add(format == "jpeg" ? "JPG" : format.uppercased(), "convert:" + format, to: submenu) }
                item.submenu = submenu; content.addItem(item)
            } else if !targets.isEmpty || action.id == "paste-files" {
                add(label(action.id), action.id)
            }
        }
        for (key, prefix, items) in [("open-with", "app:", config.applications), ("new-file", "template:", config.templates), ("directories", "directory:", config.directories)] where !items.isEmpty {
            let item = NSMenuItem(title: label(key), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for entry in items { add(entry.name, prefix + entry.id, to: submenu) }
            item.submenu = submenu; content.addItem(item)
        }
        log.notice("menu kind=\(menuKind.rawValue, privacy: .public) targets=\(targets.count, privacy: .public) items=\(self.contexts.count, privacy: .public)")
        if !config.collapsed { return content }
        let root = NSMenu()
        let item = NSMenuItem(title: "Vorssaint", action: nil, keyEquivalent: "")
        item.submenu = content; root.addItem(item)
        return root
    }
    @objc private func invoke(_ sender: NSMenuItem) {
        let hasRepresented = sender.representedObject != nil
        guard let context = contexts[sender.tag] else {
            log.error("invoke: no context for tag=\(sender.tag, privacy: .public) represented=\(hasRepresented, privacy: .public)")
            return
        }
        guard let key = FinderMenuContract.readKey() else {
            log.error("invoke: authentication key unavailable")
            return
        }
        let request = FinderMenuContract.Request(action: context.action, paths: context.paths, directory: context.directory, container: context.container)
        guard let envelope = try? FinderMenuContract.Envelope(request: request, key: key),
              let data = try? JSONEncoder().encode(envelope) else { return }
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard let url = URL(string: FinderMenuContract.scheme + "://action/" + encoded) else { return }
        let opened = NSWorkspace.shared.open(url)
        log.notice("invoke: action=\(context.action, privacy: .public) tag=\(sender.tag, privacy: .public) represented=\(hasRepresented, privacy: .public) opened=\(opened, privacy: .public)")
    }
}
