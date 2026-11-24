import XCTest
@testable import USSHCore

final class USSHCoreSmokeTests: XCTestCase {
    func testModuleLoads() {
        _ = USSHCore.self
    }
}
