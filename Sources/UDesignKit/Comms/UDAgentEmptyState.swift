import SwiftUI

/// Agent 面板的空状态（uTerm `conversationEmptyState` / uTable 空状态收编）：图标块 + 标题 +
/// 说明，可选的能力标签行与「可以从这里开始」的起手提示，以及一个可选动作钮（如「打开设置」）。
///
/// 纯展示组件：文案、提示、回调都由调用方给。
public struct UDAgentEmptyState: View {
    public struct Capability: Identifiable, Hashable, Sendable {
        public let title: String
        public let systemImage: String
        public var id: String { title }

        public init(_ title: String, systemImage: String) {
            self.title = title
            self.systemImage = systemImage
        }
    }

    let systemImage: String
    let title: String
    let message: String
    let capabilities: [Capability]
    let suggestionsTitle: String
    let suggestions: [String]
    let actionTitle: String?
    let onSuggestion: (String) -> Void
    let onAction: () -> Void

    public init(
        systemImage: String = "sparkles",
        title: String,
        message: String,
        capabilities: [Capability] = [],
        suggestionsTitle: String = "可以从这里开始",
        suggestions: [String] = [],
        actionTitle: String? = nil,
        onSuggestion: @escaping (String) -> Void = { _ in },
        onAction: @escaping () -> Void = {}
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.capabilities = capabilities
        self.suggestionsTitle = suggestionsTitle
        self.suggestions = suggestions
        self.actionTitle = actionTitle
        self.onSuggestion = onSuggestion
        self.onAction = onAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UD.accentTint)
                    Image(systemName: systemImage)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(UD.accentInk)
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)

                Text(title)
                    .font(UD.font(16, weight: .semibold))
                    .foregroundStyle(UD.text)
                Text(message)
                    .font(UD.font(12.5))
                    .lineSpacing(3)
                    .foregroundStyle(UD.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !capabilities.isEmpty {
                HStack(spacing: 10) {
                    ForEach(capabilities) { capability in
                        VStack(spacing: 5) {
                            Image(systemName: capability.systemImage)
                                .font(.system(size: 11))
                                .foregroundStyle(UD.text3)
                            Text(capability.title)
                                .font(UD.font(9.5, weight: .medium))
                                .foregroundStyle(UD.text3)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(suggestionsTitle)
                        .font(UD.font(10.5, weight: .medium))
                        .foregroundStyle(UD.text4)
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button { onSuggestion(suggestion) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(UD.accentInk)
                                Text(suggestion)
                                    .font(UD.font(12))
                                    .foregroundStyle(UD.text2)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: UD.Radius.md).fill(UD.uw03))
                            .contentShape(RoundedRectangle(cornerRadius: UD.Radius.md))
                        }
                        .buttonStyle(.udPlain)
                    }
                }
            }

            if let actionTitle {
                UDButton(title: actionTitle, style: .secondary, action: onAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}
