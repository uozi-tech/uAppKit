// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Foundation
import Observation
import ServiceManagement

/// 后台服务的两个开关：登录后在后台启动（`SMAppService.loginItem`）、允许命令行客户端按需启动。
///
/// defaults key 都已随 app 发过版（`background.launchAtLogin`、`background.allowOnDemandLaunch`），
/// 值类型（Bool）与以前逐字节一致。登录项 identifier 也由调用方传入（如 `com.uozi.uTable.BackgroundLauncher`），
/// 对应包内 `Contents/Library/LoginItems/<launcher>.app` 的 bundle id。
///
/// 「登录后启动」不以 defaults 为准：系统设置里随时能关，所以每次都从 `SMAppService` 读真实状态，
/// defaults 只是镜像（给客户端脚本读）。
@MainActor
@Observable
public final class BackgroundServiceSettings {
    public enum LoginItemStatus: Equatable, Sendable {
        case notRegistered, enabled, requiresApproval, notFound
    }

    /// 登录项的系统接口，测试注入桩。
    @MainActor
    public protocol LoginItemServicing: AnyObject {
        var status: LoginItemStatus { get }
        func register() throws
        func unregister() throws
    }

    private final class SystemLoginItemService: LoginItemServicing {
        private let service: SMAppService

        init(identifier: String) {
            service = SMAppService.loginItem(identifier: identifier)
        }

        var status: LoginItemStatus {
            switch service.status {
            case .notRegistered: .notRegistered
            case .enabled: .enabled
            case .requiresApproval: .requiresApproval
            case .notFound: .notFound
            @unknown default: .notFound
            }
        }

        func register() throws { try service.register() }
        func unregister() throws { try service.unregister() }
    }

    /// 已发版的 defaults key。
    public enum Keys {
        public static let launchAtLogin = "background.launchAtLogin"
        public static let allowOnDemandLaunch = "background.allowOnDemandLaunch"
    }

    /// 注册 / 注销登录项失败时 `loginItemError` 的前缀，后面接系统给的原因。
    public struct Messages: Sendable {
        public var enableFailedPrefix: String
        public var disableFailedPrefix: String

        public init(
            enableFailedPrefix: String = String(localized: "无法启用登录后台启动：", bundle: ModuleBundle.bundle),
            disableFailedPrefix: String = String(localized: "无法关闭登录后台启动：", bundle: ModuleBundle.bundle)
        ) {
            self.enableFailedPrefix = enableFailedPrefix
            self.disableFailedPrefix = disableFailedPrefix
        }
    }

    @ObservationIgnored public let loginItemIdentifier: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loginItemService: any LoginItemServicing
    @ObservationIgnored private let messages: Messages

    /// 系统里登录项当前是不是开着（含「等待批准」）。
    public private(set) var launchAtLogin: Bool
    public var allowOnDemandLaunch: Bool {
        didSet {
            guard allowOnDemandLaunch != oldValue else { return }
            defaults.set(allowOnDemandLaunch, forKey: Keys.allowOnDemandLaunch)
        }
    }
    /// 上一次注册 / 注销失败的原因（非持久化），设置页红字显示。
    public var loginItemError: String?
    public private(set) var loginItemStatus: LoginItemStatus = .notRegistered
    /// 系统设置里还没批准（「登录项与扩展」）。
    public var needsLoginItemApproval: Bool { loginItemStatus == .requiresApproval }

    public init(
        loginItemIdentifier: String,
        defaults: UserDefaults = .standard,
        loginItemService: (any LoginItemServicing)? = nil,
        messages: Messages = Messages()
    ) {
        self.loginItemIdentifier = loginItemIdentifier
        self.defaults = defaults
        self.loginItemService = loginItemService ?? SystemLoginItemService(identifier: loginItemIdentifier)
        self.messages = messages
        launchAtLogin = false
        allowOnDemandLaunch = defaults.object(forKey: Keys.allowOnDemandLaunch) as? Bool ?? false
        refreshLoginItemStatus()
    }

    public func setLaunchAtLogin(_ requested: Bool) {
        guard requested != launchAtLogin else {
            refreshLoginItemStatus()
            return
        }
        loginItemError = nil
        do {
            if requested {
                try loginItemService.register()
            } else if loginItemService.status != .notRegistered {
                try loginItemService.unregister()
            }
        } catch {
            loginItemError = (requested ? messages.enableFailedPrefix : messages.disableFailedPrefix)
                + error.localizedDescription
        }
        refreshLoginItemStatus(preserveError: true)
    }

    /// 从系统读一次真实状态（设置页出现、app 回到前台时调）。
    public func refreshLoginItemStatus(preserveError: Bool = false) {
        loginItemStatus = loginItemService.status
        launchAtLogin = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        if !preserveError { loginItemError = nil }
    }
}

#endif
