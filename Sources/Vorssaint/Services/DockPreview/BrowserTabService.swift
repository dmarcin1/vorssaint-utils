// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import AppKit

enum BrowserTabService {
    private static let supportedChromiumBundles: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser"
    ]

    private static let supportedSafariBundles: Set<String> = [
        "com.apple.Safari"
    ]

    static func isSupportedBrowser(bundleID: String) -> Bool {
        supportedChromiumBundles.contains(bundleID) || supportedSafariBundles.contains(bundleID)
    }

    /// Fetches all tabs for the given browser and returns them as SwitcherItem entries.
    static func fetchTabs(for bundleID: String, pid: pid_t, windows: [SwitcherItem]) -> [SwitcherItem] {
        guard isSupportedBrowser(bundleID: bundleID) else { return [] }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return [] }
        let appName = app.localizedName ?? "Browser"

        let isSafari = supportedSafariBundles.contains(bundleID)
        let scriptSource = isSafari ? safariTabScript() : chromiumTabScript(bundleID: bundleID)

        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: scriptSource) else { return [] }
        let result = script.executeAndReturnError(&errorDict)
        guard errorDict == nil, let text = result.stringValue, !text.isEmpty else { return [] }

        var tabs: [SwitcherItem] = []
        let lines = text.components(separatedBy: "\n")
        let primaryFrame = windows.first?.frame ?? .zero
        let primaryWindowID = windows.first?.windowID ?? 0

        var asWindowOrder: [String] = []
        for line in lines where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            if !parts.isEmpty && !asWindowOrder.contains(parts[0]) {
                asWindowOrder.append(parts[0])
            }
        }

        for line in lines where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let windowIDStr = parts[0]
            guard let tabIndex = Int(parts[1]) else { continue }
            let rawTitle = parts[2]
            let rawURL = parts.count >= 4 ? parts[3] : ""
            let isActive = parts.count >= 5 ? (parts[4].trimmingCharacters(in: .whitespacesAndNewlines) == "1") : (tabIndex == 1)

            let title = rawTitle.isEmpty ? (rawURL.isEmpty ? "新标签页" : rawURL) : rawTitle
            let winIdx = asWindowOrder.firstIndex(of: windowIDStr) ?? 0
            let matchedWindow = winIdx < windows.count ? windows[winIdx] : windows.first
            let actualWindowID = matchedWindow?.windowID ?? primaryWindowID
            let actualFrame = matchedWindow?.frame ?? primaryFrame

            let item = SwitcherItem.tab(
                windowID: actualWindowID,
                title: title,
                appName: appName,
                pid: pid,
                tabIndex: tabIndex,
                tabWindowID: windowIDStr,
                tabURL: rawURL,
                frame: actualFrame,
                isTabActive: isActive
            )
            tabs.append(item)
            if tabs.count >= 16 { break } // Cap at reasonable number for UI display
        }

        return tabs
    }

    static func activateTab(bundleID: String, windowID: String, tabIndex: Int) {
        let isSafari = supportedSafariBundles.contains(bundleID)
        let scriptSource = isSafari
            ? """
              tell application "Safari"
                  repeat with w in windows
                      if (id of w as string) is equal to "\(windowID)" then
                          set current tab of w to tab \(tabIndex) of w
                          set index of w to 1
                          activate
                          exit repeat
                      end if
                  end repeat
              end tell
              """
            : """
              tell application id "\(bundleID)"
                  repeat with w in windows
                      if (id of w as string) is equal to "\(windowID)" then
                          set active tab index of w to \(tabIndex)
                          set index of w to 1
                          activate
                          exit repeat
                      end if
                  end repeat
              end tell
              """

        DispatchQueue.global(qos: .userInitiated).async {
            var errorDict: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(&errorDict)
            }
        }
    }

    static func closeTab(bundleID: String, windowID: String, tabIndex: Int) {
        let isSafari = supportedSafariBundles.contains(bundleID)
        let scriptSource = isSafari
            ? """
              tell application "Safari"
                  repeat with w in windows
                      if (id of w as string) is equal to "\(windowID)" then
                          close tab \(tabIndex) of w
                          exit repeat
                      end if
                  end repeat
              end tell
              """
            : """
              tell application id "\(bundleID)"
                  repeat with w in windows
                      if (id of w as string) is equal to "\(windowID)" then
                          close tab \(tabIndex) of w
                          exit repeat
                      end if
                  end repeat
              end tell
              """

        DispatchQueue.global(qos: .userInitiated).async {
            var errorDict: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(&errorDict)
            }
        }
    }

    private static func chromiumTabScript(bundleID: String) -> String {
        """
        tell application id "\(bundleID)"
            set res to ""
            repeat with w in windows
                set wId to (id of w as string)
                set aIndex to 1
                try
                    set aIndex to (active tab index of w as integer)
                end try
                set tIndex to 1
                repeat with t in tabs of w
                    set isActive to "0"
                    if tIndex is equal to aIndex then
                        set isActive to "1"
                    end if
                    set res to res & wId & "\t" & (tIndex as string) & "\t" & (title of t as string) & "\t" & (URL of t as string) & "\t" & isActive & "\n"
                    set tIndex to tIndex + 1
                end repeat
            end repeat
            return res
        end tell
        """
    }

    private static func safariTabScript() -> String {
        """
        tell application "Safari"
            set res to ""
            repeat with w in windows
                set wId to (id of w as string)
                set cTab to current tab of w
                set tIndex to 1
                repeat with t in tabs of w
                    set isActive to "0"
                    if t is cTab then
                        set isActive to "1"
                    end if
                    set res to res & wId & "\t" & (tIndex as string) & "\t" & (name of t as string) & "\t" & (URL of t as string) & "\t" & isActive & "\n"
                    set tIndex to tIndex + 1
                end repeat
            end repeat
            return res
        end tell
        """
    }
}
