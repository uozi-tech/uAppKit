import Foundation

extension UFormat {
    /// 修饰键符号（按 macOS 菜单的顺序列出，只用于识别，不重排）。
    static let shortcutModifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘", "🌐"]

    /// 快捷键标签：修饰键之间、修饰键与主键之间加空格，`⌥⌘O` → `⌥ ⌘ O`。
    ///
    /// 等宽小字号下 `⌥⌘O` 会糊成一团；只拆开开头的修饰键符号，主键原样保留
    /// （`esc`、`Tab`、`F12`、`↩` 不会被拆成单个字母）。已带空格的输入结果不变。
    public nonisolated static func shortcut(_ label: String) -> String {
        let compact = label.filter { !$0.isWhitespace }
        var parts: [String] = []
        var rest = Substring(compact)
        while let first = rest.first, shortcutModifiers.contains(first), rest.count > 1 {
            parts.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts.joined(separator: " ")
    }
}
