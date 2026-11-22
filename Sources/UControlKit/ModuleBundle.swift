import Foundation

/// 本 target 的文案目录（`Localizable.xcstrings`）所在的 bundle。
///
/// 公开函数的默认参数会内联进调用方模块，不能直接写 internal 的 `Bundle.module`，
/// 所以默认参数里的文案走这里；函数体内照常写 `bundle: .module`。
@usableFromInline
enum ModuleBundle {
    @usableFromInline
    static var bundle: Bundle { .module }
}
