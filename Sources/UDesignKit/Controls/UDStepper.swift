import SwiftUI

/// uTerm DesignKit 步进器 —— 设计稿 v2「填充即边界」数值步进控件。
///
/// 替代原生 `Stepper`：`UD.uw04` 淡灰底**连体胶囊**，左「−」右「+」两个等宽按钮，
/// 中缝 1px 竖分隔（相邻两半共用容器底，无描边）；到达 `range` 边界时对应半侧文字
/// 置灰 `UD.text4` 且不可点。仅切底色，无位移、无投影。
/// 与原生 `Stepper` 一样只是「加减控件」本体，当前数值文本由调用方相邻展示。
///
/// 纯展示组件，只读 `UD` token + 值绑定，不依赖任何 domain model。
public struct UDStepper<V: Strideable>: View {
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride

    public init(value: Binding<V>, in range: ClosedRange<V>, step: V.Stride = 1) {
        self._value = value
        self.range = range
        self.step = step
    }

    @Environment(\.isEnabled) private var isEnabled

    private var canDec: Bool { value > range.lowerBound }
    private var canInc: Bool { value < range.upperBound }

    public var body: some View {
        HStack(spacing: 0) {
            half(system: "minus", enabled: canDec) {
                value = max(range.lowerBound, value.advanced(by: -step))
            }
            Rectangle()
                .fill(UD.border)
                .frame(width: 1)
                .padding(.vertical, 6)
            half(system: "plus", enabled: canInc) {
                value = min(range.upperBound, value.advanced(by: step))
            }
        }
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous).fill(UD.uw04)
        }
        .clipShape(RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous))
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
    }

    private func half(system: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(UDStepperHalfStyle(enabled: enabled))
        .disabled(!enabled)
    }
}

/// 步进器单侧按钮样式：透明底 idle，hover `uw05` / 按下 `uw06`，禁用文字置灰。
private struct UDStepperHalfStyle: ButtonStyle {
    let enabled: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed && enabled
        let hover = hovering && enabled
        let text: Color = !enabled ? UD.text4 : ((hover || down) ? UD.text : UD.text2)
        let bg: Color = down ? UD.uw06 : (hover ? UD.uw05 : .clear)
        return configuration.label
            .foregroundStyle(text)
            .frame(width: 30, height: 28)
            .background(bg)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Preview

#Preview {
    struct Demo: View {
        @State private var length = 255
        @State private var precision = 10
        @State private var atMin = 0
        @State private var atMax = 8

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                row("长度", value: length) { UDStepper(value: $length, in: 0...255) }
                row("精度", value: precision) { UDStepper(value: $precision, in: 0...38) }
                row("到下界", value: atMin) { UDStepper(value: $atMin, in: 0...8) }
                row("到上界", value: atMax) { UDStepper(value: $atMax, in: 0...8) }
                row("禁用", value: length) { UDStepper(value: $length, in: 0...255).disabled(true) }
            }
            .padding(24)
            .frame(width: 320, alignment: .leading)
            .background(UD.bg)
        }

        private func row<S: View>(_ label: String, value: Int, @ViewBuilder _ stepper: () -> S) -> some View {
            HStack(spacing: 12) {
                Text(label).font(UD.caption).foregroundStyle(UD.text3)
                    .frame(width: 56, alignment: .leading)
                Text("\(value)").font(UD.mono(12)).foregroundStyle(UD.text)
                    .frame(width: 40, alignment: .trailing)
                stepper()
            }
        }
    }
    return HStack(spacing: 0) {
        Demo().environment(\.colorScheme, .dark)
        Demo().environment(\.colorScheme, .light)
    }
}
