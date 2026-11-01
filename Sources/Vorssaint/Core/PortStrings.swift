// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
enum PortStrings {
    static func text(_ key: String, _ language: AppLanguage = L10n.shared.language) -> String {
        guard let url = Bundle.main.url(forResource: "Port", withExtension: "strings", subdirectory: language.rawValue + ".lproj"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return key }
        return values[key] ?? key
    }
}
