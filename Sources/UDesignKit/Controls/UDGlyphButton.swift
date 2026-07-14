import SwiftUI

/// uTerm DesignKit 自绘图标钮 —— `UDIconButton` 的 `UIconRef` 版。
///
/// `UDIconButton` 只吃 SF 符号；`UDGlyphButton` 吃 `UIconRef`（`.glyph` 品牌自绘 / `.sf` 通用），
/// 用于标题栏、导航、翻页等需要自绘品牌图标的图标钮（复刻 UTitleBarIconButton 语义并泛化）。
/// `active` → `tint` 填底（`activeFillOpacity`）+ tint 图标；hover → `UD.panelHover` + `UD.text`；
/// idle → `UD.text3`。宽高、图标尺寸、圆角可调。仅切底/图标色，无位移、无投影。
///
/// 依赖 DesignKit 内的 `UIconRef` / `UIconRefView`（同模块），不依赖任何 domain model。
public struct UDGlyphButton: View {
    let icon: UIconRef
    var width: CGFloat = 24
    var height: CGFloat = 22
    var iconSize: CGFloat = 13
    var radius: CGFloat = 6
    var active: Bool = false
    var tint: Color = UD.accentDefault
    var activeFillOpacity: Double = 0.14
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    public init(
        icon: UIconRef,
        width: CGFloat = 24,
        height: CGFloat = 22,
        iconSize: CGFloat = 13,
        radius: CGFloat = 6,
        active: Bool = false,
        tint: Color = UD.accentDefault,
        activeFillOpacity: Double = 0.14,
        help: String = "",
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.width = width
        self.height = height
        self.iconSize = iconSize
        self.radius = radius
        self.active = active
        self.tint = tint
        self.activeFillOpacity = activeFillOpacity
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            UIconRefView(icon, size: iconSize)
                .foregroundStyle(active ? tint : (hovering ? UD.text : UD.text3))
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(active ? tint.opacity(activeFillOpacity)
                                     : (hovering ? UD.panelHover : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Preview

#Preview {
    func demo(_ scheme: ColorScheme) -> some View {
        HStack(spacing: 8) {
            UDGlyphButton(icon: .sf("chevron.left.forwardslash.chevron.right"), help: "SQL") {}
            UDGlyphButton(icon: .sf("sparkles"), active: true, help: "AI") {}
            UDGlyphButton(icon: .sf("chevron.left"), width: 32, height: 32, help: "上一页") {}
            UDGlyphButton(icon: .sf("gearshape"), help: "设置") {}
        }
        .padding(20).background(UD.panel).environment(\.colorScheme, scheme)
    }
    return HStack(spacing: 0) { demo(.dark); demo(.light) }
}
