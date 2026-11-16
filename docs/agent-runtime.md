# 在 app 里接一个内置 agent

三个产品分工：

| 产品 | 管什么 |
|---|---|
| `AgentProviders` | 模型服务配置：共享的 `LLMProvider` 记录、API Key、模型目录、测试连接、旧数据导入 |
| `AgentRuntime` | agent 本身：工具、审批、循环、审计、会话持久化、`/` 命令、对模型服务的请求 |
| `AgentRuntimeUI` | 面板：`UDAgentPanel`（macOS），以及跨平台的行映射 `AgentTranscriptItems` |

UDesignKit 里的 `UDAgentTranscript` / `UDAgentApprovalCard` / `UDSlashMenu` / `UDAgentEmptyState` /
`UDAgentToolTrace` 是纯展示视图，不依赖 AgentKit，iOS 也能用。

app 要提供的只有：**工具及其 Context、system prompt、作用域 id、审批策略、`/` 命令表**。

---

## 1. Entitlements（先做，缺一不可）

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.uozi.shared</string>   <!-- 共享 provider 容器 -->
</array>
<key>com.apple.developer.icloud-services</key>
<array><string>CloudKit</string></array>
<key>com.apple.developer.icloud-container-environment</key>
<string>Production</string>                   <!-- 三个 app 都钉 Production -->
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.uozi.yourapp</string>   <!-- app 自己的组排第一 -->
    <string>$(AppIdentifierPrefix)com.uozi.shared</string>    <!-- 共享组不能排第一 -->
</array>
```

- 共享钥匙串组**不能排第一**：第一项是 app 所有未指定访问组的条目的默认写入组，排第一会改掉
  app 现有凭据的去向。
- 共享容器的 schema 必须**先**在 CloudKit Console 部署到 Production，**再**发第一个写它的版本。
- 不开沙盒的 app（uGit）同样需要这些 entitlement（Developer ID + 自动签名的 provisioning profile）。

## 2. Provider

```swift
import AgentProviders

let dir = try ProviderStoreContainer.applicationSupportDirectory(appDirectoryName: "uGit")
let monitor = ProviderCloudKitMonitor()
monitor.start(storeURL: dir.appendingPathComponent(ProviderStoreContainer.storeFileName))
let container = try ProviderStoreContainer.make(directory: dir)          // .shared；测试用 .none / makeInMemory()
monitor.bind(storeURL: dir.appendingPathComponent(ProviderStoreContainer.storeFileName))

let keychain = ProviderKeychain(accessGroup: "ABCDE12345.com.uozi.shared")
let providers = ProviderStore(context: container.mainContext, secrets: keychain)
```

- 读取一律按 id 去重（多设备 / 多 app 同时迁移会出现同 id 的两行），**不自动删重复行**；改动写到同 id 的每一行。
- 删除 provider 会连带删钥匙串里的 Key。
- **当前选中的 provider / 模型存在 app 本地**（`UserDefaults`），不要写进 `LLMProvider`：共享的话在一个
  app 里切模型会改掉另一个 app 的选择。`defaultModel` 只是提示。
- 模型目录：`AgentModelCatalog(describe: ProviderModelCatalog.describe)` 由 app 持有，打开模型下拉时
  `ProviderModelCatalog.refresh(catalog, providers: providers.snapshots(), secrets: keychain)`。
- 设置页：逻辑在 `ProviderDraft`（校验、换类型跟着换 Base URL）与 `ProviderEditorModel`（Key 保存、测试连接）；
  `ProviderEditorForm` 是只用现有 UDesignKit 控件拼的最小表单，设置页原语进 UDesignKit 后再换样式。

Base URL 约定：`openai` **带版本前缀**（`https://api.openai.com/v1`、`…/api/paas/v4`），`anthropic` 写根地址。

### 旧数据导入（不丢数据）

1. 等 `monitor.isReadyForMigration`（setup 成功之后又一次成功的 import），或
   `await monitor.waitUntilReadyForMigration(timeout:)`。否则另一台设备早已迁过的记录还没下来，这里又导一遍。
2. 用导入器（纯函数，读取方式注入）得到 `[ImportedProvider]`：
   - `ProviderImporters.importUTermAIProviders(records) { LegacyKeychainReader().genericPassword(service: "com.uozi.uTerm", account: $0.uuidString, useDataProtectionKeychain: …) }`
     —— openai 的根地址补 `/v1`，`model` 变成 `defaultModel`。
   - `ProviderImporters.importUTableProviders(defaultsData: defaults.data(forKey: "agent.providers")) { … }`
     —— `openAICompatible` → `openai`，Key 读 (`com.uozi.uTable`, `<uuid>__llmAPIKey`)，读不到回退 TablePro。
   - `ProviderImporters.importElectronUGitProviders(localStorageJSON:selection:) { LegacyKeychainReader().genericPassword(service: ProviderImporters.electronUGitKeychainService, account: $0) }`
     —— anthropic 去掉末尾 `/v1`；非 UUID 的旧 id 派生确定性 UUID；读文件型登录钥匙串**可能弹 ACL 授权框，先在 UI 上告知用户**。
     localStorage 的 JSON 要 app 自己从 Electron 版的 `Local Storage/leveldb` 里取出来。
3. 可选 `ProviderImporters.mergeDuplicates(imported, existing:)`：类型 + 归一化 Base URL + Key 哈希都相同的合并。
4. `providers.apply(imported)`：id 已存在的跳过，Key 只在缺失时写；**从不删除**旧记录或旧钥匙串条目。

## 3. 工具

```swift
import AgentRuntime

struct GitContext: Sendable { let repository: URL; let git: GitClient }

struct RunGitTool: AgentTool {
    var schema: AgentToolSchema {
        AgentToolSchema(name: "run_git", description: "…",
                        parametersJSON: #"{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"}},"reason":{"type":"string"}},"required":["args"]}"#)
    }
    func approvalRequirement(arguments: String) -> AgentToolApprovalRequirement {
        // 只读子命令由审批策略直接放行；写操作问用户，审批卡显示 `git push origin main` 这样的命令行。
        let args = decodeArgs(arguments)                        // app 自己解析参数 JSON
        return .ask(subject: args.map { "git " + ShellCommandApprovalPolicy.shellJoin($0) })
    }
    func run(arguments: String, context: GitContext) async throws -> AgentToolResult { … }
}
```

- `approvalRequirement(arguments:)` 按**这一次的参数**判断：`.none` 直接跑；`.ask(subject:)` 先过审批策略，
  策略说「问用户」再走审批门（`subject` 是审批卡正文，也是「本会话允许」的精确匹配依据）；
  `.alwaysManual` 跳过策略、每次都问、不接受「本会话允许」（强推、删分支、`reset --hard`）。
- 工具在 MainActor 之外跑（`run` 是 nonisolated async）；Context 必须 `Sendable`。
- 不开沙盒的 app：工具**必须**自己限定只能碰已管理的仓库路径——没有沙盒兜底。
- 参数里的 `reason` 字段会显示在审批卡上。

## 4. 审批

```swift
let approvals = AgentApprovalQueue()                                     // 面板据此画审批卡
let gate = InteractiveApprovalGate(presenter: approvals.presenter)        // 本会话放行列表只在这里
let policy = ShellCommandApprovalPolicy(toolNames: ["run_git"], commandPrefix: "git ",
                                        command: ShellCommandApprovalPolicy.argumentArray("args"))
```

- `ShellCommandApprovalPolicy` 包 AgentKit 的 `AgentToolApproval` 规则：确定性只读命令（含 git 的
  status / log / diff / show / blame / branch --list …）直接放行，硬规则命中的交给人，其余可选请 AI 审查
  （`review:` 传一个独立、无工具、有超时的模型请求）。参数数组经 `shellJoin` 按 sh 规则加引号后再判。
- 自定义策略实现 `AgentApprovalPolicy`，返回 `.allow` / `.deny(reason:)` / `.askUser(note:)`。
- 新对话 / 恢复历史时会话自动调 `gate.resetSession()` 清本会话放行列表。

## 5. 会话

```swift
let session = AgentRuntimeSession(
    provider: AgentLLMProviders.make(endpoint: provider.endpoint, apiKey: providers.apiKey(for: provider.id) ?? ""),
    model: selectedModel,
    tools: AgentToolRegistry(tools: [RunGitTool(), …]),
    environment: AgentTurnEnvironment { AgentTurnStep(systemPrompt: buildPrompt(), toolContext: currentContext()) },
    approvalGate: gate,
    approvalPolicy: policy,
    auditLog: AgentAuditLog(url: logsDir.appendingPathComponent("agent-audit.jsonl")))
session.reasoningProvider = { AgentReasoningPreferences.shared.request(providerID: provider.id,
                                                                        protocol: provider.kind.wireProtocol,
                                                                        model: selectedModel) }
```

- `environment.prepareStep` 每一步（每次请求模型之前）调一次：在这里取最新的仓库状态、选中文件。
- 换 provider / 模型 = 重建会话，再 `restore(messages:)` 接着聊。
- `submit` 忙碌时排队（↩ 整轮结束后发，⌘↩ 这一步跑完就并入）；`cancel` 停下并给没结果的调用补说明；
  最多 16 次模型请求；thinking 只在本轮回传；上下文压缩只作用于发出去的副本。
- 运行时协议叫 `AgentLLMProvider`（不叫 `LLMProvider`：那是共享 `@Model` 的实体名，CloudKit 只认类名）。

## 6. 持久化

```swift
// ChatSession / ChatMessageRecord 注册在 app 自己的容器里，不放进共享 provider 容器。
let chats = AgentChatStore(context: appContainer.mainContext)            // 缺省 ToolRowsTranscriptCodec
let scope = AgentChatStore.scopeID(for: repository.path)                  // 字符串 → 稳定 UUID
session.recorder = { [weak chats] message, display in chats?.record(message, display: display, scopeID: scope) }
if let restored = chats.reopenCurrent(scopeID: scope) {
    session.restore(messages: restored.messages, displayOverrides: restored.displayOverrides)
}
```

- 运行时不碰 `@Model`，经 `AgentTranscriptCodec` 读写；**不要改 `ChatSession` / `ChatMessageRecord` 的字段**
  （uTerm 的生产 CloudKit schema 依赖它们）。uTerm 那种「工具结果内嵌在 assistant 行」的形状自己写 codec，
  用 `.replaceLast` 改写最后一行。
- 会话惰性创建：首条 user 消息才建 `ChatSession`。

## 7. 面板

```swift
UDAgentPanel(session: session, approvals: approvals,
             text: UDAgentPanelText(placeholder: "问问这个仓库…", suggestions: ["总结最近 10 个提交"]),
             slashCommands: SlashCommandMatcher(commands: [SlashCommand(trigger: "review", title: "代码审查")]),
             onSlashCommand: { command, argument in .send(prompt: expand(command, argument), display: "/\(command.trigger) \(argument)") },
             message: { text, streaming in MarkdownView(text) },
             toolCard: { item in GitToolCard(item) }) {
    HStack { Spacer(); UDAgentHistoryMenu(store: chats, scopeID: scope, onSelect: …, onNew: …, onDelete: …) }
} toolbar: {
    UDComposerModelMenu(…)
}
```

- 消息流选 uTerm 的 `LazyVStack` + 渲染窗口（最多挂 200 行）+ 按「可滚高度」合并贴底，而不是 uTable 的
  非 lazy `VStack`：uTable 的问题是每次内容变化都 `scrollTo` 触发懒栈全量估高；这里贴底按 100ms 合并、
  只在可滚高度变大且原本贴底时补滚，挂载行数有上限，估高成本有界。窗口算术、贴底策略、合并器的单测从 uTerm
  移植到 `UDAgentTranscriptPolicyTests`；「窗口外的行不构造」有挂窗测试。uTerm 那组像素 / 帧心跳探针依赖它自己
  的探针设施，没有移植——两个 app 换用本面板时各自重跑性能探针。
- macOS 15 起贴底听 `onScrollGeometryChange` / `onScrollPhaseChange`；macOS 14 退回「行数变了就合并滚一次」。
- 键盘：↩ 发送，⌘↩ 忙碌时下一步送达，esc 停止；`/` 菜单开着时 ↑↓ / ↩ / Tab / esc（NSEvent 本地监听，
  输入法组字时放行）。
- 面板只在 macOS 提供（输入区、下拉、排队条带是 AppKit 专属组件）。
