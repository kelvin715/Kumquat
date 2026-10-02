import Foundation
import KumquatCore

/// English is the source language; Simplified Chinese comes from `LocalizedStrings`.
func L(_ english: String) -> String {
    L10n.usesChinese ? (LocalizedStrings.chinese[english] ?? english) : english
}

enum L10n {
    /// Read straight from UserDefaults so it works from any thread.
    static var usesChinese: Bool {
        switch UserDefaults.standard.string(forKey: "language") {
        case AppSettings.Language.english.rawValue?: return false
        case AppSettings.Language.chinese.rawValue?: return true
        default: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }

    static func title(for action: WheelAction) -> String {
        switch action {
        case .convert(let format): return format.title
        case .tool(let tool): return usesChinese ? (toolNames[tool] ?? tool.title) : tool.title
        }
    }

    static let toolNames: [ToolKind: String] = [
        .compress: "压缩", .metadata: "元数据", .edit: "编辑", .annotate: "标注", .addBackground: "加背景",
        .crop: "裁剪", .redact: "打码", .rotate: "旋转", .split: "拆分", .merge: "合并", .watermark: "水印",
        .trim: "剪辑", .mute: "静音", .snapshot: "截帧",
    ]

    static func fileCount(_ n: Int) -> String {
        usesChinese ? "\(n) 个文件" : (n == 1 ? "1 file" : "\(n) files")
    }

    static func progress(_ done: Int, of total: Int) -> String {
        usesChinese ? "已保存 \(done)/\(total)" : "\(done) of \(total) saved"
    }
}
