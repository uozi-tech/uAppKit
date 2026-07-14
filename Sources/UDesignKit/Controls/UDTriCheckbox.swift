import SwiftUI

/// 三态。`on` 全选 / `part` 部分（派生/半授权）/ `off` 未选。
public enum UDTriState { case on, part, off }

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
    let action: () -> Void

    public init(
        state: UDTriState,
        size: CGFloat = 22,
        tint: Color = UD.accentDefault,
        action: @escaping () -> Void
    ) {
        self.state = state
        self.size = size
        self.tint = tint
        self.action = action
    }

    // 说明：不内置 `isEnabled` 降透明。权限网格的「禁用」视觉是**调用方**按派生/锁定
    // 语义显式驱动的（locked-but-editable 0.55、readonly-and-off 0.55、其余 1），远比二值
    // isEnabled 细腻；`.disabled()` 交给原生 Button 拦点击即可。内置降透明会与外挂 .opacity
    // 叠乘（禁用格子误变 ~0.30）。
    private var radius: CGFloat { size * 0.27 }

    public var body: some View {
        Button(action: action) {
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
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    func demo(_ scheme: ColorScheme) -> some View {
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
