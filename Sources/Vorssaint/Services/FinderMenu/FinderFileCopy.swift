// SPDX-License-Identifier: GPL-3.0-or-later
// Copy and collision handling ported from RightSight (RClick, GPL-3.0).
import Foundation
enum FinderFileCopy {
    static func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protected = ["/", "/Users", "/Applications", home, home + "/Desktop", home + "/Applications"]
        let roots = ["/System", "/Library", "/bin", "/sbin", "/usr", "/private", "/var"]
        return protected.contains(path) || roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    static func copy(_ urls: [URL], to directory: URL) -> [Error] {
        var errors: [Error] = []
        for source in urls {
            do {
                guard (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw CocoaError(.fileWriteInvalidFileName) }
                try validateDestination(directory, for: source, fileManager: .default)
                try FileManager.default.copyItem(at: source, to: uniqueDestinationURL(for: source, in: directory))
            } catch { errors.append(error) }
        }
        return errors
    }
    nonisolated static func uniqueDestinationURL(
        for sourceURL: URL,
        in destinationDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)

        let originalName = sourceURL.lastPathComponent
        let fileExtension = isDirectory.boolValue ? "" : sourceURL.pathExtension
        let baseName = fileExtension.isEmpty
            ? originalName
            : sourceURL.deletingPathExtension().lastPathComponent

        var candidate = destinationDirectory.appendingPathComponent(
            originalName,
            isDirectory: isDirectory.boolValue
        )
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let numberedName = fileExtension.isEmpty
                ? "\(baseName)-\(suffix)"
                : "\(baseName)-\(suffix).\(fileExtension)"
            candidate = destinationDirectory.appendingPathComponent(
                numberedName,
                isDirectory: isDirectory.boolValue
            )
            suffix += 1
        }

        return candidate
    }

    private nonisolated static func validateDestination(
        _ destinationDirectory: URL,
        for sourceURL: URL,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard isDirectory.boolValue else { return }

        let sourcePath = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = destinationDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }
}
