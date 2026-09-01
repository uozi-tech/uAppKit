import SwiftUI

/// 「本面板是不是当前那一个」的信号 —— 前台标签，且它所在的组是活动组。
///
/// **传的是一个身份稳定的对象，不是 Bool。** 直接把 `Bool` 写进环境的话，值一变
/// SwiftUI 就重建整棵子树的环境节点：uTable 实测「点进另一个编辑组」这种什么都
/// 没改的操作要 80–160ms（数据网格整块重算），切标签同理。对象身份不变、翻转的
/// 只是它的 `@Observable` 属性，于是只有真正在 body 里读它的视图才失效 —— 而典型
/// 读点都在通知 / 事件回调里（运行时读，不建依赖），切活动面板因此降到 ~0。
///
/// **为什么必须有这个 gate（不只是性能）。** 因为所有标签都挂着，`⌘S 保存` /
/// `⌘R 刷新` / undo / redo 这类**广播**通知会打到隐藏面板上；处理器必须 gate 在
/// 这个值上，只让可见面板动手。
@MainActor
@Observable
public final class ActivePaneGate {
    public var isActive: Bool

    public init(isActive: Bool) {
        self.isActive = isActive
    }
}

private struct ActivePaneGateKey: EnvironmentKey {
    // 计算属性而非 `static let`：`ActivePaneGate` 是 @MainActor 类型，
    // 存储型静态属性在 Swift 6 里过不了并发检查。
    static var defaultValue: ActivePaneGate? { nil }
}

extension EnvironmentValues {
    /// `UPaneGroupArea` 为每个已挂载面板注入的活动态门。`nil` 表示宿主只挂活动
    /// 面板（「已挂载」本身就等于「活动」）。
    public var activePaneGate: ActivePaneGate? {
        get { self[ActivePaneGateKey.self] }
        set { self[ActivePaneGateKey.self] = newValue }
    }
}

#if os(macOS)
import AppKit

/// 保活面板被隐藏时的 first responder 清理。
public enum UPaneFocusRelease {
    /// 保活的面板在被隐藏时**仍持有 AppKit first responder**，不放掉的话键盘会
    /// 打进一个看不见的编辑器 / 数据网格。切标签时把**内容编辑器**
    /// （`NSTableView`、非 field-editor 的 `NSTextView`）的 first responder 交还
    /// `nil`；field editor（侧栏筛选框、AI 输入框那种 `NSTextField` 的编辑器）不动
    /// —— 那些不住在面板里，收走它们的焦点等于用户打一半字被打断。
    @MainActor
    public static func releaseHiddenEditorFocus() {
        guard let window = NSApp.keyWindow, let responder = window.firstResponder else { return }
        let isContentEditor = responder is NSTableView
            || ((responder as? NSTextView).map { !$0.isFieldEditor } ?? false)
        if isContentEditor { window.makeFirstResponder(nil) }
    }
}
#endif
