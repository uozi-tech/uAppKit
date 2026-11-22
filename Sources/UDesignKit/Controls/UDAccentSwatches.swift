import SwiftUI

/// 强调色选择器 —— 一排 `AccentColor` 色块，绑定 `AccentState.shared`（或任意 Binding）。
///
/// 选中态用色块中央的白色对勾表示，不再画外描边：描边在色块边缘与卡面之间多出一圈
/// 深色框，跟设计语言 v2「有填充就没有描边」冲突，且深色描边在日间显得很重。
public struct UDAccentSwatches: View {
    @Binding var selection: AccentColor
    let size: CGFloat
    let spacing: CGFloat

    public init(selection: Binding<AccentColor>, size: CGFloat = 26, spacing: CGFloat = 9) {
        self._selection = selection
        self.size = size
        self.spacing = spacing
    }

    public var body: some View {
        // 色块之间的间距也归入命中区：每块向四周各让出 spacing/2 作点击范围，
        // 外层再收回同样的量，视觉尺寸与左缘不变。iPhone 上 size 30 + spacing 14 恰好 44pt。
        HStack(spacing: 0) {
            ForEach(AccentColor.allCases) { color in
                Swatch(color: color, selected: color == selection, size: size, inset: spacing / 2) {
                    withAnimation(.easeOut(duration: 0.14)) { selection = color }
                }
            }
        }
        .padding(-spacing / 2)
    }
}

public extension UDAccentSwatches {
    /// 直接绑全局 `AccentState.shared`。
    @MainActor static var shared: UDAccentSwatches {
        UDAccentSwatches(selection: Binding(
            get: { AccentState.shared.selected },
            set: { AccentState.shared.selected = $0 }
        ))
    }
}

private struct Swatch: View {
    let color: AccentColor
    let selected: Bool
    let size: CGFloat
    let inset: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(UD.dyn(color.base(dark: true), color.base(dark: false)))
                .frame(width: size, height: size)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.46, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .brightness(hovering && !selected ? 0.06 : 0)
                .padding(inset)
                .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .onHover { hovering = $0 }
        .help(color.label)
        .accessibilityLabel(Text("强调色 \(color.label)", bundle: ModuleBundle.bundle))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview {
    struct Demo: View {
        @State private var pick: AccentColor = .blue
        var body: some View {
            VStack(spacing: 20) {
                UDAccentSwatches(selection: $pick).padding(20).background(UD.panel)
                UDAccentSwatches(selection: $pick).padding(20).background(UD.panel)
                    .environment(\.colorScheme, .dark)
            }
        }
    }
    return Demo()
}
