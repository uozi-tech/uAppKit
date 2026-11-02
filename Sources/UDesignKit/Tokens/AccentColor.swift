import SwiftUI
import Observation

/// 5 个可选强调色。每色提供 accent / hover / ink / soft / pressed 五槽位的深/浅 `UD.ColorSpec`。
/// `.blue` 取组件库调色板的主色三态（Ant Design 预设：深 #1668DC / #3C89E8 / #65A9F3，
/// 浅 #1677FF / #4096FF / #69B1FF）；其余从 base 派生。纯值类型，可单测。
/// hover / pressed 一律**向亮色**走（pressed 最亮），与调色板「base · hover · pressed 逐级变亮」一致。
public enum AccentColor: String, CaseIterable, Identifiable, Sendable {
    case blue, purple, green, orange, red
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .blue:   return "蓝"
        case .purple: return "紫"
        case .green:  return "绿"
        case .orange: return "橙"
        case .red:    return "红"
        }
    }

    public func base(dark: Bool) -> UD.ColorSpec {
        switch self {
        case .blue:   return dark ? .hex(0x1668DC) : .hex(0x1677FF)
        case .purple: return dark ? .hex(0xBF5AF2) : .hex(0xAF52DE)
        case .green:  return dark ? .hex(0x30D158) : .hex(0x34C759)
        case .orange: return dark ? .hex(0xFF9F0A) : .hex(0xFF8A00)
        case .red:    return dark ? .hex(0xFF5A5A) : .hex(0xFF3B30)
        }
    }

    public func accentSpec(dark: Bool) -> UD.ColorSpec { base(dark: dark) }

    /// 悬停色：调色板 hover（Ant 5 号色）。非蓝色向白混 18%，与蓝色两档的提亮幅度相当。
    public func hoverSpec(dark: Bool) -> UD.ColorSpec {
        if self == .blue { return dark ? .hex(0x3C89E8) : .hex(0x4096FF) }
        return base(dark: dark).mixedWithWhite(0.18)
    }

    /// 文字 / 图标用的强调色。日间即主色（调色板 accentInk = primary）；暗夜深底上主色偏暗，
    /// 文字取 hover 档提亮。
    public func inkSpec(dark: Bool) -> UD.ColorSpec {
        if self == .blue { return dark ? hoverSpec(dark: true) : base(dark: false) }
        return base(dark: dark).brightened(dark ? 1.22 : 0.84)
    }

    public func softSpec(dark: Bool) -> UD.ColorSpec {
        base(dark: dark).withAlpha(dark ? 0.10 : 0.12)
    }

    /// 按下色：调色板 pressed（Ant 4 号色，比 hover 更亮）。非蓝色向白混 36%。
    public func pressedSpec(dark: Bool) -> UD.ColorSpec {
        if self == .blue { return dark ? .hex(0x65A9F3) : .hex(0x69B1FF) }
        return base(dark: dark).mixedWithWhite(0.36)
    }
}

public extension UD.ColorSpec {
    /// 同色相、换 alpha。
    nonisolated func withAlpha(_ alpha: CGFloat) -> UD.ColorSpec { UD.ColorSpec(r: r, g: g, b: b, a: alpha) }
    /// 各分量乘 factor 并 clamp 到 0...1（factor>1 提亮 / <1 加深）。
    nonisolated func brightened(_ factor: CGFloat) -> UD.ColorSpec {
        func c(_ x: CGFloat) -> CGFloat { min(max(x * factor, 0), 1) }
        return UD.ColorSpec(r: c(r), g: c(g), b: c(b), a: a)
    }
    /// 向白色混合 t（0=原色，1=纯白）。
    nonisolated func mixedWithWhite(_ t: CGFloat) -> UD.ColorSpec {
        func mix(_ x: CGFloat) -> CGFloat { x * (1 - t) + t }
        return UD.ColorSpec(r: mix(r), g: mix(g), b: mix(b), a: a)
    }
    /// 向中性灰(0.5)收敛 t（0=原色，1=全灰）。
    nonisolated func desaturated(_ t: CGFloat) -> UD.ColorSpec {
        func mix(_ x: CGFloat) -> CGFloat { x * (1 - t) + 0.5 * t }
        return UD.ColorSpec(r: mix(r), g: mix(g), b: mix(b), a: a)
    }
}

/// 强调色的运行时真源。`@Observable` —— `UD.accent*` getter 同步读 `selected`，
/// SwiftUI body 求值期的访问被 Observation 追踪，故切色全局自动重渲染。
@MainActor @Observable public final class AccentState {
    public static let shared = AccentState()
    public static let key = "accentColor"

    @ObservationIgnored private let defaults: UserDefaults

    public var selected: AccentColor {
        didSet { defaults.set(selected.rawValue, forKey: AccentState.key) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selected = defaults.string(forKey: AccentState.key).flatMap(AccentColor.init) ?? .blue
    }
}

// Note: uTerm's `commandPaletteAccentItems()` (⌘K palette integration) was
// intentionally dropped in the uTable port — uTable has no command palette.
// Accent selection is driven directly through `AccentState.shared.selected`.
