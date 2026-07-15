import SwiftUI

/// uTerm DesignKit 折叠区头 —— 可展开分区/分组的标题行。
///
/// 前导「chevron.right」随 `isExpanded` 旋转 90°，可选前导 SF 图标 + 标题，可选计数靠行尾，
/// 整行 30 高、hover 提 `UD.rowHover`、点击切换 `isExpanded`。用于「已保存查询」等
/// 可折叠分区头。**注意**：带特殊手势（chevron 独立点击 vs 整行打开）或行内展开的
/// 数据树行（schema `row`）属核心导航复合交互，仍应保留 bespoke，不套此组件。
///
/// 纯展示组件，只读 `UD` token + `Bool` 绑定，不依赖任何 domain model。
public struct UDDisclosureHeader: View {
    let label: String
    @Binding var isExpanded: Bool
    var systemImage: String? = nil
    var count: Int? = nil

    @State private var hovering = false

    public init(label: String, isExpanded: Binding<Bool>, systemImage: String? = nil, count: Int? = nil) {
        self.label = label
        self._isExpanded = isExpanded
        self.systemImage = systemImage
        self.count = count
    }

    public var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(UD.text4)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.12), value: isExpanded)
                    .frame(width: 12)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11)).foregroundStyle(UD.text3)
                }
                Text(label)
                    .font(UD.font(12.5, weight: .medium))
                    .foregroundStyle(UD.text2)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)").font(UD.mono(10)).foregroundStyle(UD.text4)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? UD.rowHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Preview

#Preview {
    struct Demo: View {
        @State private var a = true
        @State private var b = false
        var body: some View {
            VStack(spacing: 2) {
                UDDisclosureHeader(label: "已保存查询", isExpanded: $a, systemImage: "bookmark", count: 7)
                UDDisclosureHeader(label: "视图", isExpanded: $b, count: 3)
            }
            .padding(12).frame(width: 260).background(UD.card)
        }
    }
    return HStack(spacing: 0) {
        Demo().environment(\.colorScheme, .dark)
        Demo().environment(\.colorScheme, .light)
    }
}
