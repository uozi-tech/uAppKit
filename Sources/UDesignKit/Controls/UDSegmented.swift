import SwiftUI

/// uTerm DesignKit 分段控制 —— 设计稿 `Components.html` 分段控制组。
///
/// `DarkSegmented` 的 drop-in 替代：泛型选项（`Value: Hashable`），等宽分段，
/// 选中段 = 纯 `UD.accent` 填充 + 白字（无内高光）；未选段悬停浅底；相邻**均未选**的
/// 两段之间显示 1px 竖分隔。纯展示组件，只读 `UD` token + 普通值输入，不依赖
/// 任何 domain model。
public struct UDSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    let labelFont: Font
    let fillsWidth: Bool

    /// - Parameter fillsWidth: `true` 时撑满父视图给的宽度、各段等分（列表头的筛选这类）；
    ///   默认按内容收紧（最宽那段决定段宽）。
    public init(selection: Binding<Value>,
         options: [(value: Value, label: String)],
         labelFont: Font = UD.font(12, weight: .medium),
         fillsWidth: Bool = false) {
        self._selection = selection
        self.options = options
        self.labelFont = labelFont
        self.fillsWidth = fillsWidth
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                segment(option.value, option.label)
                    .overlay(alignment: .trailing) {
                        if showsDivider(after: index) {
                            Rectangle()
                                .fill(UD.border)
                                .frame(width: 1)
                                .padding(.vertical, 6)
                        }
                    }
            }
        }
        .padding(3)
        .frame(height: 30)
        .background(
            // v2「填充即边界」：容器 uw04 淡灰底、无边（透明描边占位防跳动）；
            // 选中段实心 accent 白字（唯一允许实心 accent 的控件）。
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(UD.uw04)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.clear, lineWidth: 1)
        )
        .fixedSize(horizontal: !fillsWidth, vertical: false)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
    }

    // MARK: - 单段

    private func segment(_ value: Value, _ label: String) -> some View {
        let selected = value == selection
        // 选中瞬切，且不带动画写回 binding（同 NSSegmentedControl）：以前包 `withAnimation`，
        // 动画事务会顺着 binding 传到使用方——分段下面整块内容跟着淡入淡出、新旧叠影，
        // 锚定浮层里内容高度还在插值而窗口已按目标尺寸改 frame，中间几帧被截断；
        // 自身两段的强调色底同时半透明，看着像两段都选中。
        return Button {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { selection = value }
        } label: {
            SegmentLabel(label: label, selected: selected, font: labelFont)
        }
        .buttonStyle(.udPlain)
    }

    /// 仅当第 `index` 段与其右邻段**都未选中**时，显示二者间的竖分隔。
    private func showsDivider(after index: Int) -> Bool {
        guard index + 1 < options.count else { return false }
        let left = options[index].value
        let right = options[index + 1].value
        return left != selection && right != selection
    }
}

// MARK: - 段标签（承载 hover 态）

private struct SegmentLabel: View {
    let label: String
    let selected: Bool
    let font: Font
    @State private var hovering = false

    /// 未选中段的 hover 底。提成常量而非在 body 里现调 `UD.dyn`——理由见 `UD.dyn` 的注释。
    private static let hoverBg = UD.dyn(.white(0.05), .black(0.05))

    public var body: some View {
        Text(label)
            .font(font)
            .foregroundStyle(selected ? Color.white : UD.text2)
            .padding(.horizontal, 16)
            .frame(minWidth: 56)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .background {
                if selected {
                    // 选中段 = 纯强调色填充（无内高光）。
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(UD.accent)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Self.hoverBg)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Preview

#Preview {
    struct Demo: View {
        let scheme: ColorScheme
        @State private var fontChoice = "Monaco"
        @State private var appearance = "深色"
        @State private var viewMode = "分屏"

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                UDSegmented(selection: $fontChoice, options: [
                    (value: "Menlo", label: "Menlo"),
                    (value: "SF Mono", label: "SF Mono"),
                    (value: "Monaco", label: "Monaco"),
                ])
                UDSegmented(selection: $appearance, options: [
                    (value: "浅色", label: "浅色"),
                    (value: "深色", label: "深色"),
                ])
                UDSegmented(selection: $viewMode, options: [
                    (value: "编辑", label: "编辑"),
                    (value: "分屏", label: "分屏"),
                    (value: "预览", label: "预览"),
                ])
            }
            .padding(24)
            .frame(width: 320, alignment: .leading)
            .background(UD.bg)
            .environment(\.colorScheme, scheme)
        }
    }

    return HStack(spacing: 0) {
        Demo(scheme: .dark)
        Demo(scheme: .light)
    }
}
