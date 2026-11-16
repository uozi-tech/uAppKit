// macOS 专用：整份文件用平台条件包住，理由同 `PointerDownProbe.swift`。
#if os(macOS)

import AppKit
import SwiftUI

// 跨屏拖窗口时窗口与光标错位的两处修正。uTable、uTerm 原先各有一份逐字相同的实现
// （uTable `UTableWindowChrome.swift`、uTerm `WorkspaceChrome.swift`），uGit 也要用，故收进这里。

/// 关掉 AppKit 的「窗口移动时按屏幕布局调整位置」。
///
/// 这个配置默认开启：窗口换屏时，AppKit 经 `-[NSWindow _setFrameAfterMove:]` →
/// `_adjustWindowFrame:forMoveFromScreen:toScreen:` 把窗口挪到它在目标屏记住的位置。
/// 用户正在拖动时也一样，而系统拖动按增量继续，光标与窗口的相对位置就一直错开，严重时
/// 光标落到窗口外。AppKit 首次用到时才读取并缓存，所以要在创建任何窗口之前调用
/// （`App.init` 里第一件事）。
///
/// 写的是注册域（`register(defaults:)`），不进用户的偏好文件；key 名是 AppKit 自己读的，不能改。
public enum WindowMoveBehavior {
    public nonisolated static let screenLayoutAdjustKey = "NSScreenLayoutAdjustOnWindowMove"

    public nonisolated static func disableScreenLayoutAdjustment(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [screenLayoutAdjustKey: false])
    }
}

/// 把窗口顶部的系统标题栏带从 WindowServer 的拖动区里摘掉，窗口只能经 app 自绘标题栏上的拖动手势
/// （uTable 的 `WindowDragGesture`、uTerm 的 `WindowDragHandle`）拖动。必须挂在窗口根视图的最外层
/// （比 `.background` 铺的底色更靠外）。
///
/// 原生标签栏可见时不摘（`isActive = false`）：这时内容整个退到标题栏和标签栏下面，系统标题栏带上
/// 没有自绘标题栏，也就没有手势，只能继续靠 WindowServer 拖；它也不和手势重叠，不会双重开始。
///
/// 不摘的后果：透明标题栏的顶部约 32pt 归 WindowServer 管，按下就开始移窗，早于手势 / mouseDown。
/// 手势（或手柄的 `performDrag`）再叠上来，AppKit 收不到拖动开始（日志里的 `Window move completed
/// without beginning`），于是拖动中每约 100ms 把旧位置约束后写回窗口。快速跨屏时这一下写回
/// 把窗口拽开，之后系统按增量继续拖，光标和窗口的相对位置就永久错开了。
///
/// 为什么不靠标题栏自己的可命中内容：SwiftUI 把窗口里所有可命中内容的并集当防拖动区，这个
/// 并集一旦包含整个窗口（`NSHostingView` 的 `preventionRegionCoversEntireWindow`），结果
/// 就作废、按「没有防拖动区」处理。窗口铺满了可命中内容时正好触发。这里在根部直接声明这个类别的
/// 形状，子视图不再参与并集，判断也就不会触发。
///
/// `0x100` 是 `ContentShapeKinds.windowDragPreventionUnderTitlebar` 的值（私有符号，macOS
/// 27.2 实测），用的是公开的 `init(rawValue:)`。系统改了这个值只会退回旧的跳动，不会崩；
/// `WindowDragRegionTests` 会报出来。
public struct TitlebarDragRegion: ViewModifier {
    private static let preventionUnderTitlebar = ContentShapeKinds(rawValue: 0x100)

    public var isActive: Bool

    public init(isActive: Bool = true) {
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        // 用同一个形状的空路径表达「不摘」，切换标签栏时不换视图身份。
        content.contentShape(Self.preventionUnderTitlebar, Band(isActive: isActive))
    }

    /// 根视图的坐标从安全区顶部算起，标题栏带在 y < 0 那一侧。往上多留足够高度，往下多盖
    /// 10pt 防标题栏高度有出入；形状只影响拖动区，不影响点击。
    private nonisolated struct Band: Shape {
        let isActive: Bool

        nonisolated func path(in rect: CGRect) -> Path {
            guard isActive else { return Path() }
            return Path(CGRect(x: 0, y: -100, width: rect.width, height: 110))
        }
    }
}

extension View {
    /// `TitlebarDragRegion` 的便捷写法。
    public func titlebarDragRegion(isActive: Bool = true) -> some View {
        modifier(TitlebarDragRegion(isActive: isActive))
    }
}

#endif
