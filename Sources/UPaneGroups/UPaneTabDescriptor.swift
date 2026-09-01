#if os(macOS)
import SwiftUI
import UDesignKit

/// 标签图标：uTable 走自绘 `UIcon` glyph，uTerm 现在全是 SF Symbols。
public enum UPaneTabIcon: Sendable, Hashable {
    case glyph(UIconGlyph)
    case system(String)
    case none
}

/// 一个标签在标签条上怎么画。由调用方按标签算出。
///
/// **求值位置是这套 API 唯一重要的设计点：descriptor 闭包在每个 chip 自己的
/// `body` 里调用，不能在标签条的 body 里先算成数组。**
///
/// 原因是 uTable 已经踩过的那条：让每个面板自己去扫 `queryTabState.tabs`
/// （一个 `@Observable` 属性）会让所有面板都挂在那个数组上，「实测每挂一个数据
/// 网格就多 60ms，开/关任意一个标签都要付」。同一个道理：如果标签条先
/// `tabs.map(descriptor)`，那么 uTerm 预览标签里的 `buffer.isDirty`（`FileBuffer`
/// 的 `@Observable` 属性）一变，**整条标签条**连同所有 chip 一起重算；放进 chip
/// 内求值，则只有那一个 chip 失效。
public struct UPaneTabDescriptor {
    public var title: String
    public var icon: UPaneTabIcon
    /// 图标在 `.active` 态下的着色。nil = 用 `UD.accent`。
    public var accentColor: Color?
    /// 标题前的状态圆点（uTerm 终端标签的连接状态）。nil = 不画。
    public var leadingDot: Color?
    /// 脏标记小圆点（uTerm 预览标签）。
    public var isDirty: Bool
    /// 悬停提示；nil 则用 `title`。
    public var help: String?

    public init(title: String,
                icon: UPaneTabIcon = .none,
                accentColor: Color? = nil,
                leadingDot: Color? = nil,
                isDirty: Bool = false,
                help: String? = nil) {
        self.title = title
        self.icon = icon
        self.accentColor = accentColor
        self.leadingDot = leadingDot
        self.isDirty = isDirty
        self.help = help
    }
}

/// descriptor 里的图标，按 `UPaneTabIcon` 二选一渲染。
struct UPaneTabIconView: View {
    let icon: UPaneTabIcon
    var size: CGFloat = 13

    var body: some View {
        switch icon {
        case .glyph(let glyph):
            UIcon(glyph, size: size)
        case .system(let name):
            Image(systemName: name).font(.system(size: size - 0.5))
        case .none:
            EmptyView()
        }
    }
}
#endif
