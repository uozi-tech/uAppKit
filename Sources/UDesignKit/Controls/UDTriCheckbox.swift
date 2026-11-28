import SwiftUI

/// 三态。`on` 全选 / `part` 部分（派生/半授权）/ `off` 未选。
public enum UDTriState { case on, part, off }

/// 点击的承载方式。
///
/// `.button` 是默认，语义最全。`.dense` 用于**成百上千个格子同屏**的授权网格：
/// 视觉完全相同，但不套 `Button`。
///
/// 依据是实测而非偏好（2026-08-31，`DenseGridInteractionCostTests`）：161 行 ×
/// 每行 4 个交互元件、连续滚动 + 数据回填同时施压、8ms 主 runloop 心跳跑 4s（理想
/// 500 拍）——4 个 `Button` 只有 223~233 拍 / 最坏停顿 60ms，同样布局换
/// `onTapGesture` 是 377~379 拍 / 26ms；成本随每行 Button 个数线性增长，1000 行时
/// 4 Button 只剩 26 拍（最坏 561ms，肉眼即卡死）。AX 语义实测免费，所以 `.dense`
/// 手工补回 trait / label，不靠 Button 提供。
public enum UDTriCheckboxInteraction: Sendable {
    case button
    case dense
}

/// uTerm DesignKit 三态勾选块 —— 权限网格「整库→表→列」的授权格子。
///
/// 在 `UDCheckbox`（两态）之上补 `part` 态：`on` = `tint` 实底 + 白勾；
/// `part` = `tint` 22% 底 + 35% 描边 + `tint` 短横（capsule）；`off` = `UD.uw05` 中性底。
/// 用 `state: UDTriState` 值 + `action`（而非 Binding），便于调用方按授权/回收派生下一个态。
/// 22×22（可调）、连续圆角。仅切底/勾，无位移、无投影。
///
/// 纯展示组件，只读 `UD` token + 普通值输入，不依赖任何 domain model。
public struct UDTriCheckbox: View {
    let state: UDTriState
    var size: CGFloat = 22
    var tint: Color = UD.accentDefault
    var interaction: UDTriCheckboxInteraction = .button
    var accessibilityName: String?
    let action: () -> Void

    /// `.dense` 不走 `Button`，`.disabled()` 就不再自动拦点击 —— 得自己读回来。
    @Environment(\.isEnabled) private var isEnabled

    public init(
        state: UDTriState,
        size: CGFloat = 22,
        tint: Color = UD.accentDefault,
        interaction: UDTriCheckboxInteraction = .button,
        accessibilityName: String? = nil,
        action: @escaping () -> Void
    ) {
        self.state = state
        self.size = size
        self.tint = tint
        self.interaction = interaction
        self.accessibilityName = accessibilityName
        self.action = action
    }

    // 说明：不内置 `isEnabled` 降透明。权限网格的「禁用」视觉是**调用方**按派生/锁定
    // 语义显式驱动的（locked-but-editable 0.55、readonly-and-off 0.55、其余 1），远比二值
    // isEnabled 细腻；`.disabled()` 交给原生 Button 拦点击即可。内置降透明会与外挂 .opacity
    // 叠乘（禁用格子误变 ~0.30）。
    private var radius: CGFloat { size * 0.27 }

    public var body: some View {
        switch interaction {
        case .button:
            Button(action: action) { visual }
                .buttonStyle(.udPlain)
                .udRowAwareAccessibilityLabel(accessibilityName.map { Text(verbatim: $0) })
                .accessibilityValue(stateText)
                .accessibilityAddTraits(state == .off ? [] : .isSelected)
        case .dense:
            visual
                // 门控写在闭包里而不是条件挂手势：条件修饰符会改变视图标识，
                // 密集网格里那等于每次状态变化都重建格子。
                .onTapGesture { if isEnabled { action() } }
                .accessibilityElement()
                .udRowAwareAccessibilityLabel(accessibilityName.map { Text(verbatim: $0) })
                .accessibilityValue(stateText)
                .accessibilityAddTraits(state == .off ? .isButton : [.isButton, .isSelected])
        }
    }

    /// 三态读法：`.part` 与 `.on` 都带 `isSelected`，靠值区分「部分选中」。
    private var stateText: Text {
        switch state {
        case .on: Text("已选中", bundle: ModuleBundle.bundle, comment: "三态勾选框的辅助功能状态：全选")
        case .part: Text("部分选中", bundle: ModuleBundle.bundle, comment: "三态勾选框的辅助功能状态：部分选中（派生 / 半授权）")
        case .off: Text("未选中", bundle: ModuleBundle.bundle, comment: "三态勾选框的辅助功能状态：未选")
        }
    }

    private var visual: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(state == .on ? tint
                      : state == .part ? tint.opacity(0.22) : UD.uw05)
                .frame(width: size, height: size)
            if state == .part {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 1)
                    .frame(width: size, height: size)
        }
            switch state {
            case .on:
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            case .part:
                Capsule().fill(tint).frame(width: size * 0.45, height: 1.8)
            case .off:
                EmptyView()
        }
            }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Preview

#Preview {
    @MainActor func demo(_ scheme: ColorScheme) -> some View {
        HStack(spacing: 14) {
            UDTriCheckbox(state: .on) {}
            UDTriCheckbox(state: .part) {}
            UDTriCheckbox(state: .off) {}
            UDTriCheckbox(state: .part) {}.disabled(true)
        }
        .padding(24).background(UD.card).environment(\.colorScheme, scheme)
    }
    return HStack(spacing: 0) { demo(.dark); demo(.light) }
}
