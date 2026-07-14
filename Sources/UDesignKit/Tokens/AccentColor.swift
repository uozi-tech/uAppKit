import SwiftUI
import Observation

/// 5 个可选强调色。每色提供 accent / ink / soft / pressed 四槽位的深/浅 `UD.ColorSpec`。
/// `.blue` 返回现有手调常量（默认零回归）；其余从 base 派生。纯值类型，可单测。
/// 设计稿 `--u-accent` = iOS 蓝（浅 #007AFF / 深 #0A84FF），active tint = 该蓝 13–14%。
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
        case .blue:   return dark ? .hex(0x0A84FF) : .hex(0x007AFF)
        case .purple: return dark ? .hex(0xBF5AF2) : .hex(0xAF52DE)
        case .green:  return dark ? .hex(0x30D158) : .hex(0x34C759)
        case .orange: return dark ? .hex(0xFF9F0A) : .hex(0xFF8A00)
        case .red:    return dark ? .hex(0xFF5A5A) : .hex(0xFF3B30)
        }
    }

    public func accentSpec(dark: Bool) -> UD.ColorSpec { base(dark: dark) }

    public func inkSpec(dark: Bool) -> UD.ColorSpec {
        if self == .blue { return dark ? .hex(0x4DA3FF) : .hex(0x0067E0) }
        return base(dark: dark).brightened(dark ? 1.22 : 0.84)
    }

    public func softSpec(dark: Bool) -> UD.ColorSpec {
        base(dark: dark).withAlpha(dark ? 0.10 : 0.13)
    }

    public func pressedSpec(dark: Bool) -> UD.ColorSpec {
        if self == .blue { return dark ? .hex(0x96ACCD) : .hex(0x5A7099) }
        return base(dark: dark).desaturated(0.55)
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
