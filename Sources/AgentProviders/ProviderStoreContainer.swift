import Foundation
import SwiftData

/// 共享 provider store 的 `ModelContainer` 工厂。
///
/// 每个 app 各开一个独立容器，store 文件放在**各自的** App Support 目录里（不进 app group：
/// 多个进程同时镜像同一个 store 文件不安全），靠 CloudKit 私有库 `iCloud.com.uozi.shared`
/// 互相同步。这个容器只放 `LLMProvider` 一个实体，与 app 自己的业务 store 并行、互不影响。
///
/// 前置条件（缺一不可）：
/// 1. entitlements 声明 iCloud 容器 `iCloud.com.uozi.shared`；
/// 2. `com.apple.developer.icloud-container-environment = Production`（三个 app 都钉在 Production，
///    否则各读各的空 Development 库）；
/// 3. CloudKit Console 已把 schema 部署到 Production —— **先部署、后发版**。
public enum ProviderStoreContainer {
    /// 共享 CloudKit 容器标识。
    public static let sharedCloudKitContainerID = "iCloud.com.uozi.shared"
    /// store 文件名（放在调用方给的目录里）。
    public static let storeFileName = "providers.store"
    /// `ModelConfiguration` 的名字。
    public static let configurationName = "providers"

    /// 镜像方式。
    public enum Sync: Sendable, Equatable {
        /// 镜像到 CloudKit 私有库。
        case cloudKit(containerID: String)
        /// 只存本机（测试、没有 iCloud 能力的构建、离线开发）。
        case none

        /// 生产用：镜像到 `iCloud.com.uozi.shared`。
        public static let shared = Sync.cloudKit(containerID: ProviderStoreContainer.sharedCloudKitContainerID)
    }

    public static let schema = Schema([LLMProvider.self])

    /// 建容器。
    /// - Parameters:
    ///   - directory: store 文件所在目录（通常是 `<App Support>/<App 名>`）；不存在会创建。
    ///   - sync: 默认镜像到共享容器。
    public static func make(directory: URL, sync: Sync = .shared) throws -> ModelContainer {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let database: ModelConfiguration.CloudKitDatabase
        switch sync {
        case .cloudKit(let containerID): database = .private(containerID)
        case .none: database = .none
        }
        let configuration = ModelConfiguration(
            configurationName,
            schema: schema,
            url: directory.appendingPathComponent(storeFileName),
            cloudKitDatabase: database
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// 纯内存容器（单测、预览）。不镜像。
    public static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            configurationName, schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// `~/Library/Application Support/<appDirectoryName>`（沙盒 app 是容器内的等价路径）。
    public static func applicationSupportDirectory(appDirectoryName: String) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return appSupport.appendingPathComponent(appDirectoryName, isDirectory: true)
    }
}
