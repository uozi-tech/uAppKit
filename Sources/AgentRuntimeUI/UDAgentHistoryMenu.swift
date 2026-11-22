#if os(macOS)
import AgentKit
import AgentRuntime
import SwiftUI
import UDesignKit

/// 会话历史下拉：图标触发器 + 浮层（`UDDropdown`，不用 SwiftUI `Menu` / popover）。列出
/// `AgentChatStore.sessions(scopeID:)`，点一条恢复、行尾垃圾桶删除、底部「新建对话」。
///
/// 会话列表在浮层打开时现取，不常驻观察 SwiftData。恢复 / 新建 / 删除的副作用由调用方做
/// （通常是 `session.restore(…)` / `session.reset()` 配合 `store.startNewChat()`）。
public struct UDAgentHistoryMenu: View {
    let store: AgentChatStore
    let scopeID: UUID?
    let newTitle: String
    let emptyTitle: String
    let onSelect: (ChatSession) -> Void
    let onNew: () -> Void
    let onDelete: (ChatSession) -> Void

    public init(store: AgentChatStore, scopeID: UUID?, newTitle: String = String(localized: "新建对话", bundle: ModuleBundle.bundle),
                emptyTitle: String = String(localized: "还没有历史对话", bundle: ModuleBundle.bundle),
                onSelect: @escaping (ChatSession) -> Void,
                onNew: @escaping () -> Void,
                onDelete: @escaping (ChatSession) -> Void) {
        self.store = store
        self.scopeID = scopeID
        self.newTitle = newTitle
        self.emptyTitle = emptyTitle
        self.onSelect = onSelect
        self.onNew = onNew
        self.onDelete = onDelete
    }

    public var body: some View {
        UDDropdown(anchor: .trailing) { open in
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(open ? UD.text : UD.text3)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: UD.Radius.sm).fill(open ? UD.uw06 : Color.clear))
                .accessibilityLabel(String(localized: "历史对话", bundle: .module))
        } content: {
            HistoryList(store: store, scopeID: scopeID, newTitle: newTitle, emptyTitle: emptyTitle,
                        onSelect: onSelect, onNew: onNew, onDelete: onDelete)
        }
    }
}

private struct HistoryList: View {
    let store: AgentChatStore
    let scopeID: UUID?
    let newTitle: String
    let emptyTitle: String
    let onSelect: (ChatSession) -> Void
    let onNew: () -> Void
    let onDelete: (ChatSession) -> Void

    @Environment(\.udMenuDismiss) private var dismiss
    @State private var sessions: [ChatSession] = []

    var body: some View {
        VStack(spacing: 0) {
            if sessions.isEmpty {
                Text(emptyTitle)
                    .font(UD.font(12))
                    .foregroundStyle(UD.text3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(sessions, id: \.persistentModelID) { session in
                            row(session)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                onNew()
                dismiss()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 11))
                    Text(newTitle).font(UD.font(12))
                    Spacer()
                }
                .foregroundStyle(UD.text2)
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.udPlain)
            .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
        }
        .frame(width: 290)
        .background(UD.overlay)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1))
        // 不自带落影：`.anchoredPanel` 已给内容套了 `udShadow(.md)`。再叠一层时外层阴影连内层阴影一起投，
        // 拖到浮层下方 24pt 透明边之外被窗口裁成一条硬边灰块（uGit 助手面板「历史对话」下方的空白）。
        .onAppear { sessions = store.sessions(scopeID: scopeID, limit: 100) }
    }

    private func row(_ session: ChatSession) -> some View {
        let isActive = session.id == store.currentSession?.id
        return HStack(spacing: 6) {
            Button {
                onSelect(session)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(session.title.isEmpty ? String(localized: "新对话", bundle: .module, comment: "还没有标题的对话") : session.title)
                            .font(UD.font(12.5, weight: isActive ? .medium : .regular))
                            .foregroundStyle(isActive ? UD.text : UD.text2)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(UFormat.relative(session.updatedAt))
                            .font(UD.font(10))
                            .foregroundStyle(UD.text3)
                    }
                    if !session.preview.isEmpty {
                        Text(session.preview)
                            .font(UD.font(11))
                            .foregroundStyle(UD.text3)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.udPlain)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)

            Button {
                onDelete(session)
                sessions.removeAll { $0.id == session.id }
            } label: {
                Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(UD.text4)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.udPlain)
            .accessibilityLabel(String(localized: "删除对话", bundle: .module))
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: UD.Radius.sm).fill(isActive ? UD.accentSoft : Color.clear))
    }
}
#endif
