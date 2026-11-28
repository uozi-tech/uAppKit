import SwiftUI

/// uTerm DesignKit 开关 —— 设计稿 `Components.html` 开关组件。
///
/// `UDToggle` 是 `Button(.plain)` 包装的 on/off 拨动开关：40×24 Capsule 轨道，
/// Ø20 白色圆形 knob 在 2px 内边距里左 / 右滑动（`.easeOut(0.2)`）。
/// ON 时轨道填纯 `UD.accent`、无描边、knob 居右；OFF 时填中性 `UD.panelHover` +
/// 1px `UD.border` 细描边（无内阴影），knob 居左。knob 自带投影。
///
/// 通过 `@Environment(\.isEnabled)` 响应 `.disabled()`：整体降透明 ~0.45 且不响应点击。
/// 纯展示组件，只读 `UD` token + `Bool` 绑定，不依赖任何 domain model。
///
/// 辅助功能：对外表现为系统开关（`accessibilityRepresentation` 里放一个 `Toggle`），VoiceOver
/// 读出开 / 关状态，按下即拨动。`label` 是开关的名字；不传时由调用处的 `.accessibilityLabel(_:)`
/// 命名（行内已有文字标题时两者择一即可）。
public struct UDToggle: View {
    @Binding var isOn: Bool
    /// ON 态轨道填充色（默认 `UD.accent`）。AI 介入开关传 `UD.aiAccent` 显紫。
    var tint: Color
    /// 辅助功能里的开关名字，不显示在界面上。
    var label: Text?

    public init(_ isOn: Binding<Bool>, label: Text? = nil, tint: Color = UD.accentDefault) {
        self._isOn = isOn
        self.label = label
        self.tint = tint
    }

    @Environment(\.isEnabled) private var isEnabled

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                track
                knob
                    .padding(2)   // knob 在 2px 内边距里滑动（含上下，故 20+2+2=24 撑满轨道高）
            }
            .frame(width: 40, height: 24)
            .animation(.easeOut(duration: 0.2), value: isOn)
        }
        .buttonStyle(.udPlain)
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) { label ?? Text(verbatim: "") }
        }
    }

    // MARK: - 轨道

    private var track: some View {
        // v2「填充即边界」：OFF 态 uw10 中性灰填充、无描边无 inset；ON 态纯强调色填充。
        Capsule()
            .fill(isOn ? tint : UD.uw10)
            .clipShape(Capsule())
    }

    // MARK: - knob

    private var knob: some View {
        // 旋钮：v2 无描边；阴影四周均匀发散（无 y 偏移），见 `knobShadow()`。
        Circle()
            .fill(.white)
            .frame(width: 20, height: 20)
            .knobShadow()
    }
}

// MARK: - Preview

#Preview {
    struct Demo: View {
        @State private var off = false
        @State private var on = true
        @State private var disOff = false
        @State private var disOn = true
        @State private var hotReload = true

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                row("off", $off)
                row("on", $on)
                row("disabled-off", $disOff, disabled: true)
                row("disabled-on", $disOn, disabled: true)

                Rectangle().fill(UD.border).frame(height: 1)

                // 设置行示例
                HStack {
                    Text("热加载")
                        .font(UD.font(13))
                        .foregroundStyle(UD.text)
                    Spacer()
                    UDToggle($hotReload)
                }
            }
            .padding(24)
            .frame(width: 300, alignment: .leading)
            .background(UD.bg)
        }

        private func row(_ label: String, _ binding: Binding<Bool>, disabled: Bool = false) -> some View {
            HStack(spacing: 12) {
                Text(label)
                    .font(UD.caption)
                    .foregroundStyle(UD.text3)
                    .frame(width: 110, alignment: .leading)
                UDToggle(binding)
                    .disabled(disabled)
            }
        }
    }

    return Demo()
}
