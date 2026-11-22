// 输入框（`UDTextField`）是 AppKit 专属组件，表单随之只在 macOS 上提供。
#if os(macOS)
import SwiftUI
import UDesignKit

/// 最小的 provider 编辑表单：名称、类型、Base URL、API Key（保存 / 移除）、测试连接。
///
/// 只用 UDesignKit 现有控件拼出来（`UDTextField` / `UDSegmented` / `UDButton`）。设置页原语
/// （分区、行、说明文字）正在另一条线上进 UDesignKit，届时这里换成那套样式；在此之前 app 可以
/// 直接用 `ProviderEditorModel` + `ProviderDraft` 自己排版。
///
/// 表单不写库：`onSave` 拿到校验过的 `ProviderDraft`，由调用方写进 `ProviderStore`。
public struct ProviderEditorForm: View {
    @Bindable var model: ProviderEditorModel
    let requiresAPIKey: Bool
    let onSave: (ProviderDraft) -> Void

    public init(model: ProviderEditorModel, requiresAPIKey: Bool = true,
                onSave: @escaping (ProviderDraft) -> Void) {
        self.model = model
        self.requiresAPIKey = requiresAPIKey
        self.onSave = onSave
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            UDTextField(label: String(localized: "名称", bundle: .module), placeholder: String(localized: "例如 Anthropic", bundle: .module), text: $model.draft.name,
                        errorMessage: model.draft.nameError)

            VStack(alignment: .leading, spacing: 6) {
                Text("类型", bundle: .module, comment: "模型服务的协议类型").font(UD.font(11.5, weight: .medium)).foregroundStyle(UD.text2)
                UDSegmented(selection: Binding(get: { model.draft.kind }, set: { model.draft.setKind($0) }),
                            options: ProviderKind.allCases.map { ($0, $0.displayName) })
            }

            UDTextField(label: "Base URL", placeholder: model.draft.kind.defaultBaseURL,
                        text: $model.draft.baseURL, errorMessage: model.draft.baseURLError, monospaced: true)

            VStack(alignment: .leading, spacing: 8) {
                UDTextField(label: "API Key",
                            placeholder: model.hasSavedKey ? String(localized: "已保存（留空不改）", bundle: .module) : String(localized: "粘贴 API Key", bundle: .module),
                            text: $model.keyDraft, errorMessage: model.keySaveError,
                            monospaced: true, isSecure: true, revealable: true)
                HStack(spacing: 8) {
                    UDButton(title: String(localized: "保存 Key", bundle: .module), style: .secondary) { model.saveKey() }
                        .disabled(!model.canSaveKey)
                    if model.hasSavedKey {
                        UDButton(title: String(localized: "移除 Key", bundle: .module), style: .ghost) { model.removeKey() }
                    }
                    Spacer(minLength: 0)
                    UDButton(title: model.testInFlight ? String(localized: "测试中…", bundle: .module) : String(localized: "测试连接", bundle: .module), style: .secondary,
                             isLoading: model.testInFlight) {
                        Task { await model.testConnection(requiresAPIKey: requiresAPIKey) }
                    }
                }
                if let result = model.testResult {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(UD.font(11.5))
                        .foregroundStyle(result.ok ? UD.success : UD.danger)
                }
            }

            HStack {
                Spacer(minLength: 0)
                UDButton(title: String(localized: "保存", bundle: .module)) { onSave(model.draft) }
                    .disabled(!model.draft.isValid)
            }
        }
    }
}
#endif
