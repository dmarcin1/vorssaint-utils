// SPDX-License-Identifier: GPL-3.0-or-later
// Finder menu integration derived from RightSight's thin FinderSync architecture.
import Foundation
import CryptoKit

enum FinderMenuContract {
    #if VORSSAINT_DEVELOPMENT
    static let domain = "com.vorssaint.utils.dev"
    static let scheme = "vorssaint-dev-finder"
    #else
    static let domain = "com.vorssaint.utils"
    static let scheme = "vorssaint-finder"
    #endif
    static let settingsKey = "finderMenuConfiguration"
    static let configurationKey = "menuConfiguration"
    static let authenticationKey = "menuAuthenticationKey"
    static var isPreferencesAvailable: Bool { !domain.isEmpty }
    static func readKey() -> Data? {
        guard let value = CFPreferencesCopyValue(authenticationKey as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return nil }
        guard let data = value as? Data, data.count == 32 else { return nil }
        return data
    }
    static func readConfiguration() -> Configuration? {
        guard let value = CFPreferencesCopyValue(configurationKey as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return nil }
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(Configuration.self, from: data)
    }
    static func writeKey(_ key: Data) -> Bool {
        CFPreferencesSetValue(authenticationKey as CFString, key as CFData, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    static func writeConfigurationData(_ data: Data) -> Bool {
        CFPreferencesSetValue(configurationKey as CFString, data as CFData, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    struct Item: Codable, Identifiable {
        var id = UUID().uuidString
        var name: String
        var path: String
        var arguments: [String] = []
        var environment: [String: String] = [:]
        var content: Data? = nil
    }
    struct Action: Codable, Identifiable {
        var id: String
        var enabled = true
    }
    enum FinderTemplatePresets {
        static let docxBase64 = "UEsDBBQAAAAIAM66X13XeYTq8QAAALgBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbH2QzU7DMBCE730Ky9cqccoBIZSkB36OwKE8wMreJFb9J69b2rdn00KREOVozXwz62nXB+/EHjPZGDq5qhspMOhobBg7+b55ru6koALBgIsBO3lEkut+0W6OCUkwHKiTUynpXinSE3qgOiYMrAwxeyj8zKNKoLcworppmlulYygYSlXmDNkvhGgfcYCdK+LpwMr5loyOpHg4e+e6TkJKzmoorKt9ML+Kqq+SmsmThyabaMkGqa6VzOL1jh/0lSfK1qB4g1xewLNRfcRslIl65xmu/0/649o4DFbjhZ/TUo4aiXh77+qL4sGG71+06jR8/wlQSwMEFAAAAAgAzrpfXSAbhuqyAAAALgEAAAsAAABfcmVscy8ucmVsc43Puw6CMBQG4J2naM4uBQdjDIXFmLAafICmPZRGeklbL7y9HRzEODie23fyN93TzOSOIWpnGdRlBQStcFJbxeAynDZ7IDFxK/nsLDJYMELXFs0ZZ57yTZy0jyQjNjKYUvIHSqOY0PBYOo82T0YXDE+5DIp6Lq5cId1W1Y6GTwPagpAVS3rJIPSyBjIsHv/h3ThqgUcnbgZt+vHlayPLPChMDB4uSCrf7TKzQHNKuorZvgBQSwMEFAAAAAgAzrpfXZ/dzJKSAAAAswAAABEAAAB3b3JkL2RvY3VtZW50LnhtbDWNQQ7CIBBF9z0Fmb2lujCmKXTnCfQACGNtUmYIg9beXkx09f/PT94bxndc1AuzzEwG9m0HCslzmGkycL2cdydQUhwFtzChgQ0FRtsMax/YPyNSUZVA0q8GHqWkXmvxD4xOWk5I9btzjq7UmSe9cg4ps0eRKoiLPnTdUUc3E9hGqUq9cdhszaTtoH+z+ba/zn4AUEsBAhQDFAAAAAgAzrpfXdd5hOrxAAAAuAEAABMAAAAAAAAAAAAAAIABAAAAAFtDb250ZW50X1R5cGVzXS54bWxQSwECFAMUAAAACADOul9dIBuG6rIAAAAuAQAACwAAAAAAAAAAAAAAgAEiAQAAX3JlbHMvLnJlbHNQSwECFAMUAAAACADOul9dn93MkpIAAACzAAAAEQAAAAAAAAAAAAAAgAH9AQAAd29yZC9kb2N1bWVudC54bWxQSwUGAAAAAAMAAwC5AAAAvgIAAAAA"
        static let xlsxBase64 = "UEsDBBQAAAAIAM66X125mqGQAQEAADsCAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbK1RyU7DMBC99yssX6vYKQeEUJIeWI7AoXzA4EwSK97kcUv69zgpi4Qo4sBpNHqrZqrtZA07YCTtXc03ouQMnfKtdn3Nn3f3xRVnlMC1YLzDmh+R+LZZVbtjQGJZ7KjmQ0rhWkpSA1og4QO6jHQ+Wkh5jb0MoEboUV6U5aVU3iV0qUizB29WjFW32MHeJHY3ZeTUJaIhzm5O3Dmu5hCC0QpSxuXBtd+CivcQkZULhwYdaJ0JXJ4LmcHzGV/Sx3yiqFtkTxDTA9hMlJORrz6OL96P4nefH7r6rtMKW6/2NksEhYjQ0oCYrBHLFBa0W/+pwsInuYzNP3f59P+oUsnl980bUEsDBBQAAAAIAM66X11dh/QutAAAACwBAAALAAAAX3JlbHMvLnJlbHONz78OgjAQBvCdp2hul4KDMYbCYkxYDT5ALcefUHpNWxXe3o5iHBwvd9/v8hXVMmv2ROdHMgLyNAOGRlE7ml7ArbnsjsB8kKaVmgwKWNFDVSbFFbUMMeOH0XoWEeMFDCHYE+deDThLn5JFEzcduVmGOLqeW6km2SPfZ9mBu08DyoSxDcvqVoCr2xxYs1r8h6euGxWeST1mNOHHl6+LKEvXYxCwaP4iN92JpjSiwGNHvilZvgFQSwMEFAAAAAgAzrpfXfVgA4K3AAAALQEAABoAAAB4bC9fcmVscy93b3JrYm9vay54bWwucmVsc43PzQrCMAwH8PueouTusnkQkXW7iLCrzAcoXfaBW1ua+rG3t3gQBx48hSTkF/5F9ZwncSfPozUS8jQDQUbbdjS9hEtz2uxBcFCmVZM1JGEhhqpMijNNKsQbHkbHIiKGJQwhuAMi64Fmxal1ZOKms35WIba+R6f0VfWE2yzbof82oEyEWLGibiX4us1BNIujf3jbdaOmo9W3mUz48QUf1l95IAoRVb6nIOEzYnyXPI0qYAyJq5TlC1BLAwQUAAAACADOul9dgCz2JMEAAAAgAQAADwAAAHhsL3dvcmtib29rLnhtbI1PQU7DMBC85xXW3qkTDghFjntBSD0DDzDxprEa70a7poXf4xJ672lmNZrZGbf/zos5o2hiGqDbtWCQRo6JjgN8vL8+PIPREiiGhQkH+EGFvW/cheX0yXwy1U86wFzK2lur44w56I5XpKpMLDmUesrR6ioYos6IJS/2sW2fbA6JYEvo5Z4MnqY04guPXxmpbCGCSyi1vc5pVfCNMe7vifoNDYVci79deVfHXPEQ61Yw0qdK5BA7sN7Zf1vj7G2d/wVQSwMEFAAAAAgAzrpfXQea6KKEAAAAnQAAABgAAAB4bC93b3Jrc2hlZXRzL3NoZWV0MS54bWw9jEsOwjAMBfecIvKeurBACCXppuIEcACrMU1F41RxxOf2VF2wnDd6Y7tPms2Li05ZHByaFgzLkMMko4P77bo/g9FKEmjOwg6+rND5nX3n8tTIXM0aEHUQa10uiDpETqRNXlhW88glUV2xjKhLYQrbKc14bNsTJpoEvN22niqht/gv+x9QSwECFAMUAAAACADOul9duZqhkAEBAAA7AgAAEwAAAAAAAAAAAAAAgAEAAAAAW0NvbnRlbnRfVHlwZXNdLnhtbFBLAQIUAxQAAAAIAM66X11dh/QutAAAACwBAAALAAAAAAAAAAAAAACAATIBAABfcmVscy8ucmVsc1BLAQIUAxQAAAAIAM66X131YAOCtwAAAC0BAAAaAAAAAAAAAAAAAACAAQ8CAAB4bC9fcmVscy93b3JrYm9vay54bWwucmVsc1BLAQIUAxQAAAAIAM66X12ALPYkwQAAACABAAAPAAAAAAAAAAAAAACAAf4CAAB4bC93b3JrYm9vay54bWxQSwECFAMUAAAACADOul9dB5roooQAAACdAAAAGAAAAAAAAAAAAAAAgAHsAwAAeGwvd29ya3NoZWV0cy9zaGVldDEueG1sUEsFBgAAAAAFAAUARQEAAKYEAAAAAA=="
        static let pptxBase64 = "UEsDBBQAAAAIAM66X11NR4pI7wAAAL0BAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbH2QzU7DMBCE730Ka68odsoBIZSkBwpH4FAeYOVsEgv/yd5W7dvjpCB+RDmu5puZ3W02R2fFgVI2wbewljUI8jr0xo8tvO4eq1sQmdH3aIOnFk6UYdOtmt0pUhbF7HMLE3O8UyrriRxmGSL5ogwhOeQyplFF1G84krqu6xulg2fyXPGcAd1KiGZLA+4ti4djUc67JLIZxP2ZnetawBit0chFVwff/yqqPkpkcS5MnkzMVwUAdalkFi93fFmfy4uS6Um8YOIndAVUMbKKiXKxLrj8P+yPhcMwGE190HtXLPJ7mLM/RunQ+M9TGrV8v3sHUEsDBBQAAAAIAM66X1062VMktAAAADEBAAALAAAAX3JlbHMvLnJlbHONz80KwjAMB/D7nqLk7rp5EBG7XUTYVeYDlDbrhusHTRX39hZPTjx4TPLPL+TYPu3MHhhp8k5AXVbA0CmvJ2cEXPvzZg+MknRazt6hgAUJ2qY4XnCWKe/QOAViGXEkYEwpHDgnNaKVVPqALk8GH61MuYyGB6lu0iDfVtWOx08DmoKxFcs6LSB2ugbWLwH/4f0wTApPXt0tuvTjylciyzIaTAJCSDxEpNx8p8ssA8+P8tWnzQtQSwMEFAAAAAgAzrpfXUaSCv6GAAAAqwAAABQAAABwcHQvcHJlc2VudGF0aW9uLnhtbFWNQQrCMBBF954izN5OdSFSmnQnCC71AKEZ20IyCZlB9PZmqcvP470/Tu8UzYuqbJktHLoeDPGcw8aLhcf9sj+DEfUcfMxMFj4kMLndWIZSSYjVazNNq7AMxcKqWgZEmVdKXrpciBt75pq8tlkX/PVSxGPfnzD5jcG1qMRwDTdRdCP+X7gvUEsBAhQDFAAAAAgAzrpfXU1HikjvAAAAvQEAABMAAAAAAAAAAAAAAIABAAAAAFtDb250ZW50X1R5cGVzXS54bWxQSwECFAMUAAAACADOul9dOtlTJLQAAAAxAQAACwAAAAAAAAAAAAAAgAEgAQAAX3JlbHMvLnJlbHNQSwECFAMUAAAACADOul9dRpIK/oYAAACrAAAAFAAAAAAAAAAAAAAAgAH9AQAAcHB0L3ByZXNlbnRhdGlvbi54bWxQSwUGAAAAAAMAAwC8AAAAtQIAAAAA"
        static let pdfBase64 = "JVBERi0xLjQKMSAwIG9iajw8L1R5cGUvQ2F0YWxvZy9QYWdlcyAyIDAgUj4+ZW5kb2JqCjIgMCBvYmo8PC9UeXBlL1BhZ2VzL0NvdW50IDEvS2lkc1szIDAgUl0+PmVuZG9iagozIDAgb2JqPDwvVHlwZS9QYWdlL01lZGlhQm94WzAgMCA2MTIgNzkyXS9QYXJlbnQgMiAwIFIvUmVzb3VyY2VzPDw+Pj4+ZW5kb2JqCnhyZWYKMCA0CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAwOSAwMDAwMCBuIAowMDAwMDAwMDUyIDAwMDAwIG4gCjAwMDAwMDAxMDEgMDAwMDAgbiAKdHJhaWxlcjw8L1NpemUgNC9Sb290IDEgMCBSPj4Kc3RhcnR4cmVmCjE3OAolJUVPRgo="

        static func defaultTemplates() -> [Item] {
            return [
                Item(id: "preset-word", name: "Word 文档", path: "docx", content: Data(base64Encoded: docxBase64)),
                Item(id: "preset-excel", name: "Excel 工作表", path: "xlsx", content: Data(base64Encoded: xlsxBase64)),
                Item(id: "preset-ppt", name: "PowerPoint 演示文稿", path: "pptx", content: Data(base64Encoded: pptxBase64)),
                Item(id: "preset-pdf", name: "PDF 文档", path: "pdf", content: Data(base64Encoded: pdfBase64)),
                Item(id: "preset-txt", name: "文本文档", path: "txt", content: Data()),
                Item(id: "preset-md", name: "Markdown", path: "md", content: Data())
            ]
        }
    }
    struct Configuration: Codable {
        var enabled = false
        var collapsed = true
        var actions = ["copy-path", "delete-direct", "hide", "unhide", "airdrop", "cut-files", "paste-files", "copy-to", "move-to", "convert-images"].map { Action(id: $0) }
        var applications: [Item] = []
        var templates: [Item] = FinderTemplatePresets.defaultTemplates()
        var directories: [Item] = []
        var labels: [String: String] = [:]
        var canCutPaste = true
        var canConvert = true
    }
    struct Request: Codable {
        var id = UUID()
        var timestamp = Date().timeIntervalSince1970
        let action: String
        let paths: [String]
        let directory: String
        var container = false
    }
    struct Envelope: Codable {
        let message: Data
        let signature: Data
        init(request: Request, key: Data) throws {
            message = try JSONEncoder().encode(request)
            signature = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        }
        func verified(key: Data, now: Double) -> Request? {
            guard message.count < 131072,
                  HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: message, using: SymmetricKey(data: key)),
                  let request = try? JSONDecoder().decode(Request.self, from: message),
                  abs(now - request.timestamp) < 30,
                  request.paths.count <= 200,
                  request.paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
                  (request.directory.isEmpty && !request.paths.isEmpty) || (request.directory.hasPrefix("/") && !request.directory.contains("\0")) else { return nil }
            return request
        }
    }
}
