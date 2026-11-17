import SwiftUI

/// uTerm DesignKit 复选框 —— 设计稿 v2「填充即边界」勾选态。
///
/// `UDToggle` 是拨动开关（Switch 形态，两态等价的偏好项）；`UDCheckbox` 是方形勾选框，
/// 用于表单里的**布尔标志**（NOT NULL / 主键 / 唯一 / 自增 等）。16×16 连续圆角方块：
/// 未选 = `UD.uw08` 中性灰填充、**无描边**（填充即边界），hover 加深到 `UD.uw10`；
/// 选中 = `tint`（默认 `UD.accent`）实心填充 + 白色对勾（唯一允许实心 accent 的填充控件之一）。
/// 可选尾随文本标签，点击方块或标签均切换；仅切底色与勾，无位移、无投影。
///
/// `@Environment(\.isEnabled)` 响应 `.disabled()`：整体降透明 0.45 且不响应点击。
/// 纯展示组件，只读 `UD` token + `Bool` 绑定，不依赖任何 domain model。
public struct UDCheckbox: View {
    @Binding var isOn: Bool
    var title: String?
    /// 选中态方块填充色（默认 `UD.accent`）。
    var tint: Color
    /// 选中态方块内 SF 符号（默认对勾 `checkmark`；主键列传 `key.fill`）。
    var glyph: String
    /// 方块边长（默认 16；设计器列标志用 22）。
    var size: CGFloat
    /// 符号相对方块边长的缩放（默认 0.62）。`key.fill` 等实心符号视觉更「重」，需调小。
    var glyphScale: CGFloat
    /// 密集列表模式：去掉 `Button`、逐实例的 hover 跟踪与 `isOn` 隐式动画，
    /// 改成平铺 + `onTapGesture`，AX 语义手工补回。
    ///
    /// 成本随**同屏交互元件总数**超线性增长，不是「有没有 Button」：实测每行 1 个
    /// 元件（161 行档）与完全静态无差别，而表设计器宽表 150 列 × 5 个 = 750 个时，
    /// 3s / 8ms 心跳只剩 132 拍（理想 375），改 tap 后 246。所以**只在一行会出现
    /// 好几个、且行数上百的网格里开它**；表单里的单个复选框保持默认，hover 反馈值得留。
    /// 归因数据见 uTable 的 `DenseGridInteractionCostTests`。
    var dense: Bool

    /// 带文本标签——实参顺序对齐原生 `Toggle("标题", isOn:)`，迁移近乎逐字替换。
    public init(_ title: String, isOn: Binding<Bool>, tint: Color = UD.accentDefault,
         glyph: String = "checkmark", size: CGFloat = 16, glyphScale: CGFloat = 0.62,
         dense: Bool = false) {
        self.title = title
        self._isOn = isOn
        self.tint = tint
        self.glyph = glyph
        self.size = size
        self.glyphScale = glyphScale
        self.dense = dense
    }

    /// 纯方块（无标签，用于紧凑单元格 / 网格表头 / 列标志）。
    public init(isOn: Binding<Bool>, tint: Color = UD.accentDefault,
         glyph: String = "checkmark", size: CGFloat = 16, glyphScale: CGFloat = 0.62,
         dense: Bool = false) {
        self.title = nil
        self._isOn = isOn
        self.tint = tint
        self.glyph = glyph
        self.size = size
        self.glyphScale = glyphScale
        self.dense = dense
    }

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    public var body: some View {
        if dense {
            label
                .opacity(isEnabled ? 1 : 0.45)
                .allowsHitTesting(isEnabled)
                .onTapGesture { isOn.toggle() }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(title ?? ""))
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        } else {
            Button {
                isOn.toggle()
            } label: {
                label
            }
            .buttonStyle(.udPlain)
            .opacity(isEnabled ? 1 : 0.45)
            .allowsHitTesting(isEnabled)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isOn)
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            box
            if let title {
                Text(title)
                    .font(UD.font(13))
                    .foregroundStyle(UD.text)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - 方块

    private var box: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(isOn ? tint : (hovering && isEnabled ? UD.uw10 : UD.uw08))
            .frame(width: size, height: size)
            .overlay {
                if isOn {
                    Image(systemName: glyph)
                        .font(.system(size: size * glyphScale, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }
}

// MARK: - Preview

#Preview {
    struct Demo: View {
        @State private var notNull = true
        @State private var pk = false
        @State private var unique = false
        @State private var disOn = true
        @State private var disOff = false
        @State private var bare = true

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                UDCheckbox("NOT NULL", isOn: $notNull)
                UDCheckbox("主键 PRIMARY KEY", isOn: $pk)
                UDCheckbox("唯一 UNIQUE", isOn: $unique)
                UDCheckbox("禁用·选中", isOn: $disOn).disabled(true)
                UDCheckbox("禁用·未选", isOn: $disOff).disabled(true)

                Rectangle().fill(UD.border).frame(height: 1)

                HStack(spacing: 10) {
                    Text("纯方块")
                        .font(UD.caption).foregroundStyle(UD.text3)
                    UDCheckbox(isOn: $bare)
                    UDCheckbox(isOn: .constant(false))
                }
            }
            .padding(24)
            .frame(width: 300, alignment: .leading)
            .background(UD.bg)
        }
    }
    return HStack(spacing: 0) {
        Demo().environment(\.colorScheme, .dark)
        Demo().environment(\.colorScheme, .light)
    }
}
