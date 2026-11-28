// AppKit 专属组件：iOS 目标（uTermMobile 只消费 Tokens 层）整文件跳过。
#if os(macOS)
import SwiftUI

// MARK: - UDToolbar

/// 窗口工具栏条：左侧弹性、右侧固定的水平栏。
///
/// 高度 52、左右内边距 12、子项间距 10；底部 1px 边框；背景 `UD.panel`。
/// - `leading`：弹性占满剩余宽度（左对齐）。
/// - `trailing`：固定尺寸，贴右排布。
public struct UDToolbar<Leading: View, Trailing: View>: View {

    private let leading: Leading
    private let trailing: Trailing

    public init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(UD.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(UD.border)
                .frame(height: 1)
        }
    }
}

// MARK: - Standard variant

public extension UDToolbar where Leading == UDSearchField, Trailing == UDToolbarNewButton {

    /// 标准工具栏：左侧搜索框 + 右侧「新建」按钮。
    static func standard(
        text: Binding<String>,
        onNew: @escaping () -> Void
    ) -> UDToolbar {
        UDToolbar(
            leading: { UDSearchField(text: text) },
            trailing: { UDToolbarNewButton(onNew: onNew) }
        )
    }
}

// MARK: - Inline "新建" button

/// 内联「新建」按钮（不依赖 UDButton）。
public struct UDToolbarNewButton: View {

    let onNew: () -> Void

    public var body: some View {
        Button(action: onNew) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("新建", bundle: ModuleBundle.bundle)
            }
            .font(UD.control)
            .foregroundStyle(UD.accentInk)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background {
                // v2 tint 主按钮：accent 14% 底 + accent 色文字、无边。
                RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous)
                    .fill(UD.accentTint)
            }
        }
        .buttonStyle(.udPlain)
    }
}

// MARK: - Preview

#Preview {
    struct Demo: View {
        @State private var query = ""
        var body: some View {
            VStack(spacing: 0) {
                UDToolbar.standard(text: $query, onNew: {})
                Spacer()
            }
            .frame(width: 520, height: 220)
            .background(UD.bg)
        }
    }
    return Demo()
}
#endif
