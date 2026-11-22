import XCTest
@testable import UDesignKit

/// 文案走的 bundle 要找得到本模块的资源 bundle：找不到时会退回 Bundle.main，界面只剩中文原文。
final class ModuleBundleTests: XCTestCase {
    func testLocatesResourceBundleAndItsTranslations() throws {
        let bundle = ModuleBundle.bundle
        XCTAssertEqual(bundle.bundleURL.lastPathComponent, "uAppKit_UDesignKit.bundle")
        let english = try XCTUnwrap(bundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(english.localizedString(forKey: "上传", value: nil, table: nil), "Upload")
    }
}
