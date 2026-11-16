// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Foundation
import Observation

/// 命令行接口（本机 IPC）的两级门禁开关，持久化在 UserDefaults。
///
/// 两级都默认**关闭**。socket 虽然是 0600、只有本用户能连，但连上就等于拿到用户全部已保存
/// 连接 / 主机的操作能力，所以要用户在设置里明确开一次，而不是装了就通。
///
/// defaults key 都已随 app 发过版（`control.enabled`、uTable 的 `control.allowWrites`、uTerm 的
/// `control.allowMutations`），由调用方原样传入，存取的值类型（Bool）与以前逐字节一致。
@MainActor
@Observable
public final class ControlGateSettings {
    public struct Keys: Sendable, Hashable {
        /// 主开关。
        public var enabled: String
        /// 改动开关。
        public var allowMutations: String

        public init(enabled: String, allowMutations: String) {
            self.enabled = enabled
            self.allowMutations = allowMutations
        }
    }

    @ObservationIgnored public let keys: Keys
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var onChange: (@MainActor (ControlGateSettings) -> Void)?

    /// 主开关：关掉时 socket 不监听（并 unlink），`ping` 之外的一切请求都拒。
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: keys.enabled)
            onChange?(self)
        }
    }

    /// 改动开关：写入 / 执行类动作的总闸（见 `ControlGate.mutation`）。
    public var allowMutations: Bool {
        didSet {
            guard allowMutations != oldValue else { return }
            defaults.set(allowMutations, forKey: keys.allowMutations)
            onChange?(self)
        }
    }

    /// 服务端起不来的原因（非持久化），设置页红字显示。目前唯一来源是 socket 路径超过
    /// `sun_path` 上限（长用户名 + 沙盒容器路径）。接口关掉或起来了就清空。
    public var startupError: String?

    public init(keys: Keys, defaults: UserDefaults = .standard) {
        self.keys = keys
        self.defaults = defaults
        isEnabled = defaults.object(forKey: keys.enabled) as? Bool ?? false
        allowMutations = defaults.object(forKey: keys.allowMutations) as? Bool ?? false
    }

    /// 开关变化时回调（`ControlService` 用它起停服务端）。设置后立刻回调一次，
    /// 让服务端与当前持久化状态对齐。只有一个观察者，后设的覆盖先设的。
    public func observe(_ handler: @escaping @MainActor (ControlGateSettings) -> Void) {
        onChange = handler
        handler(self)
    }
}

#endif
