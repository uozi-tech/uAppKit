import SwiftUI

/// 限高内滚容器：内容矮于上限时贴内容高、不滚；超过上限钉在上限、纵向滚动。
///
/// 浮层里数据驱动的列表（会话、每核占用……）长度不可控，裸 `VStack` 会一路伸出屏幕。
/// 不直接 `ScrollView { … }.frame(maxHeight:)`：`maxHeight` 在实提案下会伸展到
/// `min(提案, 上限)` 而非贴内容，短列表被撑高、内容在 ScrollView 里垂直居中。
/// 所以实测内容高、钉 `min(实测, 上限)`；首帧未量到时才走 `maxHeight`（nil 提案按 ideal 收缩）。
struct UDCappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    @State private var measured: CGFloat?

    var body: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                    // 写回落到下一拍：同步写会让被约束的 ScrollView 实测依赖自身（AttributeGraph 环）。
                    guard measured.map({ abs($0 - h) > 0.5 }) ?? true else { return }
                    DispatchQueue.main.async {
                        guard measured.map({ abs($0 - h) > 0.5 }) ?? true else { return }
                        measured = h
                    }
                }
        }
        .scrollIndicators((measured ?? 0) > maxHeight ? .automatic : .never)
        .scrollBounceBehavior(.basedOnSize)
        .modifier(UDHeightClamp(measured: measured, cap: maxHeight))
    }
}

/// ScrollView 高度钉法：量到内容高后钉 `min(内容高, 上限)`；首帧未量到走 `maxHeight`。
struct UDHeightClamp: ViewModifier {
    let measured: CGFloat?
    let cap: CGFloat

    func body(content: Content) -> some View {
        if let measured {
            content.frame(height: min(measured, cap))
        } else {
            content.frame(maxHeight: cap)
        }
    }
}
