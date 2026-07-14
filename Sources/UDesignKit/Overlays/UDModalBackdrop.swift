import SwiftUI
import AppKit

/// 统一的模态背板：半透明遮罩 + 「点外关闭」。所有自绘居中弹层（编辑器 / 删除确认等）
/// 共用，替代各自手搓的 `Color.black.opacity(0.55).ignoresSafeArea().onTapGesture`。
///
/// 关键点：背板的「点外关闭」会等过系统双击间隔（`NSEvent.doubleClickInterval`）后才
/// 武装。这是为了吞掉「触发打开本弹层的那记双击的第二下」——否则：
///
/// - 双击某个按钮（如行内「编辑 / 删除」）打开弹层时，第二下会顺势落到刚铺上来的
///   背板上把它立刻关掉（「开一下又被关掉」）；
/// - 若该按钮所在容器还挂了 `onTapGesture(count: 2)`，那第二下还会同时再触发一次
///   打开闭包，`editing/confirm` 状态在一拍内 value→nil→value 反复横跳、跨越刚插入的
///   overlay，把转场 / AttributeGraph 卡死（端口转发「连点编辑直接卡页面」的根因）。
///
/// 显式「取消」按钮请直接调用其闭包、绕开本背板，不受武装延迟影响。
public struct UDModalBackdrop: View {
    let onDismiss: () -> Void

    @State private var armed = false
    @Environment(\.colorScheme) private var scheme

    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    /// v2 遮罩（设计稿 --u-backdrop）：日间**透明**（弹窗靠阴影浮起，无灰遮罩）；
    /// 夜间 black 35%。透明时仍靠 `contentShape` 承接「点外关闭」。
    private var backdropOpacity: Double { scheme == .dark ? 0.35 : 0 }

    public var body: some View {
        Color.black.opacity(backdropOpacity)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { if armed { onDismiss() } }
            .task {
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
                armed = true
            }
    }
}
