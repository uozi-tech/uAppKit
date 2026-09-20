import SwiftUI

/// uTerm DesignKit 徽章原语合集 —— 小型标签 / 计数 / 状态点 / 键帽（设计稿
/// `Components.html` Badges & Keys）。
///
/// 纯展示组件：只读 `UD` token + 普通值输入，不依赖任何 domain model。
/// 一文件多原语，配合列表行 / 工具条 / 命令面板等场景拼装。

// MARK: - 分组芯片 GroupChip

/// 分组标签芯片（如「生产环境」「测试」）。v2：tint 14% / 中性 uw03 胶囊底，无边。
public struct UDGroupChip: View {
    let label: String
    let tint: Color?

    public init(_ label: String, tint: Color? = nil) {
        self.label = label
        self.tint = tint
    }

    public var body: some View {
        Text(label)
            .font(UD.caption)
            .foregroundStyle(textColor)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.xs, style: .continuous)
                    .fill(fillColor)
            )
    }

    private var textColor: Color {
        tint ?? UD.text3
    }

    private var fillColor: Color {
        tint?.opacity(0.14) ?? UD.uw03
    }
}

/// 可选择的分组标签芯片。用于表单里的分组快速填充。
/// v2：选中 = accent 14% 底 + accent 文字；未选 = uw03 灰底；均无描边。
public struct UDSelectableGroupChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    public init(label: String, selected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(label)
                .font(UD.caption)
                .foregroundStyle(selected ? UD.accent : UD.text3)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: UD.Radius.xs, style: .continuous)
                        .fill(selected ? UD.accentTint : UD.uw03)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 计数徽章 CountBadge

/// 计数小徽章（未读 / 数量）。`accent` 为高亮态（蓝软底）。
public struct UDCountBadge: View {
    let count: String
    let accent: Bool

    public init(_ count: String, accent: Bool = false) {
        self.count = count
        self.accent = accent
    }

    /// 便捷 `Int` 入口。
    public init(_ count: Int, accent: Bool = false) {
        self.init(String(count), accent: accent)
    }

    public var body: some View {
        // v2：accent 14% / 中性 uw03 胶囊底，无边。
        Text(count)
            .font(UD.mono(10.5))
            .foregroundStyle(accent ? UD.accent : UD.text2)
            .padding(.horizontal, 5)
            .frame(minWidth: 18)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accent ? UD.accentTint : UD.uw03)
            )
    }
}

// MARK: - 主机状态点 HostDot

/// 主机 / 端点状态点（Ø8）。`pulse` 时外圈呼吸光晕。
public struct UDHostDot: View {
    let color: Color
    let pulse: Bool

    public init(color: Color = UD.accentDefault, pulse: Bool = false) {
        self.color = color
        self.pulse = pulse
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size: CGFloat = 8

    public var body: some View {
        ZStack {
            // 光晕走 CA（见 `Motion/UDMotion.swift`），不用 SwiftUI `.repeatForever`：
            // 后者会把整个宿主窗口钉在满帧重绘上。视觉逐参数等价 —— 原实现是两层
            // `.opacity()` 相乘，峰值 0.18 × 0.18 = 0.0324。
            if pulse && !reduceMotion {
                UDPulseHalo(color: color, diameter: size + 4, peakOpacity: 0.18 * 0.18)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 键帽 Kbd

/// 单个键帽（如 ⌘ / K / esc）。v2：uw03 灰底胶囊、无边、无投影（拍平）。
public struct UDKbd: View {
    let label: String

    public init(_ label: String) {
        self.label = label
    }

    public var body: some View {
        Text(label)
            .font(UD.monoKbd)
            .foregroundStyle(UD.text2)
            .padding(.horizontal, 5)
            .frame(minWidth: 18)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.xs, style: .continuous)
                    .fill(UD.uw03)
            )
    }
}

// MARK: - 组合键 KeyCombo

/// 组合键序列（如 ⌘⇧N）。横排键帽。
public struct UDKeyCombo: View {
    let keys: [String]

    public init(_ keys: [String]) {
        self.keys = keys
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                UDKbd(key)
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: UD.Space.xxl) {
        HStack(spacing: UD.Space.md) {
            UDGroupChip("生产环境")
            UDSelectableGroupChip(label: "测试", selected: true) {}
            UDCountBadge(12)
            UDCountBadge(4, accent: true)
            UDCountBadge("99+")
        }
        HStack(spacing: UD.Space.lg) {
            UDHostDot()
            UDHostDot(pulse: true)
            UDHostDot(color: UD.success, pulse: true)
        }
        HStack(spacing: UD.Space.md) {
            UDKbd("⌘")
            UDKbd("K")
            UDKbd("↩")
            UDKbd("esc")
            UDKeyCombo(["⌘", "⇧", "N"])
        }
    }
    .padding(UD.Space.xxxl)
    .background(UD.bg)
}
