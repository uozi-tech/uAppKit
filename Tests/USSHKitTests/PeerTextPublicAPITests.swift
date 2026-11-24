import XCTest
import USSHKit

/// app 把服务器原话（SFTP 状态消息、命令行接口的错误）拿去显示时用的是同一条规则，
/// 所以 `SSHPeerText.sanitize` 必须不靠 `@testable` 也能用。
final class PeerTextPublicAPITests: XCTestCase {
    func testSanitizeIsPublic() {
        XCTAssertEqual(SSHPeerText.sanitize("a\u{1B}[31mb\nc"), "a[31mb c")
        XCTAssertEqual(SSHPeerText.maximumLength, 300)
    }
}
