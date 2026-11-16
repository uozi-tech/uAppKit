// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

/// 「这件事还在往前走」的脉冲：长 I/O 每前进一步（一个 SFTP 回包、一块命令输出、一段落盘）
/// 就 `touch()` 一次，`ControlSocketServer` 的监督定时器据此判断 handler **静默了多久**，
/// 而不是**跑了多久**。
///
/// 用 `@TaskLocal` 而不是层层传闭包：脉冲点往往在与 IPC 毫无关系的底层（GUI 也走的 SFTP
/// 管线），挂在任务上下文里就不用给每个签名加参数；子任务（TaskGroup、`Task {}`）自动继承。
/// 没人设置时 `touch()` 是空操作。`Task.detached` 与 NIO 回调不继承 task-local，脉冲点要放在
/// async 调用链上。
///
/// **整个进程只能有这一个来源。** 服务端只读这一个 TaskLocal；若 app 里另有一个同类 TaskLocal
/// （例如 uTerm 现有的 `IOActivity`），底层打在那边的点服务端看不见，长传输就会被误判为空闲
/// 而超时。所以 app 接入时要把自己的那个改成本类型的别名（`typealias IOActivity = ControlActivity`），
/// 而不是转发 —— 别名下 `IOActivity.touch()`、`IOActivity.$pulse.withValue` 原样可用，
/// 两个名字指向同一个存储，不可能分叉。
public enum ControlActivity {
    @TaskLocal public static var pulse: (@Sendable () -> Void)?

    public static func touch() {
        pulse?()
    }
}

#endif
