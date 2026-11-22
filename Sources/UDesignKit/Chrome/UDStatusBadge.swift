import SwiftUI

/// uTerm DesignKit 状态徽章 —— 连接状态胶囊（设计稿 `Components.html` StatusBadge）。
///
/// 纯展示组件：只读 `UD` token + 一个 `State` 入参，不依赖任何 domain model。
/// 已连接 / 连接中带呼吸光晕（pulse），已断开 / 连接失败为静态点。
public struct UDStatusBadge: View {
    /// 连接状态。决定点色、文案与是否呼吸。
    public enum State {
        case idle
        case connected
        case connecting
        case disconnected
        case failed

        /// 状态点 / 光晕颜色。
        var color: Color {
            switch self {
            case .idle:         return UD.text3
            case .connected:    return UD.success
            case .connecting:   return UD.warning
            case .disconnected: return UD.caution
            case .failed:       return UD.danger
            }
        }

        /// 显示文案（经 String Catalog 本地化）。
        var label: String {
            switch self {
            case .idle:         return String(localized: "未连接", bundle: ModuleBundle.bundle)
            case .connected:    return String(localized: "已连接", bundle: ModuleBundle.bundle)
            case .connecting:   return String(localized: "连接中", bundle: ModuleBundle.bundle)
            case .disconnected: return String(localized: "已断开", bundle: ModuleBundle.bundle)
            case .failed:       return String(localized: "连接失败", bundle: ModuleBundle.bundle)
            }
        }

        /// 是否呼吸（光晕脉冲）。
        var pulse: Bool {
            switch self {
            case .connected, .connecting:       return true
            case .idle, .disconnected, .failed: return false
            }
        }
    }

    let state: State

    public init(state: State) {
        self.state = state
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let dotSize: CGFloat = 7

    public var body: some View {
        HStack(spacing: UD.Space.xs) {
            dot
            Text(state.label)
                .font(UD.caption)
                .foregroundStyle(state == .idle ? UD.text2 : state.color)
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(
            // v2 状态徽标：语义色 14% 胶囊底、无边（idle 用中性 uw03）。
            Capsule()
                .fill(state == .idle ? UD.uw03 : state.color.opacity(0.14))
        )
    }

    private var dot: some View {
        ZStack {
            // 光晕走 CA（见 `Motion/UDMotion.swift`），不用 SwiftUI `.repeatForever`：
            // 后者会把整个宿主窗口钉在满帧重绘上。原实现两层 `.opacity()` 相乘，
            // 峰值 0.2 × 0.2 = 0.04。
            if state.pulse && !reduceMotion {
                UDPulseHalo(color: state.color, diameter: dotSize + 2, peakOpacity: 0.2 * 0.2)
            }
            Circle()
                .fill(state.color)
                .frame(width: dotSize, height: dotSize)
        }
        .frame(width: dotSize, height: dotSize)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: UD.Space.lg) {
        UDStatusBadge(state: .connected)
        UDStatusBadge(state: .connecting)
        UDStatusBadge(state: .disconnected)
        UDStatusBadge(state: .failed)
    }
    .padding(UD.Space.xxxl)
    .background(UD.bg)
}
