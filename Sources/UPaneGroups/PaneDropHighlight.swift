#if os(macOS)
import SwiftUI
import UDesignKit

/// 拖拽悬停时叠在目标组上的投放区提示。区域划分与 `paneDropZone` 对应。
/// center 除描边外还带 6% 填充 —— 只描边时「并入这一组」看起来像没选中。
public struct PaneDropHighlight: View {
    public let zone: PaneDropZone
    public var color: Color

    public init(zone: PaneDropZone, color: Color? = nil) {
        self.zone = zone
        self.color = color ?? UD.accent
    }

    public var body: some View {
        GeometryReader { geo in
            let thickness: CGFloat = 4
            switch zone {
            case .center:
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(color, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.06)))
            case .top:
                VStack(spacing: 0) {
                    Rectangle().fill(color).frame(height: thickness)
                    Color.clear
                }
                .background(
                    Rectangle().fill(color.opacity(0.10))
                        .frame(height: geo.size.height / 2),
                    alignment: .top)
            case .bottom:
                VStack(spacing: 0) {
                    Color.clear
                    Rectangle().fill(color).frame(height: thickness)
                }
                .background(
                    Rectangle().fill(color.opacity(0.10))
                        .frame(height: geo.size.height / 2),
                    alignment: .bottom)
            case .leading:
                HStack(spacing: 0) {
                    Rectangle().fill(color).frame(width: thickness)
                    Color.clear
                }
                .background(
                    Rectangle().fill(color.opacity(0.10))
                        .frame(width: geo.size.width / 2),
                    alignment: .leading)
            case .trailing:
                HStack(spacing: 0) {
                    Color.clear
                    Rectangle().fill(color).frame(width: thickness)
                }
                .background(
                    Rectangle().fill(color.opacity(0.10))
                        .frame(width: geo.size.width / 2),
                    alignment: .trailing)
            }
        }
        .allowsHitTesting(false)
    }
}
#endif
