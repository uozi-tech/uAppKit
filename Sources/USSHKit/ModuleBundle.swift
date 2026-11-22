import Foundation

/// 本 target 的文案目录（`Localizable.xcstrings`）所在的 bundle。所有文案都写 `bundle: ModuleBundle.bundle`，
/// 不写 `bundle: .module`：
///
/// - SwiftPM 生成的 `Bundle.module` 找不到资源 bundle 时直接 `fatalError`。它只找主程序的 Resources、
///   链着本模块的那个 framework 的 Resources、主程序所在目录三处；装在 App 里的辅助可执行文件
///   （如 `uTerm.app/Contents/Helpers/uterm-ssh`，经 framework 链本模块）三处都没有，一出错误提示就崩。
///   这里再往上找所在 `.app` 的 `Contents/Resources`，还找不到就退回 `Bundle.main`（显示中文原文，不崩）。
/// - 公开函数的默认参数会内联进调用方模块，不能写 internal 的 `Bundle.module`，这个是 `@usableFromInline` 的。
///
/// 八个 target 里的这份文件一字不差：bundle 名由 `#fileID` 里的模块名拼出来（`uAppKit_<模块>`）。
@usableFromInline
enum ModuleBundle {
    @usableFromInline
    nonisolated static let bundle: Bundle = locate()

    private final class Finder {}

    private static func locate() -> Bundle {
        let module = String("\(#fileID)".prefix { $0 != "/" })
        let name = "uAppKit_\(module).bundle"
        let framework = Bundle(for: Finder.self)
        var candidates: [URL?] = [
            Bundle.main.resourceURL,                            // 链进 App
            framework.resourceURL,                              // 链进 framework
            Bundle.main.bundleURL,                              // 命令行工具
            framework.bundleURL.deletingLastPathComponent(),    // swift test：和 .xctest 并排
        ]
        // 嵌在别的 App 里的辅助程序：往上找每一层 .app 的 Contents/Resources。
        var dir = Bundle.main.bundleURL
        while dir.pathComponents.count > 1 {
            if dir.pathExtension == "app" {
                candidates.append(dir.appendingPathComponent("Contents/Resources", isDirectory: true))
            }
            dir.deleteLastPathComponent()
        }
        for case let base? in candidates {
            if let bundle = Bundle(url: base.appendingPathComponent(name, isDirectory: true)) {
                return bundle
            }
        }
        return .main
    }
}
