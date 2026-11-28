import SwiftUI

extension View {
    /// 悬停提示 + 读屏名字，名字和提示同一句时不让 VoiceOver 念两遍。
    ///
    /// SwiftUI 的 `.help` 既显示 tooltip，也把同一句报成 AXHelp。图标钮的读屏名字常常就是这句
    /// help（「开启只读模式」），开着「读提示」的 VoiceOver 念完名字、停一下会再念一遍。这里名字与
    /// help 相同时把 AXHelp 清空 —— 只改辅助功能属性，tooltip 由 `.help` 的那层负责，照常显示；
    /// 名字和 help 不同时 help 照常作为提示报出（「拆分分组」+「拆分出一个新分组（⌘\）…」）。
    ///
    /// - Parameters:
    ///   - help: 悬停提示。
    ///   - accessibilityName: 读屏名字；nil 时借 `help`（`help` 也为空就不挂，保留 SwiftUI 推出的名字
    ///     或调用处外挂的 `.accessibilityLabel`）。
    public func udHelp(_ help: String, accessibilityName: String? = nil) -> some View {
        let name = accessibilityName ?? (help.isEmpty ? nil : help)
        // 必须挂在 `.help` 外层：挂在里层会被 `.help` 报的 AXHelp 盖回去。
        return self.help(help)
            .udAccessibilityLabel(name.map { Text(verbatim: $0) })
            .accessibilityHint(Text(verbatim: name == help ? "" : help))
    }
}
