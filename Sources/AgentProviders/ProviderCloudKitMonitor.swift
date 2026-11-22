import CloudKit
import CoreData
import Foundation
import Observation

/// 把 CloudKit 的一次失败翻成用户看得懂、可测试的诊断。由 uTable `UTermCloudKitFailure` 泛化而来。
///
/// `ModelContainer` 建成功只代表本地 store 可用；CloudKit setup 可能随后异步失败。
public struct CloudKitSyncFailure: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case serviceUnavailable
        case networkUnavailable
        case notAuthenticated
        /// 当前构建无权访问该容器（entitlements / profile 没带上）。
        case noPermission
        case busy
        case other(String)
    }

    public let reason: Reason
    public let retryAfter: TimeInterval?
    public let retryNotBefore: Date?
    /// setup 阶段的可重试失败要重建容器，才会重新触发 CloudKit setup。
    public let shouldRecreateContainer: Bool

    public init(reason: Reason, retryAfter: TimeInterval?, retryNotBefore: Date?, shouldRecreateContainer: Bool) {
        self.reason = reason
        self.retryAfter = retryAfter
        self.retryNotBefore = retryNotBefore
        self.shouldRecreateContainer = shouldRecreateContainer
    }

    public static func make(error: Error, eventKind: CloudKitEventSnapshot.Kind, endedAt: Date) -> Self {
        let nsError = error as NSError
        let ckCode = nsError.domain == CKErrorDomain ? CKError.Code(rawValue: nsError.code) : nil
        let retryAfter = (error as? CKError)?.retryAfterSeconds
            ?? (nsError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue

        let reason: Reason
        switch ckCode {
        case .serviceUnavailable: reason = .serviceUnavailable
        case .networkUnavailable, .networkFailure: reason = .networkUnavailable
        case .notAuthenticated: reason = .notAuthenticated
        case .permissionFailure, .badContainer: reason = .noPermission
        case .requestRateLimited, .zoneBusy: reason = .busy
        default: reason = .other(nsError.localizedDescription)
        }
        return Self(
            reason: reason,
            retryAfter: retryAfter,
            retryNotBefore: retryAfter.map { endedAt.addingTimeInterval(max(0, $0)) },
            shouldRecreateContainer: eventKind == .setup && retryAfter != nil)
    }

    /// 缺省说明（经 String Catalog 本地化），如「iCloud 同步失败：当前网络无法访问 CloudKit（约 30 秒后自动重试）」。
    public var message: String {
        let text: String
        switch reason {
        case .serviceUnavailable: text = String(localized: "CloudKit 服务连接中断", bundle: .module)
        case .networkUnavailable: text = String(localized: "当前网络无法访问 CloudKit", bundle: .module)
        case .notAuthenticated: text = String(localized: "iCloud 账号不可用，请先在系统设置中登录 iCloud", bundle: .module)
        case .noPermission: text = String(localized: "当前构建无权访问共享 iCloud 容器", bundle: .module)
        case .busy: text = String(localized: "CloudKit 当前繁忙", bundle: .module)
        case .other(let description): text = description
        }
        let suffix = retryAfter.map { delay in
            let seconds = max(1, Int(ceil(delay)))
            return String(localized: "（约 \(seconds) 秒后自动重试）", bundle: .module)
        } ?? ""
        return String(localized: "iCloud 同步失败：\(text)\(suffix)", bundle: .module)
    }
}

/// `NSPersistentCloudKitContainer.Event` 里监控需要的那几样，值类型、可在测试里直接构造。
public struct CloudKitEventSnapshot: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case setup, `import`, export, other }

    public let kind: Kind
    public let storeIdentifier: String
    public let startDate: Date
    /// nil = 事件还没结束（开始通知）。
    public let endDate: Date?
    public let succeeded: Bool
    /// 结束且失败时的诊断。
    public let failure: CloudKitSyncFailure?

    public init(kind: Kind, storeIdentifier: String, startDate: Date, endDate: Date?,
                succeeded: Bool, failure: CloudKitSyncFailure?) {
        self.kind = kind
        self.storeIdentifier = storeIdentifier
        self.startDate = startDate
        self.endDate = endDate
        self.succeeded = succeeded
        self.failure = failure
    }

    public init(_ event: NSPersistentCloudKitContainer.Event) {
        let kind: Kind
        switch event.type {
        case .setup: kind = .setup
        case .import: kind = .import
        case .export: kind = .export
        @unknown default: kind = .other
        }
        let failure: CloudKitSyncFailure? = if let endDate = event.endDate, !event.succeeded, let error = event.error {
            CloudKitSyncFailure.make(error: error, eventKind: kind, endedAt: endDate)
        } else {
            nil
        }
        self.init(kind: kind, storeIdentifier: event.storeIdentifier, startDate: event.startDate,
                  endDate: event.endDate, succeeded: event.succeeded, failure: failure)
    }
}

/// 共享 provider store 的 CloudKit 同步状态。由 uTable `UTermProfileReader` 的事件处理泛化而来。
///
/// 用途有二：设置页显示同步诊断；**迁移闸门** —— 导入旧数据之前要等共享 store 首次同步完成
/// （一次成功的 setup 之后再出现一次成功的 import），否则另一台设备早已迁过的 provider 还没
/// 下来，这里又导一遍，就成了两份。
///
/// 只认自己那个 store 的事件：`start(storeURL:)` 从 store 元数据读出它的标识
/// （`NSStoreUUIDKey`，即事件里的 `storeIdentifier`）。同一进程里 app 往往还有别的 CloudKit
/// 容器在同步，按时间窗口认领 setup 事件会认错；元数据读不到时才退回按时间认领。
@MainActor
@Observable
public final class ProviderCloudKitMonitor {
    public enum Status: Equatable, Sendable {
        case notStarted
        /// 已开始监听，等 setup 完成。
        case settingUp
        /// setup 成功，等第一次 import。
        case waitingForFirstImport
        case ready
        case failed(CloudKitSyncFailure)
    }

    public private(set) var status: Status = .notStarted
    public private(set) var lastImportAt: Date?
    /// 最近一次失败；之后任何成功事件都会清掉它。
    public private(set) var failure: CloudKitSyncFailure?

    /// 一次成功的 setup 之后又出现过一次成功的 import：可以开始迁移旧数据了。
    public var isReadyForMigration: Bool { setupSucceeded && importSucceeded }

    @ObservationIgnored private var setupSucceeded = false
    @ObservationIgnored private var importSucceeded = false
    @ObservationIgnored private var storeIdentifier: String?
    @ObservationIgnored private var setupStartedAt: Date?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let now: () -> Date

    public init(notificationCenter: NotificationCenter = .default, now: @escaping () -> Date = Date.init) {
        self.notificationCenter = notificationCenter
        self.now = now
    }

    /// 开始监听。在建容器**之前**调用，才收得到 setup 事件。
    /// - Parameter storeURL: store 文件地址；能读到元数据时据此只认这个 store 的事件。
    ///   第一次启动时文件还不存在，建完容器后再调 `bind(storeURL:)` 补上。
    public func start(storeURL: URL? = nil) {
        setupStartedAt = now()
        if let storeURL { bind(storeURL: storeURL) }
        if status == .notStarted { status = .settingUp }
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            let snapshot = CloudKitEventSnapshot(event)
            MainActor.assumeIsolated { self?.handle(snapshot) }
        }
    }

    /// 从 store 元数据读出标识，此后只认这个 store 的事件。
    public func bind(storeURL: URL) {
        guard storeIdentifier == nil,
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                  ofType: NSSQLiteStoreType, at: storeURL, options: nil),
              let identifier = metadata[NSStoreUUIDKey] as? String
        else { return }
        storeIdentifier = identifier
    }

    /// 直接指定 store 标识（测试用）。
    public func bind(storeIdentifier: String) {
        self.storeIdentifier = storeIdentifier
    }

    public func stop() {
        if let observer { notificationCenter.removeObserver(observer) }
        observer = nil
    }

    /// 处理一个事件。通知回调走这里；测试直接喂 `CloudKitEventSnapshot`。
    public func handle(_ event: CloudKitEventSnapshot) {
        guard isOwnEvent(event), event.endDate != nil else { return }
        if event.succeeded {
            failure = nil
            switch event.kind {
            case .setup:
                setupSucceeded = true
            case .import:
                // import 只在 setup 成功之后才作数（首次同步的完成标志是「setup → import」）。
                if setupSucceeded {
                    importSucceeded = true
                    lastImportAt = event.endDate
                }
            case .export, .other:
                break
            }
            status = isReadyForMigration ? .ready : (setupSucceeded ? .waitingForFirstImport : .settingUp)
            if isReadyForMigration { resumeWaiters() }
            return
        }
        let failure = event.failure ?? CloudKitSyncFailure(
            reason: .other(String(localized: "未知错误", bundle: .module)), retryAfter: nil, retryNotBefore: nil, shouldRecreateContainer: false)
        self.failure = failure
        status = .failed(failure)
    }

    /// 等首次同步完成（见 `isReadyForMigration`）。超时返回 false。
    public func waitUntilReadyForMigration(timeout: Duration) async -> Bool {
        if isReadyForMigration { return true }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resumeWaiters()
        }
        await withCheckedContinuation { readyWaiters.append($0) }
        timeoutTask.cancel()
        return isReadyForMigration
    }

    /// 离 CloudKit 给的 retry-after 还剩多久；没有就是 0。
    public var retryDelayFromNow: TimeInterval {
        guard let retryNotBefore = failure?.retryNotBefore else { return 0 }
        return max(0, retryNotBefore.timeIntervalSince(now()))
    }

    /// setup 的可重试失败需要重建容器。返回 true 时调用方应丢掉旧容器、重建一个
    /// （本监控随之重新认领 setup）。
    public func prepareForRetryIfNeeded() -> Bool {
        guard failure?.shouldRecreateContainer == true else { return false }
        failure = nil
        setupSucceeded = false
        importSucceeded = false
        storeIdentifier = nil
        setupStartedAt = now()
        status = .settingUp
        return true
    }

    // MARK: - 私有

    private func isOwnEvent(_ event: CloudKitEventSnapshot) -> Bool {
        if let storeIdentifier { return event.storeIdentifier == storeIdentifier }
        // 没拿到元数据：认领监听开始后启动的第一个 setup 事件。
        guard event.kind == .setup, let setupStartedAt,
              event.startDate >= setupStartedAt.addingTimeInterval(-1) else { return false }
        storeIdentifier = event.storeIdentifier
        return true
    }

    private func resumeWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
