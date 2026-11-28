// UDesignKit — Agent 待发队列条带（uTerm / uTable 共用）
#if os(macOS)
import SwiftUI

/// 条带里的一行：一条排了队、还没发出去的用户消息。
public struct UDAgentQueueItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    /// 已标成「下一步送达」：不打断在途回复，当前这一步跑完就并入会话。
    public let sendsAtNextStep: Bool

    public init(id: UUID, text: String, sendsAtNextStep: Bool = false) {
        self.id = id
        self.text = text
        self.sendsAtNextStep = sendsAtNextStep
    }
}

/// Agent 忙碌时排队的消息，贴在输入框上方的一个托盘里。
///
/// - **一个托盘、不描边**：整组共用一块浅底（填充即边界），行与行之间不画线也不各自成卡；
///   「还没发出」靠行首的时钟和偏淡的文字交代，不用虚线框。
/// - **整行可点 = 载回输入框编辑**；行尾三个动作：立即发送、编辑、移除。动作常显
///   （只在 hover 时才出现的按钮发现不了，读屏和键盘也够不着），不 hover 时压淡。
/// - **立即发送**不是打断：消息改成「下一步送达」，行首换成转向箭头并标注，按钮收起。
///   消费方不支持这条通道时不传 `onSendNow`，按钮不出现。
///
/// 纯展示组件：只读 `UD` token + 值 / 闭包输入。排队顺序与送达时机在
/// `AgentKit.AgentMessageQueue`，这里不关心。`items` 为空时不占位（连托盘一起不画）。
public struct UDAgentQueueStrip: View {
    let items: [UDAgentQueueItem]
    let onSendNow: ((UUID) -> Void)?
    let onEdit: (UUID) -> Void
    let onRemove: (UUID) -> Void

    public init(
        items: [UDAgentQueueItem],
        onSendNow: ((UUID) -> Void)? = nil,
        onEdit: @escaping (UUID) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) {
        self.items = items
        self.onSendNow = onSendNow
        self.onEdit = onEdit
        self.onRemove = onRemove
    }

    public var body: some View {
        if !items.isEmpty {
            VStack(spacing: 1) {
                ForEach(items) { item in
                    Row(item: item,
                        onSendNow: onSendNow.map { send in { send(item.id) } },
                        onEdit: { onEdit(item.id) },
                        onRemove: { onRemove(item.id) })
                }
            }
            .padding(UDAgentQueueLayout.trayInset)
            .background {
                RoundedRectangle(cornerRadius: UDAgentQueueLayout.trayRadius, style: .continuous)
                    .fill(UD.uw03)
            }
        }
    }
}

public enum UDAgentQueueLayout {
    public nonisolated static let rowHeight: CGFloat = 28
    public nonisolated static let trayInset: CGFloat = 3
    public nonisolated static let trayRadius: CGFloat = 10
    /// 行的圆角与托盘同心。
    public nonisolated static let rowRadius: CGFloat = trayRadius - trayInset
}

private struct Row: View {
    let item: UDAgentQueueItem
    let onSendNow: (() -> Void)?
    let onEdit: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    /// 已经是「下一步送达」的不再出按钮。
    private var sendNow: (() -> Void)? { item.sendsAtNextStep ? nil : onSendNow }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: UDAgentQueueLayout.rowRadius, style: .continuous)
        HStack(spacing: 7) {
            Image(systemName: item.sendsAtNextStep ? "arrow.turn.down.right" : "clock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(item.sendsAtNextStep ? UD.accentInk : UD.text4)
                .frame(width: 14)
            Text(item.text)
                .font(UD.font(12))
                .foregroundStyle(UD.text2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.sendsAtNextStep {
                Text("下一步送达", bundle: ModuleBundle.bundle)
                    .font(UD.font(10))
                    .foregroundStyle(UD.text4)
                    .fixedSize()
            }
            HStack(spacing: 0) {
                if let sendNow {
                    IconButton(systemImage: "arrow.up", label: String(localized: "立即发送", bundle: ModuleBundle.bundle),
                               help: String(localized: "立即发送：不打断当前回复，这一步跑完就送达", bundle: ModuleBundle.bundle),
                               dimmed: !hovering, action: sendNow)
                }
                IconButton(systemImage: "pencil", label: String(localized: "编辑", bundle: ModuleBundle.bundle), help: String(localized: "编辑", bundle: ModuleBundle.bundle),
                           dimmed: !hovering, action: onEdit)
                IconButton(systemImage: "xmark", label: String(localized: "移除", bundle: ModuleBundle.bundle), help: String(localized: "移除", bundle: ModuleBundle.bundle),
                           dimmed: !hovering, action: onRemove)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: UDAgentQueueLayout.rowHeight)
        .background { shape.fill(hovering ? UD.uw04 : .clear) }
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onEdit)
        // 整行可点（= 载入编辑），但 `onTapGesture` 对 AX 完全不可见：合成一个元素，
        // 显式给 label / isButton / 默认动作，并把行尾图标钮的语义保留成命名动作，
        // 读屏与全键盘控制才按得动。
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(String(localized: "排队消息：\(item.text)", bundle: ModuleBundle.bundle))
        .accessibilityValue(item.sendsAtNextStep ? String(localized: "下一步送达", bundle: ModuleBundle.bundle) : "")
        .accessibilityHint(String(localized: "点按载入到输入框编辑", bundle: ModuleBundle.bundle))
        .accessibilityAction(.default, onEdit)
        .accessibilityActions {
            if let sendNow { Button(String(localized: "立即发送", bundle: ModuleBundle.bundle), action: sendNow) }
            Button(String(localized: "编辑", bundle: ModuleBundle.bundle), action: onEdit)
            Button(String(localized: "移除", bundle: ModuleBundle.bundle), action: onRemove)
        }
    }
}

/// 行尾图标钮：20×20，静态无底；自己 hover 才出底。
private struct IconButton: View {
    let systemImage: String
    let label: String
    let help: String
    /// 所在行没被 hover：压淡，不和文字抢。
    let dimmed: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? UD.text : dimmed ? UD.text4 : UD.text3)
                .frame(width: 20, height: 20)
                .background { shape.fill(hovering ? UD.uw06 : .clear) }
                .contentShape(shape)
        }
        .buttonStyle(.udPlain)
        .onHover { hovering = $0 }
        .udHelp(help, accessibilityName: label)
    }
}
#endif
