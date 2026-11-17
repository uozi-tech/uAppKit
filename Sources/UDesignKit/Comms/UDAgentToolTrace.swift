import SwiftUI

/// 通用工具调用的一行轨迹（uTable `ToolCallCard` + `ToolResultCard` 合并收编）：默认收起成
/// 「图标 工具名 参数预览 · 状态」一行，点头部展开看完整参数与结果。出错的结果默认展开。
///
/// 收起时无底色、展开才抬升：一轮对话常有好几条调用，条条带灰底会把面板铺成一片灰。
/// 结果展示截到 `displayCap` 字符（巨文本布局卡死的教训），模型收到的是全文。
///
/// 命令类工具（要「运行 / 跳过」的终端卡）用 `UDToolCall`；这里是其余工具的缺省卡。
/// 纯展示组件：不依赖 AgentKit。
public struct UDAgentToolTrace: View {
    public enum Status: Equatable, Sendable {
        /// 模型发起了，还没轮到 / 正在审批。
        case pending
        case running
        case done
        case failed
    }

    let name: String
    let arguments: String
    let result: String?
    let status: Status
    let resultLabel: (Int) -> String

    @State private var expanded: Bool

    public static let displayCap = 1200

    public init(name: String, arguments: String, result: String? = nil, status: Status,
                resultLabel: @escaping (Int) -> String = { "\($0) 字符" }) {
        self.name = name
        self.arguments = arguments
        self.result = result
        self.status = status
        self.resultLabel = resultLabel
        _expanded = State(initialValue: status == .failed)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                header.contentShape(Rectangle())
            }
            .buttonStyle(.udPlain)

            if expanded {
                if !arguments.isEmpty, arguments != "{}" {
                    Text(arguments)
                        .font(UD.mono(10.5))
                        .foregroundStyle(UD.text3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let result {
                    Text(Self.truncated(result))
                        .font(UD.mono(11))
                        .foregroundStyle(status == .failed ? UD.danger : UD.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, expanded ? 10 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UD.Radius.md).fill(expanded ? UD.panelHi : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: UD.Radius.md)
            .stroke(status == .failed ? Self.failedStroke : Color.clear, lineWidth: 1))
    }

    private static let failedStroke = UD.danger.opacity(0.4)

    private var header: some View {
        HStack(spacing: 6) {
            statusGlyph
            Text(name)
                .font(UD.mono(10.5, weight: .semibold))
                .foregroundStyle(status == .failed ? UD.danger : UD.text)
            if !expanded, !arguments.isEmpty, arguments != "{}" {
                Text(arguments)
                    .font(UD.mono(10))
                    .foregroundStyle(UD.text4)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let result {
                Text(resultLabel(result.count))
                    .font(UD.font(9.5))
                    .foregroundStyle(UD.text4)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(UD.text4)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed").font(.system(size: 10)).foregroundStyle(UD.text4)
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "wrench.and.screwdriver").font(.system(size: 10)).foregroundStyle(UD.info)
        case .failed:
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(UD.danger)
        }
    }

    static func truncated(_ content: String) -> String {
        guard content.count > displayCap else { return content }
        return String(content.prefix(displayCap)) + "\n… 已截断（全文 \(content.count) 字符，模型可见完整内容）"
    }
}
