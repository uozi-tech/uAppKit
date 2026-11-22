import SwiftUI

/// `/` 命令菜单里的一行（纯展示数据）。
public struct UDSlashMenuItem: Identifiable, Hashable, Sendable {
    public let id: String
    /// 命令名（不含 `/`）。
    public let trigger: String
    public let title: String
    public let subtitle: String
    public let systemImage: String

    public init(trigger: String, title: String, subtitle: String = "", systemImage: String = "command") {
        self.id = trigger
        self.trigger = trigger
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }
}

/// 输入区上方的 `/` 命令菜单（uTable AI 面板收编）：图标 + `/trigger` + 标题 + 副标题，
/// 高亮当前项。键盘（↑↓ ↩ esc）由宿主处理 —— 焦点在输入框里，菜单本身拿不到键。
///
/// 纯展示组件：过滤、高亮下标、选中回调都由调用方给。实体浮层底 + 发丝边，不用 popover。
public struct UDSlashMenu: View {
    let items: [UDSlashMenuItem]
    let selectedID: String?
    let maxHeight: CGFloat
    let onSelect: (UDSlashMenuItem) -> Void

    public init(items: [UDSlashMenuItem], selectedID: String?, maxHeight: CGFloat = 260,
                onSelect: @escaping (UDSlashMenuItem) -> Void) {
        self.items = items
        self.selectedID = selectedID
        self.maxHeight = maxHeight
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(items) { item in
                        row(item, selected: item.id == selectedID)
                            .id(item.id)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .background(RoundedRectangle(cornerRadius: UD.Radius.lg, style: .continuous).fill(UD.overlay))
        .overlay(RoundedRectangle(cornerRadius: UD.Radius.lg, style: .continuous).strokeBorder(UD.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: UD.Radius.lg, style: .continuous))
        .udShadow(.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "命令", bundle: .module, comment: "斜杠命令菜单的读屏标签"))
    }

    private func row(_ item: UDSlashMenuItem, selected: Bool) -> some View {
        Button { onSelect(item) } label: {
            HStack(spacing: 9) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? UD.accentInk : UD.text3)
                    .frame(width: 16)
                Text("/" + item.trigger)
                    .font(UD.mono(11.5, weight: .medium))
                    .foregroundStyle(UD.text)
                Text(item.title)
                    .font(UD.font(12))
                    .foregroundStyle(UD.text2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(UD.font(11))
                        .foregroundStyle(UD.text4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: UD.Radius.sm).fill(selected ? UD.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
